//! GitHub: the developer badge (one GraphQL query as the token's owner) and, for development, public facts
//! about any account.

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

use super::{HttpRequest, request_parts, revealed_json};

pub const HOST: &str = "api.github.com";

/// Public-profile request (development): fields revealed to the issuer, everything else stays hidden.
pub const REVEALED_FIELDS: [&str; 3] = ["login", "public_repos", "created_at"];

/// The developer badge's GraphQL query. It asks only for what the badge shows, so the whole answer is revealed;
/// repository names are never requested, only each repository's main language. The verifier checks the request
/// carries exactly this query.
pub const DEVELOPER_QUERY: &str = "{viewer{databaseId login createdAt contributionsCollection{contributionYears contributionCalendar{totalContributions}commitContributionsByRepository(maxRepositories:25){contributions{totalCount}repository{primaryLanguage{name}}}}repositoriesContributedTo(includeUserRepositories:true,contributionTypes:[COMMIT,PULL_REQUEST]){totalCount}}}";

/// The developer rule: an account older than a year, and either 100+ contributions in the last 12 months or
/// contributions to 3+ projects. Work on other people's repositories counts.
pub const DEVELOPER_RULE: &str = "account >= 1 year and (contributions in the last 12 months >= 100 or projects contributed to >= 3)";

fn developer_query_body() -> String {
    json!({ "query": DEVELOPER_QUERY }).to_string()
}

const ACCEPT: (&str, &str) = ("Accept", "application/vnd.github+json");

pub fn developer_request(token: &str) -> HttpRequest {
    HttpRequest {
        host: HOST,
        method: "POST",
        path: "/graphql".into(),
        headers: vec![
            ("Authorization", format!("Bearer {token}")),
            ("Content-Type", "application/json".into()),
            (ACCEPT.0, ACCEPT.1.into()),
        ],
        body: Some(developer_query_body()),
    }
}

pub fn public_request(login: &str) -> HttpRequest {
    HttpRequest { host: HOST, method: "GET", path: format!("/users/{login}"), headers: vec![(ACCEPT.0, ACCEPT.1.into())], body: None }
}

/// Which request was proven decides what is proven: /graphql (and /user, older apps) is the token owner's own
/// account; /users/<login> is anyone's public profile.
pub fn read(sent: &str, received: &str) -> Result<Map<String, Value>> {
    let (request_line, body) = request_parts(sent);
    let mut fields = Map::new();
    if request_line == "POST /graphql HTTP/1.1" {
        if body != Some(developer_query_body().as_str()) {
            bail!("the request does not carry the developer query");
        }
        let answer = revealed_json(received)?;
        if answer.get("errors").is_some() {
            bail!("GitHub returned errors: {}", answer["errors"]);
        }
        fields = developer_fields(&answer["data"]["viewer"])?;
        fields.insert("version".into(), json!(2));
        fields.insert("owner".into(), json!(true));
        return Ok(fields);
    }
    let owner = if request_line == "GET /user HTTP/1.1" {
        true
    } else if request_line.starts_with("GET /users/") && request_line.ends_with(" HTTP/1.1") && !request_line.contains('\0') {
        false
    } else {
        bail!("unexpected request: {}", request_line.replace('\0', "·"));
    };
    // Pull each revealed `"field":value` pair out of the partially hidden response.
    for field in REVEALED_FIELDS {
        let marker = format!("\"{field}\":");
        let start = received.find(&marker).with_context(|| format!("{field} not revealed"))? + marker.len();
        let rest = &received[start..];
        let end = rest.find(|c| c == ',' || c == '}' || c == '\0').unwrap_or(rest.len());
        fields.insert(field.into(), serde_json::from_str(rest[..end].trim())?);
    }
    fields.insert("version".into(), json!(1));
    fields.insert("owner".into(), json!(owner));
    Ok(fields)
}

/// The developer facts, from the GraphQL viewer: contribution years, last 12 months, languages weighted by the
/// user's own commits, projects contributed to.
fn developer_fields(viewer: &Value) -> Result<Map<String, Value>> {
    let collection = &viewer["contributionsCollection"];
    let mut languages: Vec<(String, u64)> = Vec::new();
    for entry in collection["commitContributionsByRepository"].as_array().context("no commit contributions")? {
        let commits = entry["contributions"]["totalCount"].as_u64().unwrap_or(0);
        let name = entry["repository"]["primaryLanguage"]["name"].as_str().unwrap_or("Other").to_string();
        match languages.iter_mut().find(|(known, _)| *known == name) {
            Some((_, total)) => *total += commits,
            None => languages.push((name, commits)),
        }
    }
    languages.sort_by(|a, b| b.1.cmp(&a.1));
    let mut years: Vec<u64> = collection["contributionYears"].as_array().context("no contribution years")?.iter().filter_map(Value::as_u64).collect();
    years.sort();
    let mut fields = Map::new();
    // GitHub's permanent account id: logins can change hands, this cannot. One GitHub account, one badge.
    fields.insert("github_id".into(), viewer["databaseId"].clone());
    fields.insert("login".into(), viewer["login"].clone());
    fields.insert("created_at".into(), viewer["createdAt"].clone());
    fields.insert("contribution_years".into(), json!(years));
    fields.insert("contributions_12m".into(), collection["contributionCalendar"]["totalContributions"].clone());
    fields.insert("repos_contributed".into(), viewer["repositoriesContributedTo"]["totalCount"].clone());
    fields.insert("languages".into(), json!(languages.iter().map(|(name, commits)| json!({ "name": name, "commits": commits })).collect::<Vec<_>>()));
    Ok(fields)
}

/// A public, deterministic rule (no AI) turns the revealed fields into a claim.
pub fn interpret(revealed: &Value) -> Result<Value> {
    if revealed["version"] == json!(2) {
        return interpret_developer(revealed);
    }
    let repos = revealed["public_repos"].as_u64().ok_or_else(|| anyhow!("public_repos is not a number"))?;
    let created: DateTime<Utc> = revealed["created_at"].as_str().context("created_at missing")?.parse()?;
    let years = (Utc::now() - created).num_days() / 365;
    let active = repos >= 5 && years >= 1;
    Ok(json!({
        "schema": "dev.github_account v1",
        "claim": if active { "dev.active" } else { "dev.not_yet" },
        "rule": "public_repos >= 5 and account age >= 1 year",
        "data": {
            "login": revealed["login"],
            "public_repos": repos,
            "account_age_years": years,
            // github:owner = proven through the user's own session; github:public = anyone's public profile.
            "source": if revealed["owner"] == json!(true) { "github:owner" } else { "github:public" },
            "proven_at": revealed["proven_at"],
        }
    }))
}

fn interpret_developer(revealed: &Value) -> Result<Value> {
    let created: DateTime<Utc> = revealed["created_at"].as_str().context("created_at missing")?.parse()?;
    let age_years = (Utc::now() - created).num_days() / 365;
    let years: Vec<u64> = revealed["contribution_years"].as_array().context("no years")?.iter().filter_map(Value::as_u64).collect();
    let since = years.first().copied().unwrap_or(created.format("%Y").to_string().parse()?);
    let contributions = revealed["contributions_12m"].as_u64().context("no contributions")?;
    let projects = revealed["repos_contributed"].as_u64().context("no projects")?;
    let active = age_years >= 1 && (contributions >= 100 || projects >= 3);
    Ok(json!({
        "schema": "dev.github_account v3",
        "claim": if active { "dev.active" } else { "dev.not_yet" },
        "rule": DEVELOPER_RULE,
        "data": {
            "github_id": revealed["github_id"].as_u64().context("no GitHub id")?,
            "login": revealed["login"],
            "since_year": since,
            "years_active": years.len(),
            "contributions_12m": contributions,
            "repos_contributed": projects,
            "languages": language_shares(revealed["languages"].as_array().context("no languages")?),
            "account_age_years": age_years,
            "source": "github:owner",
            "proven_at": revealed["proven_at"],
        }
    }))
}

/// "TypeScript:62,Rust:21,Swift:9,Other:8": the top languages by the user's commits over the last 12 months, in
/// percent (rounded, summing to 100), the rest grouped as Other.
pub fn language_shares(languages: &[Value]) -> String {
    let counts: Vec<(&str, u64)> = languages.iter().filter_map(|l| Some((l["name"].as_str()?, l["commits"].as_u64()?))).filter(|(_, c)| *c > 0).collect();
    let total: u64 = counts.iter().map(|(_, c)| c).sum();
    if total == 0 {
        return String::new();
    }
    let mut shares: Vec<(String, u64)> = Vec::new();
    let mut other = 0;
    for (index, (name, commits)) in counts.iter().enumerate() {
        if index < 4 && *name != "Other" { shares.push((name.to_string(), *commits)) } else { other += commits }
    }
    if other > 0 {
        shares.push(("Other".into(), other));
    }
    let mut percents: Vec<u64> = shares.iter().map(|(_, c)| c * 100 / total).collect();
    // Hand out the rounding remainder to the largest shares so the total is 100.
    let mut missing = 100 - percents.iter().sum::<u64>();
    for p in percents.iter_mut() {
        if missing == 0 { break }
        *p += 1;
        missing -= 1;
    }
    shares.iter().zip(percents).filter(|(_, p)| *p > 0).map(|((name, _), p)| format!("{name}:{p}")).collect::<Vec<_>>().join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn developer_badge_from_a_graphql_answer() {
        let viewer = json!({
            "databaseId": 6667123, "login": "jeemclr", "createdAt": "2014-03-02T10:00:00Z",
            "contributionsCollection": {
                "contributionYears": [2026, 2025, 2019, 2014],
                "contributionCalendar": { "totalContributions": 640 },
                "commitContributionsByRepository": [
                    { "contributions": { "totalCount": 300 }, "repository": { "primaryLanguage": { "name": "TypeScript" } } },
                    { "contributions": { "totalCount": 100 }, "repository": { "primaryLanguage": { "name": "Rust" } } },
                    { "contributions": { "totalCount": 80 }, "repository": { "primaryLanguage": { "name": "TypeScript" } } },
                    { "contributions": { "totalCount": 30 }, "repository": { "primaryLanguage": { "name": "Swift" } } },
                    { "contributions": { "totalCount": 10 }, "repository": { "primaryLanguage": null } },
                    { "contributions": { "totalCount": 5 }, "repository": { "primaryLanguage": { "name": "Shell" } } },
                    { "contributions": { "totalCount": 3 }, "repository": { "primaryLanguage": { "name": "Kotlin" } } }
                ]
            },
            "repositoriesContributedTo": { "totalCount": 23 }
        });
        let mut revealed = developer_fields(&viewer).unwrap();
        revealed.insert("version".into(), json!(2));
        revealed.insert("proven_at".into(), json!("2026-10-09T00:00:00+00:00"));
        let claim = interpret(&Value::Object(revealed)).unwrap();
        assert_eq!(claim["claim"], "dev.active");
        assert_eq!(claim["data"]["since_year"], 2014);
        assert_eq!(claim["data"]["github_id"], 6667123);
        assert_eq!(claim["data"]["years_active"], 4);
        assert_eq!(claim["data"]["languages"], "TypeScript:72,Rust:19,Swift:6,Other:3");
    }

    #[test]
    fn the_verifier_reads_the_developer_exchange() {
        let request = developer_request("gho_secret");
        let sent = format!("POST /graphql HTTP/1.1\r\nauthorization: \0\0\0\r\n\r\n{}", request.body.unwrap());
        let answer = r#"{"data":{"viewer":{"databaseId":1,"login":"a","createdAt":"2014-01-01T00:00:00Z","contributionsCollection":{"contributionYears":[2014],"contributionCalendar":{"totalContributions":5},"commitContributionsByRepository":[]},"repositoriesContributedTo":{"totalCount":0}}}}"#;
        let fields = read(&sent, &format!("HTTP/1.1 200 OK\r\n\r\n{answer}")).unwrap();
        assert_eq!(fields["login"], "a");
        assert_eq!(fields["version"], 2);
        // Any other query is refused.
        let other = sent.replace("databaseId", "email");
        assert!(read(&other, &format!("HTTP/1.1 200 OK\r\n\r\n{answer}")).is_err());
    }
}
