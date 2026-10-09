//! Apple Music: the kinds of music the user listens to most, from their recently played tracks.
//!
//! The phone gets a developer token and a Music User Token from MusicKit (one tap, no password, no secret in
//! the app); both are request headers, hidden in the presentation. The presentation reveals only each track's
//! genres: titles, artists, albums and everything else stay hidden, from the issuer too.

use anyhow::{Result, bail};
use serde_json::{Map, Value, json};

use super::{HttpRequest, request_parts, revealed_values, shares};

pub const HOST: &str = "api.music.apple.com";
/// The last 15 tracks played: enough to tell a taste, and an answer small enough for a phone to prove.
pub const PATH: &str = "/v1/me/recent/played/tracks?limit=15";
pub const REVEALED_KEYS: [&str; 1] = ["genreNames"];
/// Fewer tracks than this says too little about someone's taste.
const MIN_TRACKS: usize = 5;
pub const LISTENER_RULE: &str = "at least 5 recently played tracks; genres by share of plays";

pub fn request(developer_token: &str, user_token: &str) -> HttpRequest {
    HttpRequest {
        host: HOST,
        method: "GET",
        path: PATH.into(),
        headers: vec![("Authorization", format!("Bearer {developer_token}")), ("Music-User-Token", user_token.into())],
        body: None,
        // 15 tracks with their attributes: ~25-40 KB. Received data is decrypted after the session, in a
        // zero-knowledge proof the phone computes, so it is kept tight too.
        max_recv: 1 << 16,
    }
}

pub fn read(sent: &str, received: &str) -> Result<Map<String, Value>> {
    let (request_line, _) = request_parts(sent);
    if request_line != format!("GET {PATH} HTTP/1.1") {
        bail!("unexpected request: {}", request_line.replace('\0', "·"));
    }
    let genres: Vec<Vec<String>> = revealed_values(received, "genreNames")
        .into_iter()
        .map(|v| v.as_array().map(|list| list.iter().filter_map(|g| g.as_str().map(String::from)).collect()).unwrap_or_default())
        .collect();
    if genres.len() < MIN_TRACKS {
        bail!("only {} tracks revealed, at least {MIN_TRACKS} needed", genres.len());
    }
    let mut fields = Map::new();
    fields.insert("genres".into(), json!(genres));
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
        "schema": "music.apple_listener v2",
        "claim": "music.listener",
        "rule": LISTENER_RULE,
        "data": {
            "genres": shares(&by_genre, 4),
            "tracks": tracks,
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

    /// A partially revealed answer: titles, artists and albums hidden (`\0`), genres revealed.
    fn received(tracks: &[(&str, &str)]) -> String {
        let items: Vec<String> = tracks
            .iter()
            .map(|(_, genre)| format!(r#"{{"id":"\0\0\0","attributes":{{"name":"\0\0\0\0","artistName":"\0\0\0","genreNames":["{genre}","Music"],"albumName":"\0\0\0"}}}}"#))
            .collect();
        format!("HTTP/1.1 200 OK\r\n\0\0\0\r\n\r\n{{\"data\":[{}]}}", items.join(","))
    }

    #[test]
    fn listener_badge_from_revealed_genres() {
        let tracks = [("Daft Punk", "Electronic"), ("Daft Punk", "Electronic"), ("Kendrick Lamar", "Hip-Hop/Rap"), ("Daft Punk", "Electronic"), ("Justice", "Electronic"), ("Kendrick Lamar", "Hip-Hop/Rap")];
        let sent = format!("GET {PATH} HTTP/1.1\r\nauthorization: \0\0\0\r\nmusic-user-token: \0\0\0\r\n\r\n");
        let mut revealed = read(&sent, &received(&tracks)).unwrap();
        revealed.insert("proven_at".into(), json!("2026-10-09T00:00:00+00:00"));
        let claim = interpret(&Value::Object(revealed)).unwrap();
        assert!(claim["data"].get("top_artists").is_none());
        assert_eq!(claim["data"]["genres"], "Electronic:67,Hip-Hop/Rap:33");
        assert_eq!(claim["data"]["tracks"], 6);
    }

    #[test]
    fn other_requests_and_short_histories_are_refused() {
        let tracks = [("A", "Pop"); 6];
        assert!(read("GET /v1/me/library/songs HTTP/1.1\r\n\r\n", &received(&tracks)).is_err());
        let sent = format!("GET {PATH} HTTP/1.1\r\n\r\n");
        assert!(read(&sent, &received(&tracks[..3])).is_err());
    }
}
