//! Reads of the engine's logbook (`meow_common::logbook`), the persistent
//! record of notable events behind the Paw Print page: starts and stops,
//! unclean exits, config and provider failures, dialer-proxy switches. The
//! PacketTunnel writes it under the engine home; the app reads it from its
//! own process, also while the VPN is down, through `logbook::read`. The C
//! ABI lives in `lib.rs` (`meow_logbook_read`).
//!
//! Ported from meow-android's `logbook` module.

use meow_common::logbook::{self, Level, Query};
use std::path::Path;

/// A page under the engine home `home`, as `meow_logbook_read` documents.
pub(crate) fn read_page(
    home: &Path,
    before: i64,
    since: i64,
    limit: i32,
    level: &str,
    kind: &str,
) -> String {
    let level = match level {
        "" => None,
        level => match level.parse::<Level>() {
            Ok(level) => Some(level),
            Err(e) => return error_json(&e),
        },
    };
    let query = Query {
        limit: usize::try_from(limit).ok().filter(|&limit| limit > 0),
        before: u64::try_from(before).ok().filter(|&id| id > 0),
        since: u64::try_from(since).ok().filter(|&rev| rev > 0),
        level,
        kind: Some(kind).filter(|kind| !kind.is_empty()).map(Into::into),
        ..Query::default()
    };
    match logbook::read(&home.join(logbook::DIR_NAME), &query) {
        Ok(page) => serde_json::to_string(&page).unwrap_or_else(|e| error_json(&e.to_string())),
        Err(e) => error_json(&e.to_string()),
    }
}

pub(crate) fn error_json(message: &str) -> String {
    serde_json::json!({ "error": message }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::PathBuf;

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

    fn page(home: &Path, before: i64, since: i64, limit: i32, level: &str) -> Value {
        of_kind(home, before, since, limit, level, "")
    }

    fn of_kind(home: &Path, before: i64, since: i64, limit: i32, level: &str, kind: &str) -> Value {
        serde_json::from_str(&read_page(home, before, since, limit, level, kind)).unwrap()
    }

    fn messages(page: &Value) -> Vec<&str> {
        page["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["message"].as_str().unwrap())
            .collect()
    }

    #[test]
    fn no_logbook_reads_as_an_empty_page() {
        let home = Home::new("logbook-none");
        let page = page(&home.path(), 0, 0, 0, "");
        assert_eq!(messages(&page), Vec::<&str>::new());
        assert_eq!(page["rev"], 0);
        assert_eq!(page["more"], false);
    }

    #[test]
    fn reads_what_the_engine_recorded_after_it_stopped() {
        // The logbook is process-wide; no other test here installs one.
        let home = Home::new("logbook-read");
        logbook::install(&home.path().join(logbook::DIR_NAME), Default::default()).unwrap();
        for (level, message) in [
            (Level::Info, "first"),
            (Level::Error, "second"),
            (Level::Warning, "third"),
        ] {
            logbook::event(logbook::kind::CONFIG_RELOAD, level, message).record();
        }
        logbook::event(logbook::kind::DIALER_PROXY_SWITCH, Level::Info, "switched")
            .subject("US Home")
            .record();
        // Writes out what is pending and closes the database, as a stopped
        // PacketTunnel would have.
        logbook::uninstall();

        let all = page(&home.path(), 0, 0, 0, "");
        assert_eq!(messages(&all), ["switched", "third", "second", "first"]);
        assert_eq!(all["entries"][1]["kind"], "config.reload");
        assert_eq!(all["entries"][1]["level"], "warning");
        let rev = all["rev"].as_i64().unwrap();
        assert!(rev > 0);

        let newest = page(&home.path(), 0, 0, 1, "");
        assert_eq!(messages(&newest), ["switched"]);
        assert_eq!(newest["more"], true);
        let older = newest["entries"][0]["id"].as_i64().unwrap();
        assert_eq!(
            messages(&page(&home.path(), older, 0, 0, "")),
            ["third", "second", "first"]
        );

        // A kind, or its area; the page's rev is the logbook's either way.
        let switches = of_kind(&home.path(), 0, 0, 0, "", "dialer-proxy.switch");
        assert_eq!(messages(&switches), ["switched"]);
        assert_eq!(switches["rev"], all["rev"]);
        assert_eq!(
            messages(&of_kind(&home.path(), 0, 0, 0, "", "config")),
            ["third", "second", "first"]
        );

        assert_eq!(
            messages(&page(&home.path(), 0, 0, 0, "warning")),
            ["third", "second"]
        );
        assert_eq!(
            messages(&page(&home.path(), 0, rev, 0, "")),
            Vec::<&str>::new()
        );
        assert!(page(&home.path(), 0, 0, 0, "loud")["error"].is_string());
    }
}
