//! Smart-SSI prover for the mobile apps. One blocking call runs the whole proof on the device;
//! call it off the main thread.

use std::time::Instant;

use smart_ssi_prover::{Subject, interpret, notarize_via, present, verify};

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
    // Not `message`: it would clash with Exception.message in the Kotlin bindings.
    #[error("{reason}")]
    Failed { reason: String },
}

impl From<anyhow::Error> for ProveError {
    fn from(error: anyhow::Error) -> Self {
        ProveError::Failed { reason: format!("{error:#}") }
    }
}

/// Prove the GitHub account the OAuth `token` belongs to (proof of ownership), through the notary at
/// `notary` (host:port for TCP, or a ws:// / wss:// URL). The token never leaves the MPC-TLS session.
#[uniffi::export]
pub fn prove_github_owner(token: String, notary: String) -> Result<GithubProof, ProveError> {
    prove(Subject::GithubDeveloper { token }, notary)
}

/// Prove public facts about any GitHub account (development only: does not prove ownership).
#[uniffi::export]
pub fn prove_github_public(login: String, notary: String) -> Result<GithubProof, ProveError> {
    prove(Subject::GithubPublic { login }, notary)
}

/// Prove what the user listens to from one page of their Apple Music library, at `offset` (set by the wallet
/// and the day, see `apple_library_offset`). Both tokens come from MusicKit on the phone; they never leave the
/// MPC-TLS session (hidden in the presentation).
#[uniffi::export]
pub fn prove_apple_music(developer_token: String, user_token: String, offset: u32, notary: String) -> Result<GithubProof, ProveError> {
    prove(Subject::AppleMusic { developer_token, user_token, offset }, notary)
}

fn prove(subject: Subject, notary: String) -> Result<GithubProof, ProveError> {
    let start = Instant::now();
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(anyhow::Error::from)?;
    runtime.block_on(async {
        let (attestation, secrets) = notarize_via(&notary, &subject).await?;
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

// --- Wallet (used by the Android app; iOS uses CryptoKit) ------------------------------------------

/// A new random 32-byte Ed25519 seed. The app stores it encrypted; it never leaves the phone.
#[uniffi::export]
pub fn wallet_new_seed() -> Result<Vec<u8>, ProveError> {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|e| anyhow::anyhow!("no randomness: {e}"))?;
    Ok(seed.to_vec())
}

fn signing_key(seed: &[u8]) -> Result<ed25519_dalek::SigningKey, ProveError> {
    let seed: [u8; 32] = seed.try_into().map_err(|_| anyhow::anyhow!("seed must be 32 bytes"))?;
    Ok(ed25519_dalek::SigningKey::from_bytes(&seed))
}

/// Solana address (base58 public key) of the wallet.
#[uniffi::export]
pub fn wallet_address(seed: Vec<u8>) -> Result<String, ProveError> {
    Ok(bs58::encode(signing_key(&seed)?.verifying_key().as_bytes()).into_string())
}

/// Ed25519 signature of `message`, as the issuer API expects.
#[uniffi::export]
pub fn wallet_sign(seed: Vec<u8>, message: String) -> Result<Vec<u8>, ProveError> {
    use ed25519_dalek::Signer;
    Ok(signing_key(&seed)?.sign(message.as_bytes()).to_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Cross-check with @solana/kit: SEED_HEX=<32-byte seed> EXPECTED=<address> cargo test
    #[test]
    fn address_matches_solana_kit() {
        let (Ok(seed), Ok(expected)) = (std::env::var("SEED_HEX"), std::env::var("EXPECTED")) else { return };
        let seed: Vec<u8> = (0..seed.len()).step_by(2).map(|i| u8::from_str_radix(&seed[i..i + 2], 16).unwrap()).collect();
        assert_eq!(wallet_address(seed.clone()).unwrap(), expected);
        assert_eq!(wallet_sign(seed, "smart-ssi".into()).unwrap().len(), 64);
    }
}
