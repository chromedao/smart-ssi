import Foundation

/// A website Smart-SSI can prove facts from. Icons come from the website itself (see SourceIcon).
struct Source: Identifiable {
    enum Status { case available, proposed }

    let id: String
    /// The issuer's badge family for this source (SAS schema name); nil while proposed.
    var family: String? = nil
    let name: String
    let domain: String
    /// The badge, in a few words.
    let badge: String
    /// What the proof shares, and nothing else.
    let shares: [String]
    let status: Status
}

/// The catalog. GitHub and Apple Music are live; the others are candidates for phase 2 (5 to 10 sources,
/// chromedao/smart-ssi#23): the DAO votes on which come next.
let sources: [Source] = [
    Source(id: "github", family: Family.github, name: "GitHub", domain: "github.com", badge: "Developer",
           shares: ["Username", "Coding since", "Contributions over 12 months", "Projects contributed to", "Languages of your public work"], status: .available),
    Source(id: "apple_music", family: Family.appleMusic, name: "Apple Music", domain: "music.apple.com", badge: "Listener",
           shares: ["Top 3 artists", "Genres you play most", "Number of tracks counted"], status: .available),
    Source(id: "discord", name: "Discord", domain: "discord.com", badge: "CHROMES DAO member",
           shares: ["Member of the CHROMES DAO server", "Joined on", "Roles"], status: .proposed),
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
