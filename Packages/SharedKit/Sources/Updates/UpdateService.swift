import CryptoKit
import Foundation

/// A semantic application version containing major, minor, and patch components.
public struct SemanticVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Parses a version such as `0.2.0` or `v0.2.0`.
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? withoutPrefix
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Metadata required to present and download a GitHub Release update.
public struct UpdateRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let tagName: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let dmgURL: URL
    public let checksumURL: URL
    public let assetName: String
    /// Pre-pinned SHA-256 from the release manifest, when the manifest path is used.
    /// `nil` for the legacy fallback path, where only the downloaded `.sha256` sidecar
    /// is authoritative (trust-on-first-use).
    public let expectedChecksum: String?
}

/// The result of comparing the latest stable release with the installed version.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latestVersion: SemanticVersion)
    case updateAvailable(UpdateRelease)
}

/// HTTP operations used by `UpdateService` and replaceable in tests.
public protocol UpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

/// Production update HTTP client backed by `URLSession`.
public struct URLSessionUpdateHTTPClient: UpdateHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session.download(for: request)
    }
}

/// User-triggered release checker and verified DMG downloader.
///
/// Resolution flow (version-first, so a missing manifest never masks an
/// "already latest" result):
/// 1. Discover the latest stable version via the `/releases/latest` redirect.
/// 2. If the latest version is not newer than the installed one (and not forced),
///    return `.upToDate` without touching the manifest.
/// 3. Otherwise, fetch the versioned `SnapGlass-update.json` manifest. If it is
///    absent (404 — legacy releases that predate the manifest), fall back to
///    constructing the release by the `SnapGlass-v{tag}.dmg` naming convention.
public actor UpdateService {
    public static let latestReleaseURLString =
        "https://github.com/blackkcold/snapocr/releases/latest"
    public static let manifestURLTemplateString =
        "https://github.com/blackkcold/snapocr/releases/download/v%@/SnapGlass-update.json"

    private static let repositoryPathPrefix = "/blackkcold/snapocr"
    private static let releaseTagPathPrefix = "\(repositoryPathPrefix)/releases/tag/"

    private let client: any UpdateHTTPClient
    private let latestReleaseURL: URL?
    private let manifestURLTemplate: String?

    public init(
        client: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        latestReleaseURL: URL? = URL(string: UpdateService.latestReleaseURLString),
        manifestURLTemplate: String? = UpdateService.manifestURLTemplateString
    ) {
        self.client = client
        self.latestReleaseURL = latestReleaseURL
        self.manifestURLTemplate = manifestURLTemplate
    }

    /// Discovers the latest stable release and compares it with the installed version.
    public func check(currentVersion: String, force: Bool = false) async throws -> UpdateCheckResult {
        guard let installedVersion = SemanticVersion(currentVersion) else {
            throw UpdateServiceError.invalidVersion(currentVersion)
        }

        let latestVersion = try await discoverLatestVersion()

        guard force || latestVersion > installedVersion else {
            return .upToDate(latestVersion: latestVersion)
        }

        return .updateAvailable(try await fetchRelease(latestVersion: latestVersion))
    }

    /// Downloads a release DMG, verifies its SHA-256 sidecar, and moves it to Downloads.
    public func download(
        _ release: UpdateRelease,
        downloadsDirectory: URL? = nil
    ) async throws -> URL {
        let (checksumData, checksumResponse) = try await client.data(
            for: Self.request(for: release.checksumURL, accepting: "text/plain")
        )
        try Self.validate(checksumResponse, resource: .checksum)
        guard let sidecarChecksum = Self.parseChecksum(checksumData) else {
            throw UpdateServiceError.invalidChecksumFile
        }
        if let expectedChecksum = release.expectedChecksum,
           sidecarChecksum != expectedChecksum {
            throw UpdateServiceError.checksumMismatch
        }

        let (temporaryURL, downloadResponse) = try await client.download(
            for: Self.request(for: release.dmgURL, accepting: "application/octet-stream")
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Self.validate(downloadResponse, resource: .update)

        let actualChecksum = try Self.sha256(of: temporaryURL)
        guard actualChecksum == sidecarChecksum else {
            throw UpdateServiceError.checksumMismatch
        }

        let directory = try downloadsDirectory ?? Self.defaultDownloadsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = Self.uniqueDestination(
            in: directory,
            preferredName: release.assetName
        )
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateServiceError.fileMoveFailed(error.localizedDescription)
        }
        return destination
    }

    // MARK: - Version discovery

    private func discoverLatestVersion() async throws -> SemanticVersion {
        guard let latestReleaseURL else {
            throw UpdateServiceError.invalidResponse
        }
        let (_, response) = try await client.data(
            for: Self.request(for: latestReleaseURL, accepting: "text/html")
        )
        try Self.validate(response, resource: .discovery)
        guard let finalURL = response.url else {
            throw UpdateServiceError.invalidResponse
        }
        return try Self.parseTag(from: finalURL)
    }

    private static func parseTag(from url: URL) throws -> SemanticVersion {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path.hasPrefix(Self.releaseTagPathPrefix) else {
            throw UpdateServiceError.invalidResponse
        }
        let tag = url.lastPathComponent
        guard let version = SemanticVersion(tag) else {
            throw UpdateServiceError.invalidVersion(tag)
        }
        return version
    }

    // MARK: - Release resolution

    private func fetchRelease(latestVersion: SemanticVersion) async throws -> UpdateRelease {
        guard let manifestURL = manifestURL(for: latestVersion) else {
            throw UpdateServiceError.invalidResponse
        }
        let (data, response) = try await client.data(
            for: Self.request(for: manifestURL, accepting: "application/json")
        )
        do {
            try Self.validate(response, resource: .manifest)
        } catch UpdateServiceError.manifestUnavailable {
            return try Self.fallbackRelease(latestVersion: latestVersion)
        }

        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateServiceError.invalidResponse
        }

        guard manifest.schemaVersion == 1 else {
            throw UpdateServiceError.unsupportedManifestSchema(manifest.schemaVersion)
        }
        guard let manifestVersion = SemanticVersion(manifest.version),
              manifestVersion == latestVersion else {
            throw UpdateServiceError.invalidResponse
        }

        let expectedDMGName = "SnapGlass-v\(latestVersion).dmg"
        guard manifest.assetName == expectedDMGName else {
            throw UpdateServiceError.missingAsset(expectedDMGName)
        }
        let checksumName = "\(expectedDMGName).sha256"
        guard let expectedChecksum = Self.parseChecksum(Data(manifest.sha256.utf8)) else {
            throw UpdateServiceError.invalidChecksumFile
        }
        try Self.validateManifestURL(
            manifest.releasePageURL,
            expectedPathPrefix: "\(Self.repositoryPathPrefix)/releases/"
        )
        try Self.validateManifestURL(
            manifest.dmgURL,
            expectedPath: "\(Self.repositoryPathPrefix)/releases/download/v\(latestVersion)/\(expectedDMGName)"
        )
        try Self.validateManifestURL(
            manifest.checksumURL,
            expectedPath: "\(Self.repositoryPathPrefix)/releases/download/v\(latestVersion)/\(checksumName)"
        )

        return UpdateRelease(
            version: latestVersion,
            tagName: "v\(latestVersion)",
            releaseNotes: manifest.releaseNotes,
            releasePageURL: manifest.releasePageURL,
            dmgURL: manifest.dmgURL,
            checksumURL: manifest.checksumURL,
            assetName: manifest.assetName,
            expectedChecksum: expectedChecksum
        )
    }

    private func manifestURL(for version: SemanticVersion) -> URL? {
        guard let manifestURLTemplate else { return nil }
        return URL(string: String(format: manifestURLTemplate, "v\(version)"))
    }

    /// Deterministic fallback for legacy releases without a manifest: constructs
    /// the release from the `SnapGlass-v{tag}.dmg` naming convention. The DMG is
    /// still SHA-256 verified against its `.sha256` sidecar at download time.
    private static func fallbackRelease(latestVersion: SemanticVersion) throws -> UpdateRelease {
        let tag = "v\(latestVersion)"
        let assetName = "SnapGlass-\(tag).dmg"
        let checksumName = "\(assetName).sha256"
        let releasesBase = "https://github.com\(Self.repositoryPathPrefix)/releases"
        guard let releasePageURL = URL(string: "\(releasesBase)/tag/\(tag)"),
              let dmgURL = URL(string: "\(releasesBase)/download/\(tag)/\(assetName)"),
              let checksumURL = URL(string: "\(releasesBase)/download/\(tag)/\(checksumName)") else {
            throw UpdateServiceError.invalidResponse
        }
        try Self.validateManifestURL(
            releasePageURL,
            expectedPathPrefix: "\(Self.repositoryPathPrefix)/releases/"
        )
        try Self.validateManifestURL(
            dmgURL,
            expectedPath: "\(Self.repositoryPathPrefix)/releases/download/\(tag)/\(assetName)"
        )
        try Self.validateManifestURL(
            checksumURL,
            expectedPath: "\(Self.repositoryPathPrefix)/releases/download/\(tag)/\(checksumName)"
        )
        return UpdateRelease(
            version: latestVersion,
            tagName: tag,
            releaseNotes: "",
            releasePageURL: releasePageURL,
            dmgURL: dmgURL,
            checksumURL: checksumURL,
            assetName: assetName,
            expectedChecksum: nil
        )
    }

    static func parseChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let checksum = token.lowercased()
        let validCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard checksum.count == 64,
              checksum.unicodeScalars.allSatisfy(validCharacters.contains) else {
            return nil
        }
        return checksum
    }

    private static func request(for url: URL, accepting contentType: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Accept")
        request.setValue("SnapGlass-UpdateChecker", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validate(_ response: URLResponse, resource: UpdateResource) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UpdateServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 || response.statusCode == 429 {
                throw UpdateServiceError.rateLimited(retryDate(from: response))
            }
            if response.statusCode == 404 {
                switch resource {
                case .manifest:
                    throw UpdateServiceError.manifestUnavailable
                case .checksum:
                    throw UpdateServiceError.missingAsset("SHA-256 checksum")
                case .update:
                    throw UpdateServiceError.missingAsset("update DMG")
                case .discovery:
                    throw UpdateServiceError.latestReleaseUnavailable
                }
            }
            throw UpdateServiceError.httpStatus(response.statusCode)
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw UpdateServiceError.invalidResponse
        }
    }

    private static func retryDate(from response: HTTPURLResponse) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let interval = TimeInterval(retryAfter) {
            return Date().addingTimeInterval(interval)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let timestamp = TimeInterval(reset) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    private static func validateManifestURL(
        _ url: URL,
        expectedPath: String? = nil,
        expectedPathPrefix: String? = nil
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            throw UpdateServiceError.untrustedURL(url.absoluteString)
        }
        if let expectedPath, url.path != expectedPath {
            throw UpdateServiceError.untrustedURL(url.absoluteString)
        }
        if let expectedPathPrefix, !url.path.hasPrefix(expectedPathPrefix) {
            throw UpdateServiceError.untrustedURL(url.absoluteString)
        }
    }

    private static func defaultDownloadsDirectory() throws -> URL {
        if let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return directory
        }
        throw UpdateServiceError.downloadsDirectoryUnavailable
    }

    private static func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        let preferred = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }

        let extensionName = preferred.pathExtension
        let baseName = preferred.deletingPathExtension().lastPathComponent
        for index in 1...999 {
            let candidateName = extensionName.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(preferredName)")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced by update checking and verified download operations.
public enum UpdateServiceError: LocalizedError, Sendable {
    case invalidVersion(String)
    case invalidResponse
    case unsupportedManifestSchema(Int)
    case manifestUnavailable
    case latestReleaseUnavailable
    case untrustedURL(String)
    case rateLimited(Date?)
    case httpStatus(Int)
    case missingAsset(String)
    case invalidChecksumFile
    case checksumMismatch
    case downloadsDirectoryUnavailable
    case fileMoveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let version):
            "Invalid update version: \(version)"
        case .invalidResponse:
            "The update server returned an invalid release response."
        case .unsupportedManifestSchema(let version):
            "The update manifest schema (\(version)) is not supported."
        case .manifestUnavailable:
            "The latest release does not include an update manifest."
        case .latestReleaseUnavailable:
            "Unable to determine the latest stable release."
        case .untrustedURL:
            "The update manifest contains an untrusted download URL."
        case .rateLimited(let retryDate):
            if let retryDate {
                "The update server is temporarily limiting requests. Try again after "
                    + "\(retryDate.formatted())."
            } else {
                "The update server is temporarily limiting requests. Please try again later."
            }
        case .httpStatus(let status):
            "Update request failed with HTTP status \(status)."
        case .missingAsset(let name):
            "The latest release is missing \(name)."
        case .invalidChecksumFile:
            "The release checksum file is invalid."
        case .checksumMismatch:
            "The downloaded update failed SHA-256 verification."
        case .downloadsDirectoryUnavailable:
            "The Downloads folder is unavailable."
        case .fileMoveFailed(let reason):
            "Unable to save the update: \(reason)"
        }
    }
}

private enum UpdateResource {
    case manifest
    case checksum
    case update
    case discovery
}

private struct UpdateManifest: Decodable {
    let schemaVersion: Int
    let version: String
    let releaseNotes: String
    let releasePageURL: URL
    let dmgURL: URL
    let checksumURL: URL
    let assetName: String
    let sha256: String
}
