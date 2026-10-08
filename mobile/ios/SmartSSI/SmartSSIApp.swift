import SwiftUI

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
    @Published var notary = "127.0.0.1:7047"
    @Published var issuerURL = "http://127.0.0.1:8787"
    @Published var walletAddress = ""
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

    func prove() {
        let login = login.trimmingCharacters(in: .whitespaces), notary = notary
        guard !login.isEmpty else { return note("enter a GitHub login") }
        busy = true
        proof = nil
        note("proving \(login) through \(notary)…")
        Task.detached(priority: .userInitiated) {
            let result = Result { try proveGithub(login: login, notary: notary) }
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
                    TextField("login", text: $model.login)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    button(model.busy ? "PROVING…" : "PROVE ON THIS PHONE", action: model.prove)
                }

                if let proof = model.proof {
                    section("ISSUER WILL SEE") {
                        Text(proof.revealedJson).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    section("CLAIM") {
                        Text(proof.claimJson).font(.caption.monospaced()).foregroundStyle(green).textSelection(.enabled)
                        Text(String(format: "%.1f s on device", proof.seconds)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    button("GET ATTESTATION", action: model.requestAttestation)
                }

                HStack {
                    button("CHECK") { model.issuer("check") { try await $0.check() } }
                    button("REVOKE") { model.issuer("revoke") { try await $0.revoke() } }
                }

                DisclosureGroup("Development servers") {
                    TextField("notary host:port", text: $model.notary).textFieldStyle(.roundedBorder)
                    TextField("issuer URL", text: $model.issuerURL).textFieldStyle(.roundedBorder)
                }
                .font(.caption.monospaced())

                section("LOG") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
        .disabled(model.busy)
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
