import Foundation

enum CursorOwnedAuthSource: Hashable, Sendable {
    case sqlite
    case keychain
}

struct CursorOwnedAuthState: Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var source: CursorOwnedAuthSource
}

struct CursorBorrowedAuthState: Hashable, Sendable {
    let accessToken: String
}

enum CursorAuthState: Hashable, Sendable {
    case owned(CursorOwnedAuthState)
    case borrowed(CursorBorrowedAuthState)
}

enum CursorAuthLoad: Hashable, Sendable {
    case available(CursorAuthState)
    case notFound
    case grokBotPermissionRequired
    case grokBotInvalid
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case grokBotPermissionRequired
    case grokBotCredentialsUnavailable
    case grokBotAuthenticationRequired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .grokBotPermissionRequired:
            return "Grok Bot Cursor login found. Refresh manually and choose Always Allow to connect it."
        case .grokBotCredentialsUnavailable:
            return "Grok Bot Cursor login couldn't be read. Open Grok Bot, then refresh OpenUsage."
        case .grokBotAuthenticationRequired:
            return "Grok Bot's Cursor login was rejected. Open Grok Bot, then refresh OpenUsage."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var grokBot: GrokBotCursorAuthStore
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        grokBot: GrokBotCursorAuthStore = GrokBotCursorAuthStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.grokBot = grokBot
        self.now = now
    }

    func loadAuthState(allowInteraction: Bool) -> CursorAuthLoad {
        if let owned = loadOwnedAuthState() {
            return .available(.owned(owned))
        }

        switch grokBot.load(allowInteraction: allowInteraction) {
        case .available(let borrowed):
            return .available(.borrowed(borrowed))
        case .notFound:
            return .notFound
        case .permissionRequired:
            return .grokBotPermissionRequired
        case .invalid:
            return .grokBotInvalid
        }
    }

    private func loadOwnedAuthState() -> CursorOwnedAuthState? {
        let sqliteAccessToken = readStateValue(Self.accessTokenKey)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                return CursorOwnedAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                )
            }

            return CursorOwnedAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            return CursorOwnedAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            )
        }

        return nil
    }

    func needsRefresh(_ authState: CursorOwnedAuthState) -> Bool {
        guard let accessToken = authState.accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorOwnedAuthSource) throws {
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        }
    }

    private func readStateValue(_ key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
