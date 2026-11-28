//! Mobile BLE lifetime. Prns owns negotiation, framing and backpressure. Android supplies its native GATT bridge after
//! permission; iOS attaches Prns's CoreBluetooth backend after permission. Engine handles rotate so late callbacks cannot
//! enter a replacement engine. Host tests use the portable Android bridge without opening a platform radio.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use anyhow::{anyhow, Result};
use iroh::SecretKey;
use personal_rns::interfaces::bluetooth_auto::{AndroidHost, BleIdentity, Endpoint, LinkCapabilities, RadioMode, BLE_HW_MTU};
use personal_rns::interfaces::InterfaceId;
use personal_rns::prelude::PrnsNodeHandle;
use prns_interfaces_tokio::bluetooth_auto::{BluetoothAuto, BluetoothAutoStatus};

pub use prns_ffi::bluetooth_auto::android::{AndroidBleBridge, AndroidBleIngressAdmission};
use prns_ffi::bluetooth_auto::android::AndroidBleBackend;

pub const ANDROID_BLE_PEER_CAPACITY: usize = AndroidBleBackend::MAX_PEERS;

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static BRIDGES: OnceLock<Mutex<HashMap<u64, AndroidBleBridge>>> = OnceLock::new();

#[cfg(target_os = "ios")]
pub type MobileSession = AppleSession;
#[cfg(not(target_os = "ios"))]
pub type MobileSession = AndroidSession;

fn new_handle() -> Result<u64> {
    NEXT_HANDLE.try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
        .map_err(|_| anyhow!("Bluetooth session handles exhausted"))
}

fn bridges() -> &'static Mutex<HashMap<u64, AndroidBleBridge>> {
    BRIDGES.get_or_init(Mutex::default)
}

/// The platform's callback handle resolves only while its own session is alive. A missing handle is a closed session,
/// never an instruction to fall back to the most recent engine.
pub fn android_bridge(handle: u64) -> Option<AndroidBleBridge> {
    bridges().lock().unwrap().get(&handle).cloned()
}

/// A stable, opaque discovery identity, distinct from both the device public key and its Reticulum destination.
fn identity(device: &SecretKey) -> BleIdentity {
    let hash = blake3::derive_key("cache_rns bluetooth discovery identity v1", &device.to_bytes());
    let mut bytes = [0; 16];
    bytes.copy_from_slice(&hash[..16]);
    BleIdentity::new(bytes)
}

/// Owns the supervisor and the callback registry entry together. Drop detaches its whole fleet, switches the bridge off,
/// closes its queues and wakes sleeping platform pumps before the engine's handle can be forgotten.
pub struct AndroidSession {
    handle: u64,
    node: PrnsNodeHandle,
    interface: InterfaceId,
    bridge: AndroidBleBridge,
    status: BluetoothAutoStatus,
}

impl AndroidSession {
    /// Attaches a portable BLE supervisor; no Android API or real radio is accessed here.
    pub fn attach(node: &crate::RnsNode, device: &SecretKey) -> Result<Self> {
        let handle = new_handle()?;
        let bridge = AndroidBleBridge::new();
        let identity = identity(device);
        bridge.set_local_identity(identity);
        let supervisor = BluetoothAuto::<_, { AndroidBleBackend::MAX_PEERS }>::new(
            AndroidBleBackend::new(bridge.clone()), identity, Endpoint::Android(AndroidHost::Android),
            LinkCapabilities { l2cap: None, link_mtu: BLE_HW_MTU as u16 },
        );
        let status = supervisor.status();
        let attached = node.handle.supervise(supervisor);
        bridges().lock().unwrap().insert(handle, bridge.clone());
        Ok(Self { handle, node: node.handle.clone(), interface: attached.id(), bridge, status })
    }

    pub fn handle(&self) -> u64 {
        self.handle
    }

    pub fn status(&self) -> BluetoothAutoStatus {
        self.status.clone()
    }

    pub fn peers(&self) -> usize {
        use personal_rns::interfaces::{ConnectionState, InterfaceKind};
        self.node.interfaces().iter().filter(|snapshot| {
            snapshot.id.kind() == Some(InterfaceKind::BluetoothPeer) &&
                matches!(snapshot.connection, ConnectionState::Connected | ConnectionState::Degraded)
        }).count()
    }

    pub fn ready(&self) -> Option<bool> { None } // Android's actual adapter readiness comes from its native plugin.

    pub fn error(&self) -> Option<String> {
        use personal_rns::interfaces::InterfaceStatus;
        self.status.failure_reason().map(str::to_owned)
    }
}

/// iOS's data plane stays in Prns/CoreBluetooth; Swift handles permission/power UI, not packet forwarding.
#[cfg(target_os = "ios")]
pub struct AppleSession {
    handle: u64,
    node: PrnsNodeHandle,
    state: std::sync::Arc<Mutex<AppleState>>,
    preparation: tokio::task::JoinHandle<()>,
}

#[cfg(target_os = "ios")]
#[derive(Default)]
struct AppleState {
    interface: Option<InterfaceId>,
    status: Option<BluetoothAutoStatus>,
    error: Option<String>,
    closed: bool,
}

#[cfg(target_os = "ios")]
impl AppleSession {
    pub fn attach(node: &crate::RnsNode, device: &SecretKey) -> Result<Self> {
        let handle = new_handle()?;
        let state = std::sync::Arc::new(Mutex::new(AppleState::default()));
        let preparing = state.clone();
        let host = node.handle.clone();
        let identity = identity(device);
        let preparation = tokio::spawn(async move {
            use prns_ffi::bluetooth_auto::macos::MacosBleBackend;
            use personal_rns::interfaces::bluetooth_auto::{AppleHost, Endpoint};
            match MacosBleBackend::new(identity).await {
                Ok(backend) => {
                    let supervisor = BluetoothAuto::<_, { MacosBleBackend::MAX_PEERS }>::new(
                        backend, identity, Endpoint::CoreBluetooth(AppleHost::Ios),
                        LinkCapabilities { l2cap: None, link_mtu: BLE_HW_MTU as u16 },
                    );
                    let mut state = preparing.lock().unwrap();
                    if !state.closed {
                        state.status = Some(supervisor.status());
                        state.interface = Some(host.supervise(supervisor).id());
                    }
                }
                Err(error) => { preparing.lock().unwrap().error = Some(format!("CoreBluetooth: {error:?}")); }
            }
        });
        Ok(Self { handle, node: node.handle.clone(), state, preparation })
    }
    pub fn handle(&self) -> u64 { self.handle }
    pub fn peers(&self) -> usize {
        use personal_rns::interfaces::{ConnectionState, InterfaceKind};
        self.node.interfaces().iter().filter(|s| s.id.kind() == Some(InterfaceKind::BluetoothPeer) &&
            matches!(s.connection, ConnectionState::Connected | ConnectionState::Degraded)).count()
    }
    pub fn ready(&self) -> Option<bool> {
        use personal_rns::interfaces::{ConnectionState, InterfaceStatus};
        Some(self.state.lock().unwrap().status.as_ref().is_some_and(|s|
            matches!(s.connection(), ConnectionState::Connected | ConnectionState::Degraded)))
    }
    pub fn error(&self) -> Option<String> {
        use personal_rns::interfaces::InterfaceStatus;
        let state = self.state.lock().unwrap();
        state.error.clone().or_else(|| state.status.as_ref().and_then(|s| s.failure_reason()).map(str::to_owned))
    }
}

#[cfg(target_os = "ios")]
impl Drop for AppleSession {
    fn drop(&mut self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        self.preparation.abort();
        if let Some(interface) = state.interface.take() { self.node.forget_interface(interface); }
    }
}

impl Drop for AndroidSession {
    fn drop(&mut self) {
        self.node.forget_interface(self.interface);
        bridges().lock().unwrap().remove(&self.handle);
        self.bridge.set_radio_mode(RadioMode::Off);
        self.bridge.wake_work();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use crate::{Asker, BoxFut, Config, Handler, RnsNode};
    use std::time::{Duration, Instant};

    struct NoRequests;
    impl Handler for NoRequests {
        fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
            Box::pin(async { panic!("no physical adapter is present") })
        }
        fn notify(&self, _: iroh::PublicKey, _: Vec<u8>) {
            panic!("no physical adapter is present")
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_old_platform_callback_cannot_enter_a_restarted_engine() {
        let key = SecretKey::generate();
        let node = RnsNode::start(Config {
            device: key.clone(), interfaces: vec![], peers: vec![], wifi_group: None,
            paths: vec![], open_paths: vec![], max_bytes: 1024, blobs: None, pair_local_tcp: false,
        }, Arc::new(NoRequests)).await.unwrap();
        let first = AndroidSession::attach(&node, &key).unwrap();
        let old_handle = first.handle();
        let old_bridge = android_bridge(old_handle).unwrap();
        let mut old_identity = [0; 16];
        assert_eq!(old_bridge.local_identity(&mut old_identity), 16);
        drop(first);
        assert!(android_bridge(old_handle).is_none());
        assert_eq!(old_bridge.radio_state(), 0);

        let second = AndroidSession::attach(&node, &key).unwrap();
        assert_ne!(second.handle(), old_handle);
        let new_bridge = android_bridge(second.handle()).unwrap();
        let mut new_identity = [0; 16];
        assert_eq!(new_bridge.local_identity(&mut new_identity), 16);
        assert_eq!(old_identity, new_identity, "restarting the same device keeps its discovery identity");
        assert!(android_bridge(old_handle).is_none(), "old native callbacks stay closed after the new session starts");
        drop(second);
        node.stop();
    }

    struct Echo;
    impl Handler for Echo {
        fn request(&self, who: Asker, _: &str, bytes: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
            assert!(matches!(who, Asker::Linked(_)));
            Box::pin(async move { Ok(bytes) })
        }
        fn notify(&self, _: iroh::PublicKey, _: Vec<u8>) {}
    }

    /// The native adapter boundary in software: two separate Android bridges joined by a virtual GATT link. Real Prns BLE
    /// negotiation, fragmentation and bounded queues carry Reticulum announces, identified links and a resource response.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn two_devices_exchange_verified_bytes_over_virtual_gatt_only() {
        let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
        let config = |key: &SecretKey, other: &SecretKey| Config {
            device: key.clone(), interfaces: vec![],
            peers: vec![(other.public(), Some(crate::destination_for(other).unwrap()))], wifi_group: None,
            paths: vec!["/proof".into()], open_paths: vec![], max_bytes: 64 * 1024, blobs: None, pair_local_tcp: false,
        };
        let a = RnsNode::start(config(&ka, &kb), Arc::new(Echo)).await.unwrap();
        let b = RnsNode::start(config(&kb, &ka), Arc::new(Echo)).await.unwrap();
        let sa = AndroidSession::attach(&a, &ka).unwrap();
        let sb = AndroidSession::attach(&b, &kb).unwrap();
        let ab = android_bridge(sa.handle()).unwrap();
        let bb = android_bridge(sb.handle()).unwrap();
        let start = Instant::now();
        while ab.radio_state() == 0 || bb.radio_state() == 0 {
            assert!(start.elapsed() < Duration::from_secs(10), "both supervisors ask the virtual platform for its radio");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        // No L2CAP PSM: both supervisors must use their GATT data lane.
        ab.set_psm(0);
        bb.set_psm(0);
        assert!(ab.link_up(1, [2, 0, 0, 0, 0, 2], None, false));
        assert!(bb.link_up(1, [2, 0, 0, 0, 0, 1], None, true));
        let pump = tokio::spawn(async move {
            let mut bytes = vec![0; 4096];
            loop {
                for (from, to) in [(&ab, &bb), (&bb, &ab)] {
                    let n = from.control_out(1, &mut bytes);
                    if n > 0 && to.control_in(1, &bytes[..n]) == AndroidBleIngressAdmission::Accepted {
                        assert!(from.commit_control_out(1));
                    }
                    let n = from.data_out(1, &mut bytes);
                    if n > 0 && to.data_in(1, &bytes[..n]) == AndroidBleIngressAdmission::Accepted {
                        assert!(from.commit_data_out(1));
                    }
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        });
        let start = Instant::now();
        while !a.reachable(&kb.public()) || !b.reachable(&ka.public()) {
            assert!(start.elapsed() < Duration::from_secs(30), "announces cross only the virtual BLE carrier");
            a.announce().await.unwrap();
            b.announce().await.unwrap();
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let bytes: Vec<u8> = (0..8192).map(|i| (i % 251) as u8).collect();
        let reply = b.request(&ka.public(), "/proof", &bytes, Duration::from_secs(20)).await;
        pump.abort();
        let _ = pump.await;
        drop((sa, sb));
        a.stop();
        b.stop();
        let reply = reply.expect("identified request and resource response over GATT");
        assert_eq!(blake3::hash(&reply), blake3::hash(&bytes));
        assert_eq!(reply, bytes);
    }
}
