//! Smart-SSI prover library: prove facts about the user's accounts from the websites' real APIs.
//!
//! Shared by the CLI, the issuer API and the mobile apps. The full loop, the same for every source:
//! 1. Notarize: the prover sends the source's one request (see `sources`) over MPC-TLS with a notary.
//! 2. Present: the request is revealed with its credentials hidden, and the answer (or chosen fields).
//! 3. Verify: the presentation is checked against the trusted notary key and Mozilla's root certificates,
//!    then the source checks the revealed request is the expected one and reads the answer.
//! 4. Interpret: the source's public, deterministic rule turns the revealed facts into a claim.
//!
//! `serve_notary` runs the notary as its own TCP server; `notary` serves one session on any socket.

use std::{future::IntoFuture, path::Path, time::Duration};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use futures::io::{AsyncReadExt as _, AsyncWriteExt as _};
use http_body_util::Full;
use hyper::{Request, StatusCode, body::Bytes};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::compat::{FuturesAsyncReadCompatExt, TokioAsyncReadCompatExt};
use tracing::info;

use tlsn::{
    Session,
    attestation::{
        Attestation, AttestationConfig, CryptoProvider, Secrets,
        presentation::{Presentation, PresentationOutput},
        request::{Request as AttestationRequest, RequestConfig},
        signing::Secp256k1Signer,
    },
    config::{
        prove::ProveConfig, prover::ProverConfig, tls::TlsClientConfig, tls_commit::mpc::{MpcTlsConfig, NetworkSetting},
        verifier::VerifierConfig,
    },
    connection::{CertBinding, ConnectionInfo, HandshakeData, ServerName, TranscriptLength},
    prover::ProverOutput,
    transcript::{ContentType, TranscriptCommitConfig},
    verifier::{VerifierCommitStart, VerifierOutput},
    webpki::RootCertStore,
};
use tlsn::rangeset::{iter::{FromRangeIterator, IntoRangeIterator}, set::RangeSet};
use tlsn_formats::http::{BodyContent, HttpTranscript};

pub mod sources;
pub use sources::{Subject, github::REVEALED_FIELDS, interpret};

/// The GraphQL request is ~700 bytes (query + OAuth token). The phone uploads ~23 MB fixed + ~10 KB per byte
/// allowed here, so this stays close to the request size.
pub const MAX_SENT_DATA: usize = 1024;
/// GitHub answers 3-6 KB; received data is decrypted after the session and costs little.
pub const MAX_RECV_DATA: usize = 1 << 14;
// Development only: the real notary will load its key from a KMS (see ARCHITECTURE.md).
pub const DEV_NOTARY_KEY: [u8; 32] = [7u8; 32];
/// MPC-TLS sizing. The phone uploads preprocessing data in proportion to these limits, so they are kept
/// close to what GitHub needs. Experiment overrides: SMART_SSI_MAX_SENT, SMART_SSI_MAX_RECV, SMART_SSI_NETWORK.
fn mpc_tls_config(max_recv: usize) -> Result<MpcTlsConfig> {
    let env = |name: &str, default: usize| std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default);
    let mut config = MpcTlsConfig::builder()
        .max_sent_data(env("SMART_SSI_MAX_SENT", MAX_SENT_DATA))
        .max_recv_data(env("SMART_SSI_MAX_RECV", max_recv));
    if std::env::var("SMART_SSI_NETWORK").as_deref() == Ok("bandwidth") {
        config = config.network(NetworkSetting::Bandwidth);
    }
    Ok(config.build()?)
}

/// Accept prover connections forever; each one gets its own notarization session.
pub async fn serve_notary(listen: &str, key_path: &Path) -> Result<()> {
    let key = load_or_create_key(key_path)?;
    let listener = tokio::net::TcpListener::bind(listen).await?;
    println!("notary listening on {listen}, public key {}", public_key_hex(&key)?);
    loop {
        let (socket, peer) = listener.accept().await?;
        tokio::spawn(async move {
            match notary(socket, key).await {
                Ok(()) => info!("signed an attestation for {peer}"),
                Err(error) => tracing::warn!("session with {peer} failed: {error:#}"),
            }
        });
    }
}

/// Accept prover connections over WebSocket (for Cloud Run, which only routes HTTP/WebSocket).
pub async fn serve_notary_ws(listen: &str, key_path: &Path) -> Result<()> {
    let key = load_or_create_key(key_path)?;
    let listener = tokio::net::TcpListener::bind(listen).await?;
    println!("notary listening on ws://{listen}, public key {}", public_key_hex(&key)?);
    loop {
        let (mut socket, peer) = listener.accept().await?;
        tokio::spawn(async move {
            let result = async {
                // Plain HTTP (health checks, the apps' wake-up call) gets a 200 instead of a failed handshake,
                // which Cloud Run would count as a broken instance.
                if !is_websocket_upgrade(&socket).await {
                    use tokio::io::AsyncWriteExt as _;
                    socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 3\r\nconnection: close\r\n\r\nok\n").await?;
                    socket.shutdown().await?;
                    return Ok(false);
                }
                let ws = async_tungstenite::tokio::accept_async(socket).await?;
                notary_io(ws_stream_tungstenite::WsStream::new(ws), key).await.map(|()| true)
            };
            match result.await {
                Ok(true) => info!("signed an attestation for {peer} (websocket)"),
                Ok(false) => {}
                Err(error) => tracing::warn!("websocket session with {peer} failed: {error:#}"),
            }
        });
    }
}

/// Looks at the request headers without consuming them: is this a WebSocket upgrade?
async fn is_websocket_upgrade(socket: &tokio::net::TcpStream) -> bool {
    let mut buffer = [0u8; 4096];
    for _ in 0..50 {
        let Ok(n) = socket.peek(&mut buffer).await else { return false };
        let head = String::from_utf8_lossy(&buffer[..n]).to_ascii_lowercase();
        if head.contains("\r\n\r\n") || n == buffer.len() {
            return head.contains("upgrade: websocket");
        }
        if n == 0 {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    false
}

/// Development key store: 32 random bytes in a file. Production uses a KMS (see ARCHITECTURE.md).
pub fn load_or_create_key(path: &Path) -> Result<[u8; 32]> {
    if !path.exists() {
        let mut bytes = [0u8; 32];
        std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut bytes)?;
        std::fs::write(path, bytes)?;
        info!("created notary key at {}", path.display());
    }
    let bytes = std::fs::read(path)?;
    bytes.try_into().map_err(|_| anyhow!("{} must hold exactly 32 bytes", path.display()))
}

pub fn public_key_hex(key: &[u8; 32]) -> Result<String> {
    let signing_key = k256::ecdsa::SigningKey::from_bytes(&(*key).into())?;
    Ok(hex::encode(signing_key.verifying_key().to_encoded_point(true).as_bytes()))
}

/// Step 1, prover side: fetch the GitHub profile over MPC-TLS and get the notary's attestation.
pub async fn notarize<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(
    socket: S,
    subject: &Subject,
) -> Result<(Attestation, Secrets)> {
    notarize_io(socket.compat(), subject).await
}

/// Connect to the notary at `address` (`host:port` for TCP, `ws://` or `wss://` URL for WebSocket) and notarize.
pub async fn notarize_via(address: &str, subject: &Subject) -> Result<(Attestation, Secrets)> {
    if address.starts_with("ws://") || address.starts_with("wss://") {
        let (ws, _) = async_tungstenite::tokio::connect_async(address)
            .await
            .with_context(|| format!("cannot reach the notary at {address}"))?;
        notarize_io(ws_stream_tungstenite::WsStream::new(ws), subject).await
    } else {
        let socket = tokio::net::TcpStream::connect(address)
            .await
            .with_context(|| format!("cannot reach the notary at {address}"))?;
        notarize(socket, subject).await
    }
}

/// Step 1, prover side, over any byte stream (TCP or WebSocket).
pub async fn notarize_io<S: futures::io::AsyncRead + futures::io::AsyncWrite + Send + Unpin + 'static>(
    socket: S,
    subject: &Subject,
) -> Result<(Attestation, Secrets)> {
    let session = Session::new(socket);
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    let http = subject.request();
    let prover = handle
        .new_prover(ProverConfig::builder().build()?)?
        .commit(mpc_tls_config(http.max_recv)?)
        .await?;

    let client_socket = tokio::net::TcpStream::connect((http.host, 443)).await?;
    let (tls_connection, prover) = prover.connect(
        TlsClientConfig::builder()
            .server_name(ServerName::Dns(http.host.try_into()?))
            .root_store(RootCertStore::mozilla())
            .build()?,
        client_socket.compat(),
    )?;
    let prover_task = tokio::spawn(prover.into_future());

    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(tls_connection.compat())).await?;
    tokio::spawn(connection);

    let mut request = Request::builder().method(http.method).uri(&http.path);
    for (name, value) in [
        ("Host", http.host),
        // TLSNotary does not support compressed responses.
        ("Accept-Encoding", "identity"),
        ("Connection", "close"),
        ("User-Agent", "smart-ssi-prototype"),
    ] {
        request = request.header(name, value);
    }
    for (name, value) in &http.headers {
        request = request.header(*name, value);
    }
    let request = request.body(Full::new(Bytes::from(http.body.clone().unwrap_or_default())))?;
    info!("requesting {subject} from {}", http.host);
    let response = sender.send_request(request).await?;
    if response.status() != StatusCode::OK {
        bail!("{} answered {}", http.host, response.status());
    }

    let mut prover = prover_task.await??;
    let transcript = HttpTranscript::parse(prover.transcript())?;

    let mut commit = TranscriptCommitConfig::builder(prover.transcript());
    // Commit only what the presentation will reveal: one hash commitment per disclosed part. Committing every
    // JSON field (the default) means thousands of zero-knowledge hashes for a large answer like Apple Music's.
    let disclosed = disclosure(&transcript, http.host)?;
    for range in &disclosed.sent {
        commit.commit_sent(range)?;
    }
    for range in &disclosed.recv {
        commit.commit_recv(range)?;
    }
    let mut request_config = RequestConfig::builder();
    request_config.transcript_commit(commit.build()?);
    let request_config = request_config.build()?;

    let mut prove = ProveConfig::builder(prover.transcript());
    if let Some(config) = request_config.transcript_commit() {
        prove.transcript_commit(config.clone());
    }
    let ProverOutput { transcript_commitments, transcript_secrets, .. } = prover.prove(&prove.build()?).await?;

    let prover_transcript = prover.transcript().clone();
    let tls_transcript = prover.tls_transcript().clone();
    prover.close().await?;

    let mut builder = AttestationRequest::builder(&request_config);
    builder
        .server_name(ServerName::Dns(http.host.try_into()?))
        .handshake_data(HandshakeData {
            certs: tls_transcript.server_cert_chain().context("server cert chain")?.to_vec(),
            sig: tls_transcript.server_signature().context("server signature")?.clone(),
            binding: tls_transcript.certificate_binding().clone(),
        })
        .transcript(prover_transcript)
        .transcript_commitments(transcript_secrets, transcript_commitments);
    let (request, secrets) = builder.build(&CryptoProvider::default())?;

    handle.close();
    let mut socket = driver_task.await??;
    send_frame(&mut socket, &bincode::serialize(&request)?).await?;
    let attestation: Attestation = bincode::deserialize(&recv_frame(&mut socket).await?)?;
    socket.close().await?;
    request.validate(&attestation, &CryptoProvider::default())?;
    Ok((attestation, secrets))
}

/// Step 1, notary side: take part in MPC-TLS without seeing the content, then sign the attestation.
pub async fn notary<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(socket: S, key: [u8; 32]) -> Result<()> {
    notary_io(socket.compat(), key).await
}

/// Step 1, notary side, over any byte stream (TCP or WebSocket).
pub async fn notary_io<S: futures::io::AsyncRead + futures::io::AsyncWrite + Send + Unpin + 'static>(
    socket: S,
    key: [u8; 32],
) -> Result<()> {
    let session = Session::new(socket);
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    let verifier_config = VerifierConfig::builder().root_store(RootCertStore::mozilla()).build()?;
    let verifier = match handle.new_verifier(verifier_config)?.commit().await? {
        VerifierCommitStart::Mpc(verifier) => verifier.accept().await?.run().await?,
        VerifierCommitStart::Proxy(verifier) => {
            verifier.reject(Some("expecting MPC-TLS")).await?;
            bail!("prover asked for proxy mode");
        }
    };
    let (VerifierOutput { transcript_commitments, .. }, verifier) = verifier.verify().await?.accept().await?;
    let tls_transcript = verifier.tls_transcript().clone();
    verifier.close().await?;

    let length = |records: &[tlsn::transcript::Record]| {
        records.iter().filter(|r| matches!(r.typ, ContentType::ApplicationData)).map(|r| r.ciphertext.len()).sum::<usize>()
    };
    let (sent_len, recv_len) = (length(tls_transcript.sent()), length(tls_transcript.recv()));

    handle.close();
    let mut socket = driver_task.await??;
    let request: AttestationRequest = bincode::deserialize(&recv_frame(&mut socket).await?)?;

    let signing_key = k256::ecdsa::SigningKey::from_bytes(&key.into())?;
    let mut provider = CryptoProvider::default();
    provider.signer.set_signer(Box::new(Secp256k1Signer::new(&signing_key.to_bytes())?));

    let mut config = AttestationConfig::builder();
    config.supported_signature_algs(Vec::from_iter(provider.signer.supported_algs()));
    let CertBinding::V1_2(binding) = tls_transcript.certificate_binding() else {
        bail!("unsupported certificate binding");
    };
    let config = config.build()?;
    let mut builder = Attestation::builder(&config).accept_request(request)?;
    builder
        .connection_info(ConnectionInfo {
            time: tls_transcript.time(),
            version: tls_transcript.version(),
            transcript_length: TranscriptLength { sent: sent_len as u32, received: recv_len as u32 },
        })
        .server_ephemeral_key(binding.server_ephemeral_key.clone())
        .transcript_commitments(transcript_commitments);
    let attestation = builder.build(&provider)?;

    send_frame(&mut socket, &bincode::serialize(&attestation)?).await?;
    // Wait for the prover to close: closing first could drop the attestation before it is delivered.
    let mut rest = Vec::new();
    let _ = socket.read_to_end(&mut rest).await;
    Ok(())
}

// After MPC-TLS the request and the attestation are sent as length-prefixed frames, not "until end of
// stream": a WebSocket cannot be half-closed, so the end of the stream cannot mark the end of a message.
const MAX_FRAME: usize = 1 << 20;

async fn send_frame<S: futures::io::AsyncWrite + Unpin>(socket: &mut S, bytes: &[u8]) -> Result<()> {
    socket.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    socket.write_all(bytes).await?;
    socket.flush().await?;
    Ok(())
}

async fn recv_frame<S: futures::io::AsyncRead + Unpin>(socket: &mut S) -> Result<Vec<u8>> {
    let mut length = [0u8; 4];
    socket.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length > MAX_FRAME {
        bail!("frame of {length} bytes is too large");
    }
    let mut bytes = vec![0u8; length];
    socket.read_exact(&mut bytes).await?;
    Ok(bytes)
}

/// Step 2: build a presentation: the request with its credentials hidden, and the answer (or chosen fields).
pub fn present(attestation: &Attestation, secrets: &Secrets) -> Result<Presentation> {
    let transcript = HttpTranscript::parse(secrets.transcript())?;
    let mut builder = secrets.transcript_proof_builder();
    let disclosed = disclosure(&transcript, &secrets.server_name().to_string())?;
    for range in &disclosed.sent {
        builder.reveal_sent(range)?;
    }
    for range in &disclosed.recv {
        builder.reveal_recv(range)?;
    }
    let provider = CryptoProvider::default();
    let mut presentation = attestation.presentation_builder(&provider);
    presentation.identity_proof(secrets.identity_proof()).transcript_proof(builder.build()?);
    Ok(presentation.build()?)
}

/// What a proof discloses, as separate parts: the request with every header name but no secret value, and the
/// answer as the source's reveal policy says. The same parts are committed (step 1) and revealed (step 2): a
/// revealed range must be exactly covered by commitments.
fn ranges(part: impl IntoRangeIterator<usize>) -> RangeSet<usize> {
    RangeSet::from_range_iter(part)
}

struct Disclosure {
    sent: Vec<RangeSet<usize>>,
    recv: Vec<RangeSet<usize>>,
}

fn disclosure(transcript: &HttpTranscript, host: &str) -> Result<Disclosure> {
    let mut sent = Vec::new();
    let request = transcript.requests.first().context("no request")?;
    sent.push(request.without_data());
    sent.push(ranges(&request.request.target));
    for header in &request.headers {
        sent.push(ranges(header.without_value()));
        if !sources::SECRET_HEADERS.iter().any(|name| header.name.as_str().eq_ignore_ascii_case(name)) {
            sent.push(ranges(&header.value));
        }
    }
    if let Some(body) = &request.body {
        sent.push(ranges(body));
    }

    let mut recv = Vec::new();
    let response = transcript.responses.first().context("no response")?;
    recv.push(response.without_data());
    let body = response.body.as_ref().context("response has no body")?;
    match sources::reveal(host, &request.request.target.as_str()) {
        sources::Reveal::WholeResponse => {
            // API response headers carry nothing personal (request id, rate limits); the verifier needs them
            // to find the body and see whether it is chunked.
            for header in &response.headers {
                recv.push(ranges(header));
            }
            recv.push(ranges(body));
        }
        sources::Reveal::RootFields(fields) => {
            let JsonValue::Object(object) = &json_root(body)? else { bail!("expected a JSON object") };
            for field in fields {
                let kv = object
                    .elems
                    .iter()
                    .find(|kv| kv.key.view().as_str().trim_matches('"') == *field)
                    .with_context(|| format!("missing field {field}"))?;
                recv.push(ranges(kv));
            }
        }
        sources::Reveal::KeysAnywhere(keys) => collect_keys(&json_root(body)?, keys, &mut recv),
    }
    Ok(Disclosure { sent, recv })
}

use tlsn_formats::spansy::json::JsonValue;

fn json_root(body: &tlsn_formats::http::Body) -> Result<JsonValue> {
    let BodyContent::Json(document) = &body.content else {
        bail!("expected a JSON body");
    };
    Ok(document.root.clone())
}

/// Every `"key":value` pair whose key is in `keys`, at any depth, and nothing else.
fn collect_keys(value: &JsonValue, keys: &[&str], out: &mut Vec<RangeSet<usize>>) {
    match value {
        JsonValue::Object(object) => {
            for kv in &object.elems {
                if keys.contains(&kv.key.view().as_str().trim_matches('"')) {
                    out.push(ranges(kv));
                } else {
                    collect_keys(&kv.value, keys, out);
                }
            }
        }
        JsonValue::Array(array) => array.elems.iter().for_each(|element| collect_keys(element, keys, out)),
        _ => {}
    }
}

/// Step 3, issuer side: verify the presentation and read the revealed fields back.
pub fn verify(presentation: &Presentation, trusted: Option<&str>) -> Result<Value> {
    let key = hex::encode(&presentation.verifying_key().data);
    match trusted {
        Some(trusted) if !trusted.eq_ignore_ascii_case(&key) => bail!("signed by untrusted notary {key}"),
        Some(_) => info!("signed by the trusted notary"),
        None => tracing::warn!("no --trust given: accepting notary key {key}"),
    }

    let PresentationOutput { server_name, connection_info, transcript, .. } =
        presentation.clone().verify(&CryptoProvider::default())?;
    let server = server_name.context("no server name")?.to_string();
    if !sources::is_known_host(&server) {
        bail!("presentation is for {server}, which is not a Smart-SSI source");
    }
    let mut transcript = transcript.context("no transcript")?;
    transcript.set_unauthed(0);

    let sent = String::from_utf8_lossy(transcript.sent_unsafe());
    tracing::debug!("issuer view of the request: {}", sent.replace('\0', "·").replace("\r\n", " | "));
    if !transcript.received_unsafe().starts_with(b"HTTP/1.1 200 ") {
        bail!("{server} did not answer 200");
    }
    let received = String::from_utf8_lossy(transcript.received_unsafe());
    let shown = transcript.received_unsafe().iter().filter(|b| **b != 0).count();
    info!("issuer sees {shown} of {} received bytes", transcript.received_unsafe().len());
    tracing::debug!("issuer view: {}", received.replace('\0', "·"));

    let mut fields = sources::read(&server, &sent, &received)?;
    let at = DateTime::<Utc>::UNIX_EPOCH + Duration::from_secs(connection_info.time);
    fields.insert("proven_at".into(), json!(at.to_rfc3339()));
    fields.insert("server".into(), json!(server));
    Ok(Value::Object(fields))
}
