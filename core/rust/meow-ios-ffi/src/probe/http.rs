//! HTTP over one proxy: the exit-IP lookup's GET and the bandwidth samples.
//!
//! A deliberately small HTTP/1.1 client — one request at a time, no
//! redirects, no compression (none is asked for) — over the adapter's dial,
//! with the engine's own `TlsLayer` for `https`, as its latency test does.

use super::{millis, tcp_metadata, ProbeError, ProbeResult};
use meow_common::ProxyAdapter;
use meow_transport::tls::{TlsConfig, TlsLayer};
use meow_transport::{Stream, Transport as _};
use rand::RngCore as _;
use serde_json::json;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::{timeout, timeout_at};

/// One exit-IP source's attempt; the UI moves on to the next source after it.
const GET_TIMEOUT: Duration = Duration::from_secs(5);
/// Geo-IP answers are a few hundred bytes.
const GET_BODY_CAP: usize = 64 * 1024;
const HEAD_CAP: usize = 32 * 1024;

/// Dial, TLS and response head of a bandwidth sample.
const SETUP_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a bandwidth sample transfers for, at most.
const SAMPLE_WINDOW: Duration = Duration::from_secs(8);

const SPEED_HOST: &str = "speed.cloudflare.com";
/// The endpoint's ceiling: it refuses 100 MB with a 403.
const DOWNLOAD_BYTES: u64 = 50_000_000;
const UPLOAD_FIRST_REQUEST: u64 = 128 * 1024;
const UPLOAD_MAX_REQUEST: u64 = 32 * 1024 * 1024;
const UPLOAD_TOTAL_CAP: u64 = 64 * 1024 * 1024;
/// A request quicker than this doubles the next one.
const UPLOAD_GROW_BELOW: Duration = Duration::from_secs(2);

const USER_AGENT: &str = concat!("meow-ios/", env!("CARGO_PKG_VERSION"));

type Conn = Box<dyn Stream>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Url {
    https: bool,
    host: String,
    port: u16,
    /// Path and query, starting with `/`.
    target: String,
}

impl Url {
    pub(super) fn parse(url: &str) -> Option<Self> {
        let (https, rest) = if let Some(rest) = url.strip_prefix("https://") {
            (true, rest)
        } else {
            (false, url.strip_prefix("http://")?)
        };
        let rest = rest.split('#').next().unwrap_or_default();
        let (authority, target) = match rest.find(['/', '?']) {
            Some(i) if rest[i..].starts_with('?') => (&rest[..i], format!("/{}", &rest[i..])),
            Some(i) => (&rest[..i], rest[i..].to_string()),
            None => (rest, "/".to_string()),
        };
        if authority.contains('@') {
            return None;
        }
        let default_port = if https { 443 } else { 80 };
        let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
            let (host, after) = bracketed.split_once(']')?;
            let port = match after.strip_prefix(':') {
                Some(port) => port.parse().ok()?,
                None if after.is_empty() => default_port,
                None => return None,
            };
            (host, port)
        } else {
            match authority.split_once(':') {
                Some((host, port)) => (host, port.parse().ok()?),
                None => (authority, default_port),
            }
        };
        if host.is_empty() || port == 0 {
            return None;
        }
        Some(Self {
            https,
            host: host.to_string(),
            port,
            target,
        })
    }

    fn speed_test(target: String) -> Self {
        Self {
            https: true,
            host: SPEED_HOST.to_string(),
            port: 443,
            target,
        }
    }

    fn host_header(&self) -> String {
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        if self.port == if self.https { 443 } else { 80 } {
            host
        } else {
            format!("{host}:{}", self.port)
        }
    }
}

async fn open(proxy: &dyn ProxyAdapter, url: &Url) -> Result<Conn, ProbeError> {
    let conn = proxy
        .dial_tcp(&tcp_metadata(&url.host, url.port))
        .await
        .map_err(|e| ProbeError::failed(format!("dial: {e}")))?;
    if !url.https {
        return Ok(Box::new(conn));
    }
    let tls = TlsLayer::new(&TlsConfig::new(url.host.clone()))
        .map_err(|e| ProbeError::failed(format!("tls: {e}")))?;
    tls.connect(Box::new(conn))
        .await
        .map_err(|e| ProbeError::failed(format!("tls: {e}")))
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Framing {
    Length(u64),
    Chunked,
    UntilClose,
}

#[derive(Debug)]
struct Head {
    status: u16,
    framing: Framing,
    /// The server will close the connection after this response.
    close: bool,
}

/// Reads up to the end of the response head. Body bytes that arrived with it
/// are left in `carry`. Interim (1xx) responses are skipped.
async fn read_head<S: AsyncRead + Unpin + ?Sized>(
    stream: &mut S,
    carry: &mut Vec<u8>,
) -> Result<Head, ProbeError> {
    let mut chunk = [0u8; 4096];
    loop {
        if let Some((len, head)) = parse_head(carry)? {
            carry.drain(..len);
            if (100..200).contains(&head.status) {
                continue;
            }
            return Ok(head);
        }
        if carry.len() > HEAD_CAP {
            return Err(ProbeError::failed("response head too large"));
        }
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|e| ProbeError::failed(format!("read: {e}")))?;
        if n == 0 {
            return Err(ProbeError::failed("connection closed before a response"));
        }
        carry.extend_from_slice(&chunk[..n]);
    }
}

/// `None` while the head is incomplete; else its length and meaning.
fn parse_head(buf: &[u8]) -> Result<Option<(usize, Head)>, ProbeError> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut response = httparse::Response::new(&mut headers);
    let len = match response.parse(buf) {
        Ok(httparse::Status::Complete(len)) => len,
        Ok(httparse::Status::Partial) => return Ok(None),
        Err(e) => return Err(ProbeError::failed(format!("bad response: {e}"))),
    };
    let status = response.code.unwrap_or_default();
    let mut framing = Framing::UntilClose;
    let mut close = response.version == Some(0);
    for header in response.headers.iter() {
        let value = String::from_utf8_lossy(header.value);
        let value = value.trim();
        if header.name.eq_ignore_ascii_case("transfer-encoding") {
            if value.to_ascii_lowercase().ends_with("chunked") {
                framing = Framing::Chunked;
            }
        } else if header.name.eq_ignore_ascii_case("content-length") {
            if framing != Framing::Chunked {
                let length = value
                    .parse()
                    .map_err(|_| ProbeError::failed("bad content-length"))?;
                framing = Framing::Length(length);
            }
        } else if header.name.eq_ignore_ascii_case("connection") {
            close = value.eq_ignore_ascii_case("close");
        }
    }
    // Bodiless by definition, whatever the headers say.
    if status == 204 || status == 304 {
        framing = Framing::Length(0);
    }
    Ok(Some((
        len,
        Head {
            status,
            framing,
            close,
        },
    )))
}

/// Decodes a chunked body. `None` until its last chunk has arrived.
fn dechunk(raw: &[u8]) -> Result<Option<Vec<u8>>, ProbeError> {
    let mut body = Vec::new();
    let mut rest = raw;
    loop {
        let Some(line_end) = rest.windows(2).position(|w| w == b"\r\n") else {
            return Ok(None);
        };
        let line = std::str::from_utf8(&rest[..line_end])
            .map_err(|_| ProbeError::failed("bad chunk size"))?;
        let size = line.split(';').next().unwrap_or_default().trim();
        let size =
            usize::from_str_radix(size, 16).map_err(|_| ProbeError::failed("bad chunk size"))?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            // Trailers are not read; the body is complete.
            return Ok(Some(body));
        }
        if rest.len() < size + 2 {
            return Ok(None);
        }
        body.extend_from_slice(&rest[..size]);
        rest = &rest[size + 2..];
    }
}

/// The body as framed, or `None` while more is to come.
fn complete_body(raw: &[u8], framing: Framing) -> Result<Option<Vec<u8>>, ProbeError> {
    match framing {
        Framing::Length(len) => Ok(usize::try_from(len)
            .ok()
            .filter(|len| raw.len() >= *len)
            .map(|len| raw[..len].to_vec())),
        Framing::Chunked => dechunk(raw),
        Framing::UntilClose => Ok(None),
    }
}

async fn write_all<S: AsyncWrite + Unpin + ?Sized>(
    stream: &mut S,
    bytes: &[u8],
) -> Result<(), ProbeError> {
    stream
        .write_all(bytes)
        .await
        .map_err(|e| ProbeError::failed(format!("write: {e}")))
}

fn get_request(url: &Url) -> String {
    format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {USER_AGENT}\r\nAccept: */*\r\n\
         Connection: close\r\n\r\n",
        url.target,
        url.host_header(),
    )
}

// ---------------------------------------------------------------------------
// GET
// ---------------------------------------------------------------------------

/// GETs `url` through `proxy`: `{"status": …, "body": …}`. Any status is an
/// answer; the caller decides what a refusal means.
pub(super) async fn get(proxy: &dyn ProxyAdapter, url: &str) -> ProbeResult {
    let Some(url) = Url::parse(url) else {
        return Err(ProbeError::new(
            "bad-request",
            format!("not an http(s) URL: {url}"),
        ));
    };
    timeout(GET_TIMEOUT, fetch(proxy, &url))
        .await
        .unwrap_or_else(|_| Err(ProbeError::timeout("no answer in time")))
}

async fn fetch(proxy: &dyn ProxyAdapter, url: &Url) -> ProbeResult {
    let mut conn = open(proxy, url).await?;
    write_all(&mut conn, get_request(url).as_bytes()).await?;
    let mut raw = Vec::new();
    let head = read_head(&mut conn, &mut raw).await?;
    let mut chunk = [0u8; 4096];
    let body = loop {
        if let Some(body) = complete_body(&raw, head.framing)? {
            break body;
        }
        if raw.len() > GET_BODY_CAP {
            return Err(ProbeError::failed("response body too large"));
        }
        let n = conn
            .read(&mut chunk)
            .await
            .map_err(|e| ProbeError::failed(format!("read: {e}")))?;
        if n == 0 {
            if head.framing == Framing::UntilClose {
                break raw;
            }
            return Err(ProbeError::failed("connection closed mid-body"));
        }
        raw.extend_from_slice(&chunk[..n]);
    };
    Ok(json!({
        "status": head.status,
        "body": String::from_utf8_lossy(&body),
    }))
}

// ---------------------------------------------------------------------------
// Bandwidth
// ---------------------------------------------------------------------------

pub(super) async fn download(proxy: &dyn ProxyAdapter) -> ProbeResult {
    let url = Url::speed_test(format!("/__down?bytes={DOWNLOAD_BYTES}"));
    download_from(proxy, &url, SAMPLE_WINDOW).await
}

/// Downloads `url` for at most `window`, timed from the response head so the
/// dial and handshakes stay out of the rate: `{"bytes": …, "ms": …}`.
async fn download_from(proxy: &dyn ProxyAdapter, url: &Url, window: Duration) -> ProbeResult {
    let mut carry = Vec::new();
    let (mut conn, head) = timeout(SETUP_TIMEOUT, async {
        let mut conn = open(proxy, url).await?;
        write_all(&mut conn, get_request(url).as_bytes()).await?;
        let head = read_head(&mut conn, &mut carry).await?;
        Ok::<_, ProbeError>((conn, head))
    })
    .await
    .unwrap_or_else(|_| Err(ProbeError::timeout("the download did not start in time")))?;
    if head.status != 200 {
        return Err(ProbeError::failed(format!("HTTP {}", head.status)));
    }
    let limit = match head.framing {
        Framing::Length(len) => len,
        Framing::Chunked | Framing::UntilClose => u64::MAX,
    };
    let started = Instant::now();
    let deadline = tokio::time::Instant::from_std(started + window);
    let mut bytes = (carry.len() as u64).min(limit);
    let mut buf = vec![0u8; 64 * 1024];
    while bytes < limit {
        match timeout_at(deadline, conn.read(&mut buf)).await {
            Err(_) | Ok(Ok(0)) => break,
            Ok(Ok(n)) => bytes += n as u64,
            Ok(Err(e)) => return Err(ProbeError::failed(format!("read: {e}"))),
        }
    }
    if bytes == 0 {
        return Err(ProbeError::failed("no data received"));
    }
    Ok(json!({ "bytes": bytes.min(limit), "ms": millis(started.elapsed()) }))
}

pub(super) async fn upload(proxy: &dyn ProxyAdapter) -> ProbeResult {
    upload_to(proxy, &Url::speed_test("/__up".to_string()), SAMPLE_WINDOW).await
}

/// Uploads for at most `window` as a run of POSTs, each twice the size of a
/// quick predecessor, on one kept-alive connection. Only a request the server
/// has answered counts: bytes merely written may still sit in a send buffer.
/// The rate is taken from the largest requests, the least skewed by the
/// round trip each one waits out: `{"bytes": …, "ms": …}`.
async fn upload_to(proxy: &dyn ProxyAdapter, url: &Url, window: Duration) -> ProbeResult {
    let mut conn = Some(
        timeout(SETUP_TIMEOUT, open(proxy, url))
            .await
            .unwrap_or_else(|_| Err(ProbeError::timeout("could not connect in time")))?,
    );
    // Random, so nothing on the path can compress it.
    let mut payload = vec![0u8; 64 * 1024];
    rand::rng().fill_bytes(&mut payload);

    let deadline = tokio::time::Instant::now() + window;
    let mut samples: Vec<(u64, Duration)> = Vec::new();
    let mut total = 0u64;
    let mut size = UPLOAD_FIRST_REQUEST;
    while tokio::time::Instant::now() < deadline && total + size <= UPLOAD_TOTAL_CAP {
        let mut stream = match conn.take() {
            Some(stream) => stream,
            None => match timeout_at(deadline, open(proxy, url)).await {
                Ok(Ok(stream)) => stream,
                Ok(Err(_)) | Err(_) => break,
            },
        };
        let sent = Instant::now();
        match timeout_at(deadline, post(&mut stream, url, size, &payload)).await {
            // The window closed mid-request; it does not count.
            Err(_) => break,
            Ok(Err(e)) if samples.is_empty() => return Err(e),
            Ok(Err(_)) => break,
            Ok(Ok(reusable)) => {
                let took = sent.elapsed();
                samples.push((size, took));
                total += size;
                if reusable {
                    conn = Some(stream);
                }
                if took < UPLOAD_GROW_BELOW {
                    size = (size * 2).min(UPLOAD_MAX_REQUEST);
                }
            }
        }
    }
    let Some(largest) = samples.iter().map(|(size, _)| *size).max() else {
        return Err(ProbeError::failed("no upload finished in time"));
    };
    let (bytes, took) = samples
        .iter()
        .filter(|(size, _)| *size == largest)
        .fold((0u64, Duration::ZERO), |(bytes, took), (size, t)| {
            (bytes + size, took + *t)
        });
    Ok(json!({ "bytes": bytes, "ms": millis(took) }))
}

/// One POST of `size` bytes. `Ok(true)` when the connection can carry the
/// next one.
async fn post<S: AsyncRead + AsyncWrite + Unpin + ?Sized>(
    stream: &mut S,
    url: &Url,
    size: u64,
    payload: &[u8],
) -> Result<bool, ProbeError> {
    let head = format!(
        "POST {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: {USER_AGENT}\r\n\
         Content-Type: application/octet-stream\r\nContent-Length: {size}\r\n\r\n",
        url.target,
        url.host_header(),
    );
    write_all(stream, head.as_bytes()).await?;
    let mut left = size;
    while left > 0 {
        let n = usize::try_from(left).map_or(payload.len(), |left| left.min(payload.len()));
        write_all(stream, &payload[..n]).await?;
        left -= n as u64;
    }
    stream
        .flush()
        .await
        .map_err(|e| ProbeError::failed(format!("write: {e}")))?;

    let mut carry = Vec::new();
    let response = read_head(stream, &mut carry).await?;
    if response.status != 200 {
        return Err(ProbeError::failed(format!("HTTP {}", response.status)));
    }
    let Framing::Length(len) = response.framing else {
        return Ok(false);
    };
    // Drain the (normally empty) body so the next request starts clean.
    let mut left = len.saturating_sub(carry.len() as u64);
    let mut sink = [0u8; 4096];
    while left > 0 {
        let n = stream
            .read(&mut sink)
            .await
            .map_err(|e| ProbeError::failed(format!("read: {e}")))?;
        if n == 0 {
            return Ok(false);
        }
        left = left.saturating_sub(n as u64);
    }
    Ok(!response.close && carry.len() as u64 <= len)
}

#[cfg(test)]
mod tests {
    use super::*;
    use meow_proxy::DirectAdapter;
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::net::TcpListener;

    #[test]
    fn urls() {
        let url = Url::parse("https://api.ip.sb/geoip").unwrap();
        assert_eq!(
            url,
            Url {
                https: true,
                host: "api.ip.sb".into(),
                port: 443,
                target: "/geoip".into()
            }
        );
        assert_eq!(url.host_header(), "api.ip.sb");

        let url = Url::parse("http://127.0.0.1:8080?x=1#frag").unwrap();
        assert_eq!((url.port, url.target.as_str()), (8080, "/?x=1"));
        assert_eq!(url.host_header(), "127.0.0.1:8080");

        let url = Url::parse("https://[2001:db8::1]:8443/a").unwrap();
        assert_eq!(url.host, "2001:db8::1");
        assert_eq!(url.host_header(), "[2001:db8::1]:8443");
        assert_eq!(Url::parse("https://ipwho.is").unwrap().target, "/");

        for bad in [
            "ftp://x/",
            "https://",
            "https://user@host/",
            "https://host:0/",
            "https://host:port/",
            "https://[::1/",
        ] {
            assert_eq!(Url::parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn heads() {
        let (len, head) = parse_head(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nbody")
            .unwrap()
            .unwrap();
        assert_eq!(len, 39);
        assert_eq!(
            (head.status, head.framing, head.close),
            (200, Framing::Length(12), false)
        );

        let (_, head) = parse_head(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\
              Connection: close\r\n\r\n",
        )
        .unwrap()
        .unwrap();
        assert_eq!((head.framing, head.close), (Framing::Chunked, true));

        let (_, head) = parse_head(b"HTTP/1.0 403 Forbidden\r\n\r\n")
            .unwrap()
            .unwrap();
        assert_eq!(
            (head.status, head.framing, head.close),
            (403, Framing::UntilClose, true)
        );

        assert!(parse_head(b"HTTP/1.1 200 OK\r\nContent-")
            .unwrap()
            .is_none());
        assert!(parse_head(b"SSH-2.0-OpenSSH\r\n\r\n").is_err());
    }

    #[test]
    fn chunked_bodies() {
        assert_eq!(dechunk(b"5\r\nhello\r\n").unwrap(), None);
        assert_eq!(
            dechunk(b"5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n").unwrap(),
            Some(b"hello world".to_vec())
        );
        assert_eq!(dechunk(b"0\r\n\r\n").unwrap(), Some(Vec::new()));
        assert!(dechunk(b"zz\r\n").is_err());
    }

    /// Serves one canned response per connection, after reading the request
    /// head (and a `Content-Length` body).
    async fn serve(responses: Vec<Vec<u8>>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for response in responses {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut carry = Vec::new();
                read_request(&mut socket, &mut carry).await;
                let _ = socket.write_all(&response).await;
                let _ = socket.shutdown().await;
            }
        });
        addr
    }

    /// Reads one request; returns its declared body length.
    async fn read_request(socket: &mut tokio::net::TcpStream, carry: &mut Vec<u8>) -> Option<u64> {
        let mut chunk = [0u8; 65536];
        let (head_len, body_len) = loop {
            if let Some(end) = carry.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&carry[..end]).to_ascii_lowercase();
                let body_len = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length:"))
                    .map_or(0, |v| v.trim().parse().unwrap());
                break (end + 4, body_len);
            }
            let n = socket.read(&mut chunk).await.ok()?;
            if n == 0 {
                return None;
            }
            carry.extend_from_slice(&chunk[..n]);
        };
        carry.drain(..head_len);
        let mut left = body_len;
        loop {
            let take = (carry.len() as u64).min(left);
            carry.drain(..take as usize);
            left -= take;
            if left == 0 {
                return Some(body_len);
            }
            let n = socket.read(&mut chunk).await.ok()?;
            if n == 0 {
                return None;
            }
            carry.extend_from_slice(&chunk[..n]);
        }
    }

    fn url(addr: SocketAddr, target: &str) -> Url {
        Url::parse(&format!("http://{addr}{target}")).unwrap()
    }

    #[tokio::test]
    async fn get_reads_length_chunked_and_until_close_bodies() {
        let addr = serve(vec![
            b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ip\":\"1.2\"}\n".to_vec(),
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n"
                .to_vec(),
            b"HTTP/1.1 429 Too Many Requests\r\n\r\nslow down".to_vec(),
        ])
        .await;
        let direct = DirectAdapter::new();
        let mut bodies = Vec::new();
        for _ in 0..3 {
            let value = get(&direct, &format!("http://{addr}/geoip")).await.unwrap();
            bodies.push((
                value["status"].as_u64().unwrap(),
                value["body"].as_str().unwrap().to_string(),
            ));
        }
        assert_eq!(
            bodies,
            [
                (200, "{\"ip\":\"1.2\"}\n".to_string()),
                (200, "{\"a\":1}".to_string()),
                (429, "slow down".to_string()),
            ]
        );
    }

    #[tokio::test]
    async fn get_refuses_a_non_http_url() {
        let err = get(&DirectAdapter::new(), "file:///etc/hosts")
            .await
            .unwrap_err();
        assert_eq!(err.code, "bad-request");
    }

    #[tokio::test]
    async fn download_counts_the_body_within_the_window() {
        let body = vec![7u8; 300_000];
        let mut response =
            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        response.extend_from_slice(&body);
        let addr = serve(vec![response]).await;

        let value = download_from(&DirectAdapter::new(), &url(addr, "/__down"), SAMPLE_WINDOW)
            .await
            .unwrap();
        assert_eq!(value["bytes"], 300_000);
        assert!(value["ms"].as_u64().unwrap() >= 1);
    }

    #[tokio::test]
    async fn download_stops_at_the_window() {
        // A body that never ends: the sample is cut at the window.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            read_request(&mut socket, &mut Vec::new()).await;
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n")
                .await
                .unwrap();
            let chunk = vec![0u8; 1024];
            while socket.write_all(&chunk).await.is_ok() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        let started = Instant::now();
        let value = download_from(
            &DirectAdapter::new(),
            &url(addr, "/__down"),
            Duration::from_millis(400),
        )
        .await
        .unwrap();
        assert!(started.elapsed() < Duration::from_secs(3));
        let ms = value["ms"].as_u64().unwrap();
        assert!((400..1500).contains(&ms), "{ms}");
        assert!(value["bytes"].as_u64().unwrap() > 0);
    }

    #[tokio::test]
    async fn download_reports_a_refusal() {
        let addr = serve(vec![
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 1\r\n\r\nx".to_vec(),
        ])
        .await;
        let err = download_from(&DirectAdapter::new(), &url(addr, "/__down"), SAMPLE_WINDOW)
            .await
            .unwrap_err();
        assert!(err.message.contains("403"), "{err}");
    }

    /// Answers POSTs on kept-alive connections, recording each body's size.
    async fn upload_server(
        sizes: Arc<parking_lot::Mutex<Vec<u64>>>,
        connections: Arc<AtomicUsize>,
    ) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                connections.fetch_add(1, Ordering::SeqCst);
                let sizes = Arc::clone(&sizes);
                tokio::spawn(async move {
                    let mut carry = Vec::new();
                    while let Some(len) = read_request(&mut socket, &mut carry).await {
                        sizes.lock().push(len);
                        if socket
                            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                });
            }
        });
        addr
    }

    #[tokio::test]
    async fn upload_grows_its_requests_on_one_connection() {
        let sizes = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let connections = Arc::new(AtomicUsize::new(0));
        let addr = upload_server(Arc::clone(&sizes), Arc::clone(&connections)).await;

        let value = upload_to(
            &DirectAdapter::new(),
            &url(addr, "/__up"),
            Duration::from_secs(2),
        )
        .await
        .unwrap();

        let sizes = sizes.lock().clone();
        assert_eq!(connections.load(Ordering::SeqCst), 1);
        // Doubling from the first size, capped per request and in total.
        assert_eq!(sizes[0], UPLOAD_FIRST_REQUEST);
        for pair in sizes.windows(2) {
            assert!(pair[1] == pair[0] * 2 || pair[1] == pair[0], "{sizes:?}");
        }
        assert!(sizes.iter().sum::<u64>() <= UPLOAD_TOTAL_CAP);
        // The rate comes from the largest requests only.
        let largest = *sizes.iter().max().unwrap();
        let bytes = value["bytes"].as_u64().unwrap();
        assert_eq!(bytes % largest, 0, "{bytes} vs {sizes:?}");
    }

    #[tokio::test]
    async fn upload_ignores_a_request_cut_by_the_window() {
        // Accepts the body but answers only the first request.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let answered = Arc::new(AtomicU64::new(0));
        let seen = Arc::clone(&answered);
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut carry = Vec::new();
            while read_request(&mut socket, &mut carry).await.is_some() {
                if seen.fetch_add(1, Ordering::SeqCst) == 0 {
                    socket
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                        .await
                        .unwrap();
                }
            }
        });
        let value = upload_to(
            &DirectAdapter::new(),
            &url(addr, "/__up"),
            Duration::from_millis(500),
        )
        .await
        .unwrap();
        assert_eq!(value["bytes"], UPLOAD_FIRST_REQUEST);
    }

    #[tokio::test]
    async fn upload_fails_when_nothing_is_answered() {
        let addr = serve(vec![
            b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ])
        .await;
        let err = upload_to(&DirectAdapter::new(), &url(addr, "/__up"), SAMPLE_WINDOW)
            .await
            .unwrap_err();
        assert!(err.message.contains("500"), "{err}");
    }
}
