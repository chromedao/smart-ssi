import AuthenticationServices
import SwiftUI
import UIKit

@main
struct SmartSSIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// What the user sees about their account before agreeing to share it, and what the badge holds after.
struct Facts {
    var login: String
    var publicRepos: Int
    var accountAgeYears: Int
    var createdAt: Date?
    var active: Bool
    /// Attestation source, e.g. `github:owner`.
    var source = "github:owner"

    /// The website the facts come from, for its name and icon.
    var sourceDomain: String {
        let name = source.split(separator: ":").first.map(String.init) ?? source
        return ["github": "github.com"][name] ?? "\(name).com"
    }
}

struct Badge {
    var facts: Facts
    var verifiedAt: Date?
    var attestation: String
    var explorer: URL? { URL(string: "https://explorer.solana.com/address/\(attestation)?cluster=devnet") }
}

/// The journey, one step at a time: home → GitHub sign-in → proof on the phone → consent → badge.
enum Stage {
    case loading
    case home
    case signingIn(GitHubLogin.DeviceCode?)
    case proving
    case review(GithubProof, Facts)
    case issuing
    case badge(Badge)
    case failed(String)
}

/// The rule the issuer applies (prover `interpret`), shown to users in plain words.
let activeRule = "5 or more public repositories, and an account older than 1 year"

@MainActor
final class BadgeModel: ObservableObject {
    @Published var stage = Stage.loading
    @Published var walletAddress = ""
    @Published var log: [String] = []

    // Development: `-notary host:port` and `-issuer url` at launch override the defaults.
    @Published var notary = UserDefaults.standard.string(forKey: "notary") ?? "wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app"
    @Published var issuerURL = UserDefaults.standard.string(forKey: "issuer") ?? "https://smart-ssi-issuer-ikgz5gajyq-ew.a.run.app"
    // Development: `-login <name>` at launch prefills the public-profile proof.
    @Published var login = UserDefaults.standard.string(forKey: "login") ?? ""

    private var wallet: Wallet?
    private var signIn: Task<Void, Never>?
    private var browser: ASWebAuthenticationSession?
    private let anchor = WindowAnchor()

    init() {
        do {
            let wallet = try Wallet.loadOrCreate()
            self.wallet = wallet
            walletAddress = wallet.address
        } catch {
            note("wallet error: \(error)")
        }
        Task {
            await refresh()
            #if DEBUG
            // Development: `-autoProvePublic YES` runs a public-profile proof at launch (screens without GitHub sign-in).
            if UserDefaults.standard.bool(forKey: "autoProvePublic") { provePublic() }
            // `-previewBadge YES` shows a sample badge (design work; nothing is issued).
            if UserDefaults.standard.bool(forKey: "previewBadge") {
                stage = .badge(Badge(facts: Facts(login: "octocat", publicRepos: 8, accountAgeYears: 15, active: true),
                                     verifiedAt: Date(), attestation: "6wPLWihEgk7ks9RHsbsEB72PrdtxrYp5uXB66oiFrsQu"))
            }
            #endif
        }
    }

    func note(_ line: String) { log.insert(line, at: 0) }

    // MARK: Badge on Solana

    /// Shows the current badge if the wallet has one, the home screen otherwise.
    func refresh() async {
        guard let client else { return stage = .failed("This phone could not create its private key.") }
        do {
            let json = try await client.check()
            note("check: valid=\(json["valid"] ?? "?")")
            if json["valid"] as? Bool == true, let data = json["data"] as? [String: Any], let attestation = json["attestation"] as? String {
                stage = .badge(Badge(facts: Self.facts(fromAttestation: data), verifiedAt: Self.date(data["proven_at"]), attestation: attestation))
            } else {
                stage = .home
            }
        } catch {
            note("check failed: \(error)")
            stage = .home
        }
    }

    func issue(_ proof: GithubProof) {
        guard let client else { return }
        stage = .issuing
        Task {
            do {
                let json = try await client.issue(presentation: proof.presentation)
                note("issued: \(json["attestation"] ?? "?")")
                await refresh()
            } catch {
                note("issue failed: \(error)")
                stage = .failed(Self.explain(error))
            }
        }
    }

    func removeBadge() {
        guard let client else { return }
        stage = .issuing
        Task {
            do {
                _ = try await client.revoke()
                note("revoked")
                stage = .home
            } catch {
                note("revoke failed: \(error)")
                stage = .failed(Self.explain(error))
            }
        }
    }

    private var client: IssuerClient? {
        guard let wallet, let url = URL(string: issuerURL) else { return nil }
        return IssuerClient(baseURL: url, wallet: wallet)
    }

    // MARK: GitHub sign-in and proof

    func start() {
        wakeNotary()
        stage = .signingIn(nil)
        signIn = Task {
            do {
                let login = GitHubLogin()
                let code = try await login.start()
                UIPasteboard.general.string = code.user_code
                stage = .signingIn(code)
                openGitHub(code)
                let token = try await login.token(for: code)
                closeGitHub()
                prove { try proveGithubOwner(token: token, notary: $0) }
            } catch is CancellationError {
                closeGitHub()
                await refresh()
            } catch {
                closeGitHub()
                note("sign-in failed: \(error)")
                stage = .failed(Self.explain(error))
            }
        }
    }

    func cancel() {
        signIn?.cancel()
        if case .review = stage { Task { await refresh() } }
    }

    /// github.com/login/device in the system sign-in window: it shares Safari's GitHub session, and
    /// password managers work there. The device flow has no redirect, so the app closes it once GitHub
    /// hands over the token; if the user closes it first, it can be reopened.
    func openGitHub(_ code: GitHubLogin.DeviceCode) {
        guard let url = URL(string: code.verification_uri) else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "smartssi") { _, _ in }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        browser = session
        session.start()
    }

    private func closeGitHub() {
        browser?.cancel()
        browser = nil
    }

    /// Development: public facts about any account. The issuer refuses these (no ownership).
    func provePublic() {
        let login = login.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty else { return note("enter a GitHub login") }
        prove { try proveGithubPublic(login: login, notary: $0) }
    }

    private func prove(_ run: @escaping @Sendable (String) throws -> GithubProof) {
        let notary = notary
        stage = .proving
        note("proving through \(notary)…")
        Task.detached(priority: .userInitiated) {
            let result = Result { try run(notary) }
            await MainActor.run {
                switch result {
                case .success(let proof):
                    self.note(String(format: "proof done in %.1f s, %d bytes", proof.seconds, proof.presentation.count))
                    self.stage = .review(proof, Self.facts(fromProof: proof))
                case .failure(let error):
                    self.note("proof failed: \(error)")
                    self.stage = .failed(Self.explain(error))
                }
            }
        }
    }

    /// The Cloud Run notary scales to zero. Any request starts an instance, so poke it while the user
    /// signs in to GitHub: it is warm when the proof begins. The answer is ignored.
    private func wakeNotary() {
        guard let url = URL(string: notary.replacingOccurrences(of: "wss://", with: "https://")), url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    // MARK: Reading proofs and attestations

    private static func facts(fromProof proof: GithubProof) -> Facts {
        let claim = json(proof.claimJson), revealed = json(proof.revealedJson)
        let data = claim["data"] as? [String: Any] ?? [:]
        return Facts(
            login: data["login"] as? String ?? "?",
            publicRepos: data["public_repos"] as? Int ?? 0,
            accountAgeYears: data["account_age_years"] as? Int ?? 0,
            createdAt: date(revealed["created_at"]),
            active: claim["claim"] as? String == "dev.active",
            source: data["source"] as? String ?? "github:owner"
        )
    }

    private static func facts(fromAttestation data: [String: Any]) -> Facts {
        Facts(
            login: data["login"] as? String ?? "?",
            publicRepos: data["public_repos"] as? Int ?? 0,
            accountAgeYears: data["account_age_years"] as? Int ?? 0,
            createdAt: nil,
            active: data["claim"] as? String == "dev.active",
            source: data["source"] as? String ?? "github:owner"
        )
    }

    private static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Errors in words a user can act on. The technical detail stays in the debug log.
    static func explain(_ error: Error) -> String {
        if let failure = error as? GitHubLogin.Failure { return failure.localizedDescription }
        if let api = error as? IssuerClient.APIError {
            switch api.status {
            case 409: return "This proof was already used. Start again to make a new one."
            case 422 where api.message.contains("too old"): return "The proof expired before it was sent. Start again."
            case 422 where api.message.contains("ownership"): return "This proof doesn't show that the GitHub account is yours. Sign in to GitHub and try again."
            case 422: return "Chrome DAO could not verify this proof. Start again; if it keeps failing, tell us on Discord."
            default: return "Chrome DAO's server did not answer as expected. Try again in a moment."
            }
        }
        if error is URLError { return "No connection. Check your network and try again." }
        let text = "\(error)"
        if text.contains("notary") || text.contains("connect") { return "Could not reach Chrome DAO's notary. Check your network and try again." }
        if text.contains("GitHub answered") { return "GitHub refused the request. Sign in again." }
        return "Something went wrong while proving. Try again."
    }
}

/// The window the GitHub sign-in sheet is presented from.
final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
