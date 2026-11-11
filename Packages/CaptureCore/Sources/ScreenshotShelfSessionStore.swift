import CryptoKit
import Foundation

/// Errors produced while storing encrypted, session-only screenshot assets.
public enum ScreenshotShelfSessionStoreError: Error, Equatable, Sendable {
    /// The encrypted original cannot fit within the configured byte budget.
    case originalExceedsBudget

    /// The thumbnail cannot fit within the configured in-memory byte budget.
    case thumbnailExceedsBudget

    /// The session directory or one of its assets could not be read or written.
    case storageFailure
}

/// Stores encrypted originals on disk and bounded thumbnails in memory for one app session.
public actor ScreenshotShelfSessionStore {
    private struct StoredAsset: Sendable {
        let fileURL: URL
        let encryptedByteCount: Int
        let thumbnailData: Data
        let sequence: UInt64
    }

    private static let ownerPID = ProcessInfo.processInfo.processIdentifier
    private static let defaultOriginalByteBudget = 512 * 1_024 * 1_024
    private static let defaultThumbnailByteBudget = 16 * 1_024 * 1_024

    private let sessionDirectoryURL: URL
    private let encryptionKey: SymmetricKey
    private let originalByteBudget: Int
    private let thumbnailByteBudget: Int

    private var assets: [UUID: StoredAsset] = [:]
    private var storedOriginalBytes = 0
    private var storedThumbnailBytes = 0
    private var nextSequence: UInt64 = 0

    /// Creates a store in the SnapGlass cache directory with the production byte budgets.
    public init() throws {
        guard let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }

        let rootURL = cacheDirectory
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("ScreenshotShelf", isDirectory: true)
        sessionDirectoryURL = try Self.makeSessionDirectory(under: rootURL)
        encryptionKey = SymmetricKey(size: .bits256)
        originalByteBudget = Self.defaultOriginalByteBudget
        thumbnailByteBudget = Self.defaultThumbnailByteBudget
    }

    init(
        sessionRootURL: URL,
        originalByteBudget: Int,
        thumbnailByteBudget: Int
    ) throws {
        sessionDirectoryURL = try Self.makeSessionDirectory(under: sessionRootURL)
        encryptionKey = SymmetricKey(size: .bits256)
        self.originalByteBudget = max(0, originalByteBudget)
        self.thumbnailByteBudget = max(0, thumbnailByteBudget)
    }

    /// Encrypts and stores an original, caches its thumbnail, and evicts oldest assets as needed.
    ///
    /// - Parameters:
    ///   - originalData: Encoded original image bytes.
    ///   - thumbnailData: Display-sized thumbnail bytes.
    ///   - captureID: Stable identity for this screenshot.
    /// - Returns: Capture IDs whose cached original and thumbnail were evicted.
    @discardableResult
    public func store(
        originalData: Data,
        thumbnailData: Data,
        captureID: UUID
    ) throws -> [UUID] {
        try ensureSessionDirectory()
        guard thumbnailData.count <= thumbnailByteBudget else {
            throw ScreenshotShelfSessionStoreError.thumbnailExceedsBudget
        }

        let sealedData: Data
        do {
            guard let combined = try AES.GCM.seal(originalData, using: encryptionKey).combined else {
                throw ScreenshotShelfSessionStoreError.storageFailure
            }
            sealedData = combined
        } catch {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }

        guard sealedData.count <= originalByteBudget else {
            throw ScreenshotShelfSessionStoreError.originalExceedsBudget
        }

        let existingAsset = assets[captureID]
        var projectedOriginalBytes = storedOriginalBytes - (existingAsset?.encryptedByteCount ?? 0)
        var projectedThumbnailBytes = storedThumbnailBytes - (existingAsset?.thumbnailData.count ?? 0)
        var evictedIDs: [UUID] = []

        let oldestCandidates = assets
            .filter { $0.key != captureID }
            .sorted { $0.value.sequence < $1.value.sequence }

        for (candidateID, candidate) in oldestCandidates {
            guard projectedOriginalBytes + sealedData.count > originalByteBudget
                    || projectedThumbnailBytes + thumbnailData.count > thumbnailByteBudget else {
                break
            }
            projectedOriginalBytes -= candidate.encryptedByteCount
            projectedThumbnailBytes -= candidate.thumbnailData.count
            evictedIDs.append(candidateID)
        }

        guard projectedOriginalBytes + sealedData.count <= originalByteBudget,
              projectedThumbnailBytes + thumbnailData.count <= thumbnailByteBudget else {
            throw ScreenshotShelfSessionStoreError.originalExceedsBudget
        }

        let newFileURL = sessionDirectoryURL
            .appendingPathComponent("\(UUID().uuidString).sealed", isDirectory: false)
        do {
            try sealedData.write(to: newFileURL, options: .atomic)
        } catch {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }

        var idsToRemove = evictedIDs
        if existingAsset != nil {
            idsToRemove.append(captureID)
        }
        do {
            for removedID in idsToRemove {
                try removeStoredAsset(for: removedID)
            }
        } catch {
            try? FileManager.default.removeItem(at: newFileURL)
            throw ScreenshotShelfSessionStoreError.storageFailure
        }

        let sequence = existingAsset?.sequence ?? nextSequence
        if existingAsset == nil {
            nextSequence &+= 1
        }
        let asset = StoredAsset(
            fileURL: newFileURL,
            encryptedByteCount: sealedData.count,
            thumbnailData: thumbnailData,
            sequence: sequence
        )
        assets[captureID] = asset
        storedOriginalBytes += asset.encryptedByteCount
        storedThumbnailBytes += asset.thumbnailData.count
        return evictedIDs
    }

    /// Reads and decrypts an original from this session's encrypted asset directory.
    ///
    /// - Parameter captureID: Stable identity for the screenshot.
    /// - Returns: Original image bytes, or `nil` when the asset is not stored.
    public func originalData(for captureID: UUID) throws -> Data? {
        guard let asset = assets[captureID] else { return nil }

        do {
            let combined = try Data(contentsOf: asset.fileURL)
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: encryptionKey)
        } catch {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }
    }

    /// Returns a cached display-sized thumbnail without substituting it for the original.
    ///
    /// - Parameter captureID: Stable identity for the screenshot.
    /// - Returns: Thumbnail bytes, or `nil` when the asset is not stored.
    public func thumbnailData(for captureID: UUID) -> Data? {
        assets[captureID]?.thumbnailData
    }

    /// Removes one screenshot's encrypted original and cached thumbnail.
    ///
    /// - Parameter captureID: Stable identity for the screenshot.
    public func remove(captureID: UUID) throws {
        try removeStoredAsset(for: captureID)
    }

    /// Removes all encrypted originals and thumbnails owned by this session.
    public func clear() throws {
        for captureID in Array(assets.keys) {
            try removeStoredAsset(for: captureID)
        }
    }

    private func removeStoredAsset(for captureID: UUID) throws {
        guard let asset = assets[captureID] else { return }
        do {
            try FileManager.default.removeItem(at: asset.fileURL)
        } catch {
            // The directory may have been removed by an older build or by the user.
            // Treat an already-missing file as removed; anything else is a real failure.
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == NSFileNoSuchFileError else {
                throw ScreenshotShelfSessionStoreError.storageFailure
            }
        }

        assets.removeValue(forKey: captureID)
        storedOriginalBytes -= asset.encryptedByteCount
        storedThumbnailBytes -= asset.thumbnailData.count
    }

    /// Recreates the session directory when something removed it while this store was alive.
    ///
    /// Any assets whose files disappeared with the directory are dropped from memory so the
    /// store never advertises a thumbnail it can no longer read back.
    private func ensureSessionDirectory() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: sessionDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return
        }

        do {
            try fileManager.createDirectory(
                at: sessionDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }
        pruneMissingAssets()
    }

    private func pruneMissingAssets() {
        let fileManager = FileManager.default
        let missingIDs = assets
            .filter { !fileManager.fileExists(atPath: $0.value.fileURL.path) }
            .map(\.key)
        for captureID in missingIDs {
            guard let asset = assets.removeValue(forKey: captureID) else { continue }
            storedOriginalBytes -= asset.encryptedByteCount
            storedThumbnailBytes -= asset.thumbnailData.count
        }
    }

    private static func makeSessionDirectory(under rootURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let now = Date()

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
            for entry in entries {
                let values = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey]
                )
                guard values?.isDirectory == true else { continue }
                guard ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                    directoryName: entry.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    now: now,
                    grace: 60,
                    legacyGrace: 24 * 60 * 60
                ) else { continue }
                try? fileManager.removeItem(at: entry)
            }

            let sessionDirectory = rootURL.appendingPathComponent(
                ScreenshotShelfSessionDirectoryPolicy.directoryName(
                    ownerPID: ownerPID,
                    sessionID: UUID()
                ),
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return sessionDirectory
        } catch {
            throw ScreenshotShelfSessionStoreError.storageFailure
        }
    }
}
