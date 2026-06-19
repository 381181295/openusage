import Foundation

struct ClaudeRefreshResponse: Decodable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

struct ClaudeUsageClient: Sendable {
    private static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private struct AccountProfile: Decodable {
        struct Identity: Decodable { var uuid: String }
        var account: Identity
        var organization: Identity?
    }

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func refreshToken(_ refreshToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "scope": Self.scopes
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: config.refreshURL,
                headers: ["Content-Type": "application/json"],
                body: bodyData,
                timeout: 15
            )
        )
    }

    func fetchUsage(accessToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: config.usageURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: 10
            )
        )
    }

    /// Fetches the signed-in account's profile, used only to resolve the account email/identity.
    func fetchProfile(accessToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: config.profileURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: 10
            )
        )
    }
    func verifyAccount(
        accessToken: String,
        expectedIdentityKey: String,
        config: ClaudeOAuthConfig
    ) async throws -> HTTPResponse? {
        let expected = expectedIdentityKey.split(separator: "|", omittingEmptySubsequences: false)
        guard expected.count == 2 else { throw ClaudeAuthError.sessionExpired }

        let response: HTTPResponse
        do {
            response = try await httpClient.send(HTTPRequest(
                method: "GET",
                url: config.usageURL.deletingLastPathComponent().appendingPathComponent("profile"),
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "anthropic-beta": "oauth-2025-04-20"
                ],
                timeout: 10
            ))
        } catch {
            throw ClaudeUsageError.connectionFailed
        }
        guard (200..<300).contains(response.statusCode) else { return response }
        guard let profile = try? JSONDecoder().decode(AccountProfile.self, from: response.body) else {
            throw ClaudeUsageError.invalidResponse
        }
        guard profile.account.uuid.caseInsensitiveCompare(String(expected[0])) == .orderedSame,
              profile.organization?.uuid.caseInsensitiveCompare(String(expected[1])) == .orderedSame
        else {
            AppLog.warn(LogTag.auth("claude"), "Claude credential does not match its account or organization")
            throw ClaudeAuthError.sessionExpired
        }
        return nil
    }
}
/// Reads the account email from the `/api/oauth/profile` response (`account.email`). Derived from the
/// token, so it identifies the account reliably regardless of the CLI's flip-flopping `.claude.json`.
enum ClaudeProfile {
    static func email(fromProfileResponse data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let email = account["email"] as? String,
              email.contains("@")
        else { return nil }
        return email
    }
}
