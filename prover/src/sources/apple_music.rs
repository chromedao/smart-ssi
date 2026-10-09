//! Apple Music: what the user listens to, from their recently played tracks.
//!
//! The phone gets a developer token and a Music User Token from MusicKit (one tap, no password, no secret in
//! the app); both are request headers, hidden in the presentation. The presentation reveals only each track's
//! artist and genres: titles, albums and everything else stay hidden, from the issuer too.

use anyhow::{Result, bail};
use serde_json::{Map, Value, json};

use super::{HttpRequest, request_parts, revealed_values, shares};

pub const HOST: &str = "api.music.apple.com";
/// The last 30 tracks played (the endpoint's maximum).
pub const PATH: &str = "/v1/me/recent/played/tracks?limit=30";
pub const REVEALED_KEYS: [&str; 2] = ["artistName", "genreNames"];
/// Fewer tracks than this says too little about someone's taste.
const MIN_TRACKS: usize = 5;
pub const LISTENER_RULE: &str = "at least 5 recently played tracks; top artists by plays, genres by share of plays";

pub fn request(developer_token: &str, user_token: &str) -> HttpRequest {
    HttpRequest {
        host: HOST,
        method: "GET",
        path: PATH.into(),
        headers: vec![("Authorization", format!("Bearer {developer_token}")), ("Music-User-Token", user_token.into())],
        body: None,
        // 30 tracks with their attributes: ~60-90 KB. Received data is decrypted after the session.
        max_recv: 1 << 17,
    }
}

pub fn read(sent: &str, received: &str) -> Result<Map<String, Value>> {
    let (request_line, _) = request_parts(sent);
    if request_line != format!("GET {PATH} HTTP/1.1") {
        bail!("unexpected request: {}", request_line.replace('\0', "·"));
    }
    let artists: Vec<String> = revealed_values(received, "artistName").into_iter().filter_map(|v| v.as_str().map(String::from)).collect();
    let genres: Vec<Vec<String>> = revealed_values(received, "genreNames")
        .into_iter()
        .map(|v| v.as_array().map(|list| list.iter().filter_map(|g| g.as_str().map(String::from)).collect()).unwrap_or_default())
        .collect();
    if artists.len() < MIN_TRACKS {
        bail!("only {} tracks revealed, at least {MIN_TRACKS} needed", artists.len());
    }
    let mut fields = Map::new();
    fields.insert("artists".into(), json!(artists));
    fields.insert("genres".into(), json!(genres));
    Ok(fields)
}

pub fn interpret(revealed: &Value) -> Result<Value> {
    let artists: Vec<&str> = revealed["artists"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut by_artist: Vec<(String, u64)> = Vec::new();
    for artist in &artists {
        count(&mut by_artist, artist);
    }
    by_artist.sort_by(|a, b| b.1.cmp(&a.1));
    // "Music" is Apple's catch-all genre on every track: it says nothing.
    let mut by_genre: Vec<(String, u64)> = Vec::new();
    for genre in revealed["genres"].as_array().into_iter().flatten().filter_map(|g| g.as_array()?.first()?.as_str()).filter(|g| *g != "Music") {
        count(&mut by_genre, genre);
    }
    Ok(json!({
        "schema": "music.apple_listener v1",
        "claim": "music.listener",
        "rule": LISTENER_RULE,
        "data": {
            "top_artists": by_artist.iter().take(3).map(|(name, _)| name.as_str()).collect::<Vec<_>>().join(","),
            "genres": shares(&by_genre, 4),
            "tracks": artists.len(),
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

    /// A partially revealed answer: titles and albums hidden (`\0`), artist and genres revealed.
    fn received(tracks: &[(&str, &str)]) -> String {
        let items: Vec<String> = tracks
            .iter()
            .map(|(artist, genre)| format!(r#"{{"id":"\0\0\0","attributes":{{"name":"\0\0\0\0","artistName":"{artist}","genreNames":["{genre}","Music"],"albumName":"\0\0\0"}}}}"#))
            .collect();
        format!("HTTP/1.1 200 OK\r\n\0\0\0\r\n\r\n{{\"data\":[{}]}}", items.join(","))
    }

    #[test]
    fn listener_badge_from_revealed_artists_and_genres() {
        let tracks = [("Daft Punk", "Electronic"), ("Daft Punk", "Electronic"), ("Kendrick Lamar", "Hip-Hop/Rap"), ("Daft Punk", "Electronic"), ("Justice", "Electronic"), ("Kendrick Lamar", "Hip-Hop/Rap")];
        let sent = format!("GET {PATH} HTTP/1.1\r\nauthorization: \0\0\0\r\nmusic-user-token: \0\0\0\r\n\r\n");
        let mut revealed = read(&sent, &received(&tracks)).unwrap();
        revealed.insert("proven_at".into(), json!("2026-10-09T00:00:00+00:00"));
        let claim = interpret(&Value::Object(revealed)).unwrap();
        assert_eq!(claim["data"]["top_artists"], "Daft Punk,Kendrick Lamar,Justice");
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
