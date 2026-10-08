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

private let green = Color(red: 0, green: 1, blue: 0.255)

@MainActor
final class ProofModel: ObservableObject {
    // Development: `-login <name>` at launch prefills the field (simctl launch … -login jeemclr).
    @Published var login = UserDefaults.standard.string(forKey: "login") ?? ""
    // Development: `-notary host:port` and `-issuer url` at launch override the defaults.
    @Published var notary = UserDefaults.standard.string(forKey: "notary") ?? "wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app"
    @Published var issuerURL = UserDefaults.standard.string(forKey: "issuer") ?? "https://smart-ssi-issuer-ikgz5gajyq-ew.a.run.app"
    @Published var walletAddress = ""
    @Published var deviceCode: GitHubLogin.DeviceCode?
    private var signIn: Task<Void, Never>?
    private var browser: ASWebAuthenticationSession?
    private let anchor = WindowAnchor()
    @Published var busy = false
    @Published var proof: GithubProof?
    @Published var log: [String] = []

    private var wallet: Wallet?

    init() {
        do {
            let wallet = try Wallet.loadOrCreate()
            self.wallet = wallet
            walletAddress = wallet.address
        } catch {
            note("wallet error: \(error.localizedDescription)")
        }
    }

    func note(_ line: String) { log.insert(line, at: 0) }

    /// Sign in to GitHub, then prove the signed-in account: this proves the user owns it.
    func proveMine() {
        busy = true
        proof = nil
        wakeNotary()
        signIn = Task {
            do {
                let login = GitHubLogin()
                let code = try await login.start()
                UIPasteboard.general.string = code.user_code
                deviceCode = code
                note("GitHub code \(code.user_code) (copied)")
                openGitHub()
                let token = try await login.token(for: code)
                closeGitHub()
                run("proving your GitHub account through \(notary)…") { try proveGithubOwner(token: token, notary: $0) }
            } catch {
                closeGitHub()
                busy = false
                note(error is CancellationError ? "sign-in cancelled" : "sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    /// github.com/login/device in the system sign-in window: it shares Safari's GitHub session, and
    /// password managers work there. The device flow has no redirect, so the app closes it once GitHub
    /// hands over the token; if the user closes it first, it can be reopened.
    func openGitHub() {
        guard let code = deviceCode, let url = URL(string: code.verification_uri) else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "smartssi") { _, _ in }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        browser = session
        session.start()
    }

    /// The Cloud Run notary scales to zero and takes ~10 s to start. Any request starts an instance, so poke
    /// it while the user signs in to GitHub (15-20 s): it is warm when the proof begins. The answer is ignored.
    private func wakeNotary() {
        guard let url = URL(string: notary.replacingOccurrences(of: "wss://", with: "https://")), url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    func cancelSignIn() { signIn?.cancel() }

    private func closeGitHub() {
        browser?.cancel()
        browser = nil
        deviceCode = nil
    }

    /// Development: public facts about any account. The issuer refuses these (no ownership).
    func provePublic() {
        let login = login.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty else { return note("enter a GitHub login") }
        busy = true
        proof = nil
        run("proving public account \(login) through \(notary)…") { try proveGithubPublic(login: login, notary: $0) }
    }

    private func run(_ message: String, _ prove: @escaping @Sendable (String) throws -> GithubProof) {
        let notary = notary
        note(message)
        Task.detached(priority: .userInitiated) {
            let result = Result { try prove(notary) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let proof):
                    self.proof = proof
                    self.note(String(format: "proof done in %.1f s, %d bytes", proof.seconds, proof.presentation.count))
                case .failure(let error):
                    self.note("proof failed: \(error)")
                }
            }
        }
    }

    func issuer(_ label: String, _ call: @escaping (IssuerClient) async throws -> [String: Any]) {
        guard let wallet, let url = URL(string: issuerURL) else { return note("issuer URL or wallet missing") }
        busy = true
        Task {
            defer { busy = false }
            do {
                let json = try await call(IssuerClient(baseURL: url, wallet: wallet))
                note("\(label): \(Self.short(json))")
            } catch {
                note("\(label) failed: \(error.localizedDescription)")
            }
        }
    }

    func requestAttestation() {
        guard let proof else { return note("prove first") }
        issuer("attestation") { try await $0.issue(presentation: proof.presentation) }
    }

    private static func short(_ json: [String: Any]) -> String {
        let keys = ["claim", "valid", "reason", "revoked", "attestation"]
        return keys.compactMap { key in json[key].map { "\(key)=\($0)" } }.joined(separator: " ")
    }
}

struct ContentView: View {
    @StateObject private var model = ProofModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("CHROME DAO · SMART-SSI").font(.caption.monospaced()).foregroundStyle(green)
                Text("Prove what you did.\nReveal nothing else.").font(.title2.monospaced().bold())

                section("WALLET") {
                    Text(model.walletAddress).font(.caption.monospaced()).textSelection(.enabled)
                }

                section("GITHUB") {
                    if let code = model.deviceCode {
                        Text("Enter this code on GitHub, then authorize Smart-SSI:").font(.caption.monospaced())
                        Text(code.user_code).font(.title.monospaced().bold()).foregroundStyle(green).textSelection(.enabled)
                        HStack {
                            button("OPEN GITHUB", action: model.openGitHub)
                            button("CANCEL", action: model.cancelSignIn)
                        }
                    } else {
                        button(model.busy ? "PROVING…" : "SIGN IN WITH GITHUB AND PROVE", action: model.proveMine)
                            .disabled(model.busy)
                    }
                    Text("Proves the account you sign in to. Your password and token never leave GitHub and this phone.")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }

                if let proof = model.proof {
                    section("ISSUER WILL SEE") {
                        Text(proof.revealedJson).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    section("CLAIM") {
                        Text(proof.claimJson).font(.caption.monospaced()).foregroundStyle(green).textSelection(.enabled)
                        Text(String(format: "%.1f s on device", proof.seconds)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    button("GET ATTESTATION", action: model.requestAttestation).disabled(model.busy)
                }

                HStack {
                    button("CHECK") { model.issuer("check") { try await $0.check() } }
                    button("REVOKE") { model.issuer("revoke") { try await $0.revoke() } }
                }
                .disabled(model.busy)

                // Local servers and public-profile proofs: Xcode builds only, never TestFlight or the App Store.
                #if DEBUG
                DisclosureGroup("Development") {
                    TextField("public GitHub login", text: $model.login)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    button("PROVE PUBLIC PROFILE (NO OWNERSHIP)", action: model.provePublic)
                    TextField("notary host:port", text: $model.notary).textFieldStyle(.roundedBorder)
                    TextField("issuer URL", text: $model.issuerURL).textFieldStyle(.roundedBorder)
                }
                .font(.caption.monospaced())
                .disabled(model.busy)
                #endif

                section("LOG") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("[\(title)]").font(.caption.monospaced()).foregroundStyle(green)
            content()
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.monospaced().bold()).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .overlay(Rectangle().stroke(green, lineWidth: 1))
        .foregroundStyle(green)
    }
}

extension GitHubLogin.DeviceCode: Identifiable {
    var id: String { device_code }
}

/// The window the GitHub sign-in sheet is presented from.
final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
