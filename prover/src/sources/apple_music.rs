//! Apple Music: the kinds of music the user listens to, from a sample of their library.
//!
//! One page of 100 library songs, genres only (`fields[library-songs]=genreNames`, ~14 KB). The page is not the
//! user's choice: its offset comes from their wallet and the day (`sample_offset`), which the issuer recomputes,
//! so nobody can pick a flattering page. The library is sorted by title, so a page is a fair sample of it.
//!
//! The phone gets a developer token and a Music User Token from MusicKit (one tap, no password, no secret in
//! the app); both are request headers, hidden in the presentation. The presentation reveals only each track's
//! genres: the request asks for nothing else, so the answer (opaque library ids and genres) is revealed whole.

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};

use super::{HttpRequest, request_parts, revealed_json, shares};

pub const HOST: &str = "api.music.apple.com";
/// Songs per page: the API's maximum.
pub const PAGE: u32 = 100;

/// The proven request: one page of the library, genres only, in English so badges compare across countries.
pub fn path(offset: u32) -> String {
    format!("/v1/me/library/songs?limit={PAGE}&offset={offset}&l=en-US&fields[library-songs]=genreNames")
}
/// Fewer tracks than this says too little about someone's taste.
const MIN_TRACKS: usize = 5;
pub const LISTENER_RULE: &str = "a page of 100 library songs at an offset set by the wallet and the day; genres by share of songs";

pub fn request(developer_token: &str, user_token: &str, offset: u32) -> HttpRequest {
    HttpRequest {
        host: HOST,
        method: "GET",
        path: path(offset),
        headers: vec![("Authorization", format!("Bearer {developer_token}")), ("Music-User-Token", user_token.into())],
        body: None,
        // 100 songs, genres only: ~14 KB measured. Received data is decrypted after the session, in a
        // zero-knowledge proof the phone computes, so it is kept tight.
        max_recv: 1 << 15,
    }
}

pub fn read(sent: &str, received: &str) -> Result<Map<String, Value>> {
    let (request_line, _) = request_parts(sent);
    let offset: u32 = request_line
        .strip_prefix(&format!("GET /v1/me/library/songs?limit={PAGE}&offset="))
        .and_then(|rest| rest.split('&').next())
        .and_then(|offset| offset.parse().ok())
        .with_context(|| format!("unexpected request: {}", request_line.replace('\0', "·")))?;
    if request_line != format!("GET {} HTTP/1.1", path(offset)) {
        bail!("unexpected request: {}", request_line.replace('\0', "·"));
    }
    let answer = revealed_json(received)?;
    let genres: Vec<Vec<String>> = answer["data"]
        .as_array()
        .context("no songs")?
        .iter()
        .map(|song| song["attributes"]["genreNames"].as_array().into_iter().flatten().filter_map(|g| g.as_str().map(String::from)).collect())
        .collect();
    if genres.len() < MIN_TRACKS {
        bail!("only {} tracks revealed, at least {MIN_TRACKS} needed", genres.len());
    }
    let mut fields = Map::new();
    fields.insert("genres".into(), json!(genres));
    fields.insert("offset".into(), json!(offset));
    fields.insert("total".into(), answer["meta"]["total"].clone());
    Ok(fields)
}

pub fn interpret(revealed: &Value) -> Result<Value> {
    let tracks = revealed["genres"].as_array().map_or(0, Vec::len);
    // A track's first genre is its main one; "Music" is Apple's catch-all on every track: it says nothing.
    let mut by_genre: Vec<(String, u64)> = Vec::new();
    for genre in revealed["genres"].as_array().into_iter().flatten().filter_map(|g| g.as_array()?.first()?.as_str()).filter(|g| *g != "Music") {
        count(&mut by_genre, genre);
    }
    Ok(json!({
        "schema": "music.apple_listener v3",
        "claim": "music.listener",
        "rule": LISTENER_RULE,
        "data": {
            "genres": shares(&by_genre, 4),
            "tracks": tracks,
            "library_size": revealed["total"].as_u64().context("no library size")?,
            "sample_offset": revealed["offset"].as_u64().context("no offset")?,
            "source": "apple_music:owner",
            "proven_at": revealed["proven_at"],
        }
    }))
}

fn count(counts: &mut Vec<(String, u64)>, name: &str) {
    match counts.iter_mut().find(|(known, _)| known == name) {
        Some((_, total)) => *total += 1,
        None => counts.push((name.to_string(), 1)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn received(genres: &[&str], total: u32) -> String {
        let songs: Vec<String> = genres.iter().enumerate().map(|(i, genre)| format!(r#"{{"id":"i.{i}","type":"library-songs","attributes":{{"genreNames":["{genre}"]}}}}"#)).collect();
        format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{{\"data\":[{}],\"meta\":{{\"total\":{total}}}}}", songs.join(","))
    }

    #[test]
    fn listener_badge_from_a_library_page() {
        let sent = format!("GET {} HTTP/1.1\r\nauthorization: \0\0\0\r\nmusic-user-token: \0\0\0\r\n\r\n", path(4200));
        let genres = ["Electronic", "Electronic", "Hip-Hop/Rap", "Electronic", "Pop", "Hip-Hop/Rap"];
        let mut revealed = read(&sent, &received(&genres, 14555)).unwrap();
        revealed.insert("proven_at".into(), json!("2026-10-09T00:00:00+00:00"));
        let claim = interpret(&Value::Object(revealed)).unwrap();
        assert_eq!(claim["data"]["genres"], "Electronic:50,Hip-Hop/Rap:33,Pop:17");
        assert_eq!(claim["data"]["tracks"], 6);
        assert_eq!(claim["data"]["library_size"], 14555);
        assert_eq!(claim["data"]["sample_offset"], 4200);
    }

    #[test]
    fn other_requests_and_short_pages_are_refused() {
        let genres = ["Pop"; 6];
        assert!(read("GET /v1/me/library/songs?limit=100&offset=1 HTTP/1.1\r\n\r\n", &received(&genres, 500)).is_err());
        assert!(read("GET /v1/me/recent/played/tracks?limit=15 HTTP/1.1\r\n\r\n", &received(&genres, 500)).is_err());
        let sent = format!("GET {} HTTP/1.1\r\n\r\n", path(0));
        assert!(read(&sent, &received(&genres[..3], 3)).is_err());
    }
}
