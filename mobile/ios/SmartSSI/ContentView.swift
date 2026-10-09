import SwiftUI

private let green = Color(red: 0, green: 1, blue: 0.255)
private let dim = Color.white.opacity(0.6)
private let card = Color.white.opacity(0.06)

struct ContentView: View {
    @StateObject private var model = BadgeModel()

    var body: some View {
        TabView(selection: $model.tab) {
            BadgesTab(model: model)
                .tabItem { Label("Badges", systemImage: "checkmark.seal") }
                .tag(Tab.badges)
            SourcesTab(model: model)
                .tabItem { Label("Sources", systemImage: "square.grid.2x2") }
                .tag(Tab.sources)
            MeTab(model: model)
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
                .tag(Tab.me)
        }
        .tint(green)
        .fullScreenCover(isPresented: Binding(get: { model.flow != nil }, set: { if !$0 { model.cancel() } })) {
            VerifyFlow(model: model)
        }
    }
}

/// Black page with the Chrome DAO header, shared by the tabs.
private struct Page<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("CHROME DAO · SMART-SSI").font(.caption.monospaced()).foregroundStyle(green)
                Text(title).font(.largeTitle.monospaced().bold())
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }
}

// MARK: Badges

private struct BadgesTab: View {
    @ObservedObject var model: BadgeModel
    @State private var showing: Badge?

    var body: some View {
        Page(title: "Badges") {
            if !model.loaded {
                Waiting(title: "", detail: "Looking for your badges on Solana…")
            } else if model.badges.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(dim)
                    Text("No badge yet").font(.title2.monospaced().bold())
                    Text("A badge proves something about you (that you're a developer, what you listen to…) without sharing the account behind it. Apps and DAO votes check it directly.")
                        .foregroundStyle(dim)
                    PrimaryButton(title: "GET MY FIRST BADGE") { model.tab = .sources }
                }
                .padding(.top, 8)
            } else {
                ForEach(model.badges) { badge in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { showing = badge } label: { BadgeCard(badge: badge) }.buttonStyle(.plain)
                        PrimaryButton(title: "SHOW TO SOMEONE") { showing = badge }
                        BadgeActions(badge: badge, model: model)
                    }
                    .padding(.bottom, 14)
                }
                Text("Public on Solana: apps and DAO votes check your badges directly, without asking Chrome DAO and without seeing your accounts.")
                    .font(.callout).foregroundStyle(dim)
                SecondaryButton(title: "ADD A BADGE") { model.tab = .sources }
            }
            #if DEBUG
            DevelopmentPanel(model: model)
            #endif
        }
        .refreshable { await model.refresh() }
        .fullScreenCover(item: $showing) { badge in
            ShowBadge(badge: badge, link: { model.showLink(badge.family) }, close: { showing = nil })
        }
    }
}

private struct BadgeCard: View {
    let badge: Badge

    var body: some View {
        switch badge.kind {
        case .developer(let facts): DeveloperCard(facts: facts, verifiedAt: badge.verifiedAt)
        case .listener(let listening): ListenerCard(listening: listening, verifiedAt: badge.verifiedAt)
        }
    }
}

/// Card frame shared by every badge: source icon with a seal, title, subtitle, then the badge's own content.
private struct CardFrame<Content: View>: View {
    let domain: String
    let title: String
    let subtitle: String
    var highlighted = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SourceIcon(domain: domain, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: highlighted ? "checkmark.seal.fill" : "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(highlighted ? green : dim)
                            .background(Circle().fill(Color.black).padding(2))
                            .offset(x: 6, y: 6)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.monospaced().bold())
                    Text(subtitle).font(.callout.monospaced()).foregroundStyle(dim)
                }
            }
            content
        }
        .padding(18)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(highlighted ? green.opacity(0.6) : .clear, lineWidth: 1))
    }
}

private struct DeveloperCard: View {
    let facts: Facts
    let verifiedAt: Date?

    var body: some View {
        CardFrame(domain: facts.sourceDomain, title: facts.title, subtitle: "@\(facts.login) · GitHub", highlighted: facts.active) {
            if facts.version == 2 {
                if !facts.languages.isEmpty { LanguageBar(languages: facts.languages) }
                VStack(spacing: 0) {
                    FactRow(label: "Coding since", value: "\(facts.sinceYear)")
                    FactRow(label: "Contributions, 12 months", value: facts.contributions12m.formatted())
                    FactRow(label: "Projects contributed to", value: "\(facts.reposContributed)")
                    if let verifiedAt { FactRow(label: "Verified", value: verifiedAt.formatted(date: .abbreviated, time: .omitted)) }
                }
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            } else {
                if !facts.active {
                    Text("Update your badge: the new GitHub badge counts your contributions to every project, your languages and since when you code.")
                        .font(.callout).foregroundStyle(dim)
                }
                VStack(spacing: 0) {
                    FactRow(label: "Public repositories", value: "\(facts.publicRepos)")
                    FactRow(label: "Account age", value: facts.accountAgeYears == 1 ? "1 year" : "\(facts.accountAgeYears) years")
                    if let verifiedAt { FactRow(label: "Verified", value: verifiedAt.formatted(date: .abbreviated, time: .omitted)) }
                }
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct ListenerCard: View {
    let listening: Listening
    let verifiedAt: Date?

    var body: some View {
        CardFrame(domain: "music.apple.com", title: "Listener", subtitle: listening.topArtists.prefix(3).joined(separator: " · ")) {
            if !listening.genres.isEmpty { ShareBar(title: "WHAT YOU PLAY", shares: listening.genres, color: genreColor(listening.genres)) }
            VStack(spacing: 0) {
                FactRow(label: "Tracks counted", value: "\(listening.tracks)")
                if let verifiedAt { FactRow(label: "Verified", value: verifiedAt.formatted(date: .abbreviated, time: .omitted)) }
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct BadgeActions: View {
    let badge: Badge
    @ObservedObject var model: BadgeModel
    @State private var confirmRemove = false

    var body: some View {
        HStack {
            SecondaryButton(title: "UPDATE") { model.start(sources.first { $0.family == badge.family }?.id ?? "github") }
            SecondaryButton(title: model.removing ? "…" : "REMOVE") { confirmRemove = true }
                .disabled(model.removing)
                .confirmationDialog("Remove this badge?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { model.removeBadge(badge.family) }
                } message: {
                    Text("Apps will no longer see it. You can get it again at any time.")
                }
        }
        if let url = badge.explorer {
            Link(destination: url) { Label("See it on Solana (test network)", systemImage: "arrow.up.right.square") }
                .font(.caption).tint(green)
        }
    }
}

// MARK: Sources

private struct SourcesTab: View {
    @ObservedObject var model: BadgeModel

    var body: some View {
        Page(title: "Sources") {
            Text("Prove something from an account you already have. Your phone checks it; only the facts listed are shared, after you agree.")
                .foregroundStyle(dim)
            ForEach(sources.filter { $0.status == .available }) { source in
                SourceRow(source: source, verified: source.family.flatMap(model.badge) != nil, action: { model.start(source.id) })
            }
            Text("COMING NEXT").font(.caption.monospaced()).foregroundStyle(green).padding(.top, 8)
            Text("Candidates for the next sources. Chrome holders vote on which come first.").font(.callout).foregroundStyle(dim)
            ForEach(sources.filter { $0.status == .proposed }) { source in
                SourceRow(source: source, verified: false, action: nil)
            }
            Link(destination: suggestSourceURL) { Label("Suggest a source", systemImage: "plus.bubble") }
                .font(.callout).tint(green).padding(.top, 4)
        }
    }
}

private struct SourceRow: View {
    let source: Source
    let verified: Bool
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SourceIcon(domain: source.domain, size: 44)
                    .opacity(action == nil ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.headline)
                    Text(source.badge).font(.subheadline.monospaced()).foregroundStyle(action == nil ? dim : green)
                }
                Spacer()
                if action == nil {
                    Text("SOON").font(.caption2.monospaced()).foregroundStyle(dim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().stroke(dim.opacity(0.5)))
                } else if verified {
                    Label("Verified", systemImage: "checkmark.seal.fill").font(.caption.monospaced()).foregroundStyle(green)
                }
            }
            Text("Shares: " + source.shares.joined(separator: ", ").lowercased() + ".")
                .font(.caption).foregroundStyle(dim)
            if let action {
                PrimaryButton(title: verified ? "UPDATE MY BADGE" : "VERIFY WITH \(source.name.uppercased())", action: action)
            }
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: Me

private struct MeTab: View {
    @ObservedObject var model: BadgeModel

    var body: some View {
        Page(title: "Me") {
            InfoBlock(icon: "key", title: "Your private key",
                      text: "Created on this phone when you first opened the app; it signs your requests. It is kept in your iCloud Keychain, end-to-end encrypted: a new iPhone on the same Apple account gets it back. No recovery phrase to keep.")
            Text(model.walletAddress).font(.caption2.monospaced()).foregroundStyle(dim).textSelection(.enabled)
            InfoBlock(icon: "arrow.triangle.2.circlepath", title: "Lost your phone?",
                      text: "Install Smart-SSI on the new one and sign in to GitHub again: your badge moves to the new phone and the old one stops working. One GitHub account, one badge.")
            InfoBlock(icon: "eye.slash", title: "What Chrome DAO sees",
                      text: "Only the facts you agree to share on the last screen of a verification. Never your passwords, tokens, email or private data: your phone proves the facts itself, with a notary that co-signs without seeing the content.")
            InfoBlock(icon: "testtube.2", title: "Test version",
                      text: "Badges are recorded on Solana's test network while Smart-SSI is in its pilot. They will move to the main network before the public release.")
            VStack(alignment: .leading, spacing: 12) {
                Link(destination: whitePaperURL) { Label("White paper", systemImage: "doc.text") }
                Link(destination: sourceCodeURL) { Label("Open source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: discordURL) { Label("CHROMES DAO Discord", systemImage: "bubble.left.and.bubble.right") }
            }
            .font(.callout).tint(green)
            Text("Smart-SSI \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                .font(.caption2.monospaced()).foregroundStyle(dim)
        }
    }
}

private struct InfoBlock: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(green).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(dim)
            }
        }
    }
}

// MARK: Verification (full screen)

private struct VerifyFlow: View {
    @ObservedObject var model: BadgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("CHROME DAO · SMART-SSI").font(.caption.monospaced()).foregroundStyle(green)
                    Spacer()
                    if case .done = model.flow {} else {
                        Button { model.cancel() } label: { Image(systemName: "xmark").foregroundStyle(dim) }
                    }
                }
                step
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var step: some View {
        switch model.flow {
        case .signingIn(let code):
            SigningIn(code: code, open: { code.map(model.openGitHub) }, cancel: model.cancel)
        case .proving:
            Steps(current: 2)
            Waiting(
                title: "Checking your account",
                detail: "Your phone reads your account straight from the source. Chrome DAO's notary co-signs the exchange without seeing it. About 10 seconds; on mobile data it sends around 25 MB."
            )
        case .review(let proof, .developer(let facts)):
            Review(facts: facts, issue: { model.issue(proof) }, cancel: model.cancel)
        case .review(let proof, .listener(let listening)):
            ListenerReview(listening: listening, issue: { model.issue(proof) }, cancel: model.cancel)
        case .issuing:
            Steps(current: 3)
            Waiting(title: "Recording your badge", detail: "Writing it on Solana, where anyone can check it.")
        case .done:
            Done(badge: model.justIssued.flatMap(model.badge), close: model.finish)
        case .failed(let message, let detail):
            Failed(message: message, detail: detail, retry: model.cancel)
        case .none:
            EmptyView()
        }
    }
}

private struct ListenerReview: View {
    let listening: Listening
    let issue: () -> Void
    let cancel: () -> Void

    var body: some View {
        Steps(current: 3)
        Text("Here's everything Chrome DAO will receive").font(.title2.monospaced().bold())
        HStack(spacing: 10) {
            SourceIcon(domain: "music.apple.com", size: 28)
            Text("Proven from **Apple Music**").font(.callout).foregroundStyle(dim)
        }
        VStack(spacing: 0) {
            FactRow(label: "Top artists", value: listening.topArtists.prefix(3).joined(separator: ", "))
            FactRow(label: "Tracks counted", value: "\(listening.tracks)")
        }
        .background(card, in: RoundedRectangle(cornerRadius: 14))
        if !listening.genres.isEmpty {
            ShareBar(title: "WHAT YOU PLAY", shares: listening.genres, color: genreColor(listening.genres))
                .padding(14)
                .background(card, in: RoundedRectangle(cornerRadius: 14))
        }
        Text("Nothing else: not the songs, albums or playlists, not when you listened. Only each recent track's artist and genre are read, from your last 30 plays.")
            .font(.callout).foregroundStyle(dim)
        PrimaryButton(title: "SHARE AND GET MY BADGE", action: issue)
        SecondaryButton(title: "DON'T SHARE", action: cancel)
    }
}

private struct Done: View {
    let badge: Badge?
    let close: () -> Void

    var body: some View {
        Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(green)
        Text("Your badge is ready").font(.title.monospaced().bold())
        if let badge { BadgeCard(badge: badge) }
        PrimaryButton(title: "SEE MY BADGES", action: close)
    }
}

private struct SigningIn: View {
    let code: GitHubLogin.DeviceCode?
    let open: () -> Void
    let cancel: () -> Void

    var body: some View {
        Steps(current: 1)
        Text("Sign in to GitHub").font(.title2.monospaced().bold())
        if let code {
            Text("On GitHub, paste this code (it's already copied), then tap **Authorize Smart-SSI**.")
                .foregroundStyle(dim)
            Text(code.user_code)
                .font(.largeTitle.monospaced().bold()).foregroundStyle(green)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(card, in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            Text("Smart-SSI only asks for read access to your public profile. It cannot see private repositories or change anything.")
                .font(.caption).foregroundStyle(dim)
            PrimaryButton(title: "OPEN GITHUB", action: open)
        } else {
            Waiting(title: "", detail: "Asking GitHub for a sign-in code…")
        }
        SecondaryButton(title: "CANCEL", action: cancel)
    }
}

private struct Review: View {
    let facts: Facts
    let issue: () -> Void
    let cancel: () -> Void

    var body: some View {
        Steps(current: 3)
        Text("Here's everything Chrome DAO will receive").font(.title2.monospaced().bold())
        HStack(spacing: 10) {
            SourceIcon(domain: facts.sourceDomain, size: 28)
            Text("Proven from **\(facts.sourceDomain)**").font(.callout).foregroundStyle(dim)
        }
        VStack(spacing: 0) {
            FactRow(label: "GitHub username", value: facts.login)
            if facts.version == 2 {
                FactRow(label: "Coding since", value: "\(facts.sinceYear)")
                FactRow(label: "Contributions, 12 months", value: facts.contributions12m.formatted())
                FactRow(label: "Projects contributed to", value: "\(facts.reposContributed)")
            } else {
                FactRow(label: "Public repositories", value: "\(facts.publicRepos)")
                FactRow(label: "Account created", value: facts.createdAt.map { $0.formatted(.dateTime.month(.wide).year()) } ?? "\(facts.accountAgeYears) years ago")
            }
        }
        .background(card, in: RoundedRectangle(cornerRadius: 14))
        if facts.version == 2, !facts.languages.isEmpty {
            LanguageBar(languages: facts.languages)
                .padding(14)
                .background(card, in: RoundedRectangle(cornerRadius: 14))
        }
        Text(facts.version == 2
             ? "Nothing else: no repository names, no code, no email, no GitHub token. Languages are counted from your own commits to public projects over the last 12 months; private work counts in your contributions, never by name or language. Your badge is tied to a private key that only this phone holds."
             : "Nothing else: no email, no private repositories, no GitHub token. Your badge is tied to a private key that only this phone holds.")
            .font(.callout).foregroundStyle(dim)
        Eligibility(active: facts.active, repos: facts.publicRepos, years: facts.accountAgeYears)
        PrimaryButton(title: "SHARE AND GET MY BADGE", action: issue)
        SecondaryButton(title: "DON'T SHARE", action: cancel)
    }
}

private struct Failed: View {
    let message: String
    var detail = ""
    let retry: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.yellow)
        Text("That didn't work").font(.title2.monospaced().bold())
        Text(message).foregroundStyle(dim)
        if !detail.isEmpty {
            DisclosureGroup("Details") {
                Text(detail).font(.caption2.monospaced()).foregroundStyle(dim).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).tint(dim)
        }
        PrimaryButton(title: "CLOSE", action: retry)
    }
}

// MARK: Pieces

private struct Steps: View {
    let current: Int
    private let names = ["Sign in", "Check", "Share"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { step in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(step <= current ? green : Color.white.opacity(0.15)).frame(height: 3)
                    Text(names[step - 1]).font(.caption2.monospaced()).foregroundStyle(step == current ? green : dim)
                }
            }
        }
    }
}

/// The source website's own icon (`/apple-touch-icon.png`, then `/favicon.ico`), fetched from that website
/// only: no third-party favicon service learns which sources the user has badges from.
private struct SourceIcon: View {
    let domain: String
    let size: CGFloat
    @State private var useFavicon = false

    var body: some View {
        AsyncImage(url: URL(string: "https://\(domain)/\(useFavicon ? "favicon.ico" : "apple-touch-icon.png")")) { phase in
            switch phase {
            case .success(let image): image.resizable().interpolation(.high).scaledToFit()
            case .failure: Color.clear.onAppear { if !useFavicon { useFavicon = true } }
            default: Color.white.opacity(0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

extension Facts {
    var title: String {
        if version == 2 { return active ? "Active developer" : "Developer" }
        return active ? "Active developer" : "GitHub account verified"
    }
}

/// GitHub's own language colors (linguist), as on profiles; the same table as the /verify page.
func languageColor(_ name: String) -> Color {
    let hex: [String: UInt32] = [
        "TypeScript": 0x3178c6, "JavaScript": 0xf1e05a, "Rust": 0xdea584, "Swift": 0xf05138, "Python": 0x3572a5, "Go": 0x00add8,
        "Kotlin": 0xa97bff, "Java": 0xb07219, "C++": 0xf34b7d, "C": 0x555555, "C#": 0x178600, "Ruby": 0x701516, "PHP": 0x4f5d95,
        "Shell": 0x89e051, "Dart": 0x00b4ab, "HTML": 0xe34c26, "CSS": 0x663399, "Solidity": 0xaa6746, "Vue": 0x41b883,
        "Elixir": 0x6e4a7e, "Haskell": 0x5e5086, "Scala": 0xc22d40, "Objective-C": 0x438eff, "Lua": 0x000080, "Zig": 0xec915c,
    ]
    let value = hex[name] ?? 0x8b8b8b
    return Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
}

/// What the user codes, by their own commits.
struct LanguageBar: View {
    let languages: [(name: String, percent: Int)]
    var body: some View { ShareBar(title: "WHAT YOU CODE · PUBLIC PROJECTS", shares: languages, color: languageColor) }
}

/// Genre colors by rank (largest first), so two genres never share a color; Other stays gray.
private let rankPalette: [Color] = [green, Color(red: 0.2, green: 0.6, blue: 1), Color(red: 1, green: 0.4, blue: 0.6), Color(red: 1, green: 0.75, blue: 0.2)]
func genreColor(_ shares: [(name: String, percent: Int)]) -> (String) -> Color {
    { name in
        guard name != "Other", let rank = shares.firstIndex(where: { $0.name == name }) else { return .gray }
        return rankPalette[rank % rankPalette.count]
    }
}

/// One stacked bar, then each entry with its share.
struct ShareBar: View {
    let title: String
    let shares: [(name: String, percent: Int)]
    let color: (String) -> Color

    var body: some View {
        let languages = shares
        let languageColor = color
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption2.monospaced()).foregroundStyle(dim)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(languages, id: \.name) { language in
                        Rectangle().fill(languageColor(language.name))
                            .frame(width: max(2, geometry.size.width * CGFloat(language.percent) / 100 - 2))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            ForEach(languages, id: \.name) { language in
                HStack(spacing: 10) {
                    Circle().fill(languageColor(language.name)).frame(width: 9, height: 9)
                    Text(language.name).font(.subheadline)
                    Spacer()
                    Text("\(language.percent)%").font(.subheadline.monospaced()).foregroundStyle(dim)
                }
            }
        }
    }
}

private struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(dim)
            Spacer()
            Text(value).font(.body.monospaced().bold())
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

private struct Eligibility: View {
    let active: Bool
    let repos: Int
    let years: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: active ? "checkmark.seal.fill" : "info.circle").foregroundStyle(active ? green : dim)
            Text(active
                 ? "You qualify as an **active developer** (\(activeRule))."
                 : "You'll get a developer badge, but not the **active** status yet: it takes \(activeRule).")
                .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Waiting: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().tint(green)
                if !title.isEmpty { Text(title).font(.title3.monospaced().bold()) }
            }
            Text(detail).foregroundStyle(dim)
        }
        .padding(.vertical, 8)
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.monospaced().bold()).frame(maxWidth: .infinity).padding(.vertical, 16)
        }
        .background(green, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.black)
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.monospaced()).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .foregroundStyle(.white)
    }
}

#if DEBUG
/// Xcode builds only: local servers, public-profile proofs, the log.
private struct DevelopmentPanel: View {
    @ObservedObject var model: BadgeModel

    var body: some View {
        DisclosureGroup("Development") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("public GitHub login", text: $model.login)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                SecondaryButton(title: "PROVE PUBLIC PROFILE (NO OWNERSHIP)", action: model.provePublic)
                TextField("notary", text: $model.notary).textFieldStyle(.roundedBorder)
                TextField("issuer URL", text: $model.issuerURL).textFieldStyle(.roundedBorder)
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(dim)
                }
            }
        }
        .font(.caption.monospaced())
        .padding(.top, 24)
    }
}
#endif
