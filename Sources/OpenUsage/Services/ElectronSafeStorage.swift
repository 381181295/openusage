import CommonCrypto
import Foundation
import LocalAuthentication
import Security

struct ElectronSafeStorageKeychainItem: Hashable, Sendable {
    let service: String
    let account: String
}

protocol ElectronSafeStoragePasswordReading: Sendable {
    func readPassword(
        for item: ElectronSafeStorageKeychainItem,
        allowInteraction: Bool
    ) throws -> String?
}

struct SecurityElectronSafeStoragePasswordReader: ElectronSafeStoragePasswordReading {
    func readPassword(
        for item: ElectronSafeStorageKeychainItem,
        allowInteraction: Bool
    ) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw ElectronSafeStorageError.invalidSafeStorageKey
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ElectronSafeStorageError.permissionRequired
        default:
            throw ElectronSafeStorageError.keychainFailure(Int(status))
        }
    }
}

enum ElectronSafeStorageError: Error, Sendable, Equatable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
    case invalidCiphertext
    case decryptionFailed(Int32)
}

enum ElectronSafeStorageKeyPolicy: Sendable, Equatable {
    case cached
    case reload
}

struct ElectronSafeStorage: Sendable {
    let item: ElectronSafeStorageKeychainItem
    var passwordReader: any ElectronSafeStoragePasswordReading
    private let keyCache: ElectronSafeStorageKeyCache

    init(
        item: ElectronSafeStorageKeychainItem,
        passwordReader: any ElectronSafeStoragePasswordReading = SecurityElectronSafeStoragePasswordReader(),
        keyCache: ElectronSafeStorageKeyCache = ElectronSafeStorageKeyCache()
    ) {
        self.item = item
        self.passwordReader = passwordReader
        self.keyCache = keyCache
    }

    func loadKey(
        allowInteraction: Bool,
        policy: ElectronSafeStorageKeyPolicy = .cached
    ) throws -> Data? {
        if policy == .cached, let cached = keyCache.value { return cached }
        guard let password = try passwordReader.readPassword(for: item, allowInteraction: allowInteraction) else {
            keyCache.value = nil
            return nil
        }
        let key = try Self.deriveKey(password: password)
        keyCache.value = key
        return key
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw ElectronSafeStorageError.invalidSafeStorageKey
        }
        return key
    }

    static func decryptV10(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw ElectronSafeStorageError.invalidCiphertext
        }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ElectronSafeStorageError.decryptionFailed(status)
        }
        output.count = outputLength
        return output
    }
}

final class ElectronSafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
