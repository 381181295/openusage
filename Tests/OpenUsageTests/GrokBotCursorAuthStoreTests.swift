import Foundation
import XCTest
@testable import OpenUsage

final class GrokBotCursorAuthStoreTests: XCTestCase {
    func testDecryptsOnlyTheActiveAccountsAccessToken() throws {
        let fixture = try makeGrokBotCursorFixture(accessToken: "active-access-token")

        let load = fixture.store.load(allowInteraction: true)

        XCTAssertEqual(load, .available(CursorBorrowedAuthState(accessToken: "active-access-token")))
        XCTAssertEqual(fixture.keyReader.items, [GrokBotCursorAuthStore.safeStorageItem])
        XCTAssertEqual(fixture.keyReader.calls, [true])
    }

    func testAbsentExternalCredentialDataIsNotFound() throws {
        let keyReader = FakeElectronSafeStoragePasswordReader(password: "unused")
        let missingFile = GrokBotCursorAuthStore(
            files: FakeFiles(),
            safeStorage: ElectronSafeStorage(
                item: GrokBotCursorAuthStore.safeStorageItem,
                passwordReader: keyReader
            )
        )
        let missingAccounts = GrokBotCursorAuthStore(
            files: FakeFiles([GrokBotCursorAuthStore.secretsPath: "{}"]),
            safeStorage: ElectronSafeStorage(
                item: GrokBotCursorAuthStore.safeStorageItem,
                passwordReader: keyReader
            )
        )

        XCTAssertEqual(missingFile.load(allowInteraction: false), .notFound)
        XCTAssertEqual(missingAccounts.load(allowInteraction: false), .notFound)
        XCTAssertTrue(keyReader.calls.isEmpty)
    }

    func testMalformedExternalCredentialDataIsInvalid() throws {
        let malformedDocuments = [
            "not-json",
            try grokBotSecrets(cursorAccounts: "not-json"),
            try grokBotSecrets(cursorAccounts: #"{"active":"missing","accounts":{}}"#),
            try grokBotSecrets(cursorAccounts: #"{"active":"selected","accounts":{"selected":{"cursor-access-token":"not-base64"}}}"#)
        ]

        for document in malformedDocuments {
            let store = GrokBotCursorAuthStore(
                files: FakeFiles([GrokBotCursorAuthStore.secretsPath: document]),
                safeStorage: ElectronSafeStorage(
                    item: GrokBotCursorAuthStore.safeStorageItem,
                    passwordReader: FakeElectronSafeStoragePasswordReader(password: "fixture-password")
                )
            )
            XCTAssertEqual(store.load(allowInteraction: false), .invalid)
        }
    }
}

struct GrokBotCursorFixture {
    var store: GrokBotCursorAuthStore
    var files: FakeFiles
    var keyReader: FakeElectronSafeStoragePasswordReader
}

func makeGrokBotCursorFixture(accessToken: String) throws -> GrokBotCursorFixture {
    let password = "fixture-grok-bot-safe-storage-password"
    let key = try ElectronSafeStorage.deriveKey(password: password)
    let encryptedAccessToken = try encryptElectronSafeStorageV10(Data(accessToken.utf8), key: key)
        .base64EncodedString()
    let encodedAccounts = try jsonString([
        "active": "selected",
        "accounts": [
            "selected": [
                "cursor-access-token": encryptedAccessToken,
                "cursor-refresh-token": "deliberately-not-base64",
                "cursor-account-profile": "deliberately-not-base64"
            ],
            "inactive": [
                "cursor-access-token": "deliberately-not-base64"
            ]
        ]
    ])
    let files = FakeFiles([
        GrokBotCursorAuthStore.secretsPath: try grokBotSecrets(cursorAccounts: encodedAccounts)
    ])
    let keyReader = FakeElectronSafeStoragePasswordReader(password: password)
    let store = GrokBotCursorAuthStore(
        files: files,
        safeStorage: ElectronSafeStorage(
            item: GrokBotCursorAuthStore.safeStorageItem,
            passwordReader: keyReader
        )
    )
    return GrokBotCursorFixture(store: store, files: files, keyReader: keyReader)
}

private func grokBotSecrets(cursorAccounts: String) throws -> String {
    try jsonString(["cursor-accounts": cursorAccounts])
}

private func jsonString(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}
