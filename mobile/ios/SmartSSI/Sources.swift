import Foundation

/// A website Smart-SSI can prove facts from. Icons come from the website itself (see SourceIcon).
struct Source: Identifiable {
    enum Status { case available, proposed }

    let id: String
    let name: String
    let domain: String
    /// The badge, in a few words.
    let badge: String
    /// What the proof shares, and nothing else.
    let shares: [String]
    let status: Status
}

/// The catalog. Only GitHub is live; the others are candidates for phase 2 (5 to 10 sources,
/// chromedao/smart-ssi#23): the DAO votes on which come next.
let sources: [Source] = [
    Source(id: "github", name: "GitHub", domain: "github.com", badge: "Developer",
           shares: ["Username", "Number of public repositories", "Account creation date"], status: .available),
    Source(id: "strava", name: "Strava", domain: "strava.com", badge: "Regular athlete",
           shares: ["Activities per month", "Member since"], status: .proposed),
    Source(id: "steam", name: "Steam", domain: "steampowered.com", badge: "Gamer",
           shares: ["Hours played", "Account age"], status: .proposed),
    Source(id: "chess", name: "Chess.com", domain: "chess.com", badge: "Chess player",
           shares: ["Rating range", "Games played"], status: .proposed),
]

/// Where users suggest a source: the idea template of the public repository.
let suggestSourceURL = URL(string: "https://github.com/chromedao/smart-ssi/issues/new?template=idea.yml")!
let whitePaperURL = URL(string: "https://github.com/chromedao/smart-ssi-paper")!
let sourceCodeURL = URL(string: "https://github.com/chromedao/smart-ssi")!
let discordURL = URL(string: "https://discord.gg/7TVqQF4GH")!
