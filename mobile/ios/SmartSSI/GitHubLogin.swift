import Foundation

/// GitHub sign-in with the OAuth device flow: the app needs no client secret and no redirect URL.
/// The user approves on github.com (in a Safari sheet, where password managers and autofill work),
/// the app polls until GitHub hands over a token. The token only lives in memory for one proof.
///
/// Scope is empty: the token can read public profile data only, which is all `GET /user` needs.
struct GitHubLogin {
    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let interval: Int
        let expires_in: Int
    }

    enum Failure: LocalizedError {
        case missingClientID, denied, expired, github(String)
        var errorDescription: String? {
            switch self {
            case .missingClientID: "GitHub OAuth app not configured (GitHubClientID)"
            case .denied: "GitHub sign-in was cancelled"
            case .expired: "GitHub code expired, try again"
            case .github(let message): "GitHub: \(message)"
            }
        }
    }

    /// Public identifier of the Chrome DAO OAuth app (not a secret). `-githubClientId <id>` at launch overrides it.
    static var clientID: String? {
        let id = UserDefaults.standard.string(forKey: "githubClientId")
            ?? Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
        return id?.isEmpty == false ? id : nil
    }

    func start() async throws -> DeviceCode {
        guard let clientID = Self.clientID else { throw Failure.missingClientID }
        return try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": ""])
    }

    /// Polls until the user approves (returns the token), denies or lets the code expire.
    func token(for code: DeviceCode) async throws -> String {
        guard let clientID = Self.clientID else { throw Failure.missingClientID }
        var interval = code.interval
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let reply: [String: String] = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = reply["access_token"] { return token }
            switch reply["error"] {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw Failure.denied
            case "expired_token": throw Failure.expired
            default: throw Failure.github(reply["error_description"] ?? reply["error"] ?? "unexpected answer")
            }
        }
        throw Failure.expired
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var query = URLComponents()
        query.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = query.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        // The token endpoint mixes strings and numbers; keep strings only for [String: String].
        if T.self == [String: String].self, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.compactMapValues { $0 as? String } as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
