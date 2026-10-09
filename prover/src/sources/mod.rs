//! Sources: the websites Smart-SSI proves facts from. A source defines the one HTTP request the prover sends
//! (its secret headers stay hidden in the presentation), how the verifier reads the revealed exchange back,
//! and the public rule that turns it into a claim. Everything else (MPC-TLS, notary, presentation) is shared.

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value};

pub mod github;

/// What the user proves, and the credentials to ask for it. No Debug: tokens must never reach a log.
pub enum Subject {
    /// The developer badge: the GitHub account the OAuth token belongs to (one GraphQL query).
    GithubDeveloper { token: String },
    /// Public facts about any GitHub account (`GET /users/<login>`): not ownership. Development only.
    GithubPublic { login: String },
}

impl std::fmt::Display for Subject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Subject::GithubDeveloper { .. } => write!(f, "the token owner's GitHub developer profile"),
            Subject::GithubPublic { login } => write!(f, "public GitHub account {login}"),
        }
    }
}

/// The single request a proof is made of.
pub struct HttpRequest {
    pub host: &'static str,
    pub method: &'static str,
    pub path: String,
    /// Source-specific headers, credentials included (listed in SECRET_HEADERS, so never revealed).
    pub headers: Vec<(&'static str, String)>,
    pub body: Option<String>,
}

impl Subject {
    pub fn request(&self) -> HttpRequest {
        match self {
            Subject::GithubDeveloper { token } => github::developer_request(token),
            Subject::GithubPublic { login } => github::public_request(login),
        }
    }
}

/// Request headers whose value is never revealed in a presentation.
pub const SECRET_HEADERS: [&str; 3] = ["authorization", "cookie", "music-user-token"];

/// Hosts the verifier accepts, by TLS server name.
pub fn is_known_host(host: &str) -> bool {
    host == github::HOST
}

/// Whether the presentation reveals the whole response. Requests ask only for what the badge shows, so the
/// answer is revealed as is; the GitHub public-profile request is the exception (it gets a full profile and
/// reveals three fields).
pub fn reveals_whole_response(host: &str, target: &str) -> bool {
    !(host == github::HOST && target.starts_with("/users/"))
}

/// Step 3 for one source: check the revealed request is the expected one and read the revealed answer.
/// `sent` and `received` are the authenticated transcripts, hidden bytes as `\0`.
pub fn read(host: &str, sent: &str, received: &str) -> Result<Map<String, Value>> {
    match host {
        github::HOST => github::read(sent, received),
        _ => bail!("no source for {host}"),
    }
}

/// Step 4: the source's public rule turns the revealed facts into a claim.
pub fn interpret(revealed: &Value) -> Result<Value> {
    match revealed["server"].as_str() {
        Some(github::HOST) | None => github::interpret(revealed),
        Some(other) => bail!("no source for {other}"),
    }
}

/// The JSON body of a fully revealed response (plain or chunked).
pub(crate) fn revealed_json(received: &str) -> Result<Value> {
    let (head, body) = received.split_once("\r\n\r\n").context("response has no body")?;
    if body.contains('\0') {
        bail!("the answer is not fully revealed");
    }
    let body = if head.to_ascii_lowercase().contains("transfer-encoding: chunked") { dechunk(body)? } else { body.to_string() };
    serde_json::from_str(&body).context("the answer is not JSON")
}

fn dechunk(body: &str) -> Result<String> {
    let (mut rest, mut out) = (body, String::new());
    loop {
        let (size, after) = rest.split_once("\r\n").context("bad chunk")?;
        let size = usize::from_str_radix(size.split(';').next().unwrap_or("").trim(), 16)?;
        if size == 0 {
            return Ok(out);
        }
        out.push_str(after.get(..size).context("short chunk")?);
        rest = after.get(size + 2..).context("short chunk")?;
    }
}

/// The request line and body of a revealed request.
pub(crate) fn request_parts(sent: &str) -> (&str, Option<&str>) {
    let line = sent.split("\r\n").next().unwrap_or_default();
    (line, sent.split_once("\r\n\r\n").map(|(_, body)| body).filter(|body| !body.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunked_answers_are_read() {
        let received = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"dat\r\n16\r\na\":{\"viewer\":{\"a\":1}}}\r\n0\r\n\r\n";
        assert_eq!(revealed_json(received).unwrap()["data"]["viewer"]["a"], 1);
    }
}
