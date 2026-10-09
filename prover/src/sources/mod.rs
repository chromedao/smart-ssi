//! Sources: the websites Smart-SSI proves facts from. A source defines the one HTTP request the prover sends
//! (its secret headers stay hidden in the presentation), how the verifier reads the revealed exchange back,
//! and the public rule that turns it into a claim. Everything else (MPC-TLS, notary, presentation) is shared.

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value};

pub mod apple_music;
pub mod github;

/// What the user proves, and the credentials to ask for it. No Debug: tokens must never reach a log.
pub enum Subject {
    /// The developer badge: the GitHub account the OAuth token belongs to (one GraphQL query).
    GithubDeveloper { token: String },
    /// Public facts about any GitHub account (`GET /users/<login>`): not ownership. Development only.
    GithubPublic { login: String },
    /// What the user listens to: their recently played Apple Music tracks (MusicKit developer + user tokens).
    AppleMusic { developer_token: String, user_token: String },
}

impl std::fmt::Display for Subject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Subject::GithubDeveloper { .. } => write!(f, "the token owner's GitHub developer profile"),
            Subject::GithubPublic { login } => write!(f, "public GitHub account {login}"),
            Subject::AppleMusic { .. } => write!(f, "the user's recently played Apple Music tracks"),
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
    /// Bytes reserved for the answer (MPC-TLS). Received data costs little; requests stay tight.
    pub max_recv: usize,
}

impl Subject {
    pub fn request(&self) -> HttpRequest {
        match self {
            Subject::GithubDeveloper { token } => github::developer_request(token),
            Subject::GithubPublic { login } => github::public_request(login),
            Subject::AppleMusic { developer_token, user_token } => apple_music::request(developer_token, user_token),
        }
    }
}

/// Request headers whose value is never revealed in a presentation.
pub const SECRET_HEADERS: [&str; 3] = ["authorization", "cookie", "music-user-token"];

/// Hosts the verifier accepts, by TLS server name.
pub fn is_known_host(host: &str) -> bool {
    [github::HOST, apple_music::HOST].contains(&host)
}

/// What of the answer a presentation reveals.
pub enum Reveal {
    /// Everything: the request asked only for what the badge shows.
    WholeResponse,
    /// These fields of the top-level JSON object.
    RootFields(&'static [&'static str]),
    /// Every occurrence of these keys, at any depth (e.g. each track's artist), and nothing else.
    KeysAnywhere(&'static [&'static str]),
}

pub fn reveal(host: &str, target: &str) -> Reveal {
    match host {
        github::HOST if target.starts_with("/users/") => Reveal::RootFields(&github::REVEALED_FIELDS),
        apple_music::HOST => Reveal::KeysAnywhere(&apple_music::REVEALED_KEYS),
        _ => Reveal::WholeResponse,
    }
}

/// Step 3 for one source: check the revealed request is the expected one and read the revealed answer.
/// `sent` and `received` are the authenticated transcripts, hidden bytes as `\0`.
pub fn read(host: &str, sent: &str, received: &str) -> Result<Map<String, Value>> {
    match host {
        github::HOST => github::read(sent, received),
        apple_music::HOST => apple_music::read(sent, received),
        _ => bail!("no source for {host}"),
    }
}

/// Step 4: the source's public rule turns the revealed facts into a claim.
pub fn interpret(revealed: &Value) -> Result<Value> {
    match revealed["server"].as_str() {
        Some(github::HOST) | None => github::interpret(revealed),
        Some(apple_music::HOST) => apple_music::interpret(revealed),
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

/// Every revealed value of `key` in a partially revealed JSON answer: `"key":<value>` where both the key and
/// its value were revealed (hidden bytes are `\0`, so a hidden value never parses).
pub(crate) fn revealed_values(received: &str, key: &str) -> Vec<Value> {
    let marker = format!("\"{key}\":");
    received
        .match_indices(&marker)
        .filter_map(|(at, _)| serde_json::Deserializer::from_str(&received[at + marker.len()..]).into_iter::<Value>().next()?.ok())
        .collect()
}

/// "A:62,B:21,C:9,Other:8": shares of the largest counts in percent (rounded, summing to 100), the rest as Other.
pub fn shares(counts: &[(String, u64)], top: usize) -> String {
    let mut counts: Vec<(&str, u64)> = counts.iter().map(|(name, count)| (name.as_str(), *count)).filter(|(_, c)| *c > 0).collect();
    counts.sort_by(|a, b| b.1.cmp(&a.1));
    let total: u64 = counts.iter().map(|(_, c)| c).sum();
    if total == 0 {
        return String::new();
    }
    let mut kept: Vec<(String, u64)> = Vec::new();
    let mut other = 0;
    for (index, (name, count)) in counts.iter().enumerate() {
        if index < top && *name != "Other" { kept.push((name.to_string(), *count)) } else { other += count }
    }
    if other > 0 {
        kept.push(("Other".into(), other));
    }
    let mut percents: Vec<u64> = kept.iter().map(|(_, c)| c * 100 / total).collect();
    // Hand out the rounding remainder to the largest shares so the total is 100.
    let mut missing = 100 - percents.iter().sum::<u64>();
    for p in percents.iter_mut() {
        if missing == 0 { break }
        *p += 1;
        missing -= 1;
    }
    kept.iter().zip(percents).filter(|(_, p)| *p > 0).map(|((name, _), p)| format!("{name}:{p}")).collect::<Vec<_>>().join(",")
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
