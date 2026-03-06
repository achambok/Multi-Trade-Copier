use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

// ── Connection slot ──────────────────────────────────────────────────────────

struct Conn {
    stream: Mutex<TcpStream>,
    queue:  Arc<Mutex<VecDeque<Vec<u8>>>>,
    alive:  Arc<AtomicBool>,
}

fn slots() -> &'static Mutex<Vec<Option<Arc<Conn>>>> {
    static S: OnceLock<Mutex<Vec<Option<Arc<Conn>>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(vec![None, None, None, None]))
}

// ── MQTT packet builders ─────────────────────────────────────────────────────

fn encode_remaining(buf: &mut Vec<u8>, mut n: usize) {
    loop {
        let mut b = (n & 0x7f) as u8;
        n >>= 7;
        if n > 0 { b |= 0x80; }
        buf.push(b);
        if n == 0 { break; }
    }
}

fn mqtt_connect_packet(client_id: &str) -> Vec<u8> {
    let id = client_id.as_bytes();
    let remaining = 10 + 2 + id.len();
    let mut p = Vec::with_capacity(2 + remaining);
    p.push(0x10);
    encode_remaining(&mut p, remaining);
    p.extend_from_slice(&[0x00, 0x04, b'M', b'Q', b'T', b'T', 0x04, 0x02, 0x00, 0x3c]);
    p.push((id.len() >> 8) as u8);
    p.push((id.len() & 0xff) as u8);
    p.extend_from_slice(id);
    p
}

fn mqtt_subscribe_packet(topic: &str, packet_id: u16) -> Vec<u8> {
    let t = topic.as_bytes();
    let remaining = 2 + 2 + t.len() + 1;
    let mut p = Vec::with_capacity(2 + remaining);
    p.push(0x82);
    encode_remaining(&mut p, remaining);
    p.push((packet_id >> 8) as u8);
    p.push((packet_id & 0xff) as u8);
    p.push((t.len() >> 8) as u8);
    p.push((t.len() & 0xff) as u8);
    p.extend_from_slice(t);
    p.push(0x00); // QoS 0
    p
}

fn mqtt_pingreq() -> [u8; 2] { [0xc0, 0x00] }

// ── Receive thread ───────────────────────────────────────────────────────────

fn read_remaining_length(sock: &mut TcpStream) -> Option<usize> {
    let mut value = 0usize;
    let mut shift = 0usize;
    loop {
        let mut b = [0u8; 1];
        sock.read_exact(&mut b).ok()?;
        value |= ((b[0] & 0x7f) as usize) << shift;
        if b[0] & 0x80 == 0 { break; }
        shift += 7;
        if shift > 21 { return None; }
    }
    Some(value)
}

fn recv_thread(
    mut sock:  TcpStream,
    queue:     Arc<Mutex<VecDeque<Vec<u8>>>>,
    alive:     Arc<AtomicBool>,
) {
    let _ = sock.set_read_timeout(Some(Duration::from_millis(100)));
    let mut last_ping = Instant::now();

    while alive.load(Ordering::Relaxed) {
        if last_ping.elapsed() >= Duration::from_secs(45) {
            if sock.write_all(&mqtt_pingreq()).is_err() { break; }
            last_ping = Instant::now();
        }

        let mut hdr = [0u8; 1];
        match sock.read_exact(&mut hdr) {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock
                   || e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(_) => break,
            Ok(_)  => {}
        }

        let remaining = match read_remaining_length(&mut sock) {
            Some(n) => n,
            None    => break,
        };

        let mut body = vec![0u8; remaining];
        if remaining > 0 && sock.read_exact(&mut body).is_err() { break; }

        if hdr[0] >> 4 == 3 {
            // PUBLISH: 2-byte topic length, then topic, then payload
            if body.len() < 2 { continue; }
            let topic_len = ((body[0] as usize) << 8) | body[1] as usize;
            let payload_start = 2 + topic_len;
            if body.len() < payload_start { continue; }
            let payload = body[payload_start..].to_vec();
            if let Ok(mut q) = queue.lock() {
                if q.len() < 64 { q.push_back(payload); }
            }
        }
        // All other packet types (CONNACK, SUBACK, PINGRESP) are silently discarded
    }

    alive.store(false, Ordering::Relaxed);
}

// ── String helper (MQL4 passes `string` params as UTF-16 wchar_t*) ───────────

unsafe fn wstr_to_string(ptr: *const u16) -> String {
    if ptr.is_null() { return String::new(); }
    let mut len = 0usize;
    while *ptr.add(len) != 0 { len += 1; }
    String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len)).to_string()
}

// ── Exported API ─────────────────────────────────────────────────────────────

/// Connect to broker, perform MQTT handshake, start recv thread.
/// Returns handle 0–3 on success, -1 on any failure.
#[no_mangle]
pub unsafe extern "C" fn MQTT_Connect(
    host:      *const u16,
    port:      i32,
    client_id: *const u16,
) -> i32 {
    let host_s = wstr_to_string(host);
    let cid_s  = wstr_to_string(client_id);
    let addr   = format!("{}:{}", host_s, port);

    let sa: std::net::SocketAddr = match addr.parse() {
        Ok(a)  => a,
        Err(_) => return -1,
    };
    let stream = match TcpStream::connect_timeout(&sa, Duration::from_secs(5)) {
        Ok(s)  => s,
        Err(_) => return -1,
    };
    let _ = stream.set_nodelay(true);

    // Clone for write / read / recv-thread
    let mut write_sock = match stream.try_clone() { Ok(s) => s, Err(_) => return -1 };
    let mut read_sock  = match stream.try_clone() { Ok(s) => s, Err(_) => return -1 };
    let recv_sock      = match stream.try_clone() { Ok(s) => s, Err(_) => return -1 };

    // Send MQTT CONNECT
    if write_sock.write_all(&mqtt_connect_packet(&cid_s)).is_err() { return -1; }

    // Read CONNACK (4 bytes: fixed hdr 0x20, len 0x02, session present, return code)
    let _ = read_sock.set_read_timeout(Some(Duration::from_secs(5)));
    let mut ack = [0u8; 4];
    if read_sock.read_exact(&mut ack).is_err() { return -1; }
    if ack[0] != 0x20 || ack[3] != 0x00 { return -1; }

    let alive    = Arc::new(AtomicBool::new(true));
    let queue    = Arc::new(Mutex::new(VecDeque::<Vec<u8>>::new()));
    let q_thread = Arc::clone(&queue);
    let a_thread = Arc::clone(&alive);

    thread::spawn(move || recv_thread(recv_sock, q_thread, a_thread));

    let conn = Arc::new(Conn {
        stream: Mutex::new(write_sock),
        queue,
        alive,
    });

    let mut sl = match slots().lock() { Ok(g) => g, Err(_) => return -1 };
    for (i, slot) in sl.iter_mut().enumerate() {
        if slot.is_none() {
            *slot = Some(conn);
            return i as i32;
        }
    }
    -1
}

/// Subscribe to a topic on an open handle. Returns 0 on success, -1 on failure.
#[no_mangle]
pub unsafe extern "C" fn MQTT_Subscribe(handle: i32, topic: *const u16) -> i32 {
    let topic_s = wstr_to_string(topic);
    let conn = {
        let sl = match slots().lock() { Ok(g) => g, Err(_) => return -1 };
        match sl.get(handle as usize).and_then(|s| s.as_ref()) {
            Some(c) => Arc::clone(c),
            None    => return -1,
        }
    };
    let pkt = mqtt_subscribe_packet(&topic_s, 1);
    let result = match conn.stream.lock() {
        Ok(mut s) => if s.write_all(&pkt).is_ok() { 0 } else { -1 },
        Err(_)    => -1,
    };
    result
}

/// Non-blocking poll for next message. Returns bytes copied, 0 if none, -1 if disconnected.
#[no_mangle]
pub unsafe extern "C" fn MQTT_Receive(handle: i32, buf: *mut u8, buf_size: i32) -> i32 {
    let conn = {
        let sl = match slots().lock() { Ok(g) => g, Err(_) => return -1 };
        match sl.get(handle as usize).and_then(|s| s.as_ref()) {
            Some(c) => Arc::clone(c),
            None    => return -1,
        }
    };

    if !conn.alive.load(Ordering::Relaxed) { return -1; }

    let msg = {
        let mut q = match conn.queue.lock() { Ok(g) => g, Err(_) => return 0 };
        q.pop_front()
    };

    if let Some(data) = msg {
        let n = data.len().min(buf_size as usize);
        std::ptr::copy_nonoverlapping(data.as_ptr(), buf, n);
        return n as i32;
    }
    0
}

/// Disconnect and free the slot.
#[no_mangle]
pub unsafe extern "C" fn MQTT_Disconnect(handle: i32) {
    let mut sl = match slots().lock() { Ok(g) => g, Err(_) => return };
    if let Some(slot) = sl.get_mut(handle as usize) {
        if let Some(conn) = slot.take() {
            conn.alive.store(false, Ordering::Relaxed);
            if let Ok(s) = conn.stream.lock() {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
        }
    }
}
