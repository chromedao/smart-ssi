//! Smart-SSI prototype CLI. The proof logic lives in the library (src/lib.rs).

use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::{Parser, Subcommand};
use tlsn::attestation::presentation::Presentation;
use tracing::info;

use smart_ssi_prover::{
    DEV_NOTARY_KEY, REVEALED_FIELDS, interpret, load_or_create_key, notarize, notarize_via, notary, present,
    public_key_hex, serve_notary, serve_notary_ws, verify, Subject,
};

#[derive(Parser, Debug)]
#[command(about = "Smart-SSI prototype: prove facts about a GitHub account with TLSNotary")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Run the notary as a TCP server (or a WebSocket server with --ws).
    Notary {
        /// Address to listen on. With --ws and no --listen, 0.0.0.0:$PORT (Cloud Run).
        #[arg(long)]
        listen: Option<String>,
        /// Accept WebSocket connections instead of raw TCP.
        #[arg(long)]
        ws: bool,
        /// Notary signing key (32 raw bytes). Created on first run if missing.
        #[arg(long, default_value = "notary.key")]
        key: PathBuf,
    },
    /// Print the notary's public key, for issuers to trust.
    Pubkey {
        #[arg(long, default_value = "notary.key")]
        key: PathBuf,
    },
    /// Issuer side: verify a presentation and print the claim it supports, as JSON.
    Verify {
        /// Presentation file produced by `prove`.
        presentation: PathBuf,
        /// Notary public key (hex) to accept.
        #[arg(long)]
        trust: String,
    },
    /// Prove facts about a GitHub account.
    Prove {
        /// Public account to prove facts about (development: does not prove ownership).
        /// Without it, proves the account of the OAuth token in $GITHUB_TOKEN.
        login: Option<String>,
        /// Notary address: host:port (TCP) or ws:// / wss:// URL. Without it, an in-process notary with a development key is used.
        #[arg(long)]
        notary: Option<String>,
        /// Notary public key (hex) the issuer accepts. Without it, any notary key is accepted.
        #[arg(long)]
        trust: Option<String>,
        /// Where to write the attestation, secrets, presentation and claim.
        #[arg(long, default_value = "out")]
        out: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    // Logs go to stderr so stdout stays clean JSON for `verify`.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    match Cli::parse().command {
        Command::Notary { listen, ws: false, key } => serve_notary(&listen.unwrap_or("127.0.0.1:7047".into()), &key).await,
        Command::Notary { listen, ws: true, key } => {
            let listen = listen.unwrap_or_else(|| format!("0.0.0.0:{}", std::env::var("PORT").unwrap_or("8080".into())));
            serve_notary_ws(&listen, &key).await
        }
        Command::Pubkey { key } => {
            println!("{}", public_key_hex(&load_or_create_key(&key)?)?);
            Ok(())
        }
        Command::Prove { login, notary: address, trust, out } => {
            let subject = match login {
                Some(login) => Subject::Public { login },
                // From the environment only: never on the command line, where shells and `ps` would keep it.
                None => Subject::Owner {
                    token: std::env::var("GITHUB_TOKEN")
                        .map_err(|_| anyhow::anyhow!("give a login, or set GITHUB_TOKEN to prove your own account"))?,
                },
            };
            prove(&subject, address, trust, &out).await
        }
        Command::Verify { presentation, trust } => {
            let presentation: Presentation = bincode::deserialize(&std::fs::read(&presentation)?)?;
            let claim = interpret(&verify(&presentation, Some(&trust))?)?;
            println!("{}", serde_json::to_string(&claim)?);
            Ok(())
        }
    }
}

async fn prove(subject: &Subject, address: Option<String>, trust: Option<String>, out: &Path) -> Result<()> {
    tokio::fs::create_dir_all(out).await?;

    let (attestation, secrets) = match address {
        Some(address) => {
            info!("notarizing with the notary at {address}");
            notarize_via(&address, subject).await?
        }
        None => {
            let (notary_socket, prover_socket) = tokio::io::duplex(1 << 23);
            let notary_task = tokio::spawn(notary(notary_socket, DEV_NOTARY_KEY));
            let result = notarize(prover_socket, subject).await?;
            notary_task.await??;
            result
        }
    };
    write(out, "attestation.tlsn", &attestation).await?;
    write(out, "secrets.tlsn", &secrets).await?;
    println!("1/4 notarized: attestation signed by the notary");

    let presentation = present(&attestation, &secrets)?;
    write(out, "presentation.tlsn", &presentation).await?;
    println!("2/4 presented: only {} revealed", REVEALED_FIELDS.join(", "));

    let revealed = verify(&presentation, trust.as_deref())?;
    println!("3/4 verified: {}", serde_json::to_string(&revealed)?);

    let claim = interpret(&revealed)?;
    tokio::fs::write(out.join("claim.json"), serde_json::to_vec_pretty(&claim)?).await?;
    println!("4/4 claim:\n{}", serde_json::to_string_pretty(&claim)?);
    Ok(())
}

async fn write<T: serde::Serialize>(dir: &Path, name: &str, value: &T) -> Result<()> {
    tokio::fs::write(dir.join(name), bincode::serialize(value)?).await?;
    Ok(())
}

