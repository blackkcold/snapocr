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

/// User-triggered GitHub Release checker and verified DMG downloader.
public actor UpdateService {
    public static let latestReleaseURLString =
        "https://api.github.com/repos/blackkcold/snapocr/releases/latest"

    private let client: any UpdateHTTPClient

    public init(client: any UpdateHTTPClient = URLSessionUpdateHTTPClient()) {
        self.client = client
    }

    /// Fetches the latest stable release and compares it with the installed version.
    public func check(currentVersion: String, force: Bool = false) async throws -> UpdateCheckResult {
        guard let installedVersion = SemanticVersion(currentVersion) else {
            throw UpdateServiceError.invalidVersion(currentVersion)
        }

        guard let latestReleaseURL = URL(string: Self.latestReleaseURLString) else {
            throw UpdateServiceError.invalidResponse
        }
        let (data, response) = try await client.data(for: Self.request(for: latestReleaseURL))
        try Self.validate(response)

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateServiceError.invalidResponse
        }

        guard !release.draft, !release.prerelease,
              let latestVersion = SemanticVersion(release.tagName) else {
            throw UpdateServiceError.invalidVersion(release.tagName)
        }

        let expectedDMGName = "SnapGlass-v\(latestVersion).dmg"
        guard let dmgAsset = release.assets.first(where: { $0.name == expectedDMGName }) else {
            throw UpdateServiceError.missingAsset(expectedDMGName)
        }
        let checksumName = "\(expectedDMGName).sha256"
        guard let checksumAsset = release.assets.first(where: { $0.name == checksumName }) else {
            throw UpdateServiceError.missingAsset(checksumName)
        }

        guard force || latestVersion > installedVersion else {
            return .upToDate(latestVersion: latestVersion)
        }

        return .updateAvailable(UpdateRelease(
            version: latestVersion,
            tagName: release.tagName,
            releaseNotes: release.body,
            releasePageURL: release.htmlURL,
            dmgURL: dmgAsset.browserDownloadURL,
            checksumURL: checksumAsset.browserDownloadURL,
            assetName: dmgAsset.name
        ))
    }

    /// Downloads a release DMG, verifies its SHA-256 sidecar, and moves it to Downloads.
    public func download(
        _ release: UpdateRelease,
        downloadsDirectory: URL? = nil
    ) async throws -> URL {
        let (checksumData, checksumResponse) = try await client.data(
            for: Self.request(for: release.checksumURL)
        )
        try Self.validate(checksumResponse)
        guard let expectedChecksum = Self.parseChecksum(checksumData) else {
            throw UpdateServiceError.invalidChecksumFile
        }

        let (temporaryURL, downloadResponse) = try await client.download(
            for: Self.request(for: release.dmgURL)
        )
        try Self.validate(downloadResponse)

        let actualChecksum = try Self.sha256(of: temporaryURL)
        guard actualChecksum == expectedChecksum else {
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

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SnapGlass-UpdateChecker", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateServiceError.httpStatus(status)
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
            "GitHub returned an invalid release response."
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

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
