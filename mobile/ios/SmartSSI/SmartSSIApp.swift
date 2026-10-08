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
    var publicRepos: Int = 0
    var accountAgeYears: Int
    var createdAt: Date?
    var active: Bool
    /// Developer badge (v2): since when, how much lately, where, in which languages (by the user's own commits).
    var version = 1
    var sinceYear = 0
    var yearsActive = 0
    var contributions12m = 0
    var reposContributed = 0
    var languages: [(name: String, percent: Int)] = []
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

/// A verification, one step at a time: GitHub sign-in → proof on the phone → consent → recorded.
enum Flow {
    case signingIn(GitHubLogin.DeviceCode?)
    case proving
    case review(GithubProof, Facts)
    case issuing
    case done
    case failed(String)
}

enum Tab: Hashable { case badges, sources, me }

/// The rule the issuer applies (prover `interpret`, DEVELOPER_RULE), shown to users in plain words.
let activeRule = "100+ contributions in the last 12 months, or contributions to 3+ projects, on an account older than a year"

@MainActor
final class BadgeModel: ObservableObject {
    /// The wallet's badge on Solana; `loaded` turns true after the first check.
    @Published var badge: Badge?
    @Published var loaded = false
    @Published var removing = false
    /// The verification in progress, shown full screen; nil when none.
    @Published var flow: Flow?
    @Published var tab = Tab.badges
    @Published var walletAddress = ""
    @Published var log: [String] = []

    // Development: `-notary host:port` and `-issuer url` at launch override the defaults.
    @Published var notary = UserDefaults.standard.string(forKey: "notary") ?? "wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app"
    @Published var issuerURL = UserDefaults.standard.string(forKey: "issuer") ?? "https://smart-ssi-issuer-ikgz5gajyq-ew.a.run.app"
    // Development: `-verifyURL http://<mac>:4242/verify` points QR codes at a local copy of the site.
    let verifyURL = UserDefaults.standard.string(forKey: "verifyURL") ?? "https://www.chromedao.xyz/verify"
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
                var sample = Facts(login: "octocat", accountAgeYears: 15, active: true)
                (sample.version, sample.sinceYear, sample.yearsActive, sample.contributions12m, sample.reposContributed) = (2, 2014, 9, 640, 23)
                sample.languages = [("TypeScript", 62), ("Rust", 21), ("Swift", 9), ("Other", 8)]
                badge = (Badge(facts: sample,
                                     verifiedAt: Date(), attestation: "6wPLWihEgk7ks9RHsbsEB72PrdtxrYp5uXB66oiFrsQu"))
            }
            #endif
        }
    }

    func note(_ line: String) { log.insert(line, at: 0) }

    // MARK: Badge on Solana

    /// Reads the wallet's badge from Solana (through the issuer API's public check).
    func refresh() async {
        guard let client else { loaded = true; return note("no wallet") }
        do {
            let json = try await client.check()
            note("check: valid=\(json["valid"] ?? "?")")
            if json["valid"] as? Bool == true, let data = json["data"] as? [String: Any], let attestation = json["attestation"] as? String {
                badge = Badge(facts: Self.facts(fromAttestation: data), verifiedAt: Self.date(data["proven_at"]), attestation: attestation)
            } else {
                badge = nil
            }
        } catch {
            note("check failed: \(error)")
        }
        loaded = true
    }

    func issue(_ proof: GithubProof) {
        guard let client else { return }
        flow = .issuing
        Task {
            do {
                let json = try await client.issue(presentation: proof.presentation)
                note("issued: \(json["attestation"] ?? "?")")
                await refresh()
                flow = .done
            } catch {
                note("issue failed: \(error)")
                flow = .failed(Self.explain(error))
            }
        }
    }

    /// Closes the verification screen; after a new badge, shows it.
    func finish() {
        if case .done = flow { tab = .badges }
        flow = nil
    }

    func removeBadge() {
        guard let client else { return }
        removing = true
        Task {
            defer { removing = false }
            do {
                _ = try await client.revoke()
                note("revoked")
                badge = nil
            } catch {
                note("revoke failed: \(error)")
            }
        }
    }

    /// The link a QR code carries: the wallet signs `smart-ssi:show:<wallet>:<unix time>`, so the page knows the
    /// person showing it holds the badge right now. Everything is in the fragment, which browsers never send to a
    /// server. The page refuses codes older than 2 minutes; the app renews them every 30 seconds.
    func showLink() -> URL? {
        guard let wallet else { return nil }
        let time = Int(Date().timeIntervalSince1970)
        guard let signature = try? wallet.sign("smart-ssi:show:\(wallet.address):\(time)") else { return nil }
        let base64url = signature.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "\(verifyURL)#w=\(wallet.address)&t=\(time)&s=\(base64url)")
    }

    private var client: IssuerClient? {
        guard let wallet, let url = URL(string: issuerURL) else { return nil }
        return IssuerClient(baseURL: url, wallet: wallet)
    }

    // MARK: GitHub sign-in and proof

    func start() {
        wakeNotary()
        flow = .signingIn(nil)
        signIn = Task {
            do {
                let login = GitHubLogin()
                let code = try await login.start()
                UIPasteboard.general.string = code.user_code
                flow = .signingIn(code)
                openGitHub(code)
                let token = try await login.token(for: code)
                closeGitHub()
                prove { try proveGithubOwner(token: token, notary: $0) }
            } catch is CancellationError {
                closeGitHub()
                flow = nil
            } catch {
                closeGitHub()
                note("sign-in failed: \(error)")
                flow = .failed(Self.explain(error))
            }
        }
    }

    func cancel() {
        signIn?.cancel()
        flow = nil
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
        flow = .proving
        note("proving through \(notary)…")
        Task.detached(priority: .userInitiated) {
            let result = Result { try run(notary) }
            await MainActor.run {
                switch result {
                case .success(let proof):
                    self.note(String(format: "proof done in %.1f s, %d bytes", proof.seconds, proof.presentation.count))
                    // Cancelled while proving: drop the proof.
                    guard self.flow != nil else { return }
                    self.flow = .review(proof, Self.facts(fromProof: proof))
                case .failure(let error):
                    self.note("proof failed: \(error)")
                    if self.flow != nil { self.flow = .failed(Self.explain(error)) }
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
        var facts = facts(from: claim["data"] as? [String: Any] ?? [:], claim: claim["claim"] as? String)
        facts.createdAt = date(revealed["created_at"])
        return facts
    }

    private static func facts(fromAttestation data: [String: Any]) -> Facts {
        facts(from: data, claim: data["claim"] as? String)
    }

    /// Reads v1 (public_repos) and v2 (since_year, languages…) badge data alike.
    private static func facts(from data: [String: Any], claim: String?) -> Facts {
        let number = { (key: String) in (data[key] as? NSNumber)?.intValue ?? 0 }
        var facts = Facts(
            login: data["login"] as? String ?? "?",
            publicRepos: number("public_repos"),
            accountAgeYears: number("account_age_years"),
            active: claim == "dev.active"
        )
        facts.source = data["source"] as? String ?? "github:owner"
        if data["since_year"] != nil {
            facts.version = 2
            facts.sinceYear = number("since_year")
            facts.yearsActive = number("years_active")
            facts.contributions12m = number("contributions_12m")
            facts.reposContributed = number("repos_contributed")
            facts.languages = (data["languages"] as? String ?? "").split(separator: ",").compactMap { entry in
                let parts = entry.split(separator: ":")
                guard parts.count == 2, let percent = Int(parts[1]) else { return nil }
                return (String(parts[0]), percent)
            }
        }
        return facts
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
