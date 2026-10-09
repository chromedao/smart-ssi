import Foundation

/// Client for the Smart-SSI issuer API (issuer/src/server.ts). Issue and revoke are signed by the wallet.
struct IssuerClient {
    var baseURL: URL
    var wallet: Wallet

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "\(status): \(message)" }
    }

    func issue(presentation: Data) async throws -> [String: Any] {
        let signature = try wallet.sign("smart-ssi:issue:\(presentation.sha256Hex)")
        return try await send("POST", "/v1/attestations", [
            "wallet": wallet.address,
            "presentation": presentation.base64EncodedString(),
            "signature": signature,
        ])
    }

    /// All of the wallet's valid badges, one per family, as read from Solana.
    func badges() async throws -> [[String: Any]] {
        try await send("GET", "/v1/badges/\(wallet.address)", nil)["badges"] as? [[String: Any]] ?? []
    }

    /// Removes the badge of one family (the family is part of the signed message).
    func revoke(family: String) async throws -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = try wallet.sign("smart-ssi:revoke:\(wallet.address):\(timestamp):\(family)")
        return try await send("DELETE", "/v1/attestations/\(wallet.address)", ["timestamp": timestamp, "signature": signature, "family": family])
    }

    private func send(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: json["error"] as? String ?? "request failed")
        }
        return json
    }
}
