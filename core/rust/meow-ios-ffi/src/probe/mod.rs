//! Per-node diagnostics behind the proxy detail page.
//!
//! The app asks the PacketTunnel extension (`ProbeIPC`, tag 0x05) to run one
//! probe through one named proxy of the running engine:
//!
//! * `udp-latency` — a DNS query's round trip over the node's UDP relay;
//! * `http-get` — a GET of `arg` (the exit-IP lookup);
//! * `nat` — the NAT behaviour the node's UDP relay presents (RFC 5780);
//! * `download` / `upload` — a bandwidth sample against Cloudflare's speed
//!   test endpoints.
//!
//! Each dials the adapter directly, as the engine's own latency test does,
//! so rules play no part, and marks its dial as a probe
//! (`ConnType::Tunnel`) so it does not count as use of a group. Every probe
//! has its own time budget and can be ended early by the app's id (tag
//! 0x06). Answers are JSON objects; a failure is `{"error": …, "code": …}`.
//!
//! Ported from meow-android's `probe` module; the C ABI lives in `lib.rs`
//! (`meow_probe_proxy`, `meow_cancel_proxy_probe`).

mod http;
mod stun;
mod udp;

use meow_common::{ConnType, Metadata, Network, ProxyAdapter};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fmt;
use std::net::SocketAddr;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

/// Why a probe produced no measurement. `code` is for the UI to branch on;
/// `message` is shown as is.
#[derive(Debug)]
pub(crate) struct ProbeError {
    code: &'static str,
    message: String,
}

impl ProbeError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub(crate) fn failed(message: impl Into<String>) -> Self {
        Self::new("failed", message)
    }

    pub(crate) fn timeout(message: impl Into<String>) -> Self {
        Self::new("timeout", message)
    }

    pub(crate) fn udp_unsupported() -> Self {
        Self::new("udp-unsupported", "the proxy does not relay UDP")
    }
}

impl fmt::Display for ProbeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

type ProbeResult = Result<Value, ProbeError>;

/// A dial marked as a probe: groups skip their usage bump for it, as they do
/// for the engine's own latency test.
pub(crate) fn tcp_metadata(host: &str, port: u16) -> Metadata {
    Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Tunnel,
        host: host.into(),
        dst_port: port,
        ..Default::default()
    }
}

pub(crate) fn udp_metadata(dst: SocketAddr) -> Metadata {
    Metadata {
        network: Network::Udp,
        conn_type: ConnType::Tunnel,
        dst_ip: Some(dst.ip()),
        dst_port: dst.port(),
        ..Default::default()
    }
}

/// Milliseconds for the UI, never 0: a rate divides by it.
pub(crate) fn millis(elapsed: Duration) -> u64 {
    u64::try_from(elapsed.as_millis())
        .unwrap_or(u64::MAX)
        .max(1)
}

async fn probe(proxy: &dyn ProxyAdapter, kind: &str, arg: &str) -> ProbeResult {
    match kind {
        "udp-latency" => udp::latency(proxy).await,
        "http-get" => http::get(proxy, arg).await,
        "nat" => stun::nat_type(proxy).await,
        "download" => http::download(proxy).await,
        "upload" => http::upload(proxy).await,
        other => Err(ProbeError::new(
            "bad-request",
            format!("unknown probe {other:?}"),
        )),
    }
}

/// Runs one probe and returns its JSON answer. Blocks the calling thread
/// until the probe ends; a panic becomes a `failed` answer rather than
/// unwinding into C.
pub(crate) fn run_guarded(id: i64, proxy_name: &str, kind: &str, arg: &str) -> String {
    std::panic::catch_unwind(|| run(id, proxy_name, kind, arg)).unwrap_or_else(|_| {
        inflight().finish(id);
        answer(Err(ProbeError::failed("the probe crashed")))
    })
}

fn run(id: i64, proxy_name: &str, kind: &str, arg: &str) -> String {
    let token = inflight().start(id);
    let result = match crate::engine::tunnel() {
        None => Err(ProbeError::new(
            "engine-stopped",
            "the engine is not running",
        )),
        Some(tunnel) => {
            // Held for the whole probe: a `dialer-proxy` chain resolves its
            // front hop through the route generation it was built in.
            let routes = tunnel.route_snapshot();
            match routes.proxies.get(proxy_name).cloned() {
                None => Err(ProbeError::new(
                    "no-proxy",
                    format!("no proxy named {proxy_name:?}"),
                )),
                Some(proxy) => crate::get_engine_runtime().block_on(async {
                    tokio::select! {
                        result = probe(proxy.as_ref(), kind, arg) => result,
                        () = token.cancelled() => {
                            Err(ProbeError::new("cancelled", "cancelled"))
                        }
                    }
                }),
            }
        }
    };
    inflight().finish(id);
    answer(result)
}

fn answer(result: ProbeResult) -> String {
    match result {
        Ok(value) => value.to_string(),
        Err(e) => json!({ "error": e.message, "code": e.code }).to_string(),
    }
}

// ---------------------------------------------------------------------------
// Cancellation by id
// ---------------------------------------------------------------------------

/// Probes in flight by the app's id. A cancel can reach the extension before
/// its probe does (each provider message is handled on its own queue
/// thread), so a cancel for an unknown id leaves a cancelled token behind for
/// the probe to find. Tokens nobody claims are dropped once they are old.
#[derive(Default)]
struct Inflight {
    tokens: Mutex<HashMap<i64, (CancellationToken, Instant)>>,
}

const STALE_TOKEN: Duration = Duration::from_secs(300);

impl Inflight {
    fn start(&self, id: i64) -> CancellationToken {
        let mut tokens = self.tokens.lock();
        tokens.retain(|_, (_, since)| since.elapsed() < STALE_TOKEN);
        tokens
            .entry(id)
            .or_insert_with(|| (CancellationToken::new(), Instant::now()))
            .0
            .clone()
    }

    fn finish(&self, id: i64) {
        self.tokens.lock().remove(&id);
    }

    fn cancel(&self, id: i64) {
        self.tokens
            .lock()
            .entry(id)
            .or_insert_with(|| (CancellationToken::new(), Instant::now()))
            .0
            .cancel();
    }

    fn cancel_all(&self) {
        for (token, _) in self.tokens.lock().values() {
            token.cancel();
        }
    }
}

fn inflight() -> &'static Inflight {
    static INFLIGHT: OnceLock<Inflight> = OnceLock::new();
    INFLIGHT.get_or_init(Inflight::default)
}

/// Ends probe `id` early; a no-op once it has ended.
pub(crate) fn cancel(id: i64) {
    inflight().cancel(id);
}

/// Ends every running probe; the engine is going away.
pub(crate) fn cancel_all() {
    inflight().cancel_all();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_cancel_that_arrives_first_still_ends_the_probe() {
        let inflight = Inflight::default();
        inflight.cancel(7);
        let token = inflight.start(7);
        assert!(token.is_cancelled());
        inflight.finish(7);
        assert!(!inflight.start(7).is_cancelled());
    }

    #[test]
    fn cancel_all_reaches_every_running_probe() {
        let inflight = Inflight::default();
        let (a, b) = (inflight.start(1), inflight.start(2));
        inflight.cancel_all();
        assert!(a.is_cancelled() && b.is_cancelled());
    }

    #[test]
    fn errors_carry_their_code() {
        let text = answer(Err(ProbeError::udp_unsupported()));
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["code"], "udp-unsupported");
        assert!(value["error"].as_str().is_some_and(|m| !m.is_empty()));
    }
}
