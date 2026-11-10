//! The engine's traffic ledger (`meow_common::traffic_ledger`): every day's
//! traffic by host, policy and network, kept for 62 days, behind the
//! Traffic page. The PacketTunnel writes it under the engine home and tells
//! it the network (`meow_engine_set_network_kind`) and the time zone
//! (`meow_traffic_set_time_zone`); the app reads and clears it from its own
//! process, also while the VPN is down. The C ABI lives in `lib.rs`.
//!
//! Ported from meow-android's `traffic` module, without its App grouping:
//! iOS cannot tell which app opened a flow (see `engine::traffic_ledger`).

use meow_common::traffic_ledger::{self, GroupBy, Query};
use std::path::Path;

/// The report `meow_traffic_read` documents, under the engine home `home`.
pub(crate) fn read_report(
    home: &Path,
    from: i32,
    to: i32,
    by: &str,
    [host, policy, interface]: [Option<String>; 3],
) -> String {
    let by = match by.parse::<GroupBy>() {
        Ok(by) => by,
        Err(e) => return error_json(&e),
    };
    let query = Query {
        from,
        to,
        by,
        host,
        app: None,
        policy,
        interface,
    };
    match traffic_ledger::read(&home.join(traffic_ledger::DIR_NAME), &query) {
        Ok(report) => serde_json::to_string(&report).unwrap_or_else(|e| error_json(&e.to_string())),
        Err(e) => error_json(&e.to_string()),
    }
}

/// Delete everything in the ledger under the engine home `home`.
pub(crate) fn clear(home: &Path) -> std::io::Result<()> {
    traffic_ledger::clear_at(&home.join(traffic_ledger::DIR_NAME))
}

pub(crate) fn error_json(message: &str) -> String {
    serde_json::json!({ "error": message }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use smol_str::SmolStr;
    use std::path::PathBuf;
    use std::sync::Arc;

    /// An empty engine home, `<dir>/meow` as the App Group's `meow` dir;
    /// `<dir>` is removed on drop.
    struct Home(PathBuf);

    impl Home {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("meow-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(dir.join("meow")).unwrap();
            Self(dir)
        }

        fn path(&self) -> PathBuf {
            self.0.join("meow")
        }
    }

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn report(json: &str) -> Value {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn no_ledger_reads_as_an_empty_report() {
        let home = Home::new("traffic-none");
        let json = read_report(&home.path(), 20_000, 20_001, "policy", Default::default());
        let report = report(&json);
        assert_eq!(report["by"], "policy");
        assert_eq!(report["from"], "2024-10-04");
        assert_eq!(report["rows"], serde_json::json!([]));
        assert!(read_report(&home.path(), 0, 0, "nodes", Default::default()).contains("error"));
    }

    #[test]
    fn the_app_reads_and_clears_what_the_engine_wrote() {
        // The ledger is process-wide, and an engine start installs one.
        let _serial = crate::engine::LEDGER_TESTS.lock();
        let home = Home::new("traffic-read");
        let dir = home.path().join(traffic_ledger::DIR_NAME);
        traffic_ledger::install(&dir, crate::engine::traffic_ledger("").1).unwrap();
        // As `meow_engine_set_network_kind` labels a Wi-Fi network.
        assert_eq!(crate::meow_engine_set_network_kind(1), 0);
        let host = SmolStr::new("www.example.com");
        let no_app = SmolStr::default();
        traffic_ledger::add(
            &host,
            &no_app,
            &traffic_ledger::Route::from("HK 01"),
            10,
            20,
            1,
        );
        // A flow out through JP 02 whose hop to its server HK 01 carried
        // (a `dialer-proxy`): HK 01's policy row counts it too, the totals
        // once.
        let chained = traffic_ledger::Route {
            policy: Arc::from("JP 02"),
            via: Some(Arc::from("HK 01")),
        };
        traffic_ledger::add(&host, &no_app, &chained, 1, 2, 1);
        traffic_ledger::flush();
        let today = traffic_ledger::today();

        let narrowed = report(&read_report(
            &home.path(),
            today,
            today,
            "host",
            [None, Some("HK 01".into()), Some("Wi-Fi".into())],
        ));
        assert_eq!(narrowed["rows"][0]["name"], "example.com");
        assert_eq!(narrowed["download"], 22);

        let by_policy = report(&read_report(
            &home.path(),
            today,
            today,
            "policy",
            Default::default(),
        ));
        let rows: Vec<_> = by_policy["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                (
                    row["name"].as_str().unwrap(),
                    row["download"].as_u64().unwrap(),
                )
            })
            .collect();
        assert_eq!(rows, [("HK 01", 22), ("JP 02", 2)]);
        assert_eq!(
            (&by_policy["download"], &by_policy["requests"]),
            (&22.into(), &2.into())
        );

        let by_network = report(&read_report(
            &home.path(),
            today,
            today,
            "interface",
            [Some("example.com".into()), None, None],
        ));
        assert_eq!(by_network["rows"][0]["name"], "Wi-Fi");

        clear(&home.path()).unwrap();
        let json = read_report(&home.path(), today, today, "host", Default::default());
        assert!(json.contains(r#""rows":[]"#), "{json}");
        traffic_ledger::uninstall();
        traffic_ledger::set_interface("");
    }

    /// The Other IP addresses note names the engine's cap from a Swift copy
    /// (`TrafficRow.maxIPHosts`); an engine bump that moves it fails here
    /// until the copy follows.
    #[test]
    fn the_ip_cap_matches_the_app() {
        assert_eq!(
            traffic_ledger::MAX_IP_HOSTS,
            8192,
            "update TrafficRow.maxIPHosts"
        );
        assert_eq!(traffic_ledger::OTHER_IPS, "*", "update TrafficRow.otherIPs");
    }
}
