#![no_std]
#![allow(non_snake_case, dead_code)]

use core::sync::atomic::{AtomicI32, Ordering};
use windows_sys::Win32::Networking::WinSock::{
    WSAStartup, WSASocketW, connect, send, closesocket, WSACleanup,
    SOCKADDR_IN, SOCKET, SOCKET_ERROR, INVALID_SOCKET,
    WSADATA, AF_INET, SOCK_STREAM, IPPROTO_TCP, WSA_FLAG_OVERLAPPED,
    IN_ADDR, IN_ADDR_0,
};

// ------------------------------------------------------------------
// Shared state
// ------------------------------------------------------------------

static SOCKET_FD: AtomicI32 = AtomicI32::new(-1);

// ------------------------------------------------------------------
// Wire payload (packed, matches Go relay's binary.LittleEndian decode)
// ------------------------------------------------------------------

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct TradePayload {
    ticket:     i64,
    symbol:     [u8; 12],
    order_type: i32,
    volume:     f64,
    price:      f64,
    sl:         f64,
    tp:         f64,
    magic:      i32,
    _pad:       i32,
}

// ------------------------------------------------------------------
// MQTT helpers (stack-only, no heap)
// ------------------------------------------------------------------

const MQTT_BROKER_IP: u32 = 0x0100007f; // 127.0.0.1 in network byte order
const MQTT_PORT:      u16 = 1883;
const TOPIC_TRADE:    &[u8] = b"trading/master";
const TOPIC_CONFIG:   &[u8] = b"trading/config";
const CLIENT_ID:      &[u8] = b"mt4bridge";

fn htons(v: u16) -> u16 { v.to_be() }

fn build_connect(buf: &mut [u8; 128]) -> usize {
    let cid_len = CLIENT_ID.len() as u16;
    let var_hdr: &[u8] = &[
        0x00, 0x04, b'M', b'Q', b'T', b'T',
        0x04,       // protocol level 3.1.1
        0x02,       // clean session
        0x00, 0x3c, // keepalive 60s
    ];
    let remaining = var_hdr.len() + 2 + CLIENT_ID.len();
    let mut pos = 0;
    buf[pos] = 0x10;           pos += 1;
    buf[pos] = remaining as u8; pos += 1;
    buf[pos..pos + var_hdr.len()].copy_from_slice(var_hdr);
    pos += var_hdr.len();
    buf[pos] = (cid_len >> 8) as u8;   pos += 1;
    buf[pos] = (cid_len & 0xff) as u8; pos += 1;
    buf[pos..pos + CLIENT_ID.len()].copy_from_slice(CLIENT_ID);
    pos + CLIENT_ID.len()
}

// Generic PUBLISH builder — accepts any topic and any raw payload bytes.
fn build_publish_raw(topic: &[u8], payload_bytes: &[u8], out: &mut [u8; 512]) -> usize {
    let topic_len = topic.len();
    let remaining = 2 + topic_len + payload_bytes.len();
    let mut pos = 0;
    out[pos] = 0x30; pos += 1; // PUBLISH, QoS 0
    let mut rem = remaining;
    loop {
        let mut enc = (rem & 0x7f) as u8;
        rem >>= 7;
        if rem > 0 { enc |= 0x80; }
        out[pos] = enc; pos += 1;
        if rem == 0 { break; }
    }
    out[pos] = (topic_len >> 8) as u8;   pos += 1;
    out[pos] = (topic_len & 0xff) as u8; pos += 1;
    out[pos..pos + topic_len].copy_from_slice(topic);
    pos += topic_len;
    out[pos..pos + payload_bytes.len()].copy_from_slice(payload_bytes);
    pos + payload_bytes.len()
}

// ------------------------------------------------------------------
// Socket management
// ------------------------------------------------------------------

unsafe fn open_socket() -> SOCKET {
    let mut wsa: WSADATA = core::mem::zeroed();
    WSAStartup(0x0202, &mut wsa);

    let sock = WSASocketW(
        AF_INET as i32, SOCK_STREAM as i32, IPPROTO_TCP as i32,
        core::ptr::null(), 0, WSA_FLAG_OVERLAPPED,
    );
    if sock == INVALID_SOCKET { return INVALID_SOCKET; }

    let addr = SOCKADDR_IN {
        sin_family: AF_INET,
        sin_port:   htons(MQTT_PORT),
        sin_addr:   IN_ADDR { S_un: IN_ADDR_0 { S_addr: MQTT_BROKER_IP } },
        sin_zero:   [0i8; 8],
    };
    if connect(sock, &addr as *const _ as _, core::mem::size_of::<SOCKADDR_IN>() as i32) == SOCKET_ERROR {
        closesocket(sock);
        return INVALID_SOCKET;
    }

    let mut conn_buf = [0u8; 128];
    let conn_len = build_connect(&mut conn_buf);
    if send(sock, conn_buf.as_ptr(), conn_len as i32, 0) == SOCKET_ERROR {
        closesocket(sock);
        return INVALID_SOCKET;
    }
    sock
}

unsafe fn publish_raw(topic: &[u8], bytes: &[u8]) -> i32 {
    let sock = SOCKET_FD.load(Ordering::SeqCst);
    if sock < 0 { return -1; }
    let sock = sock as SOCKET;

    let mut pub_buf = [0u8; 512];
    let pub_len = build_publish_raw(topic, bytes, &mut pub_buf);

    if send(sock, pub_buf.as_ptr(), pub_len as i32, 0) == SOCKET_ERROR {
        SOCKET_FD.store(-1, Ordering::SeqCst);
        closesocket(sock);
        return -1;
    }
    0
}

// ------------------------------------------------------------------
// Exported API
// ------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bridge_init() -> i32 {
    let sock = open_socket();
    if sock == INVALID_SOCKET { return -1; }
    SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    0
}

#[no_mangle]
pub unsafe extern "C" fn bridge_shutdown() {
    let sock = SOCKET_FD.swap(-1, Ordering::SeqCst);
    if sock >= 0 {
        closesocket(sock as SOCKET);
        WSACleanup();
    }
}

/// Send a trade event to trading/master.
/// Called by MasterEA with flat args matching the MQL4 #import declaration.
#[no_mangle]
pub unsafe extern "C" fn send_trade_event(
    ticket:     i64,
    symbol:     *const u8,
    order_type: i32,
    volume:     f64,
    price:      f64,
    sl:         f64,
    tp:         f64,
    magic:      i32,
    pad:        i32,
) -> i32 {
    if SOCKET_FD.load(Ordering::SeqCst) < 0 {
        let sock = open_socket();
        if sock == INVALID_SOCKET { return -1; }
        SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    }

    let mut sym = [0u8; 12];
    if !symbol.is_null() {
        for i in 0..12usize {
            let b = *symbol.add(i);
            sym[i] = b;
            if b == 0 { break; }
        }
    }

    let payload = TradePayload { ticket, symbol: sym, order_type, volume, price, sl, tp, magic, _pad: pad };
    let raw = core::slice::from_raw_parts(
        &payload as *const TradePayload as *const u8,
        core::mem::size_of::<TradePayload>(),
    );

    let res = publish_raw(TOPIC_TRADE, raw);
    if res == 0 { return 0; }

    // Reconnect and retry once
    let sock = open_socket();
    if sock == INVALID_SOCKET { return -1; }
    SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    publish_raw(TOPIC_TRADE, raw)
}

/// Send a JSON config payload to trading/config.
/// MasterEA builds the JSON string and passes it as a uchar array + length.
/// The relay receives it and hot-reloads risk settings for all slaves.
#[no_mangle]
pub unsafe extern "C" fn send_config_event(
    json_bytes: *const u8,
    json_len:   i32,
) -> i32 {
    if json_bytes.is_null() || json_len <= 0 { return -2; }

    if SOCKET_FD.load(Ordering::SeqCst) < 0 {
        let sock = open_socket();
        if sock == INVALID_SOCKET { return -1; }
        SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    }

    let bytes = core::slice::from_raw_parts(json_bytes, json_len as usize);

    let res = publish_raw(TOPIC_CONFIG, bytes);
    if res == 0 { return 0; }

    let sock = open_socket();
    if sock == INVALID_SOCKET { return -1; }
    SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    publish_raw(TOPIC_CONFIG, bytes)
}

// ------------------------------------------------------------------
// no_std panic handler
// ------------------------------------------------------------------

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }
