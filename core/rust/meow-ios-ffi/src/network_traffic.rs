//! Splits one engine run's byte totals by the kind of network they left the
//! device on, for the app's Statistics page. The engine keeps only totals, so
//! when the extension's path monitor reports a new network, what they gained
//! since the last change is charged to the network that was in use meanwhile;
//! a read charges the gain so far to the current one.
//!
//! Bytes counted while no network is known stay unclaimed and go to the next
//! one: they can only be the tail of a hand-over.
//!
//! The same meter as meow-android's `NetworkTrafficMeter`. The kind outlives
//! engine runs (the path monitor reports changes, not the state at each
//! start); the split restarts with the totals on every `engine::start`.

use parking_lot::Mutex;
use std::os::raw::c_int;

/// The network kinds `meow_engine_set_network_kind` takes; `0` is none.
pub const MEOW_NETWORK_KIND_NONE: c_int = 0;
pub const MEOW_NETWORK_KIND_WIFI_ETHERNET: c_int = 1;
pub const MEOW_NETWORK_KIND_CELLULAR: c_int = 2;
pub const MEOW_NETWORK_KIND_OTHER: c_int = 3;

/// One engine run's bytes by the kind of network they went out on.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct MeowInterfaceTraffic {
    pub wifi_ethernet_upload: i64,
    pub wifi_ethernet_download: i64,
    pub cellular_upload: i64,
    pub cellular_download: i64,
    pub other_upload: i64,
    pub other_download: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    WifiEthernet,
    Cellular,
    Other,
}

impl Kind {
    /// `Ok(None)` for no network, `Err` for a value outside the constants.
    pub(crate) fn from_c(kind: c_int) -> Result<Option<Self>, ()> {
        match kind {
            MEOW_NETWORK_KIND_NONE => Ok(None),
            MEOW_NETWORK_KIND_WIFI_ETHERNET => Ok(Some(Self::WifiEthernet)),
            MEOW_NETWORK_KIND_CELLULAR => Ok(Some(Self::Cellular)),
            MEOW_NETWORK_KIND_OTHER => Ok(Some(Self::Other)),
            _ => Err(()),
        }
    }
}

#[derive(Debug)]
struct Meter {
    split: MeowInterfaceTraffic,
    current: Option<Kind>,
    charged_tx: i64,
    charged_rx: i64,
}

impl Meter {
    const fn new() -> Self {
        Self {
            split: MeowInterfaceTraffic {
                wifi_ethernet_upload: 0,
                wifi_ethernet_download: 0,
                cellular_upload: 0,
                cellular_download: 0,
                other_upload: 0,
                other_download: 0,
            },
            current: None,
            charged_tx: 0,
            charged_rx: 0,
        }
    }

    /// The default network is now `kind`, or none; `tx` and `rx` are the
    /// engine's totals at the change.
    fn on_network(&mut self, kind: Option<Kind>, tx: i64, rx: i64) {
        self.charge(tx, rx);
        self.current = kind;
    }

    /// The run so far; `tx` and `rx` are the engine's totals now.
    fn read(&mut self, tx: i64, rx: i64) -> MeowInterfaceTraffic {
        self.charge(tx, rx);
        self.split
    }

    /// A new engine run: its totals start from zero, on the same network.
    fn restart(&mut self) {
        *self = Self {
            current: self.current,
            ..Self::new()
        };
    }

    fn charge(&mut self, tx: i64, rx: i64) {
        let Some(kind) = self.current else {
            return;
        };
        // The totals only grow while the engine runs, and `restart` zeroes
        // what was charged before the next run; a read racing the stop sees
        // them back at zero.
        let up = (tx - self.charged_tx).max(0);
        let down = (rx - self.charged_rx).max(0);
        let split = &mut self.split;
        let (upload, download) = match kind {
            Kind::WifiEthernet => (
                &mut split.wifi_ethernet_upload,
                &mut split.wifi_ethernet_download,
            ),
            Kind::Cellular => (&mut split.cellular_upload, &mut split.cellular_download),
            Kind::Other => (&mut split.other_upload, &mut split.other_download),
        };
        *upload += up;
        *download += down;
        self.charged_tx = tx;
        self.charged_rx = rx;
    }
}

static METER: Mutex<Meter> = Mutex::new(Meter::new());

/// Reads the totals under the meter's lock, so two readers cannot charge
/// out of order and count the same bytes twice.
pub(crate) fn set_kind(kind: Option<Kind>) {
    let mut meter = METER.lock();
    let (tx, rx) = crate::engine::traffic();
    meter.on_network(kind, tx, rx);
}

pub(crate) fn read() -> MeowInterfaceTraffic {
    let mut meter = METER.lock();
    let (tx, rx) = crate::engine::traffic();
    meter.read(tx, rx)
}

/// Called by `engine::start` while no engine runs, so the totals are zero.
pub(crate) fn restart() {
    METER.lock().restart();
}

#[cfg(test)]
mod tests {
    use super::{Kind, MeowInterfaceTraffic, Meter};

    #[test]
    fn traffic_is_charged_to_the_network_it_went_out_on() {
        let mut meter = Meter::new();
        meter.on_network(Some(Kind::WifiEthernet), 0, 0);
        meter.on_network(Some(Kind::Cellular), 100, 1000);
        let split = meter.read(120, 1300);
        assert_eq!(
            split,
            MeowInterfaceTraffic {
                wifi_ethernet_upload: 100,
                wifi_ethernet_download: 1000,
                cellular_upload: 20,
                cellular_download: 300,
                ..MeowInterfaceTraffic::default()
            }
        );
    }

    #[test]
    fn a_read_charges_the_gain_so_far() {
        let mut meter = Meter::new();
        meter.on_network(Some(Kind::Other), 0, 0);
        assert_eq!(meter.read(5, 7).other_upload, 5);
        let split = meter.read(9, 10);
        assert_eq!((split.other_upload, split.other_download), (9, 10));
    }

    #[test]
    fn bytes_counted_with_no_network_go_to_the_next_one() {
        let mut meter = Meter::new();
        meter.on_network(Some(Kind::WifiEthernet), 10, 10);
        meter.on_network(None, 30, 30);
        meter.read(35, 40);
        meter.on_network(Some(Kind::Cellular), 40, 50);
        let split = meter.read(40, 50);
        assert_eq!(
            split,
            MeowInterfaceTraffic {
                wifi_ethernet_upload: 30,
                wifi_ethernet_download: 30,
                cellular_upload: 10,
                cellular_download: 20,
                ..MeowInterfaceTraffic::default()
            }
        );
    }

    #[test]
    fn totals_back_at_zero_charge_nothing() {
        let mut meter = Meter::new();
        meter.on_network(Some(Kind::Cellular), 0, 0);
        meter.read(50, 60);
        let split = meter.read(0, 0);
        assert_eq!((split.cellular_upload, split.cellular_download), (50, 60));
    }

    #[test]
    fn a_restart_keeps_the_network_and_starts_from_zero() {
        let mut meter = Meter::new();
        meter.on_network(Some(Kind::WifiEthernet), 0, 0);
        meter.read(500, 600);
        meter.restart();
        let split = meter.read(30, 40);
        assert_eq!(
            split,
            MeowInterfaceTraffic {
                wifi_ethernet_upload: 30,
                wifi_ethernet_download: 40,
                ..MeowInterfaceTraffic::default()
            }
        );
    }

    #[test]
    fn the_setter_rejects_unknown_kinds() {
        assert_eq!(crate::meow_engine_set_network_kind(4), -1);
        assert_eq!(
            crate::meow_engine_set_network_kind(super::MEOW_NETWORK_KIND_NONE),
            0
        );
    }

    #[test]
    fn kinds_follow_the_c_constants() {
        assert_eq!(Kind::from_c(0), Ok(None));
        assert_eq!(Kind::from_c(1), Ok(Some(Kind::WifiEthernet)));
        assert_eq!(Kind::from_c(2), Ok(Some(Kind::Cellular)));
        assert_eq!(Kind::from_c(3), Ok(Some(Kind::Other)));
        assert_eq!(Kind::from_c(4), Err(()));
        assert_eq!(Kind::from_c(-1), Err(()));
    }
}
