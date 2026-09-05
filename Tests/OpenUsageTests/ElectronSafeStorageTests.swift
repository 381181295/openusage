import Foundation
import XCTest
@testable import OpenUsage

final class ElectronSafeStorageTests: XCTestCase {
    func testDecryptsElectronV10ValueWithExistingAlgorithm() throws {
        let key = try ElectronSafeStorage.deriveKey(password: "fixture-safe-storage-password")
        let plaintext = Data(#"{"token":"secret"}"#.utf8)
        let encrypted = try encryptElectronSafeStorageV10(plaintext, key: key)

        XCTAssertEqual(try ElectronSafeStorage.decryptV10(encrypted, key: key), plaintext)
        XCTAssertThrowsError(try ElectronSafeStorage.decryptV10(Data("v11bad".utf8), key: key))
    }

    func testReadsTheConfiguredKeychainItemOnce() throws {
        let item = ElectronSafeStorageKeychainItem(service: "Example Safe Storage", account: "Example Key")
        let reader = FakeElectronSafeStoragePasswordReader(password: "fixture-password")
        let storage = ElectronSafeStorage(item: item, passwordReader: reader)

        XCTAssertNotNil(try storage.loadKey(allowInteraction: true))
        XCTAssertNotNil(try storage.loadKey(allowInteraction: false))
        XCTAssertEqual(reader.items, [item])
        XCTAssertEqual(reader.calls, [true])
    }
}
