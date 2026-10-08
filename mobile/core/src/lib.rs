//! Smart-SSI prover for the mobile apps. One blocking call runs the whole proof on the device;
//! call it off the main thread.

use std::time::Instant;

use smart_ssi_prover::{interpret, notarize, present, verify};

uniffi::setup_scaffolding!();

/// A finished proof, ready to send to the issuer API.
#[derive(uniffi::Record)]
pub struct GithubProof {
    /// TLSNotary presentation (bincode), the bytes the issuer verifies.
    pub presentation: Vec<u8>,
    /// What the issuer will see: the revealed fields, as JSON.
    pub revealed_json: String,
    /// The claim the public rule derives from them, as JSON.
    pub claim_json: String,
    /// Wall-clock time of the whole proof, for the measurements in #4.
    pub seconds: f64,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ProveError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<anyhow::Error> for ProveError {
    fn from(error: anyhow::Error) -> Self {
        ProveError::Failed { message: format!("{error:#}") }
    }
}

/// Prove facts about a GitHub account through the notary at `notary` (host:port).
#[uniffi::export]
pub fn prove_github(login: String, notary: String) -> Result<GithubProof, ProveError> {
    let start = Instant::now();
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(anyhow::Error::from)?;
    runtime.block_on(async {
        let socket = tokio::net::TcpStream::connect(&notary)
            .await
            .map_err(|e| anyhow::anyhow!("cannot reach the notary at {notary}: {e}"))?;
        let (attestation, secrets) = notarize(socket, &login).await?;
        let presentation = present(&attestation, &secrets)?;
        // The app checks its own proof before sending it; the issuer checks it again against the trusted key.
        let revealed = verify(&presentation, None)?;
        let claim = interpret(&revealed)?;
        Ok::<_, anyhow::Error>(GithubProof {
            presentation: bincode::serialize(&presentation)?,
            revealed_json: serde_json::to_string(&revealed)?,
            claim_json: serde_json::to_string(&claim)?,
            seconds: start.elapsed().as_secs_f64(),
        })
    })
    .map_err(Into::into)
}
