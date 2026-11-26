// SPDX-License-Identifier: MIT

use std::ffi::{c_char, c_void, CStr, CString};
use std::net::{IpAddr, SocketAddr};
use std::ptr;
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::net::TcpListener;

pub type JitBridgeReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type JitBridgePinCb = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;
pub type JitBridgeCancelledCb = Option<extern "C" fn(ctx: *mut c_void) -> i32>;

#[repr(C)]
pub struct JitBridgePairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
}

impl JitBridgePairResult {
    fn empty() -> Self {
        Self {
            error: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_file_path: ptr::null_mut(),
        }
    }
}

fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

struct Callbacks {
    ready: JitBridgeReadyCb,
    pin: JitBridgePinCb,
    ctx: *mut c_void,
}

unsafe impl Send for Callbacks {}

unsafe fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    match CStr::from_ptr(p).to_str() {
        Ok(s) if !s.is_empty() => s.to_string(),
        _ => default.to_string(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn jit_bridge_pair_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    ready_cb: JitBridgeReadyCb,
    pin_cb: JitBridgePinCb,
    cancelled_cb: JitBridgeCancelledCb,
    ctx: *mut c_void,
    out: *mut JitBridgePairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = JitBridgePairResult::empty();

    let bind_addr = opt_str(bind_addr, "0.0.0.0");
    let name = opt_str(name, "Andarium");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "rp_pairing_file.plist");
    let cbs = Callbacks {
        ready: ready_cb,
        pin: pin_cb,
        ctx,
    };

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            (*out).error = cstr(format!("failed to start runtime: {e}"));
            return 1;
        }
    };

    match rt.block_on(async {
        let pairing = run_pair_host(bind_addr, port, name, model, out_path, cbs);
        tokio::select! {
            result = pairing => result,
            _ = wait_for_cancellation(cancelled_cb, ctx) => Err("Pairing cancelled.".into()),
            _ = tokio::time::sleep(Duration::from_secs(120)) => Err("Pairing timed out.".into()),
        }
    }) {
        Ok((dev_name, dev_model, dev_udid, path)) => {
            (*out).device_name = cstr(dev_name);
            (*out).device_model = cstr(dev_model);
            (*out).device_udid = cstr(dev_udid);
            (*out).pairing_file_path = cstr(path);
            0
        }
        Err(e) => {
            (*out).error = cstr(e);
            1
        }
    }
}

async fn wait_for_cancellation(callback: JitBridgeCancelledCb, ctx: *mut c_void) {
    let Some(callback) = callback else {
        std::future::pending().await
    };
    while callback(ctx) == 0 {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn run_pair_host(
    bind_addr: String,
    port: u16,
    name: String,
    model: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<(String, String, String, String), String> {
    let ip: IpAddr = bind_addr
        .parse()
        .map_err(|_| "Invalid listener address.".to_string())?;
    let listener = TcpListener::bind(SocketAddr::new(ip, port))
        .await
        .map_err(|e| format!("failed to bind {bind_addr}:{port}: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("no local addr: {e}"))?
        .port();

    let mut pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, &model);
    let service_identifier = pairing_file.identifier.clone();

    emit_ready(&cbs, &service_identifier, port, &host_info);

    let (stream, _peer) = listener
        .accept()
        .await
        .map_err(|e| format!("accept failed: {e}"))?;

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let peer = host
        .accept(&mut pairing_file, move |pin| async move {
            if let Some(cb) = cbs.pin {
                if let Ok(c) = CString::new(pin) {
                    cb(c.as_ptr(), cbs.ctx);
                }
            }
        })
        .await
        .map_err(|e| format!("pairing failed: {e}"))?;

    pairing_file
        .write_to_file(&out_path)
        .await
        .map_err(|e| format!("failed to write pairing file: {e}"))?;

    Ok((peer.name, peer.model, peer.remotepairing_udid, out_path))
}

fn emit_ready(cbs: &Callbacks, service_id: &str, port: u16, host_info: &PairableHostInfo) {
    let Some(cb) = cbs.ready else { return };

    let records = host_info.mdns_txt_records(service_id);
    let mut keys: Vec<CString> = Vec::with_capacity(records.len());
    let mut vals: Vec<CString> = Vec::with_capacity(records.len());
    for (k, v) in &records {
        keys.push(CString::new(k.as_str()).unwrap_or_default());
        vals.push(CString::new(v.as_str()).unwrap_or_default());
    }
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
    let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();

    let Ok(id_c) = CString::new(service_id) else {
        return;
    };
    cb(
        cbs.ctx,
        id_c.as_ptr(),
        port,
        key_ptrs.as_ptr(),
        val_ptrs.as_ptr(),
        records.len(),
    );
}

#[no_mangle]
pub unsafe extern "C" fn jit_bridge_pair_result_free(r: *mut JitBridgePairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = JitBridgePairResult::empty();
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn cancelled(_: *mut c_void) -> i32 {
        1
    }

    #[tokio::test]
    async fn cancellation_is_observed_without_a_peer() {
        assert!(tokio::time::timeout(
            Duration::from_secs(1),
            wait_for_cancellation(Some(cancelled), ptr::null_mut())
        )
        .await
        .is_ok());
    }

    #[tokio::test]
    async fn missing_callback_does_not_cancel() {
        assert!(tokio::time::timeout(
            Duration::from_millis(20),
            wait_for_cancellation(None, ptr::null_mut())
        )
        .await
        .is_err());
    }
}
