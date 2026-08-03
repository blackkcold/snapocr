import CoreGraphics
import Foundation
import Testing
@testable import SharedKit

struct PreferenceKeysTests {
    @Test func keysAreNamespacedAndUnique() {
        let keys = [
            PreferenceKeys.launchAtLogin,
            PreferenceKeys.captureOpenEditor,
            PreferenceKeys.captureCopyToClipboard,
            PreferenceKeys.captureIncludeCursor,
            PreferenceKeys.captureAutoOCR,
            PreferenceKeys.captureCopyOCRText,
            PreferenceKeys.captureSelectionStyle,
            PreferenceKeys.captureHighResolution,
            PreferenceKeys.captureImageFormat,
            PreferenceKeys.captureJPEGQuality,
            PreferenceKeys.ocrLanguagePriority,
            PreferenceKeys.ocrConfidenceThreshold,
            PreferenceKeys.ocrEngine,
            PreferenceKeys.historyRetentionPolicy,
            PreferenceKeys.historyRetentionDays,
            PreferenceKeys.historyMaxItems,
            PreferenceKeys.historyStorageSize,
            PreferenceKeys.historyAutoSave,
            PreferenceKeys.historySaveFullText,
            PreferenceKeys.developerMode,
            PreferenceKeys.engineComparison,
            PreferenceKeys.forceUpdateAvailable,
        ]

        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.contains("_") })
    }

    @Test func privacySafeDefaultsAreConservative() {
        #expect(!PreferenceDefaults.launchAtLogin)
        #expect(!PreferenceDefaults.captureIncludeCursor)
        #expect(!PreferenceDefaults.captureAutoOCR)
        #expect(!PreferenceDefaults.captureCopyOCRText)
        #expect(PreferenceDefaults.captureSelectionStyle == CaptureSelectionStyle.rectangle.rawValue)
        #expect(PreferenceDefaults.captureHighResolution)
        #expect(!PreferenceDefaults.historySaveFullText)
        #expect(!PreferenceDefaults.forceUpdateAvailable)
        #expect(PreferenceDefaults.historyRetentionDays > 0)
        #expect(PreferenceDefaults.historyMaxItems >= 10)
    }
}

struct UpdateServiceTests {
    @Test func semanticVersionsCompareNumerically() {
        guard let version010 = SemanticVersion("v0.10.0"),
              let version099 = SemanticVersion("0.9.9"),
              let version100 = SemanticVersion("1.0.0"),
              let version09999 = SemanticVersion("0.99.99") else {
            Issue.record("Valid semantic versions must parse")
            return
        }
        #expect(version010 > version099)
        #expect(version100 > version09999)
        #expect(SemanticVersion("not-a-version") == nil)
    }

    @Test func latestReleaseRequiresNewerVersionUnlessForced() async throws {
        let client = MockUpdateHTTPClient(releaseData: makeReleaseData(version: "0.2.0"))
        let service = UpdateService(client: client)

        let normal = try await service.check(currentVersion: "0.2.0")
        let forced = try await service.check(currentVersion: "0.2.0", force: true)

        guard let expectedVersion = SemanticVersion("0.2.0") else {
            Issue.record("Valid semantic version must parse")
            return
        }
        #expect(normal == .upToDate(latestVersion: expectedVersion))
        guard case .updateAvailable(let release) = forced else {
            Issue.record("Forced checks must return the latest release as available")
            return
        }
        #expect(release.assetName == "SnapGlass-v0.2.0.dmg")
    }

    @Test func latestReleaseSelectsExactDMGAndChecksumAssets() async throws {
        let client = MockUpdateHTTPClient(releaseData: makeReleaseData(version: "0.3.0"))
        let result = try await UpdateService(client: client).check(currentVersion: "0.2.0")

        guard case .updateAvailable(let release) = result else {
            Issue.record("A newer semantic version must be available")
            return
        }
        #expect(release.version == SemanticVersion("0.3.0"))
        #expect(release.dmgURL.lastPathComponent == "SnapGlass-v0.3.0.dmg")
        #expect(release.checksumURL.lastPathComponent == "SnapGlass-v0.3.0.dmg.sha256")
    }

    @Test func checksumParserRejectsMalformedValues() {
        let valid = String(repeating: "a", count: 64)
        #expect(UpdateService.parseChecksum(Data("\(valid)  SnapGlass.dmg\n".utf8)) == valid)
        #expect(UpdateService.parseChecksum(Data("not-a-checksum".utf8)) == nil)
    }
}

private struct MockUpdateHTTPClient: UpdateHTTPClient {
    let releaseData: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw MockUpdateError.invalidRequest
        }
        return (releaseData, response)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw MockUpdateError.downloadNotExpected
    }
}

private enum MockUpdateError: Error {
    case downloadNotExpected
    case invalidRequest
}

private func makeReleaseData(version: String) -> Data {
    Data("""
    {
      "tag_name": "v\(version)",
      "body": "Release notes",
      "html_url": "https://github.com/blackkcold/snapocr/releases/tag/v\(version)",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "SnapGlass-v\(version).dmg",
          "browser_download_url": "https://github.com/blackkcold/snapocr/releases/download/v\(version)/SnapGlass-v\(version).dmg"
        },
        {
          "name": "SnapGlass-v\(version).dmg.sha256",
          "browser_download_url": "https://github.com/blackkcold/snapocr/releases/download/v\(version)/SnapGlass-v\(version).dmg.sha256"
        }
      ]
    }
    """.utf8)
}

struct ImageEncoderTests {
    @Test func encodesPNGAndJPEG() throws {
        let image = try makeImage()
        let png = try ImageEncoder.encode(image, format: .png)
        let jpeg = try ImageEncoder.encode(image, format: .jpeg, jpegQuality: 0.8)

        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        #expect(!ImageEncoder.containsTransparency(image))
    }

    private func makeImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw AppError.internalError("Unable to create test context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage() else {
            throw AppError.internalError("Unable to create test image")
        }
        return image
    }
}

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
