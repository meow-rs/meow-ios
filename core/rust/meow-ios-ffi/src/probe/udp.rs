//! UDP over one proxy: the relay wrapper the UDP probes share, and the
//! relay latency probe.

use super::{millis, udp_metadata, ProbeError, ProbeResult};
use meow_common::{ProxyAdapter, ProxyPacketConn};
use serde_json::json;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;

type Packet = (Vec<u8>, SocketAddr);

/// A proxy's UDP relay for one probe. A task of its own reads it: dropping a
/// `read_packet` half-way would break the framing of relays that carry
/// datagrams in a stream (Trojan, UDP-over-TCP), so reads are never raced
/// against timers. Dropping the relay ends the task and closes the relay.
pub(super) struct Relay {
    conn: Arc<dyn ProxyPacketConn>,
    packets: mpsc::Receiver<Result<Packet, String>>,
    reader: JoinHandle<()>,
}

impl Relay {
    pub(super) async fn dial(
        proxy: &dyn ProxyAdapter,
        dst: SocketAddr,
    ) -> Result<Self, ProbeError> {
        let conn = proxy
            .dial_udp(&udp_metadata(dst))
            .await
            .map_err(|e| ProbeError::failed(format!("dial: {e}")))?;
        Ok(Self::new(Arc::from(conn)))
    }

    pub(super) fn new(conn: Arc<dyn ProxyPacketConn>) -> Self {
        let (tx, packets) = mpsc::channel(16);
        let reader_conn = Arc::clone(&conn);
        let reader = tokio::spawn(async move {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let packet = reader_conn
                    .read_packet(&mut buf)
                    .await
                    .map(|(n, from)| (buf[..n].to_vec(), from))
                    .map_err(|e| e.to_string());
                let failed = packet.is_err();
                if tx.send(packet).await.is_err() || failed {
                    break;
                }
            }
        });
        Self {
            conn,
            packets,
            reader,
        }
    }

    pub(super) async fn send(&self, payload: &[u8], dst: SocketAddr) -> Result<(), ProbeError> {
        self.conn
            .write_packet(payload, &dst)
            .await
            .map(drop)
            .map_err(|e| ProbeError::failed(format!("send: {e}")))
    }

    /// The next datagram and its reported source, or `None` once `deadline`
    /// passes.
    pub(super) async fn recv_until(
        &mut self,
        deadline: tokio::time::Instant,
    ) -> Result<Option<Packet>, ProbeError> {
        match tokio::time::timeout_at(deadline, self.packets.recv()).await {
            Err(_) => Ok(None),
            Ok(None) => Err(ProbeError::failed("the relay closed")),
            Ok(Some(Err(e))) => Err(ProbeError::failed(format!("receive: {e}"))),
            Ok(Some(Ok(packet))) => Ok(Some(packet)),
        }
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.reader.abort();
        let _ = self.conn.close();
    }
}

// ---------------------------------------------------------------------------
// Relay latency
// ---------------------------------------------------------------------------

const DNS_SERVERS: [SocketAddr; 2] = [
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(1, 1, 1, 1), 53)),
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(8, 8, 8, 8), 53)),
];
const QUERY_NAME: &str = "www.gstatic.com";
const LATENCY_TIMEOUT: Duration = Duration::from_secs(5);
const RETRANSMIT_EVERY: Duration = Duration::from_secs(1);

pub(super) async fn latency(proxy: &dyn ProxyAdapter) -> ProbeResult {
    if !proxy.support_udp() {
        return Err(ProbeError::udp_unsupported());
    }
    latency_via(proxy, &DNS_SERVERS, RETRANSMIT_EVERY, LATENCY_TIMEOUT).await
}

/// Time from the dial to the first answer to a DNS query sent over the relay,
/// as the TCP test counts its dial too: `{"ms": …}`. A lost query is resent
/// every `retransmit`, to the next of `servers`.
async fn latency_via(
    proxy: &dyn ProxyAdapter,
    servers: &[SocketAddr],
    retransmit: Duration,
    budget: Duration,
) -> ProbeResult {
    let started = Instant::now();
    let round_trip = async {
        let mut relay = Relay::dial(proxy, servers[0]).await?;
        let id: u16 = rand::random();
        let query = dns_query(id, QUERY_NAME);
        for server in servers.iter().cycle() {
            relay.send(&query, *server).await?;
            let resend_at = tokio::time::Instant::now() + retransmit;
            while let Some((packet, _)) = relay.recv_until(resend_at).await? {
                if answers(&packet, id) {
                    return Ok(json!({ "ms": millis(started.elapsed()) }));
                }
            }
        }
        Err(ProbeError::failed("no DNS server to query"))
    };
    timeout(budget, round_trip)
        .await
        .unwrap_or_else(|_| Err(ProbeError::timeout("no answer in time")))
}

/// A recursive `A` query for `name`.
fn dns_query(id: u16, name: &str) -> Vec<u8> {
    let mut query = Vec::with_capacity(12 + name.len() + 2 + 4);
    query.extend_from_slice(&id.to_be_bytes());
    // RD; one question.
    query.extend_from_slice(&[0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    for label in name.split('.') {
        query.push(label.len() as u8);
        query.extend_from_slice(label.as_bytes());
    }
    query.extend_from_slice(&[0, 0x00, 0x01, 0x00, 0x01]);
    query
}

/// Any response to query `id` counts, NXDOMAIN and SERVFAIL included: the
/// datagram made the round trip.
fn answers(packet: &[u8], id: u16) -> bool {
    packet.len() >= 12 && packet[..2] == id.to_be_bytes() && packet[2] & 0x80 != 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use meow_proxy::DirectAdapter;
    use tokio::net::UdpSocket;

    #[test]
    fn query_layout() {
        let query = dns_query(0xbeef, "a.bc");
        assert_eq!(
            query,
            [
                0xbe, 0xef, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 1, b'a', 2, b'b', b'c', 0, 0, 1, 0,
                1
            ]
        );
        let mut reply = query.clone();
        assert!(!answers(&reply, 0xbeef), "a query is no answer");
        reply[2] |= 0x80;
        assert!(answers(&reply, 0xbeef));
        assert!(!answers(&reply, 0xbeee));
        assert!(!answers(&reply[..11], 0xbeef));
    }

    /// Answers every query it gets with the header flipped to a response.
    async fn dns_echo() -> (SocketAddr, Arc<std::sync::atomic::AtomicUsize>) {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        let seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = Arc::clone(&seen);
        tokio::spawn(async move {
            let mut buf = [0u8; 512];
            while let Ok((n, from)) = socket.recv_from(&mut buf).await {
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                buf[2] |= 0x80;
                let _ = socket.send_to(&buf[..n], from).await;
            }
        });
        (addr, seen)
    }

    #[tokio::test]
    async fn measures_a_round_trip() {
        let (server, seen) = dns_echo().await;
        let value = latency_via(
            &DirectAdapter::new(),
            &[server],
            RETRANSMIT_EVERY,
            LATENCY_TIMEOUT,
        )
        .await
        .unwrap();
        assert!(value["ms"].as_u64().unwrap() < 1000);
        assert_eq!(seen.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn resends_to_the_next_server() {
        // Bound but silent: the first query is lost.
        let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (server, _) = dns_echo().await;
        let retransmit = Duration::from_millis(200);
        let value = latency_via(
            &DirectAdapter::new(),
            &[silent.local_addr().unwrap(), server],
            retransmit,
            LATENCY_TIMEOUT,
        )
        .await
        .unwrap();
        let ms = value["ms"].as_u64().unwrap();
        assert!((200..1000).contains(&ms), "{ms}");
    }

    #[tokio::test]
    async fn times_out_when_nothing_answers() {
        let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let err = latency_via(
            &DirectAdapter::new(),
            &[silent.local_addr().unwrap()],
            Duration::from_millis(50),
            Duration::from_millis(300),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, "timeout");
    }
}
