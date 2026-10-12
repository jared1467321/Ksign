//! Ksign's cancellable iOS pairing bridge. Built into the existing idevice FFI
//! library, so there is only one Rust runtime and one version of the protocol.
//! Bonjour advertising belongs to Swift/NetService, not raw multicast sockets.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

pub struct KsignPairingSession {
    cancelled: AtomicBool,
}

#[unsafe(no_mangle)]
pub extern "C" fn ksign_pairing_new() -> *mut KsignPairingSession {
    Box::into_raw(Box::new(KsignPairingSession { cancelled: AtomicBool::new(false) }))
}

/// Safe concurrently with run. The caller must keep the session alive until run returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_cancel(session: *mut KsignPairingSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

/// Call only after run has returned and all cancel calls have completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_free(session: *mut KsignPairingSession) {
    if !session.is_null() { drop(unsafe { Box::from_raw(session) }); }
}

/// Callback strings are borrowed for the duration of the callback only.
/// event=0: JSON {identifier,port,txt}; event=1: PIN. Callbacks run off the UI thread.
/// On success out_record receives JSON containing credentials and host identity.
/// Free that string with ksign_pairing_string_free. Never log it.
/// All non-optional pointers must be valid; call run at most once per session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_run(
    session: *mut KsignPairingSession,
    name: *const c_char,
    callback: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
    context: *mut c_void,
    out_record: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || name.is_null() || out_record.is_null() {
        return ffi_err!(idevice::IdeviceError::FfiInvalidArg);
    }
    unsafe { *out_record = std::ptr::null_mut(); }
    if unsafe { &*session }.cancelled.load(Ordering::Acquire) {
        return ffi_err!(idevice::IdeviceError::InternalError("Pairing cancelled".into()));
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) => name.to_owned(),
        Err(_) => return ffi_err!(idevice::IdeviceError::FfiInvalidString),
    };
    let session = unsafe { &*session };
    let emit = |event: i32, value: String| {
        if let (Some(callback), Ok(value)) = (callback, CString::new(value)) {
            callback(context, event, value.as_ptr());
        }
    };
    let result: Result<String, String> = run_sync_local(async {
        let pairing = async {
            let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0))
                .await.map_err(|e| format!("Cannot listen for pairing: {e}"))?;
            let port = listener.local_addr().map_err(|e| e.to_string())?.port();
            let mut credentials = RpPairingFile::generate(&name);
            let host = PairableHostInfo::generate(&name, "Mac17,7");
            let host_alt_irk = host.alt_irk;
            let txt: std::collections::BTreeMap<_, _> = host.mdns_txt_records(&credentials.identifier)
                .into_iter().collect();
            emit(0, serde_json::json!({
                "identifier": credentials.identifier, "port": port, "txt": txt
            }).to_string());
            let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
            let mut responder = PairableHost::new(RpPairingSocket::new_device(stream), host);
            let peer = responder.accept(&mut credentials, |pin| async { emit(1, pin); })
                .await.map_err(|e| format!("Pairing failed: {e}"))?;
            let plist = String::from_utf8(credentials.to_bytes()).map_err(|e| e.to_string())?;
            Ok(serde_json::json!({
                "pairing_plist": plist,
                "host_alt_irk": host_alt_irk,
                "device_udid": peer.remotepairing_udid,
                "device_name": peer.name
            }).to_string())
        };
        tokio::select! {
            result = pairing => result,
            _ = wait_cancelled(session) => Err("Pairing cancelled".into()),
            _ = tokio::time::sleep(Duration::from_secs(180)) =>
                Err("Pairing timed out. Return to Ksign and try again.".into()),
        }
    });
    match result {
        Ok(record) => {
            match CString::new(record) {
                Ok(record) => { unsafe { *out_record = record.into_raw(); } std::ptr::null_mut() }
                Err(_) => ffi_err!(idevice::IdeviceError::FfiInvalidString),
            }
        }
        Err(message) => ffi_err!(idevice::IdeviceError::InternalError(message)),
    }
}

async fn wait_cancelled(session: &KsignPairingSession) {
    while !session.cancelled.load(Ordering::Acquire) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_string_free(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn cancel_when_listening(context: *mut c_void, event: i32, payload: *const c_char) {
        if event == 0 {
            let value: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(payload) }.to_str().unwrap()).unwrap();
            assert!(value["port"].as_u64().unwrap() > 0);
            assert!(value["txt"]["authTag"].is_string());
            unsafe { ksign_pairing_cancel(context.cast()); }
        }
    }

    #[test]
    fn cancellation_closes_a_waiting_listener_without_a_device() {
        unsafe {
            let session = ksign_pairing_new();
            let name = CString::new("Ksign test").unwrap();
            let mut record = std::ptr::null_mut();
            let started = std::time::Instant::now();
            let error = ksign_pairing_run(session, name.as_ptr(), Some(cancel_when_listening), session.cast(), &mut record);
            assert!(!error.is_null());
            assert!(record.is_null());
            assert!(started.elapsed() < Duration::from_secs(5));
            assert!(CStr::from_ptr((*error).message).to_str().unwrap().contains("cancelled"));
            crate::idevice_error_free(error);
            ksign_pairing_free(session);
        }
    }
}
