import Foundation
import Testing
@testable import SharedKit

struct LocalKeyStoreTests {
    @Test func createsStableOwnerOnlyKeyFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-key-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL = root.appendingPathComponent("Security/history-v2.key")

        let first = try LocalKeyStore.loadOrCreateKey(at: keyURL)
        let second = try LocalKeyStore.loadOrCreateKey(at: keyURL)
        let firstData = first.withUnsafeBytes { Data($0) }
        let secondData = second.withUnsafeBytes { Data($0) }
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)

        #expect(firstData.count == 32)
        #expect(firstData == secondData)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
