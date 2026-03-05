#![no_std]
#![allow(non_snake_case, unused_imports, dead_code)]

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
// Exported struct (must match MQL4 layout exactly)
// ------------------------------------------------------------------

#[repr(C, packed)]
#[derive(Clone, Copy)]
pub struct TradePayload {
    pub ticket:     i64,
    pub symbol:     [u8; 12],
    pub order_type: i32,
    pub volume:     f64,
    pub price:      f64,
    pub sl:         f64,
    pub tp:         f64,
    pub magic:      i32,
    pub _pad:       i32,
}

// ------------------------------------------------------------------
// Minimal MQTT helpers (no heap, stack-only)
// ------------------------------------------------------------------

const MQTT_BROKER_IP: u32 = 0x0100007f; // 127.0.0.1 little-endian → network order
const MQTT_PORT:      u16 = 1883;
const TOPIC:          &[u8] = b"trading/master";
const CLIENT_ID:      &[u8] = b"mt4bridge";

fn htons(v: u16) -> u16 { v.to_be() }

fn build_connect(buf: &mut [u8; 128]) -> usize {
    let client_id_len = CLIENT_ID.len() as u16;
    let var_header: &[u8] = &[
        0x00, 0x04, b'M', b'Q', b'T', b'T',
        0x04,       // protocol level 3.1.1
        0x02,       // clean session
        0x00, 0x3c, // keepalive 60s
    ];
    let remaining = var_header.len() + 2 + CLIENT_ID.len();

    let mut pos = 0;
    buf[pos] = 0x10; pos += 1;
    buf[pos] = remaining as u8; pos += 1;
    buf[pos..pos + var_header.len()].copy_from_slice(var_header);
    pos += var_header.len();
    buf[pos] = (client_id_len >> 8) as u8; pos += 1;
    buf[pos] = (client_id_len & 0xff) as u8; pos += 1;
    buf[pos..pos + CLIENT_ID.len()].copy_from_slice(CLIENT_ID);
    pos + CLIENT_ID.len()
}

fn build_publish(payload_bytes: &[u8], out: &mut [u8; 256]) -> usize {
    let topic_len = TOPIC.len() as u16;
    let remaining = 2 + TOPIC.len() + payload_bytes.len();

    let mut pos = 0;
    out[pos] = 0x30; pos += 1; // PUBLISH QoS 0 (fire-and-forget, no packet-id needed)
    let mut rem = remaining;
    loop {
        let mut enc = (rem & 0x7f) as u8;
        rem >>= 7;
        if rem > 0 { enc |= 0x80; }
        out[pos] = enc; pos += 1;
        if rem == 0 { break; }
    }
    out[pos] = (topic_len >> 8) as u8; pos += 1;
    out[pos] = (topic_len & 0xff) as u8; pos += 1;
    out[pos..pos + TOPIC.len()].copy_from_slice(TOPIC);
    pos += TOPIC.len();
    out[pos..pos + payload_bytes.len()].copy_from_slice(payload_bytes);
    pos + payload_bytes.len()
}

// ------------------------------------------------------------------
// Socket helpers
// ------------------------------------------------------------------

unsafe fn open_socket() -> SOCKET {
    let mut wsa: WSADATA = core::mem::zeroed();
    WSAStartup(0x0202, &mut wsa);

    let sock = WSASocketW(
        AF_INET as i32,
        SOCK_STREAM as i32,
        IPPROTO_TCP as i32,
        core::ptr::null(),
        0,
        WSA_FLAG_OVERLAPPED,
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

unsafe fn send_payload(payload: &TradePayload) -> i32 {
    let sock = SOCKET_FD.load(Ordering::SeqCst);
    if sock < 0 { return -1; }
    let sock = sock as SOCKET;

    let raw: &[u8] = core::slice::from_raw_parts(
        payload as *const TradePayload as *const u8,
        core::mem::size_of::<TradePayload>(),
    );

    let mut pub_buf = [0u8; 256];
    let pub_len = build_publish(raw, &mut pub_buf);

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

#[no_mangle]
pub unsafe extern "C" fn send_trade_event(payload: *const TradePayload) -> i32 {
    if payload.is_null() { return -2; }

    if SOCKET_FD.load(Ordering::SeqCst) < 0 {
        let sock = open_socket();
        if sock == INVALID_SOCKET { return -1; }
        SOCKET_FD.store(sock as i32, Ordering::SeqCst);
    }

    send_payload(&*payload)
}

// ------------------------------------------------------------------
// no_std panic handler required by the linker
// ------------------------------------------------------------------

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
