//! The NAT behaviour a proxy's UDP relay presents, found the way RFC 5780
//! (STUN NAT behaviour discovery) does it:
//!
//! * mapping — does the relay keep one public address for every
//!   destination, or a new one per destination address (or address and
//!   port)?
//! * filtering — whom does it let answer: anyone, only addresses it has sent
//!   to, or only exact address-and-port pairs it has sent to?
//!
//! The UI names the combination the classic way (full cone, restricted cone,
//! port-restricted cone, symmetric).

use super::udp::Relay;
use super::{ProbeError, ProbeResult};
use meow_common::ProxyAdapter;
use serde_json::{json, Value};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;
use tokio::time::{timeout, Instant};

/// Servers that answer from a second address and port on request
/// (`OTHER-ADDRESS` + `CHANGE-REQUEST`), tried in order.
const RFC5780_SERVERS: [(&str, u16); 3] = [
    ("stunserver2025.stunprotocol.org", 3478),
    ("stun.miwifi.com", 3478),
    ("stun.fitauto.ru", 3478),
];
/// Plain servers on unrelated addresses: when no RFC 5780 server answers,
/// they still tell whether the mapping depends on the destination.
const PLAIN_SERVERS: [(&str, u16); 2] =
    [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478)];

const NAT_TIMEOUT: Duration = Duration::from_secs(20);

/// When one binding transaction (re)sends its request, and when it gives up
/// on an answer.
#[derive(Clone, Copy)]
struct Schedule {
    sends: [Duration; 3],
    give_up: Duration,
}

const SCHEDULE: Schedule = Schedule {
    sends: [
        Duration::ZERO,
        Duration::from_millis(500),
        Duration::from_millis(1500),
    ],
    give_up: Duration::from_millis(2500),
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Behavior {
    EndpointIndependent,
    AddressDependent,
    AddressAndPortDependent,
    /// Not endpoint-independent; the test could not tell which of the two.
    Dependent,
    Unknown,
}

impl Behavior {
    fn wire(self) -> &'static str {
        match self {
            Self::EndpointIndependent => "endpoint-independent",
            Self::AddressDependent => "address-dependent",
            Self::AddressAndPortDependent => "address-and-port-dependent",
            Self::Dependent => "dependent",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Report {
    mapping: Behavior,
    filtering: Behavior,
    /// The relay's public address, as the first server saw it.
    mapped: Option<SocketAddr>,
    /// Why the behaviour stayed unknown, when the answers say.
    note: Option<&'static str>,
}

impl Report {
    fn to_json(&self, server: &str) -> Value {
        json!({
            "mapping": self.mapping.wire(),
            "filtering": self.filtering.wire(),
            "mapped": self.mapped.map(|a| a.to_string()),
            "server": server,
            "note": self.note,
        })
    }
}

/// The relay reports one source for every datagram (the destination it is
/// bound to, or none at all), so no answer can be told apart by its sender.
const NOTE_SOURCE_HIDDEN: &str = "source-hidden";

pub(super) async fn nat_type(proxy: &dyn ProxyAdapter) -> ProbeResult {
    if !proxy.support_udp() {
        return Err(ProbeError::udp_unsupported());
    }
    timeout(NAT_TIMEOUT, discover(proxy))
        .await
        .unwrap_or_else(|_| Err(ProbeError::timeout("the test did not finish in time")))
}

async fn discover(proxy: &dyn ProxyAdapter) -> ProbeResult {
    for (host, port) in RFC5780_SERVERS {
        let Some(primary) = resolve(host, port).await else {
            continue;
        };
        let mut relay = Relay::dial(proxy, primary).await?;
        if let Some(report) = classify(&mut relay, primary, SCHEDULE).await {
            return Ok(report.to_json(host));
        }
    }
    let mut servers = Vec::new();
    for (host, port) in PLAIN_SERVERS {
        if let Some(addr) = resolve(host, port).await {
            servers.push(addr);
        }
    }
    if let [first, second] = servers[..] {
        let mut relay = Relay::dial(proxy, first).await?;
        if let Some(report) = mapping_only(&mut relay, first, second, SCHEDULE).await {
            return Ok(report.to_json(PLAIN_SERVERS[0].0));
        }
    }
    Err(ProbeError::new(
        "no-reply",
        "no STUN server answered through this proxy",
    ))
}

/// Through the engine's resolver hook (real addresses, not fake-IP), IPv4
/// first: a relay's server side is far more often IPv4-only than not.
async fn resolve(host: &str, port: u16) -> Option<SocketAddr> {
    let addrs = meow_common::resolve_host_all(host, port).await.ok()?;
    addrs
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| addrs.first())
        .copied()
}

fn same(a: SocketAddr, b: SocketAddr) -> bool {
    a.port() == b.port() && a.ip().to_canonical() == b.ip().to_canonical()
}

/// RFC 5780 §4.3 / §4.4 against one server. `None` when the server does not
/// answer or cannot run the test (no usable `OTHER-ADDRESS`), so the next one
/// is tried.
async fn classify(relay: &mut Relay, primary: SocketAddr, schedule: Schedule) -> Option<Report> {
    let Outcome::Answered { from, answer } = transact(relay, primary, 0, schedule).await else {
        return None;
    };
    let mapped = answer.mapped?;
    if !same(from, primary) {
        return Some(Report {
            mapping: Behavior::Unknown,
            filtering: Behavior::Unknown,
            mapped: Some(mapped),
            note: Some(NOTE_SOURCE_HIDDEN),
        });
    }
    let other = answer.other.filter(|o| {
        o.ip().to_canonical() != primary.ip().to_canonical() && o.port() != primary.port()
    })?;

    // Filtering first, while `primary` is still the only address contacted:
    // a later send to the other address would open the filter for it.
    let filtering = match transact(relay, primary, CHANGE_IP | CHANGE_PORT, schedule).await {
        Outcome::Answered { from, .. } if same(from, other) => Behavior::EndpointIndependent,
        Outcome::Silent => {
            let other_port = SocketAddr::new(primary.ip(), other.port());
            match transact(relay, primary, CHANGE_PORT, schedule).await {
                Outcome::Answered { from, .. } if same(from, other_port) => {
                    Behavior::AddressDependent
                }
                Outcome::Silent => Behavior::AddressAndPortDependent,
                _ => Behavior::Unknown,
            }
        }
        // From somewhere else (a relay that reports its bound destination
        // for every datagram, or a server ignoring the request), refused, or
        // not sent at all.
        _ => Behavior::Unknown,
    };

    let alternate = SocketAddr::new(other.ip(), primary.port());
    let mapping = match transact(relay, alternate, 0, schedule).await {
        Outcome::Answered { from, answer } if same(from, alternate) => match answer.mapped {
            Some(m) if same(m, mapped) => Behavior::EndpointIndependent,
            Some(m2) => match transact(relay, other, 0, schedule).await {
                Outcome::Answered { from, answer } if same(from, other) => match answer.mapped {
                    Some(m3) if same(m3, m2) => Behavior::AddressDependent,
                    Some(_) => Behavior::AddressAndPortDependent,
                    None => Behavior::Unknown,
                },
                _ => Behavior::Unknown,
            },
            None => Behavior::Unknown,
        },
        _ => Behavior::Unknown,
    };
    let note = (mapping == Behavior::Unknown && filtering == Behavior::Unknown)
        .then_some(NOTE_SOURCE_HIDDEN);
    Some(Report {
        mapping,
        filtering,
        mapped: Some(mapped),
        note,
    })
}

/// Two plain servers: the same mapped address for both means the mapping is
/// endpoint-independent. Filtering cannot be tested without `CHANGE-REQUEST`.
async fn mapping_only(
    relay: &mut Relay,
    first: SocketAddr,
    second: SocketAddr,
    schedule: Schedule,
) -> Option<Report> {
    let Outcome::Answered { from, answer } = transact(relay, first, 0, schedule).await else {
        return None;
    };
    let m1 = answer.mapped?;
    let unknown = |note| Report {
        mapping: Behavior::Unknown,
        filtering: Behavior::Unknown,
        mapped: Some(m1),
        note,
    };
    if !same(from, first) {
        return Some(unknown(Some(NOTE_SOURCE_HIDDEN)));
    }
    let mapping = match transact(relay, second, 0, schedule).await {
        Outcome::Answered { from, answer } if same(from, second) => match answer.mapped {
            Some(m2) if same(m2, m1) => Behavior::EndpointIndependent,
            Some(_) => Behavior::Dependent,
            None => Behavior::Unknown,
        },
        _ => Behavior::Unknown,
    };
    Some(Report {
        mapping,
        ..unknown(None)
    })
}

// ---------------------------------------------------------------------------
// STUN messages (RFC 5389, plus RFC 5780's attributes)
// ---------------------------------------------------------------------------

const MAGIC_COOKIE: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const BINDING_ERROR: u16 = 0x0111;

const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_CHANGE_REQUEST: u16 = 0x0003;
/// RFC 3489's name for what RFC 5780 calls `OTHER-ADDRESS`.
const ATTR_CHANGED_ADDRESS: u16 = 0x0005;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_OTHER_ADDRESS: u16 = 0x802C;

const CHANGE_IP: u32 = 0x04;
const CHANGE_PORT: u32 = 0x02;

fn binding_request(tid: &[u8; 12], change: u32) -> Vec<u8> {
    let mut request = Vec::with_capacity(28);
    request.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    request.extend_from_slice(&(if change == 0 { 0u16 } else { 8 }).to_be_bytes());
    request.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    request.extend_from_slice(tid);
    if change != 0 {
        request.extend_from_slice(&ATTR_CHANGE_REQUEST.to_be_bytes());
        request.extend_from_slice(&4u16.to_be_bytes());
        request.extend_from_slice(&change.to_be_bytes());
    }
    request
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Answer {
    mapped: Option<SocketAddr>,
    other: Option<SocketAddr>,
}

#[derive(Debug, PartialEq, Eq)]
enum Reply {
    Success(Answer),
    Error,
}

/// A response to transaction `tid`, or `None` for anything else.
fn parse_reply(packet: &[u8], tid: &[u8; 12]) -> Option<Reply> {
    if packet.len() < 20 || packet[8..20] != tid[..] {
        return None;
    }
    let kind = u16::from_be_bytes([packet[0], packet[1]]);
    let len = usize::from(u16::from_be_bytes([packet[2], packet[3]]));
    match kind {
        BINDING_SUCCESS => {}
        BINDING_ERROR => return Some(Reply::Error),
        _ => return None,
    }
    let attrs = packet.get(20..20 + len)?;
    let mut answer = Answer::default();
    let (mut xor_mapped, mut mapped, mut other, mut changed) = (None, None, None, None);
    let mut rest = attrs;
    while rest.len() >= 4 {
        let kind = u16::from_be_bytes([rest[0], rest[1]]);
        let len = usize::from(u16::from_be_bytes([rest[2], rest[3]]));
        let Some(value) = rest.get(4..4 + len) else {
            break;
        };
        match kind {
            ATTR_XOR_MAPPED_ADDRESS => xor_mapped = address(value, Some(tid)),
            ATTR_MAPPED_ADDRESS => mapped = address(value, None),
            ATTR_OTHER_ADDRESS => other = address(value, None),
            ATTR_CHANGED_ADDRESS => changed = address(value, None),
            _ => {}
        }
        // Values are padded to a multiple of four.
        let padded = (4 + len + 3) & !3;
        rest = rest.get(padded..).unwrap_or_default();
    }
    answer.mapped = xor_mapped.or(mapped);
    answer.other = other.or(changed);
    Some(Reply::Success(answer))
}

/// An address attribute's value; XOR-encoded when `xor` carries the
/// transaction id.
fn address(value: &[u8], xor: Option<&[u8; 12]>) -> Option<SocketAddr> {
    if value.len() < 4 {
        return None;
    }
    let mut port = u16::from_be_bytes([value[2], value[3]]);
    let mut key = [0u8; 16];
    key[..4].copy_from_slice(&MAGIC_COOKIE.to_be_bytes());
    if let Some(tid) = xor {
        key[4..].copy_from_slice(tid);
        port ^= (MAGIC_COOKIE >> 16) as u16;
    }
    let unmask = |bytes: &[u8]| -> Vec<u8> {
        bytes
            .iter()
            .zip(key.iter())
            .map(|(b, k)| if xor.is_some() { b ^ k } else { *b })
            .collect()
    };
    let ip = match (value[1], value.len()) {
        (0x01, 8) => {
            let b = unmask(&value[4..8]);
            IpAddr::V4(Ipv4Addr::new(b[0], b[1], b[2], b[3]))
        }
        (0x02, 20) => {
            let b: [u8; 16] = unmask(&value[4..20]).try_into().ok()?;
            IpAddr::V6(Ipv6Addr::from(b))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

enum Outcome {
    Answered {
        from: SocketAddr,
        answer: Answer,
    },
    /// An error response: the server would not do what was asked.
    Refused,
    /// No answer within the schedule.
    Silent,
    /// The request could not be sent, or the relay failed.
    Failed,
}

/// One binding transaction to `dst`, resent on `schedule`. Answers to
/// earlier transactions (late duplicates) are skipped by their id.
async fn transact(relay: &mut Relay, dst: SocketAddr, change: u32, schedule: Schedule) -> Outcome {
    let tid: [u8; 12] = rand::random();
    let request = binding_request(&tid, change);
    let start = Instant::now();
    for (i, at) in schedule.sends.iter().enumerate() {
        let until = start
            + schedule
                .sends
                .get(i + 1)
                .copied()
                .unwrap_or(schedule.give_up);
        tokio::time::sleep_until(start + *at).await;
        if relay.send(&request, dst).await.is_err() {
            return Outcome::Failed;
        }
        loop {
            match relay.recv_until(until).await {
                Ok(Some((packet, from))) => match parse_reply(&packet, &tid) {
                    Some(Reply::Success(answer)) => return Outcome::Answered { from, answer },
                    Some(Reply::Error) => return Outcome::Refused,
                    None => {}
                },
                Ok(None) => break,
                Err(_) => return Outcome::Failed,
            }
        }
    }
    Outcome::Silent
}

#[cfg(test)]
mod tests {
    use super::*;
    use meow_common::{MeowError, ProxyPacketConn};
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::net::UdpSocket;
    use tokio::sync::mpsc;

    const TEST_SCHEDULE: Schedule = Schedule {
        sends: [
            Duration::ZERO,
            Duration::from_millis(60),
            Duration::from_millis(150),
        ],
        give_up: Duration::from_millis(250),
    };

    const TID: [u8; 12] = [
        0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
    ];

    #[test]
    fn rfc5769_sample_ipv4_response() {
        // RFC 5769 §2.2, with its SOFTWARE, MESSAGE-INTEGRITY and FINGERPRINT
        // attributes (all skipped here).
        let packet = hex("0101003c2112a442b7e7a701bc34d686fa87dfae\
             8022000b7465737420766563746f7220\
             002000080001a147e112a643\
             000800142b91f599fd9e90c38c7489f92af9ba53f06be7d7\
             80280004c07d4c96");
        assert_eq!(
            parse_reply(&packet, &TID),
            Some(Reply::Success(Answer {
                mapped: Some("192.0.2.1:32853".parse().unwrap()),
                other: None,
            }))
        );
        let mut other_tid = TID;
        other_tid[11] ^= 1;
        assert_eq!(parse_reply(&packet, &other_tid), None);
    }

    #[test]
    fn rfc5769_sample_ipv6_mapped_address() {
        // RFC 5769 §2.3's XOR-MAPPED-ADDRESS.
        let packet = hex("010100182112a442b7e7a701bc34d686fa87dfae\
             002000140002a1470113a9faa5d3f179bc25f4b5bed2b9d9");
        let Some(Reply::Success(answer)) = parse_reply(&packet, &TID) else {
            panic!("no answer");
        };
        assert_eq!(
            answer.mapped,
            Some(
                "[2001:db8:1234:5678:11:2233:4455:6677]:32853"
                    .parse()
                    .unwrap()
            )
        );
    }

    #[test]
    fn plain_and_rfc3489_attributes() {
        // MAPPED-ADDRESS and CHANGED-ADDRESS, as an RFC 3489 server sends.
        let packet = hex("010100182112a442b7e7a701bc34d686fa87dfae\
             0001000800010d96c0000201\
             00050008000100500c000202");
        assert_eq!(
            parse_reply(&packet, &TID),
            Some(Reply::Success(Answer {
                mapped: Some("192.0.2.1:3478".parse().unwrap()),
                other: Some("12.0.2.2:80".parse().unwrap()),
            }))
        );
        let error = hex("011100002112a442b7e7a701bc34d686fa87dfae");
        assert_eq!(parse_reply(&error, &TID), Some(Reply::Error));
        // Shorter than its declared length: no answer, and no read past it.
        assert!(parse_reply(&packet[..30], &TID).is_none());
    }

    #[test]
    fn request_layout() {
        assert_eq!(
            binding_request(&TID, 0),
            hex("000100002112a442b7e7a701bc34d686fa87dfae")
        );
        assert_eq!(
            binding_request(&TID, CHANGE_IP | CHANGE_PORT),
            hex("000100082112a442b7e7a701bc34d686fa87dfae0003000400000006")
        );
    }

    fn hex(s: &str) -> Vec<u8> {
        let s: String = s.split_whitespace().collect();
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    // -----------------------------------------------------------------------
    // An RFC 5780 server on loopback: 127.0.0.1 and 127.0.0.2, two ports each
    // -----------------------------------------------------------------------

    #[derive(Clone, Copy)]
    enum ServerMode {
        Full,
        /// Answers without OTHER-ADDRESS, as a plain server does.
        Plain,
        /// Rejects CHANGE-REQUEST with an error response.
        RefusesChange,
    }

    async fn stun_server(mode: ServerMode) -> SocketAddr {
        let (a1, a2): (IpAddr, IpAddr) =
            ("127.0.0.1".parse().unwrap(), "127.0.0.2".parse().unwrap());
        let (sockets, p1, p2) = loop {
            let first = UdpSocket::bind((a1, 0)).await.unwrap();
            let p1 = first.local_addr().unwrap().port();
            let second = UdpSocket::bind((a1, 0)).await.unwrap();
            let p2 = second.local_addr().unwrap().port();
            let (Ok(third), Ok(fourth)) = (
                UdpSocket::bind((a2, p1)).await,
                UdpSocket::bind((a2, p2)).await,
            ) else {
                continue;
            };
            break ([first, second, third, fourth].map(Arc::new), p1, p2);
        };
        let by_addr: HashMap<SocketAddr, Arc<UdpSocket>> = sockets
            .iter()
            .map(|s| (s.local_addr().unwrap(), Arc::clone(s)))
            .collect();
        for socket in sockets {
            let by_addr = by_addr.clone();
            tokio::spawn(async move {
                let me = socket.local_addr().unwrap();
                let mut buf = [0u8; 512];
                while let Ok((n, from)) = socket.recv_from(&mut buf).await {
                    let request = &buf[..n];
                    let tid: [u8; 12] = request[8..20].try_into().unwrap();
                    let change = if n >= 28 {
                        u32::from_be_bytes(request[24..28].try_into().unwrap())
                    } else {
                        0
                    };
                    let flip_ip = |ip: IpAddr| if ip == a1 { a2 } else { a1 };
                    let flip_port = |p: u16| if p == p1 { p2 } else { p1 };
                    if change != 0 && matches!(mode, ServerMode::RefusesChange) {
                        let mut error = Vec::new();
                        error.extend_from_slice(&BINDING_ERROR.to_be_bytes());
                        error.extend_from_slice(&0u16.to_be_bytes());
                        error.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
                        error.extend_from_slice(&tid);
                        let _ = socket.send_to(&error, from).await;
                        continue;
                    }
                    let reply_from = SocketAddr::new(
                        if change & CHANGE_IP != 0 {
                            flip_ip(me.ip())
                        } else {
                            me.ip()
                        },
                        if change & CHANGE_PORT != 0 {
                            flip_port(me.port())
                        } else {
                            me.port()
                        },
                    );
                    let other = SocketAddr::new(flip_ip(me.ip()), flip_port(me.port()));
                    let mut attrs = xor_address_attr(from);
                    if !matches!(mode, ServerMode::Plain) {
                        attrs.extend_from_slice(&address_attr(ATTR_OTHER_ADDRESS, other));
                    }
                    let mut reply = Vec::new();
                    reply.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
                    reply.extend_from_slice(&(attrs.len() as u16).to_be_bytes());
                    reply.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
                    reply.extend_from_slice(&tid);
                    reply.extend_from_slice(&attrs);
                    let _ = by_addr[&reply_from].send_to(&reply, from).await;
                }
            });
        }
        SocketAddr::new(a1, p1)
    }

    fn address_attr(kind: u16, addr: SocketAddr) -> Vec<u8> {
        let SocketAddr::V4(v4) = addr else {
            unreachable!()
        };
        let mut attr = Vec::new();
        attr.extend_from_slice(&kind.to_be_bytes());
        attr.extend_from_slice(&8u16.to_be_bytes());
        attr.extend_from_slice(&[0, 1]);
        attr.extend_from_slice(&v4.port().to_be_bytes());
        attr.extend_from_slice(&v4.ip().octets());
        attr
    }

    fn xor_address_attr(addr: SocketAddr) -> Vec<u8> {
        let SocketAddr::V4(v4) = addr else {
            unreachable!()
        };
        let port = v4.port() ^ (MAGIC_COOKIE >> 16) as u16;
        let ip = u32::from(*v4.ip()) ^ MAGIC_COOKIE;
        address_attr(
            ATTR_XOR_MAPPED_ADDRESS,
            SocketAddr::new(Ipv4Addr::from(ip).into(), port),
        )
    }

    // -----------------------------------------------------------------------
    // Relays with a NAT's behaviour, over real loopback sockets
    // -----------------------------------------------------------------------

    /// Maps and filters like a NAT of the given behaviour: one socket per
    /// mapping key, and inbound datagrams dropped unless the filter admits
    /// their source.
    struct SimNat {
        mapping: Behavior,
        filtering: Behavior,
        sockets: parking_lot::Mutex<HashMap<String, Arc<UdpSocket>>>,
        contacted: parking_lot::Mutex<Vec<SocketAddr>>,
        tx: mpsc::UnboundedSender<(Vec<u8>, SocketAddr)>,
        rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<(Vec<u8>, SocketAddr)>>,
        /// Report this source for every datagram instead of the real one.
        reported_source: Option<SocketAddr>,
    }

    impl SimNat {
        fn new(mapping: Behavior, filtering: Behavior) -> Self {
            let (tx, rx) = mpsc::unbounded_channel();
            Self {
                mapping,
                filtering,
                sockets: parking_lot::Mutex::default(),
                contacted: parking_lot::Mutex::default(),
                tx,
                rx: tokio::sync::Mutex::new(rx),
                reported_source: None,
            }
        }

        async fn socket_for(&self, dst: SocketAddr) -> Arc<UdpSocket> {
            let key = match self.mapping {
                Behavior::EndpointIndependent => String::new(),
                Behavior::AddressDependent => dst.ip().to_string(),
                _ => dst.to_string(),
            };
            if let Some(socket) = self.sockets.lock().get(&key) {
                return Arc::clone(socket);
            }
            let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
            let (reader, tx) = (Arc::clone(&socket), self.tx.clone());
            tokio::spawn(async move {
                let mut buf = [0u8; 1500];
                while let Ok((n, from)) = reader.recv_from(&mut buf).await {
                    if tx.send((buf[..n].to_vec(), from)).is_err() {
                        break;
                    }
                }
            });
            self.sockets.lock().insert(key, Arc::clone(&socket));
            socket
        }

        fn admits(&self, from: SocketAddr) -> bool {
            let contacted = self.contacted.lock();
            match self.filtering {
                Behavior::EndpointIndependent => true,
                Behavior::AddressDependent => contacted.iter().any(|c| c.ip() == from.ip()),
                _ => contacted.contains(&from),
            }
        }
    }

    #[async_trait::async_trait]
    impl ProxyPacketConn for SimNat {
        async fn read_packet(&self, buf: &mut [u8]) -> meow_common::Result<(usize, SocketAddr)> {
            let mut rx = self.rx.lock().await;
            loop {
                let (data, from) = rx
                    .recv()
                    .await
                    .ok_or_else(|| MeowError::Other("closed".into()))?;
                if self.admits(from) {
                    buf[..data.len()].copy_from_slice(&data);
                    return Ok((data.len(), self.reported_source.unwrap_or(from)));
                }
            }
        }

        async fn write_packet(&self, buf: &[u8], addr: &SocketAddr) -> meow_common::Result<usize> {
            self.contacted.lock().push(*addr);
            Ok(self.socket_for(*addr).await.send_to(buf, addr).await?)
        }

        fn local_addr(&self) -> meow_common::Result<SocketAddr> {
            Ok("127.0.0.1:0".parse().unwrap())
        }

        fn close(&self) -> meow_common::Result<()> {
            Ok(())
        }
    }

    /// Sends every datagram to the destination it was opened for and reports
    /// that destination as every datagram's source, as relays bound to one
    /// destination do.
    struct BoundRelay {
        socket: UdpSocket,
        remote: SocketAddr,
    }

    #[async_trait::async_trait]
    impl ProxyPacketConn for BoundRelay {
        async fn read_packet(&self, buf: &mut [u8]) -> meow_common::Result<(usize, SocketAddr)> {
            let (n, _) = self.socket.recv_from(buf).await?;
            Ok((n, self.remote))
        }

        async fn write_packet(&self, buf: &[u8], _addr: &SocketAddr) -> meow_common::Result<usize> {
            Ok(self.socket.send_to(buf, self.remote).await?)
        }

        fn local_addr(&self) -> meow_common::Result<SocketAddr> {
            Ok(self.socket.local_addr()?)
        }

        fn close(&self) -> meow_common::Result<()> {
            Ok(())
        }
    }

    async fn run(conn: impl ProxyPacketConn + 'static, server: SocketAddr) -> Option<Report> {
        let mut relay = Relay::new(Arc::new(conn));
        classify(&mut relay, server, TEST_SCHEDULE).await
    }

    async fn behaviour(mapping: Behavior, filtering: Behavior) -> (Behavior, Behavior) {
        let server = stun_server(ServerMode::Full).await;
        let report = run(SimNat::new(mapping, filtering), server).await.unwrap();
        assert!(report.mapped.is_some());
        (report.mapping, report.filtering)
    }

    use Behavior::{
        AddressAndPortDependent as Apd, AddressDependent as Ad, EndpointIndependent as Ei, Unknown,
    };

    #[tokio::test]
    async fn full_cone() {
        assert_eq!(behaviour(Ei, Ei).await, (Ei, Ei));
    }

    #[tokio::test]
    async fn restricted_cone() {
        assert_eq!(behaviour(Ei, Ad).await, (Ei, Ad));
    }

    #[tokio::test]
    async fn port_restricted_cone() {
        assert_eq!(behaviour(Ei, Apd).await, (Ei, Apd));
    }

    #[tokio::test]
    async fn address_dependent_mapping() {
        assert_eq!(behaviour(Ad, Apd).await, (Ad, Apd));
    }

    #[tokio::test]
    async fn symmetric() {
        assert_eq!(behaviour(Apd, Apd).await, (Apd, Apd));
    }

    #[tokio::test]
    async fn a_relay_bound_to_one_destination_is_not_misread() {
        let server = stun_server(ServerMode::Full).await;
        let relay = BoundRelay {
            socket: UdpSocket::bind("127.0.0.1:0").await.unwrap(),
            remote: server,
        };
        let report = run(relay, server).await.unwrap();
        assert_eq!(
            (report.mapping, report.filtering, report.note),
            (Unknown, Unknown, Some(NOTE_SOURCE_HIDDEN))
        );
    }

    #[tokio::test]
    async fn a_relay_without_sources_is_not_misread() {
        let server = stun_server(ServerMode::Full).await;
        let mut nat = SimNat::new(Ei, Ei);
        nat.reported_source = Some("0.0.0.0:0".parse().unwrap());
        let report = run(nat, server).await.unwrap();
        assert_eq!(
            (report.mapping, report.filtering, report.note),
            (Unknown, Unknown, Some(NOTE_SOURCE_HIDDEN))
        );
    }

    #[tokio::test]
    async fn a_refused_change_request_leaves_filtering_unknown() {
        let server = stun_server(ServerMode::RefusesChange).await;
        let report = run(SimNat::new(Ei, Apd), server).await.unwrap();
        assert_eq!((report.mapping, report.filtering), (Ei, Unknown));
    }

    #[tokio::test]
    async fn a_plain_server_is_passed_over() {
        let server = stun_server(ServerMode::Plain).await;
        assert_eq!(run(SimNat::new(Ei, Ei), server).await, None);
    }

    #[tokio::test]
    async fn a_silent_server_is_passed_over() {
        let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        assert_eq!(
            run(SimNat::new(Ei, Ei), silent.local_addr().unwrap()).await,
            None
        );
    }

    #[tokio::test]
    async fn two_plain_servers_tell_the_mapping_only() {
        let (first, second) = (
            stun_server(ServerMode::Plain).await,
            stun_server(ServerMode::Plain).await,
        );
        for (nat, expected) in [(Ei, Ei), (Apd, Behavior::Dependent)] {
            let mut relay = Relay::new(Arc::new(SimNat::new(nat, Apd)));
            let report = mapping_only(&mut relay, first, second, TEST_SCHEDULE)
                .await
                .unwrap();
            assert_eq!((report.mapping, report.filtering), (expected, Unknown));
        }
    }
}
