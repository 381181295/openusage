import Foundation

enum GrokBotCursorCredentialLoad: Equatable, Sendable {
    case available(CursorBorrowedAuthState)
    case notFound
    case permissionRequired
    case invalid
}

struct GrokBotCursorAuthStore: Sendable {
    static let secretsPath = "~/Library/Application Support/Grok Bot/sand-secrets.json"
    static let safeStorageItem = ElectronSafeStorageKeychainItem(
        service: "Grok Bot Safe Storage",
        account: "Grok Bot Key"
    )

    var files: any TextFileAccessing
    var safeStorage: ElectronSafeStorage

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        safeStorage: ElectronSafeStorage = ElectronSafeStorage(item: GrokBotCursorAuthStore.safeStorageItem)
    ) {
        self.files = files
        self.safeStorage = safeStorage
    }

    func load(allowInteraction: Bool) -> GrokBotCursorCredentialLoad {
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(Self.secretsPath) else {
                return .notFound
            }
            text = stored
        } catch {
            return .invalid
        }

        guard let outerData = text.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any]
        else {
            return .invalid
        }
        guard let storedAccounts = outer["cursor-accounts"] else {
            return .notFound
        }
        guard let encodedAccounts = storedAccounts as? String,
              let accountsData = encodedAccounts.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: accountsData) as? [String: Any],
              let activeValue = root["active"] as? String
        else {
            return .invalid
        }

        let active = activeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !active.isEmpty,
              let accounts = root["accounts"] as? [String: Any],
              let activeAccount = accounts[active] as? [String: Any],
              let storedAccessToken = activeAccount["cursor-access-token"] as? String
        else {
            return .invalid
        }

        let encodedAccessToken = storedAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encodedAccessToken.isEmpty,
              let encryptedAccessToken = Data(base64Encoded: encodedAccessToken)
        else {
            return .invalid
        }

        do {
            guard let key = try safeStorage.loadKey(
                allowInteraction: allowInteraction,
                policy: .reload
            ) else {
                return .invalid
            }
            let plaintext = try ElectronSafeStorage.decryptV10(encryptedAccessToken, key: key)
            guard let value = String(data: plaintext, encoding: .utf8) else {
                return .invalid
            }
            let accessToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty else {
                return .invalid
            }
            return .available(CursorBorrowedAuthState(accessToken: accessToken))
        } catch ElectronSafeStorageError.permissionRequired {
            return .permissionRequired
        } catch {
            return .invalid
        }
    }
}
