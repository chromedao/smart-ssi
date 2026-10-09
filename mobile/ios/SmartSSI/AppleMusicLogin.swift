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

    static func tokens() async throws -> (developer: String, user: String) {
        guard await MusicAuthorization.request() == .authorized else { throw Failure.denied }
        let provider = DefaultMusicTokenProvider()
        let developer = try await provider.developerToken(options: .ignoreCache)
        let user = try await provider.userToken(for: developer, options: .ignoreCache)
        return (developer, user)
    }
}
