//! Smart-SSI prototype, step 2: prove facts about a GitHub account from the real GitHub API.
//!
//! One run does the whole loop the white paper describes, in a single process:
//! 1. Notarize: the prover fetches `api.github.com/users/<login>` over MPC-TLS with a notary.
//! 2. Present: only `login`, `public_repos` and `created_at` are revealed; everything else stays hidden.
//! 3. Verify: the presentation is checked against the notary key and Mozilla's root certificates.
//! 4. Interpret: a public, deterministic rule turns the revealed fields into a claim.
//!
//! The notary runs in-process with a fixed development key. Step 3 moves it to its own server.

use std::{future::IntoFuture, path::PathBuf, time::Duration};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use clap::Parser;
use futures::io::{AsyncReadExt as _, AsyncWriteExt as _};
use http_body_util::Empty;
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
        prove::ProveConfig, prover::ProverConfig, tls::TlsClientConfig, tls_commit::mpc::MpcTlsConfig,
        verifier::VerifierConfig,
    },
    connection::{CertBinding, ConnectionInfo, HandshakeData, ServerName, TranscriptLength},
    prover::ProverOutput,
    transcript::{ContentType, TranscriptCommitConfig},
    verifier::{VerifierCommitStart, VerifierOutput},
    webpki::RootCertStore,
};
use tlsn_formats::http::{BodyContent, DefaultHttpCommitter, HttpCommit, HttpTranscript};

const HOST: &str = "api.github.com";
const MAX_SENT_DATA: usize = 1 << 12;
const MAX_RECV_DATA: usize = 1 << 14;
// Development only: the real notary will load its key from a KMS (see ARCHITECTURE.md).
const DEV_NOTARY_KEY: [u8; 32] = [7u8; 32];
// Fields revealed to the issuer. Everything else in the response stays hidden.
const REVEALED_FIELDS: [&str; 3] = ["login", "public_repos", "created_at"];

#[derive(Parser, Debug)]
#[command(about = "Prove facts about a GitHub account with TLSNotary")]
struct Args {
    /// GitHub login to prove facts about.
    login: String,
    /// Where to write the attestation, secrets, presentation and claim.
    #[arg(long, default_value = "out")]
    out: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let args = Args::parse();
    tokio::fs::create_dir_all(&args.out).await?;

    let (notary_socket, prover_socket) = tokio::io::duplex(1 << 23);
    let notary_task = tokio::spawn(notary(notary_socket));
    let (attestation, secrets) = notarize(prover_socket, &args.login).await?;
    notary_task.await??;
    write(&args.out, "attestation.tlsn", &attestation).await?;
    write(&args.out, "secrets.tlsn", &secrets).await?;
    println!("1/4 notarized: attestation signed by the notary");

    let presentation = present(&attestation, &secrets)?;
    write(&args.out, "presentation.tlsn", &presentation).await?;
    println!("2/4 presented: only {} revealed", REVEALED_FIELDS.join(", "));

    let revealed = verify(&presentation)?;
    println!("3/4 verified: {}", serde_json::to_string(&revealed)?);

    let claim = interpret(&revealed)?;
    tokio::fs::write(args.out.join("claim.json"), serde_json::to_vec_pretty(&claim)?).await?;
    println!("4/4 claim:\n{}", serde_json::to_string_pretty(&claim)?);
    Ok(())
}

async fn write<T: serde::Serialize>(dir: &PathBuf, name: &str, value: &T) -> Result<()> {
    tokio::fs::write(dir.join(name), bincode::serialize(value)?).await?;
    Ok(())
}

/// Step 1, prover side: fetch the GitHub profile over MPC-TLS and get the notary's attestation.
async fn notarize<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(
    socket: S,
    login: &str,
) -> Result<(Attestation, Secrets)> {
    let session = Session::new(socket.compat());
    let (driver, mut handle) = session.split();
    let driver_task = tokio::spawn(driver);

    let prover = handle
        .new_prover(ProverConfig::builder().build()?)?
        .commit(MpcTlsConfig::builder().max_sent_data(MAX_SENT_DATA).max_recv_data(MAX_RECV_DATA).build()?)
        .await?;

    let client_socket = tokio::net::TcpStream::connect((HOST, 443)).await?;
    let (tls_connection, prover) = prover.connect(
        TlsClientConfig::builder()
            .server_name(ServerName::Dns(HOST.try_into()?))
            .root_store(RootCertStore::mozilla())
            .build()?,
        client_socket.compat(),
    )?;
    let prover_task = tokio::spawn(prover.into_future());

    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(tls_connection.compat())).await?;
    tokio::spawn(connection);

    let request = Request::builder()
        .uri(format!("/users/{login}"))
        .header("Host", HOST)
        .header("Accept", "application/vnd.github+json")
        // TLSNotary does not support compressed responses.
        .header("Accept-Encoding", "identity")
        .header("Connection", "close")
        .header("User-Agent", "smart-ssi-prototype")
        .body(Empty::<Bytes>::new())?;
    info!("requesting https://{HOST}/users/{login}");
    let response = sender.send_request(request).await?;
    if response.status() != StatusCode::OK {
        bail!("GitHub answered {}", response.status());
    }

    let mut prover = prover_task.await??;
    let transcript = HttpTranscript::parse(prover.transcript())?;

    let mut commit = TranscriptCommitConfig::builder(prover.transcript());
    DefaultHttpCommitter::default().commit_transcript(&mut commit, &transcript)?;
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
        .server_name(ServerName::Dns(HOST.try_into()?))
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
    socket.write_all(&bincode::serialize(&request)?).await?;
    socket.close().await?;

    let mut attestation_bytes = Vec::new();
    socket.read_to_end(&mut attestation_bytes).await?;
    let attestation: Attestation = bincode::deserialize(&attestation_bytes)?;
    request.validate(&attestation, &CryptoProvider::default())?;
    Ok((attestation, secrets))
}

/// Step 1, notary side: take part in MPC-TLS without seeing the content, then sign the attestation.
async fn notary<S: AsyncWrite + AsyncRead + Send + Sync + Unpin + 'static>(socket: S) -> Result<()> {
    let session = Session::new(socket.compat());
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
    let mut request_bytes = Vec::new();
    socket.read_to_end(&mut request_bytes).await?;
    let request: AttestationRequest = bincode::deserialize(&request_bytes)?;

    let signing_key = k256::ecdsa::SigningKey::from_bytes(&DEV_NOTARY_KEY.into())?;
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

    socket.write_all(&bincode::serialize(&attestation)?).await?;
    socket.close().await?;
    Ok(())
}

/// Step 2: build a presentation that reveals only the fields the claim needs.
fn present(attestation: &Attestation, secrets: &Secrets) -> Result<Presentation> {
    let transcript = HttpTranscript::parse(secrets.transcript())?;
    let mut builder = secrets.transcript_proof_builder();

    let request = &transcript.requests[0];
    builder.reveal_sent(request.without_data())?;
    builder.reveal_sent(&request.request.target)?;

    let response = &transcript.responses[0];
    builder.reveal_recv(response.without_data())?;
    let body = response.body.as_ref().context("response has no body")?;
    let BodyContent::Json(document) = &body.content else {
        bail!("expected a JSON body");
    };
    let tlsn_formats::spansy::json::JsonValue::Object(object) = &document.root else {
        bail!("expected a JSON object");
    };
    // The committer commits each pair in two parts (key, then value): reveal both for the chosen fields.
    for field in REVEALED_FIELDS {
        let kv = object
            .elems
            .iter()
            .find(|kv| kv.key.view().as_str().trim_matches('"') == field)
            .with_context(|| format!("missing field {field}"))?;
        builder.reveal_recv(kv.without_value())?;
        builder.reveal_recv(&kv.value)?;
    }

    let provider = CryptoProvider::default();
    let mut presentation = attestation.presentation_builder(&provider);
    presentation.identity_proof(secrets.identity_proof()).transcript_proof(builder.build()?);
    Ok(presentation.build()?)
}

/// Step 3, issuer side: verify the presentation and read the revealed fields back.
fn verify(presentation: &Presentation) -> Result<Value> {
    let key = presentation.verifying_key();
    info!("notary key ({}): {}", key.alg, hex::encode(&key.data));

    let PresentationOutput { server_name, connection_info, transcript, .. } =
        presentation.clone().verify(&CryptoProvider::default())?;
    let server = server_name.context("no server name")?.to_string();
    if server != HOST {
        bail!("presentation is for {server}, expected {HOST}");
    }
    let mut transcript = transcript.context("no transcript")?;
    transcript.set_unauthed(0);
    let received = String::from_utf8_lossy(transcript.received_unsafe());
    let shown = transcript.received_unsafe().iter().filter(|b| **b != 0).count();
    info!("issuer sees {shown} of {} received bytes", transcript.received_unsafe().len());
    info!("issuer view: {}", received.replace('\0', "·"));

    // Pull each revealed `"field":value` pair out of the partially hidden response.
    let mut fields = serde_json::Map::new();
    for field in REVEALED_FIELDS {
        let marker = format!("\"{field}\":");
        let start = received.find(&marker).with_context(|| format!("{field} not revealed"))? + marker.len();
        let rest = &received[start..];
        let end = rest.find(|c| c == ',' || c == '}' || c == '\0').unwrap_or(rest.len());
        fields.insert(field.into(), serde_json::from_str(rest[..end].trim())?);
    }
    let at = DateTime::<Utc>::UNIX_EPOCH + Duration::from_secs(connection_info.time);
    fields.insert("proven_at".into(), json!(at.to_rfc3339()));
    fields.insert("server".into(), json!(server));
    Ok(Value::Object(fields))
}

/// Step 4: a public, deterministic rule (no AI) turns the revealed fields into a claim.
fn interpret(revealed: &Value) -> Result<Value> {
    let repos = revealed["public_repos"].as_u64().ok_or_else(|| anyhow!("public_repos is not a number"))?;
    let created: DateTime<Utc> = revealed["created_at"].as_str().context("created_at missing")?.parse()?;
    let years = (Utc::now() - created).num_days() / 365;
    let active = repos >= 5 && years >= 1;
    Ok(json!({
        "schema": "dev.github_account v0",
        "claim": if active { "dev.active" } else { "dev.not_yet" },
        "rule": "public_repos >= 5 and account age >= 1 year",
        "data": {
            "login": revealed["login"],
            "public_repos": repos,
            "account_age_years": years,
            "source": "github",
            "proven_at": revealed["proven_at"],
        }
    }))
}
