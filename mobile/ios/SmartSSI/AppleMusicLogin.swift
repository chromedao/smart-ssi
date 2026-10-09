import CryptoKit
import Foundation
import MusicKit

/// Apple Music access through MusicKit: one system prompt, no password, no secret in the app. MusicKit makes the
/// developer token (Automatic Developer Token Generation, enabled for the app id) and the user's Music User
/// Token; the prover sends both as request headers, hidden in the presentation.
enum AppleMusicLogin {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "Smart-SSI needs access to Apple Music to see what you listen to." }
    }

    /// Songs in one library page (the API's maximum), and the page proven.
    static let page = 100

    /// The library page to prove is not the user's choice: sha256 of the wallet and the UTC day, modulo the number
    /// of full pages. The issuer recomputes it (issuer/src/core.ts, librarySampleOffset) and refuses any other page.
    static func offset(wallet: String, librarySize: Int, date: Date = Date()) -> UInt32 {
        guard librarySize > page else { return 0 }
        let day = ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        let digest = SHA256.hash(data: Data("smart-ssi:apple-library:\(wallet):\(day)".utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return UInt32(value % UInt64(librarySize - page + 1))
    }

    /// How many songs the library holds, to place the sample. Not proven: the proof reveals the real total, and
    /// the issuer checks the page against it.
    static func librarySize() async throws -> Int {
        let url = URL(string: "https://api.music.apple.com/v1/me/library/songs?limit=1&fields[library-songs]=genreNames")!
        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        return ((json?["meta"] as? [String: Any])?["total"] as? NSNumber)?.intValue ?? 0
    }

    static func tokens() async throws -> (developer: String, user: String) {
        guard await MusicAuthorization.request() == .authorized else { throw Failure.denied }
        let provider = DefaultMusicTokenProvider()
        let developer = try await provider.developerToken(options: .ignoreCache)
        let user = try await provider.userToken(for: developer, options: .ignoreCache)
        return (developer, user)
    }
}

#if DEBUG
/// Development: asks Apple Music what the library endpoints return (sizes, attributes, totals), without proving
/// anything. Answers whether a page can carry genres only, how many songs fit in a page, and the library size.
enum AppleMusicProbe {
    static func run(log: @escaping @MainActor (String) -> Void) async {
        guard await MusicAuthorization.request() == .authorized else { return await log("probe: not authorized") }
        let paths = [
            "/v1/me/library/songs?limit=1",
            "/v1/me/library/songs?limit=100&fields[library-songs]=genreNames",
            "/v1/me/library/songs?limit=300&fields[library-songs]=genreNames",
            "/v1/me/recent/played/tracks?limit=30",
        ]
        for path in paths {
            guard let url = URL(string: "https://api.music.apple.com" + path) else { continue }
            do {
                let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
                let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
                let items = json["data"] as? [[String: Any]] ?? []
                let attributes = (items.first?["attributes"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
                let total = (json["meta"] as? [String: Any])?["total"] ?? "-"
                await log("probe \(path): \(response.urlResponse.statusCode), \(response.data.count) B, \(items.count) items, total \(total), attributes [\(attributes)]")
            } catch {
                await log("probe \(path): \(error)")
            }
        }
    }
}
#endif
