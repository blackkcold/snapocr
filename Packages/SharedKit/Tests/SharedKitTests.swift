import CoreGraphics
import Foundation
import Testing
@testable import SharedKit

struct PreferenceKeysTests {
    @Test func keysAreNamespacedAndUnique() {
        let keys = [
            PreferenceKeys.launchAtLogin,
            PreferenceKeys.appLanguage,
            PreferenceKeys.appearanceMode,
            PreferenceKeys.captureOpenEditor,
            PreferenceKeys.captureCopyToClipboard,
            PreferenceKeys.captureIncludeCursor,
            PreferenceKeys.captureAutoOCR,
            PreferenceKeys.captureCopyOCRText,
            PreferenceKeys.captureSelectionStyle,
            PreferenceKeys.captureOverlayMode,
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
        #expect(PreferenceDefaults.appearanceMode == AppearanceMode.system.rawValue)
        #expect(!PreferenceDefaults.captureIncludeCursor)
        #expect(!PreferenceDefaults.captureAutoOCR)
        #expect(!PreferenceDefaults.captureCopyOCRText)
        #expect(PreferenceDefaults.captureSelectionStyle == CaptureSelectionStyle.rectangle.rawValue)
        #expect(PreferenceDefaults.captureOverlayMode == CaptureOverlayMode.live.rawValue)
        #expect(PreferenceDefaults.captureHighResolution)
        #expect(!PreferenceDefaults.historySaveFullText)
        #expect(!PreferenceDefaults.forceUpdateAvailable)
        #expect(PreferenceDefaults.historyRetentionDays > 0)
        #expect(PreferenceDefaults.historyMaxItems >= 10)
    }

    @Test func appearanceModesHaveStablePersistedValues() {
        #expect(AppearanceMode.allCases.map(\.rawValue) == ["system", "light", "dark"])
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue)?.rawValue == mode.rawValue)
        }
    }

    @Test func captureOverlayModesHaveStablePersistedValues() {
        #expect(CaptureOverlayMode.allCases.map(\.rawValue) == ["live", "snapshot"])
        for mode in CaptureOverlayMode.allCases {
            #expect(CaptureOverlayMode(rawValue: mode.rawValue)?.rawValue == mode.rawValue)
        }
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
        let client = try makeClient(
            discoveryVersion: "0.2.0",
            manifestData: makeManifestData(version: "0.2.0")
        )
        let service = UpdateService(client: client, latestReleaseURL: try testLatestReleaseURL())

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

    @Test func upToDateSkipsManifestWhenAlreadyLatest() async throws {
        let client = try makeClient(
            discoveryVersion: "0.5.6",
            manifestData: Data(),
            manifestStatusCode: 404
        )
        let result = try await UpdateService(
            client: client,
            latestReleaseURL: try testLatestReleaseURL()
        ).check(currentVersion: "0.5.6")

        guard case .upToDate(let latestVersion) = result else {
            Issue.record("An installed version equal to latest must be up to date")
            return
        }
        #expect(latestVersion == SemanticVersion("0.5.6"))
    }

    @Test func latestReleaseSelectsExactDMGAndChecksumAssets() async throws {
        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: makeManifestData(version: "0.3.0")
        )
        let result = try await UpdateService(
            client: client,
            latestReleaseURL: try testLatestReleaseURL()
        ).check(currentVersion: "0.2.0")

        guard case .updateAvailable(let release) = result else {
            Issue.record("A newer semantic version must be available")
            return
        }
        #expect(release.version == SemanticVersion("0.3.0"))
        #expect(release.dmgURL.lastPathComponent == "SnapGlass-v0.3.0.dmg")
        #expect(release.checksumURL.lastPathComponent == "SnapGlass-v0.3.0.dmg.sha256")
        #expect(release.expectedChecksum == String(repeating: "a", count: 64))
    }

    @Test func checksumParserRejectsMalformedValues() {
        let valid = String(repeating: "a", count: 64)
        #expect(UpdateService.parseChecksum(Data("\(valid)  SnapGlass.dmg\n".utf8)) == valid)
        #expect(UpdateService.parseChecksum(Data("not-a-checksum".utf8)) == nil)
    }

    @Test func rateLimitResponseIncludesRetryDate() async throws {
        let resetDate = Date().addingTimeInterval(600)
        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: Data(),
            manifestStatusCode: 403,
            manifestHeaders: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": String(Int(resetDate.timeIntervalSince1970)),
            ]
        )

        do {
            _ = try await UpdateService(
                client: client,
                latestReleaseURL: try testLatestReleaseURL()
            ).check(currentVersion: "0.2.0")
            Issue.record("A rate-limited response must throw")
        } catch UpdateServiceError.rateLimited(let retryDate) {
            #expect(retryDate != nil)
        }
    }

    @Test func missingManifestFallsBackToNamingConvention() async throws {
        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: Data(),
            manifestStatusCode: 404
        )
        let result = try await UpdateService(
            client: client,
            latestReleaseURL: try testLatestReleaseURL()
        ).check(currentVersion: "0.2.0")

        guard case .updateAvailable(let release) = result else {
            Issue.record("A missing manifest must fall back to a constructed release")
            return
        }
        #expect(release.version == SemanticVersion("0.3.0"))
        #expect(release.tagName == "v0.3.0")
        #expect(release.releaseNotes == "")
        #expect(release.expectedChecksum == nil)
        #expect(release.dmgURL.lastPathComponent == "SnapGlass-v0.3.0.dmg")
        #expect(release.checksumURL.lastPathComponent == "SnapGlass-v0.3.0.dmg.sha256")
    }

    @Test func manifestVersionMismatchIsRejected() async throws {
        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: makeManifestData(version: "0.3.0", declaredVersion: "0.4.0")
        )

        do {
            _ = try await UpdateService(
                client: client,
                latestReleaseURL: try testLatestReleaseURL()
            ).check(currentVersion: "0.2.0")
            Issue.record("A manifest version mismatch must throw")
        } catch UpdateServiceError.invalidResponse {
            // Expected.
        }
    }

    @Test func discoveryRejectsNonGitHubRedirect() async throws {
        let latestReleaseURL = try testLatestReleaseURL()
        let manifestURL = try testManifestURL(version: "0.3.0")
        guard let untrustedFinalURL = URL(string: "https://example.com/releases/tag/v0.3.0") else {
            Issue.record("Test URL must parse")
            return
        }
        let client = MockUpdateHTTPClient(
            latestReleaseURL: latestReleaseURL,
            discoveryFinalURL: untrustedFinalURL,
            manifestURL: manifestURL,
            manifestData: makeManifestData(version: "0.3.0")
        )

        do {
            _ = try await UpdateService(client: client, latestReleaseURL: latestReleaseURL)
                .check(currentVersion: "0.2.0")
            Issue.record("A non-GitHub redirect must throw")
        } catch UpdateServiceError.invalidResponse {
            // Expected.
        }
    }

    @Test func manifestRejectsUntrustedAssetURL() async throws {
        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: makeManifestData(
                version: "0.3.0",
                dmgURL: "https://example.com/SnapGlass-v0.3.0.dmg"
            )
        )

        do {
            _ = try await UpdateService(
                client: client,
                latestReleaseURL: try testLatestReleaseURL()
            ).check(currentVersion: "0.2.0")
            Issue.record("An untrusted asset URL must throw")
        } catch UpdateServiceError.untrustedURL(let url) {
            #expect(url.contains("example.com"))
        }
    }

    @Test func verifiedDownloadUsesUniqueDestination() async throws {
        let checksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-update-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: temporaryFile)
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }
        try Data().write(
            to: destinationDirectory.appendingPathComponent("SnapGlass-v0.3.0.dmg")
        )

        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: makeManifestData(version: "0.3.0", checksum: checksum),
            checksumData: Data("\(checksum)  SnapGlass-v0.3.0.dmg\n".utf8),
            downloadFileURL: temporaryFile
        )
        let service = UpdateService(client: client, latestReleaseURL: try testLatestReleaseURL())
        let result = try await service.check(currentVersion: "0.2.0")
        guard case .updateAvailable(let release) = result else {
            Issue.record("A newer semantic version must be available")
            return
        }

        let downloadedURL = try await service.download(
            release,
            downloadsDirectory: destinationDirectory
        )

        #expect(downloadedURL.lastPathComponent == "SnapGlass-v0.3.0-1.dmg")
        #expect(try Data(contentsOf: downloadedURL) == Data("hello".utf8))
    }

    @Test func fallbackDownloadVerifiesSidecarWithoutPinnedChecksum() async throws {
        let checksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-update-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: temporaryFile)
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }

        let client = try makeClient(
            discoveryVersion: "0.3.0",
            manifestData: Data(),
            manifestStatusCode: 404,
            checksumData: Data("\(checksum)  SnapGlass-v0.3.0.dmg\n".utf8),
            downloadFileURL: temporaryFile
        )
        let service = UpdateService(client: client, latestReleaseURL: try testLatestReleaseURL())
        let result = try await service.check(currentVersion: "0.2.0")
        guard case .updateAvailable(let release) = result else {
            Issue.record("A missing manifest must fall back to a constructed release")
            return
        }

        let downloadedURL = try await service.download(
            release,
            downloadsDirectory: destinationDirectory
        )

        #expect(downloadedURL.lastPathComponent == "SnapGlass-v0.3.0.dmg")
        #expect(try Data(contentsOf: downloadedURL) == Data("hello".utf8))
    }
}

private struct MockUpdateHTTPClient: UpdateHTTPClient {
    let latestReleaseURL: URL
    let discoveryFinalURL: URL
    var discoveryStatusCode = 200
    let manifestURL: URL
    let manifestData: Data
    var manifestStatusCode = 200
    var manifestHeaders: [String: String]?
    var checksumData = Data()
    var downloadFileURL: URL?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw MockUpdateError.invalidRequest
        }
        if url == latestReleaseURL {
            guard let response = HTTPURLResponse(
                url: discoveryFinalURL,
                statusCode: discoveryStatusCode,
                httpVersion: nil,
                headerFields: nil
            ) else {
                throw MockUpdateError.invalidRequest
            }
            return (Data(), response)
        }
        if url == manifestURL {
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: manifestStatusCode,
                httpVersion: nil,
                headerFields: manifestHeaders
            ) else {
                throw MockUpdateError.invalidRequest
            }
            return (manifestData, response)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw MockUpdateError.invalidRequest
        }
        return (checksumData, response)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        guard let url = request.url,
              let downloadFileURL,
              let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw MockUpdateError.downloadNotExpected
        }
        return (downloadFileURL, response)
    }
}

private enum MockUpdateError: Error {
    case downloadNotExpected
    case invalidRequest
}

private func testLatestReleaseURL() throws -> URL {
    guard let url = URL(string: UpdateService.latestReleaseURLString) else {
        throw MockUpdateError.invalidRequest
    }
    return url
}

private func testManifestURL(version: String) throws -> URL {
    guard let url = URL(string: String(format: UpdateService.manifestURLTemplateString, "v\(version)")) else {
        throw MockUpdateError.invalidRequest
    }
    return url
}

private func testDiscoveryFinalURL(version: String) throws -> URL {
    guard let url = URL(string: "https://github.com/blackkcold/snapocr/releases/tag/v\(version)") else {
        throw MockUpdateError.invalidRequest
    }
    return url
}

private func makeClient(
    discoveryVersion: String,
    manifestData: Data,
    manifestStatusCode: Int = 200,
    manifestHeaders: [String: String]? = nil,
    checksumData: Data = Data(),
    downloadFileURL: URL? = nil
) throws -> MockUpdateHTTPClient {
    let latestReleaseURL = try testLatestReleaseURL()
    return MockUpdateHTTPClient(
        latestReleaseURL: latestReleaseURL,
        discoveryFinalURL: try testDiscoveryFinalURL(version: discoveryVersion),
        manifestURL: try testManifestURL(version: discoveryVersion),
        manifestData: manifestData,
        manifestStatusCode: manifestStatusCode,
        manifestHeaders: manifestHeaders,
        checksumData: checksumData,
        downloadFileURL: downloadFileURL
    )
}

private func makeManifestData(
    version: String,
    declaredVersion: String? = nil,
    checksum: String = String(repeating: "a", count: 64),
    dmgURL: String? = nil
) -> Data {
    let declared = declaredVersion ?? version
    let resolvedDMGURL = dmgURL
        ?? "https://github.com/blackkcold/snapocr/releases/download/v\(version)/SnapGlass-v\(version).dmg"
    let resolvedChecksumURL = "https://github.com/blackkcold/snapocr/releases/download/v\(version)"
        + "/SnapGlass-v\(version).dmg.sha256"
    return Data("""
    {
      "schemaVersion": 1,
      "version": "\(declared)",
      "releaseNotes": "Release notes",
      "releasePageURL": "https://github.com/blackkcold/snapocr/releases/tag/v\(version)",
      "dmgURL": "\(resolvedDMGURL)",
      "checksumURL": "\(resolvedChecksumURL)",
      "assetName": "SnapGlass-v\(version).dmg",
      "sha256": "\(checksum)"
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
