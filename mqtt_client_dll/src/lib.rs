use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;
use std::thread;
use rumqttc::{Client, Connection, MqttOptions, QoS, Event, Packet};

lazy_static::lazy_static! {
    static ref MESSAGE_QUEUE: Arc<Mutex<VecDeque<Vec<u8>>>> = Arc::new(Mutex::new(VecDeque::new()));
}

#[no_mangle]
pub extern "system" fn MQTT_Connect(host: *const c_char, port: c_int, client_id: *const c_char) -> c_int {
    if host.is_null() || client_id.is_null() { return -1; }
    
    let c_host = unsafe { CStr::from_ptr(host) }.to_string_lossy().into_owned();
    let c_id = unsafe { CStr::from_ptr(client_id) }.to_string_lossy().into_owned();
    
    let mut mqttoptions = MqttOptions::new(c_id, c_host, port as u16);
    mqttoptions.set_keep_alive(std::time::Duration::from_secs(5));

    let (mut client, mut connection) = Client::new(mqttoptions, 10);

    // Spawn background thread to handle the MQTT event loop
    thread::spawn(move || {
        for notification in connection.iter() {
            if let Ok(Event::Incoming(Packet::Publish(publish))) = notification {
                let mut queue = MESSAGE_QUEUE.lock().unwrap();
                queue.push_back(publish.payload.to_vec());
                // Limit queue size to prevent memory leaks if EA stops polling
                if queue.len() > 100 { queue.pop_front(); }
            }
        }
    });

    // In a production DLL, you'd store the 'client' in a global Map linked to the handle
    // For now, we return 1 to signal success
    1 
}

#[no_mangle]
pub extern "system" fn MQTT_Receive(_handle: c_int, buf: *mut u8, buf_size: c_int) -> c_int {
    let mut queue = match MESSAGE_QUEUE.lock() {
        Ok(q) => q,
        Err(_) => return -1,
    };
    
    if let Some(data) = queue.pop_front() {
        let len = data.len().min(buf_size as usize);
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), buf, len);
        }
        return len as c_int;
    }
    0
}

#[no_mangle] pub extern "system" fn MQTT_Subscribe(_handle: c_int, _topic: *const c_char) -> c_int { 0 }
#[no_mangle] pub extern "system" fn MQTT_Disconnect(_handle: c_int) {}
