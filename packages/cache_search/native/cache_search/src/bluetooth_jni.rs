//! JNI for the Android BLE adapter. Buffers are owned by that adapter's worker for the duration of each call. Every call
//! resolves its instance's session handle; a callback from a closed engine never falls through to another engine.
#![allow(non_snake_case)]

use cache_sync::{android_bridge, AndroidBleBridge, AndroidBleIngressAdmission};
use jni::objects::{JByteBuffer, JObject};
use jni::sys::{jboolean, jint, jlong};
use jni::JNIEnv;

fn bridge(env: &mut JNIEnv<'_>, object: &JObject<'_>) -> Option<AndroidBleBridge> {
    match env.get_field(object, "handle", "J").and_then(|v| v.j()) {
        Ok(h) if h > 0 => android_bridge(h as u64),
        Ok(_) => None,
        Err(_) => {
            let _ = env.exception_clear();
            None
        }
    }
}

fn input<T>(env: &JNIEnv<'_>, buffer: &JByteBuffer<'_>, len: jint, f: impl FnOnce(&[u8]) -> T) -> Option<T> {
    let len = usize::try_from(len).ok()?;
    let capacity = env.get_direct_buffer_capacity(buffer).ok()?;
    let address = env.get_direct_buffer_address(buffer).ok()?;
    if address.is_null() || len == 0 || len > capacity {
        return None;
    }
    // SAFETY: JNI pins this direct buffer during the call. The adapter owns it on this worker, and len was checked against
    // its capacity. The borrowed slice is used only inside f and cannot outlive this JNI call.
    Some(f(unsafe { std::slice::from_raw_parts(address, len) }))
}

fn output<T>(env: &JNIEnv<'_>, buffer: &JByteBuffer<'_>, f: impl FnOnce(&mut [u8]) -> T) -> Option<T> {
    let capacity = env.get_direct_buffer_capacity(buffer).ok()?;
    let address = env.get_direct_buffer_address(buffer).ok()?;
    if address.is_null() || capacity == 0 {
        return None;
    }
    // SAFETY: the pinned direct buffer is exclusively owned by the calling adapter worker; capacity comes from JNI.
    // No reference to its contents escapes this call.
    Some(f(unsafe { std::slice::from_raw_parts_mut(address, capacity) }))
}

fn octets<const N: usize>(env: &JNIEnv<'_>, buffer: &JByteBuffer<'_>) -> Option<[u8; N]> {
    input(env, buffer, N as jint, |b| b.try_into().unwrap())
}

fn rssi(value: jint) -> Option<i8> {
    if value == 127 { None } else { i8::try_from(value).ok() }
}

fn admission(value: AndroidBleIngressAdmission) -> jint {
    match value {
        AndroidBleIngressAdmission::Accepted => 0,
        AndroidBleIngressAdmission::Full => 1,
        AndroidBleIngressAdmission::Closed => 2,
    }
}

macro_rules! simple {
    ($name:ident($($arg:ident: $ty:ty),*) -> (), (), |$b:ident| $body:expr) => {
        #[no_mangle]
        pub extern "system" fn $name(mut env: JNIEnv<'_>, object: JObject<'_>, $($arg: $ty),*) {
            let Some($b) = bridge(&mut env, &object) else { return };
            $body
        }
    };
    ($name:ident($($arg:ident: $ty:ty),*) -> $out:ty, $default:expr, |$b:ident| $body:expr) => {
        #[no_mangle]
        pub extern "system" fn $name(mut env: JNIEnv<'_>, object: JObject<'_>, $($arg: $ty),*) -> $out {
            let Some($b) = bridge(&mut env, &object) else { return $default };
            $body
        }
    };
}

simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleSetPsm(psm: jint) -> (), (), |b| {
    if let Ok(psm) = u16::try_from(psm) { b.set_psm(psm); }
});
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleDesiredState() -> jint, 0, |b| b.radio_state() as jint);
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBlePeerCapacity() -> jint, 0, |_b| cache_sync::ANDROID_BLE_PEER_CAPACITY as jint);
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleWorkGeneration() -> jlong, 0, |b| b.work_generation() as jlong);
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleWakePumps() -> (), (), |b| b.wake_work());
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleCommitControlOut(conn_id: jint) -> jboolean, 0, |b| u32::try_from(conn_id).is_ok_and(|id| b.commit_control_out(id)).into());
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleCommitDataOut(conn_id: jint) -> jboolean, 0, |b| u32::try_from(conn_id).is_ok_and(|id| b.commit_data_out(id)).into());
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleL2capUp(conn_id: jint) -> (), (), |b| {
    if let Ok(id) = u32::try_from(conn_id) { b.l2cap_up(id); }
});
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleDisconnected(conn_id: jint) -> (), (), |b| {
    if let Ok(id) = u32::try_from(conn_id) { b.disconnected(id); }
});
simple!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleNextClose() -> jint, -1, |b| b.next_close().and_then(|n| jint::try_from(n).ok()).unwrap_or(-1));

#[no_mangle]
pub extern "system" fn Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleWaitForWork(mut env: JNIEnv<'_>, object: JObject<'_>, observed: jlong, timeout: jlong) -> jlong {
    let Some(b) = bridge(&mut env, &object) else {
        // BleLink's worker boundary catches interruption and exits. Returning immediately for a revoked handle would leave
        // its old blocking pumps spinning until the platform controller notices that the engine was replaced.
        let _ = env.throw_new("java/lang/InterruptedException", "Bluetooth session closed");
        return 0;
    };
    b.wait_for_work(observed as u64, timeout.max(0) as u64) as jlong
}

macro_rules! buffer_out {
    ($name:ident, $default:expr, |$b:ident, $bytes:ident| $body:expr, $ty:ty) => {
        #[no_mangle]
        pub extern "system" fn $name(mut env: JNIEnv<'_>, object: JObject<'_>, buffer: JByteBuffer<'_>) -> $ty {
            let Some($b) = bridge(&mut env, &object) else { return $default };
            output(&env, &buffer, |$bytes| $body).unwrap_or($default)
        }
    };
}
buffer_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleIdentity, 0, |b, bytes| b.local_identity(bytes) as jint, jint);
buffer_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleNextDial, 0, |b, bytes| b.next_dial(bytes).into(), jboolean);
buffer_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleNextL2capOpen, 0, |b, bytes| b.next_l2cap_open(bytes).into(), jboolean);

macro_rules! frame_out {
    ($name:ident, $method:ident) => {
        #[no_mangle]
        pub extern "system" fn $name(mut env: JNIEnv<'_>, object: JObject<'_>, conn_id: jint, buffer: JByteBuffer<'_>) -> jint {
            let Some(b) = bridge(&mut env, &object) else { return 0 };
            let Ok(id) = u32::try_from(conn_id) else { return 0 };
            output(&env, &buffer, |bytes| b.$method(id, bytes) as jint).unwrap_or(0)
        }
    };
}
frame_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleControlOut, control_out);
frame_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleDataOut, data_out);
frame_out!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleL2capOut, l2cap_out);

macro_rules! frame_in {
    ($name:ident, $method:ident, $ty:ty, $default:expr, $convert:expr) => {
        #[no_mangle]
        pub extern "system" fn $name(mut env: JNIEnv<'_>, object: JObject<'_>, conn_id: jint, buffer: JByteBuffer<'_>, len: jint) -> $ty {
            let Some(b) = bridge(&mut env, &object) else { return $default };
            let Ok(id) = u32::try_from(conn_id) else { return $default };
            input(&env, &buffer, len, |bytes| ($convert)(b.$method(id, bytes))).unwrap_or($default)
        }
    };
}
frame_in!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleControlIn, control_in, jint, 2, admission);
frame_in!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleDataIn, data_in, jint, 2, admission);
frame_in!(Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleL2capIn, l2cap_in, jboolean, 0, jboolean::from);

#[no_mangle]
pub extern "system" fn Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleSighting(mut env: JNIEnv<'_>, object: JObject<'_>, address: JByteBuffer<'_>, strength: jint) {
    if let (Some(b), Some(address)) = (bridge(&mut env, &object), octets(&env, &address)) {
        b.sighting(address, rssi(strength));
    }
}

#[no_mangle]
pub extern "system" fn Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleDialFailed(mut env: JNIEnv<'_>, object: JObject<'_>, address: JByteBuffer<'_>) -> jboolean {
    match (bridge(&mut env, &object), octets(&env, &address)) {
        (Some(b), Some(address)) => b.dial_failed(address).into(),
        _ => 0,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleLinkUp(mut env: JNIEnv<'_>, object: JObject<'_>, conn_id: jint, address: JByteBuffer<'_>, strength: jint, dialed: jboolean) -> jboolean {
    match (bridge(&mut env, &object), u32::try_from(conn_id), octets(&env, &address)) {
        (Some(b), Ok(id), Some(address)) => b.link_up(id, address, rssi(strength), dialed != 0).into(),
        _ => 0,
    }
}

#[no_mangle]
pub extern "system" fn Java_com_happylittlellc_cache_reticulum_NativeBridge_nativeBleColumbaLinkUp(mut env: JNIEnv<'_>, object: JObject<'_>, conn_id: jint, address: JByteBuffer<'_>, strength: jint, dialed: jboolean, identity: JByteBuffer<'_>) -> jboolean {
    match (bridge(&mut env, &object), u32::try_from(conn_id), octets(&env, &address), octets(&env, &identity)) {
        (Some(b), Ok(id), Some(address), Some(identity)) => b.columba_link_up(id, address, rssi(strength), dialed != 0, identity).into(),
        _ => 0,
    }
}
