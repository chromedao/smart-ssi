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

    var body: some View {
        Page(title: "Badges") {
            if !model.loaded {
                Waiting(title: "", detail: "Looking for your badges on Solana…")
            } else if let badge = model.badge {
                BadgeCard(badge: badge)
                BadgeActions(badge: badge, model: model)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "checkmark.seal").font(.system(size: 44)).foregroundStyle(dim)
                    Text("No badge yet").font(.title2.monospaced().bold())
                    Text("A badge proves something about you (that you're a developer, an athlete…) without sharing the account behind it. Apps and DAO votes check it directly.")
                        .foregroundStyle(dim)
                    PrimaryButton(title: "GET MY FIRST BADGE") { model.tab = .sources }
                }
                .padding(.top, 8)
            }
            #if DEBUG
            DevelopmentPanel(model: model)
            #endif
        }
        .refreshable { await model.refresh() }
    }
}

private struct BadgeCard: View {
    let badge: Badge

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SourceIcon(domain: badge.facts.sourceDomain, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: badge.facts.active ? "checkmark.seal.fill" : "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(badge.facts.active ? green : dim)
                            .background(Circle().fill(Color.black).padding(2))
                            .offset(x: 6, y: 6)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(badge.facts.active ? "Active developer" : "GitHub account verified").font(.title3.monospaced().bold())
                    Text("@\(badge.facts.login) · GitHub").font(.callout.monospaced()).foregroundStyle(dim)
                }
            }
            if !badge.facts.active {
                Text("Not an active developer yet: that takes \(activeRule). Update your badge once you get there.")
                    .font(.callout).foregroundStyle(dim)
            }
            VStack(spacing: 0) {
                FactRow(label: "Public repositories", value: "\(badge.facts.publicRepos)")
                FactRow(label: "Account age", value: badge.facts.accountAgeYears == 1 ? "1 year" : "\(badge.facts.accountAgeYears) years")
                if let date = badge.verifiedAt { FactRow(label: "Verified", value: date.formatted(date: .abbreviated, time: .omitted)) }
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(badge.facts.active ? green.opacity(0.6) : .clear, lineWidth: 1))
    }
}

private struct BadgeActions: View {
    let badge: Badge
    @ObservedObject var model: BadgeModel
    @State private var confirmRemove = false

    var body: some View {
        Text("Public on Solana: apps and DAO votes check it directly, without asking Chrome DAO and without seeing your GitHub account.")
            .font(.callout).foregroundStyle(dim)
        if let url = badge.explorer {
            Link(destination: url) { Label("See it on Solana (test network)", systemImage: "arrow.up.right.square") }
                .font(.callout).tint(green)
        }
        PrimaryButton(title: "UPDATE", action: model.start)
        SecondaryButton(title: model.removing ? "REMOVING…" : "REMOVE") { confirmRemove = true }
            .disabled(model.removing)
            .confirmationDialog("Remove your badge?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: model.removeBadge)
            } message: {
                Text("Apps will no longer see you as verified. You can get a new badge at any time.")
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
                SourceRow(source: source, verified: model.badge != nil, action: model.start)
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
                      text: "Created on this phone when you first opened the app. It signs your requests and never leaves the phone; there is no recovery phrase to keep. Your badges are tied to it.")
            Text(model.walletAddress).font(.caption2.monospaced()).foregroundStyle(dim).textSelection(.enabled)
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
                detail: "Your phone reads your profile straight from GitHub. Chrome DAO's notary co-signs the exchange without seeing it. About 10 seconds; on mobile data it sends around 25 MB."
            )
        case .review(let proof, let facts):
            Review(facts: facts, issue: { model.issue(proof) }, cancel: model.cancel)
        case .issuing:
            Steps(current: 3)
            Waiting(title: "Recording your badge", detail: "Writing it on Solana, where anyone can check it.")
        case .done:
            Done(badge: model.badge, close: model.finish)
        case .failed(let message):
            Failed(message: message, retry: model.cancel)
        case .none:
            EmptyView()
        }
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
            FactRow(label: "Public repositories", value: "\(facts.publicRepos)")
            FactRow(label: "Account created", value: facts.createdAt.map { $0.formatted(.dateTime.month(.wide).year()) } ?? "\(facts.accountAgeYears) years ago")
        }
        .background(card, in: RoundedRectangle(cornerRadius: 14))
        Text("Nothing else: no email, no private repositories, no GitHub token. Your badge is tied to a private key that only this phone holds.")
            .font(.callout).foregroundStyle(dim)
        Eligibility(active: facts.active, repos: facts.publicRepos, years: facts.accountAgeYears)
        PrimaryButton(title: "SHARE AND GET MY BADGE", action: issue)
        SecondaryButton(title: "DON'T SHARE", action: cancel)
    }
}

private struct Failed: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.yellow)
        Text("That didn't work").font(.title2.monospaced().bold())
        Text(message).foregroundStyle(dim)
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
                 : "You'll get a verified GitHub badge, but not the **active developer** status yet: it takes \(activeRule).")
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
