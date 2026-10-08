import SwiftUI

private let green = Color(red: 0, green: 1, blue: 0.255)
private let dim = Color.white.opacity(0.6)
private let card = Color.white.opacity(0.06)

struct ContentView: View {
    @StateObject private var model = BadgeModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("CHROME DAO · SMART-SSI").font(.caption.monospaced()).foregroundStyle(green)
                stage
                #if DEBUG
                DevelopmentPanel(model: model)
                #endif
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.2), value: stageID)
    }

    @ViewBuilder private var stage: some View {
        switch model.stage {
        case .loading:
            Waiting(title: "Loading", detail: "Looking for your badge…")
        case .home:
            Home(start: model.start, wallet: model.walletAddress)
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
        case .badge(let badge):
            BadgeView(badge: badge, update: model.start, remove: model.removeBadge, wallet: model.walletAddress)
        case .failed(let message):
            Failed(message: message, retry: { Task { await model.refresh() } })
        }
    }

    private var stageID: String { String(describing: model.stage).prefix(12).description }
}

// MARK: Screens

private struct Home: View {
    let start: () -> Void
    let wallet: String

    var body: some View {
        Text("Prove you're a developer.\nShare nothing else.").font(.title.monospaced().bold())
        Text("Get a Chrome DAO developer badge from your GitHub account. Apps and DAO votes can check it without ever seeing your account.")
            .foregroundStyle(dim)

        VStack(alignment: .leading, spacing: 16) {
            StepRow(number: 1, icon: "person.crop.circle.badge.checkmark", title: "Sign in to GitHub",
                    detail: "On GitHub's own page. Your password stays with GitHub.")
            StepRow(number: 2, icon: "iphone", title: "Your phone checks your account",
                    detail: "It keeps everything private except three facts: your username, your number of public repositories, and when your account was created.")
            StepRow(number: 3, icon: "checkmark.seal", title: "You get your badge",
                    detail: "You see exactly what is shared before anything is sent. You can remove the badge at any time.")
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 14))

        PrimaryButton(title: "GET MY DEVELOPER BADGE", action: start)
        Text("Wi-Fi recommended: the proof sends about 25 MB.").font(.caption).foregroundStyle(dim)
        WalletNote(address: wallet)
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

private struct BadgeView: View {
    let badge: Badge
    let update: () -> Void
    let remove: () -> Void
    let wallet: String
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: badge.facts.active ? "checkmark.seal.fill" : "seal")
                    .font(.system(size: 40)).foregroundStyle(badge.facts.active ? green : dim)
                VStack(alignment: .leading, spacing: 2) {
                    Text(badge.facts.active ? "Active developer" : "GitHub account verified").font(.title2.monospaced().bold())
                    Text("@\(badge.facts.login)").font(.callout.monospaced()).foregroundStyle(dim)
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

        Text("Your badge is public on Solana: apps and DAO votes check it directly, without asking Chrome DAO and without seeing your GitHub account.")
            .font(.callout).foregroundStyle(dim)
        if let url = badge.explorer {
            Link(destination: url) { Label("See it on Solana (test network)", systemImage: "arrow.up.right.square") }
                .font(.callout).tint(green)
        }
        PrimaryButton(title: "UPDATE MY BADGE", action: update)
        SecondaryButton(title: "REMOVE MY BADGE") { confirmRemove = true }
            .confirmationDialog("Remove your badge?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: remove)
            } message: {
                Text("Apps will no longer see you as verified. You can get a new badge at any time.")
            }
        WalletNote(address: wallet)
    }
}

private struct Failed: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.yellow)
        Text("That didn't work").font(.title2.monospaced().bold())
        Text(message).foregroundStyle(dim)
        PrimaryButton(title: "BACK", action: retry)
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

private struct StepRow: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(green).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(dim)
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

private struct WalletNote: View {
    let address: String

    var body: some View {
        DisclosureGroup {
            Text("A private key was created on this phone when you opened the app. It signs your requests and never leaves the phone; there is no recovery phrase to keep.")
                .font(.caption).foregroundStyle(dim)
            Text(address).font(.caption2.monospaced()).foregroundStyle(dim).textSelection(.enabled)
        } label: {
            Text("Your private key").font(.caption).foregroundStyle(dim)
        }
        .tint(dim)
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
