use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::idevice_support::mounter::mount_personalized_ddi_rppairing;
use crate::idevice_support::rsd::set_rppairing_file;
use crate::idevice_support::{
    device::{fetch_udid_rppairing, test_device_connection},
    install::{install_ipa_rppairing, remove_app_rppairing, yeet_app_afc_rppairing},
    jit::{debug_app_rppairing, debug_process_rppairing},
    provision::{
        dump_provisioning_profile_rppairing, install_provisioning_profile_rppairing,
        remove_provisioning_profile_rppairing,
    },
};
use crate::IdeviceFfiError;
use crate::post17::RUNTIME;

fn to_char(value: String) -> *mut c_char {
    CString::new(value).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_test_device_connection() -> bool {
    test_device_connection()
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_fetch_udid(
    udid_out: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if udid_out.is_null() {
        return crate::ffi_err!(idevice::IdeviceError::InvalidArgument);
    }

    unsafe {
        *udid_out = std::ptr::null_mut();
    }

    match RUNTIME.block_on(fetch_udid_rppairing()) {
        Ok(udid) => {
            unsafe {
                *udid_out = to_char(udid);
            }
            std::ptr::null_mut()
        }
        Err(err) => crate::ffi_err!(err),
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_yeet_app_afc(
    bundle_id: *const c_char,
    ipa_ptr: *const u8,
    ipa_len: u32,
) -> *mut IdeviceFfiError {
    let bundle_id = unsafe { CStr::from_ptr(bundle_id) }
        .to_str()
        .unwrap()
        .to_string();
    let ipa_bytes = unsafe { std::slice::from_raw_parts(ipa_ptr, ipa_len as usize) };

    RUNTIME.block_on(async move {
        match yeet_app_afc_rppairing(bundle_id, ipa_bytes).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_install_ipa(
    bundle_id: *const c_char,
) -> *mut IdeviceFfiError {
    let bundle_id = unsafe { CStr::from_ptr(bundle_id) }
        .to_str()
        .unwrap()
        .to_string();
    RUNTIME.block_on(async move {
        match install_ipa_rppairing(bundle_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_remove_app(bundle_id: *const c_char) -> *mut IdeviceFfiError {
    let bundle_id = unsafe { CStr::from_ptr(bundle_id) }
        .to_str()
        .unwrap()
        .to_string();
    RUNTIME.block_on(async move {
        match remove_app_rppairing(bundle_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_debug_app(app_id: *const c_char) -> *mut IdeviceFfiError {
    let app_id = unsafe { CStr::from_ptr(app_id) }
        .to_str()
        .unwrap()
        .to_string();
    RUNTIME.block_on(async move {
        match debug_app_rppairing(app_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_debug_process(pid: u32) -> *mut IdeviceFfiError {
    RUNTIME.block_on(async move {
        match debug_process_rppairing(pid).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_install_provisioning_profile(
    profile_ptr: *const u8,
    profile_len: u32,
) -> *mut IdeviceFfiError {
    let profile = unsafe { std::slice::from_raw_parts(profile_ptr, profile_len as usize) };
    RUNTIME.block_on(async move {
        match install_provisioning_profile_rppairing(profile).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_remove_provisioning_profile(
    id: *const c_char,
) -> *mut IdeviceFfiError {
    let id = unsafe { CStr::from_ptr(id) }.to_str().unwrap().to_string();
    RUNTIME.block_on(async move {
        match remove_provisioning_profile_rppairing(id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_dump_provisioning_profile(
    docs_path: *const c_char,
) -> *mut IdeviceFfiError {
    let docs_path = unsafe { CStr::from_ptr(docs_path) }
        .to_str()
        .unwrap()
        .to_string();
    RUNTIME.block_on(async move {
        match dump_provisioning_profile_rppairing(docs_path).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_set_rppairing_file(
    pairing_file: *const c_char,
) -> *mut IdeviceFfiError {
    let pairing_file_str = unsafe { CStr::from_ptr(pairing_file) }
        .to_str()
        .unwrap()
        .to_string();

    match set_rppairing_file(pairing_file_str) {
        Ok(()) => std::ptr::null_mut(),
        Err(err) => crate::ffi_err!(err),
    }
}

#[repr(C)]
pub struct MountResult {
    pub value: i32,
    pub error: *mut c_char,
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_mount_personalized_ddi(
    image_ptr: *const u8,
    image_len: u32,
    trustcache_ptr: *const u8,
    trustcache_len: u32,
    manifest_ptr: *const u8,
    manifest_len: u32,
) -> MountResult {
    let image = unsafe { std::slice::from_raw_parts(image_ptr, image_len as usize) };
    let trustcache = unsafe { std::slice::from_raw_parts(trustcache_ptr, trustcache_len as usize) };
    let manifest = unsafe { std::slice::from_raw_parts(manifest_ptr, manifest_len as usize) };
    RUNTIME.block_on(async move {
        match mount_personalized_ddi_rppairing(image, trustcache, manifest).await {
            Ok(()) => MountResult {
                value: 0,
                error: std::ptr::null_mut(),
            },
            Err((code, err_msg)) => MountResult {
                value: code,
                error: to_char(err_msg),
            },
        }
    })
}

// --- Wireless Pairing FFI (WirelessPair) ---

use std::os::raw::c_void;

pub type WirelessPairReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type WirelessPairPinCb = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;

#[repr(C)]
pub struct WirelessPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
}

impl WirelessPairResult {
    fn empty() -> Self {
        Self {
            error: std::ptr::null_mut(),
            device_name: std::ptr::null_mut(),
            device_model: std::ptr::null_mut(),
            device_udid: std::ptr::null_mut(),
            pairing_file_path: std::ptr::null_mut(),
            host_alt_irk_hex: std::ptr::null_mut(),
        }
    }
}

struct Callbacks {
    ready: WirelessPairReadyCb,
    pin: WirelessPairPinCb,
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
pub unsafe extern "C" fn wirelesspair_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    ready_cb: WirelessPairReadyCb,
    pin_cb: WirelessPairPinCb,
    ctx: *mut c_void,
    out: *mut WirelessPairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = WirelessPairResult::empty();

    let bind_addr = opt_str(bind_addr, "0.0.0.0");
    let name = opt_str(name, "WirelessPair");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "rp_pairing_file.plist");
    let cbs = Callbacks { ready: ready_cb, pin: pin_cb, ctx };

    match RUNTIME.block_on(run_wirelesspair(bind_addr, port, name, model, out_path, cbs)) {
        Ok(res) => {
            (*out).device_name = to_char(res.name);
            (*out).device_model = to_char(res.model);
            (*out).device_udid = to_char(res.udid);
            (*out).pairing_file_path = to_char(res.path);
            (*out).host_alt_irk_hex = to_char(res.host_alt_irk_hex);
            0
        }
        Err(e) => {
            (*out).error = to_char(e);
            1
        }
    }
}

struct Paired {
    name: String,
    model: String,
    udid: String,
    path: String,
    host_alt_irk_hex: String,
}

async fn run_wirelesspair(
    bind_addr: String,
    port: u16,
    name: String,
    model: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<Paired, String> {
    use idevice::remote_pairing::{
        PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
    };
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use tokio::net::TcpListener;

    let ip: IpAddr = bind_addr
        .parse()
        .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let listener = TcpListener::bind(SocketAddr::new(ip, port))
        .await
        .map_err(|e| format!("failed to bind {bind_addr}:{port}: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("no local addr: {e}"))?
        .port();

    let mut pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, &model);
    let host_alt_irk = host_info.alt_irk;
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

    Ok(Paired {
        name: peer.name,
        model: peer.model,
        udid: peer.remotepairing_udid,
        path: out_path,
        host_alt_irk_hex: hex(&host_alt_irk),
    })
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn emit_ready(cbs: &Callbacks, service_id: &str, port: u16, host_info: &idevice::remote_pairing::PairableHostInfo) {
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

    let Ok(id_c) = CString::new(service_id) else { return };
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
pub unsafe extern "C" fn wirelesspair_result_free(r: *mut WirelessPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = WirelessPairResult::empty();
}
