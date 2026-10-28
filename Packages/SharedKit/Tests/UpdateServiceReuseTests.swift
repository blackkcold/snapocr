import CryptoKit
import Foundation
import Testing
@testable import SharedKit

/// Covers the download half of `UpdateService`: verified reuse, corrupt-file
/// fallback, and the checksum gate that must run before any DMG is fetched.
struct UpdateServiceReuseTests {
    @Test func reusesVerifiedExistingDMGWithoutDownloading() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("already verified payload".utf8)
        let checksum = sha256(payload)
        let release = try makeRelease(expectedChecksum: checksum)
        let canonical = root.appendingPathComponent(release.assetName)
        try payload.write(to: canonical)

        let client = StubHTTPClient(
            checksumData: sidecar(checksum, name: release.assetName)
        )
        let service = UpdateService(client: client)

        let result = try await service.download(release, downloadsDirectory: root)
        let downloadCount = await client.downloadCount

        #expect(result == canonical)
        #expect(downloadCount == 0)
    }

    @Test func downloadsWhenExistingDMGIsCorrupted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let release = try makeRelease()
        let canonical = root.appendingPathComponent(release.assetName)
        try Data("corrupted".utf8).write(to: canonical)

        let payload = Data("fresh verified payload".utf8)
        let temporary = root.appendingPathComponent("download-\(UUID().uuidString).tmp")
        try payload.write(to: temporary)
        let checksum = sha256(payload)

        let client = StubHTTPClient(
            checksumData: sidecar(checksum, name: release.assetName),
            downloadFile: temporary
        )
        let service = UpdateService(client: client)

        let result = try await service.download(release, downloadsDirectory: root)
        let downloadCount = await client.downloadCount
        let savedData = try Data(contentsOf: result)

        #expect(result.lastPathComponent == "SnapGlass-v1.2.3-1.dmg")
        #expect(savedData == payload)
        #expect(downloadCount == 1)
    }

    @Test func rejectsChecksumMismatchBeforeDownloading() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pinnedChecksum = String(repeating: "a", count: 64)
        let sidecarChecksum = String(repeating: "b", count: 64)
        let release = try makeRelease(expectedChecksum: pinnedChecksum)
        let client = StubHTTPClient(
            checksumData: sidecar(sidecarChecksum, name: release.assetName)
        )
        let service = UpdateService(client: client)

        do {
            _ = try await service.download(release, downloadsDirectory: root)
            Issue.record("Expected checksumMismatch")
        } catch UpdateServiceError.checksumMismatch {
            // Expected: the manifest and sidecar disagree.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let downloadCount = await client.downloadCount
        #expect(downloadCount == 0)
    }
}

// MARK: - Fixtures

private actor StubHTTPClient: UpdateHTTPClient {
    private let checksumData: Data
    private let downloadFile: URL?
    private(set) var downloadCount = 0

    init(checksumData: Data, downloadFile: URL? = nil) {
        self.checksumData = checksumData
        self.downloadFile = downloadFile
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (checksumData, try response(for: request))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        downloadCount += 1
        guard let downloadFile else {
            throw StubError.unexpectedDownload
        }
        return (downloadFile, try response(for: request))
    }

    private func response(for request: URLRequest) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
    }
}

private enum StubError: Error {
    case unexpectedDownload
}

private func makeRelease(
    version: String = "1.2.3",
    expectedChecksum: String? = nil
) throws -> UpdateRelease {
    let parsedVersion = try #require(SemanticVersion(version))
    let tag = "v\(version)"
    let assetName = "SnapGlass-\(tag).dmg"
    let base = "https://github.com/blackkcold/snapocr/releases"

    return UpdateRelease(
        version: parsedVersion,
        tagName: tag,
        releaseNotes: "",
        releasePageURL: try #require(URL(string: "\(base)/tag/\(tag)")),
        dmgURL: try #require(URL(string: "\(base)/download/\(tag)/\(assetName)")),
        checksumURL: try #require(URL(string: "\(base)/download/\(tag)/\(assetName).sha256")),
        assetName: assetName,
        expectedChecksum: expectedChecksum
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapglass-update-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func sidecar(_ checksum: String, name: String) -> Data {
    Data("\(checksum)  \(name)\n".utf8)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
