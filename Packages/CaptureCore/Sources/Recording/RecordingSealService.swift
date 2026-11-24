import AVFoundation
import CryptoKit
import Darwin
import Foundation
/// Immutable settings for sealing one segment.
public struct RecordingSealContext: Sendable, Hashable {
    /// Identity of the recording session.
    public let sessionID: UUID
    /// The recording kind requested for the session.
    public let kind: RecordingKind
    /// The audio output layout requested for the session.
    public let layout: AudioOutputLayout
    /// Fixed sample rate in hertz.
    public let sampleRate: Int
    /// Requested AAC target bitrate, or `nil` to use the legacy channel-count defaults.
    public let bitRate: Int?
    /// Complete output stem without a segment suffix or extension.
    public let outputStem: String
    /// Existing directory that receives the published segment.
    public let destinationDirectory: URL
    /// Creates a seal context.
    public init(
        sessionID: UUID, kind: RecordingKind, layout: AudioOutputLayout,
        sampleRate: Int, outputStem: String, destinationDirectory: URL,
        bitRate: Int? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.layout = layout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.outputStem = outputStem
        self.destinationDirectory = destinationDirectory
    }
}
/// A verified stage that is ready for atomic publication.
public struct SegmentPublicationCandidate: Sendable, Hashable {
    /// Identity of the sealed segment.
    public let segmentID: UUID
    /// Zero-based segment index.
    public let segmentIndex: Int
    /// Staged file or directory owned by this seal attempt.
    public let stagingURL: URL
    /// Actual final URL reserved by Task 3, including collision suffixes.
    public let reservedFinalURL: URL
    /// Whether the product is a directory rather than a single file.
    public let isDirectory: Bool
    /// Staged audio file for each role.
    public let stagedFileURLs: [RecordingTrackRole: URL]
    /// SHA-256 for each published file name, including the manifest.
    public let contentHashes: [String: String]
    /// Staged manifest URL for directory products, or `nil` for a single file.
    public let manifestURL: URL?
    /// Session-global effective range covered by the product.
    public let effectiveRange: RecordingSampleRange
    /// The per-role coverage that produced the product.
    public let coverage: RecordingSegmentCoverage
    /// Creates a publication candidate.
    public init(
        segmentID: UUID, segmentIndex: Int, stagingURL: URL, reservedFinalURL: URL,
        isDirectory: Bool, stagedFileURLs: [RecordingTrackRole: URL],
        contentHashes: [String: String], manifestURL: URL?,
        effectiveRange: RecordingSampleRange, coverage: RecordingSegmentCoverage
    ) {
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.stagingURL = stagingURL
        self.reservedFinalURL = reservedFinalURL
        self.isDirectory = isDirectory
        self.stagedFileURLs = stagedFileURLs
        self.contentHashes = contentHashes
        self.manifestURL = manifestURL
        self.effectiveRange = effectiveRange
        self.coverage = coverage
    }
}
/// Observes a verified segment immediately before Task 3 publishes it.
public protocol SegmentPublicationHooking: Sendable {
    /// Called after all staged files and hashes are verified and before the
    /// atomic final rename. Any error cancels publication and retains the stage.
    func beforePublish(_ candidate: SegmentPublicationCandidate) async throws
}
/// The published result of sealing one segment.
public struct SealedSegment: Sendable, Hashable {
    /// Identity of the sealed segment.
    public let segmentID: UUID
    /// Zero-based segment index.
    public let index: Int
    /// Published audio file for each role.
    public let files: [RecordingTrackRole: URL]
    /// Published manifest for a directory product, or `nil` for a single file.
    public let manifestURL: URL?
    /// Session-global effective range.
    public let effectiveRange: SampleRange
    /// Video boundary for a screen product, or `nil` for audio-only.
    public let videoBoundary: CMTime?
    /// Published audio track index per role.
    public let trackMap: [RecordingTrackRole: Int]
    /// Published screen video URL, or `nil` for audio-only.
    public let videoURL: URL?
    /// Audio track index inside the screen video, or `nil` for audio-only.
    public let videoTrackIndex: Int?
    /// Creates a sealed segment.
    public init(
        segmentID: UUID, index: Int, files: [RecordingTrackRole: URL],
        manifestURL: URL?, effectiveRange: SampleRange, videoBoundary: CMTime? = nil,
        trackMap: [RecordingTrackRole: Int], videoURL: URL? = nil,
        videoTrackIndex: Int? = nil
    ) {
        self.segmentID = segmentID
        self.index = index
        self.files = files
        self.manifestURL = manifestURL
        self.effectiveRange = effectiveRange
        self.videoBoundary = videoBoundary
        self.trackMap = trackMap
        self.videoURL = videoURL
        self.videoTrackIndex = videoTrackIndex
    }
}
/// Failures raised while verifying, sealing, or publishing a segment.
public enum RecordingSealError: Error, Equatable, Sendable {
    /// The context's sample rate, output stem, or destination is invalid.
    case invalidContext
    /// No audio role was active in the segment.
    case noActiveAudio
    /// The coverage roles do not match the requested audio layout.
    case invalidLayout
    /// Coverage, checkpoints, or encoded ranges do not agree.
    case coverageMismatch
    /// Screen video output is owned by Task 17 and is not implemented here.
    case screenVideoUnsupported
    /// Video chunks were supplied but video muxing is not implemented here.
    case videoChunksUnsupported
    /// Another seal or recovery publication is already running.
    case sealInProgress
    /// No embedded Task 8 record was found.
    case metadataMissing
    /// The portable record or its schema is invalid.
    case metadataInvalid
    /// A native passthrough metadata export failed.
    case metadataExportFailed
    /// The metadata destination already exists.
    case metadataDestinationExists
    /// A directory product did not supply a manifest URL.
    case manifestRequired
    /// The manifest is missing or is not a regular file.
    case manifestMissing
    /// The stage is not a real regular file.
    case stagingNotRegularFile
    /// The stage is not a real directory.
    case stagingNotDirectory
    /// A staged file is missing.
    case stagedFileMissing
    /// The candidate's paths or shape are not safe to publish.
    case invalidCandidate
    /// A staged or published file hash does not match the candidate.
    case hashMismatch
    /// The existing final product does not match the candidate identity.
    case existingFinalMismatch
    /// Task 3 returned a URL different from the reserved final URL.
    case publishedURLMismatch
}
private struct SealRolePlan: Sendable {
    let role: RecordingTrackRole
    let channelCount: Int
    let missingRanges: [RecordingSampleRange]
    var expectedSilenceFrames: Int64 { missingRanges.reduce(0) { $0 + $1.sampleCount } }
}
private struct SealPlan: Sendable {
    let segmentIndex: Int
    let segmentStartSample: Int64
    let segmentEndSample: Int64
    let sampleRate: Int
    let isDirectory: Bool
    let roles: [SealRolePlan]
}
private struct EncodedRole: Sendable {
    let role: RecordingTrackRole
    let coverage: RecordingTrackCoverage
    let result: AudioSealResult
    let verification: AudioEncodingVerification
}
/// Seals verified checkpoints into per-role m4a files and publishes atomically.
///
/// The actor enforces one in-flight seal or recovery publication. Capture and
/// checkpoint writers are never held by this gate because they live in
/// different actors and tasks.
public actor RecordingSealService {
    let fileManager: FileManager
    private let publicationHooks: [any SegmentPublicationHooking]
    private let publishOverride: (@Sendable (URL, URL) throws -> URL)?
    private var isPublishing = false
    /// Creates a seal service.
    public init(
        fileManager: FileManager = .default,
        publicationHooks: [any SegmentPublicationHooking] = []
    ) {
        self.init(
            fileManager: fileManager, publicationHooks: publicationHooks, publishOverride: nil
        )
    }
    init(
        fileManager: FileManager = .default,
        publicationHooks: [any SegmentPublicationHooking] = [],
        publishOverride: (@Sendable (URL, URL) throws -> URL)?
    ) {
        self.fileManager = fileManager
        self.publicationHooks = publicationHooks
        self.publishOverride = publishOverride
    }
    /// Seals one segment and publishes it only after every hook succeeds.
    public func seal(
        _ bundle: RecordingSegmentCheckpointBundle, videoChunks: [URL],
        segmentID: UUID, context: RecordingSealContext
    ) async throws -> SealedSegment {
        guard !isPublishing else { throw RecordingSealError.sealInProgress }
        isPublishing = true
        defer { isPublishing = false }
        var destinationIsDirectory: ObjCBool = false
        guard context.sampleRate > 0, !context.outputStem.isEmpty,
              context.destinationDirectory.isFileURL,
              fileManager.fileExists(
                  atPath: context.destinationDirectory.path, isDirectory: &destinationIsDirectory
              ), destinationIsDirectory.boolValue
        else { throw RecordingSealError.invalidContext }
        guard context.kind == .audio else { throw RecordingSealError.screenVideoUnsupported }
        guard videoChunks.isEmpty else { throw RecordingSealError.videoChunksUnsupported }
        let plan = try makePlan(bundle: bundle, context: context)
        try Task.checkCancellation()
        let request = try RecordingOutputRequest(
            destinationDirectory: context.destinationDirectory,
            stem: context.outputStem,
            segmentIndex: plan.segmentIndex,
            shape: plan.isDirectory ? .directory : .singleFile(fileExtension: "m4a")
        )
        let transaction = try RecordingOutputTransaction(request: request, fileManager: fileManager)
        try transaction.prepareForWriting()
        let staged = try await stage(
            plan: plan, bundle: bundle, transaction: transaction,
            segmentID: segmentID, context: context
        )
        try transaction.markWriterFinished()
        for hook in publicationHooks {
            try await hook.beforePublish(staged.candidate)
        }
        try Task.checkCancellation()
        let publishedURL: URL
        if let publishOverride {
            publishedURL = try publishOverride(transaction.partialURL, transaction.finalURL)
        } else {
            publishedURL = try transaction.publish()
        }
        guard publishedURL == transaction.finalURL else {
            throw RecordingSealError.publishedURLMismatch
        }
        return try makeSealedSegment(
            record: staged.record, candidate: staged.candidate, publishedURL: publishedURL
        )
    }
    /// Re-publishes a previously verified stage after a crash.
    public func publishPrepared(
        _ candidate: SegmentPublicationCandidate
    ) async throws -> SealedSegment {
        guard !isPublishing else { throw RecordingSealError.sealInProgress }
        isPublishing = true
        defer { isPublishing = false }
        try validateCandidatePaths(candidate)
        try Task.checkCancellation()
        let record: SegmentPortableRecord
        if fileManager.fileExists(atPath: candidate.reservedFinalURL.path) {
            record = try await verifyProduct(at: candidate.reservedFinalURL, candidate: candidate, isFinal: true)
        } else {
            _ = try await verifyProduct(at: candidate.stagingURL, candidate: candidate, isFinal: false)
            try Task.checkCancellation()
            do {
                if candidate.isDirectory {
                    try AtomicDirectoryOutputPublisher().publish(
                        stagingURL: candidate.stagingURL, finalURL: candidate.reservedFinalURL
                    )
                } else {
                    _ = try AtomicRecordingOutputPublisher().publish(
                        partialURL: candidate.stagingURL, finalURL: candidate.reservedFinalURL
                    )
                }
            } catch RecordingOutputTransactionError.destinationAlreadyExists {
                // A concurrent publisher won the reservation; adopt only after verification below.
            }
            record = try await verifyProduct(at: candidate.reservedFinalURL, candidate: candidate, isFinal: true)
        }
        return try makeSealedSegment(
            record: record, candidate: candidate, publishedURL: candidate.reservedFinalURL
        )
    }
}
extension RecordingSealService {
    private func makePlan(
        bundle: RecordingSegmentCheckpointBundle, context: RecordingSealContext
    ) throws -> SealPlan {
        let coverage = bundle.coverage
        guard coverage.segmentIndex == bundle.checkpoints.segmentIndex,
              coverage.segmentEndSample > coverage.segmentStartSample,
              Set(coverage.tracks.map(\.role)).count == coverage.tracks.count
        else { throw RecordingSealError.coverageMismatch }
        var active: [SealRolePlan] = []
        for track in coverage.tracks {
            let role = try audioRole(from: track.role)
            guard track.sampleRate == context.sampleRate else { throw RecordingSealError.coverageMismatch }
            guard track.wasActive else { continue }
            guard let first = track.firstSample, let last = track.lastSample,
                  first >= coverage.segmentStartSample, last <= coverage.segmentEndSample,
                  first <= last, (1...2).contains(track.channelCount)
            else { throw RecordingSealError.coverageMismatch }
            for range in track.missingRanges {
                guard range.sampleCount >= 0, range.startSample >= coverage.segmentStartSample,
                      range.endSample <= coverage.segmentEndSample
                else { throw RecordingSealError.coverageMismatch }
            }
            active.append(
                SealRolePlan(
                    role: role, channelCount: track.channelCount,
                    missingRanges: track.missingRanges.sorted { $0.startSample < $1.startSample }
                )
            )
        }
        guard !active.isEmpty else { throw RecordingSealError.noActiveAudio }
        let roles = try orderedRoles(active, layout: context.layout)
        return SealPlan(
            segmentIndex: coverage.segmentIndex, segmentStartSample: coverage.segmentStartSample,
            segmentEndSample: coverage.segmentEndSample, sampleRate: context.sampleRate,
            isDirectory: context.layout == .separateTracks, roles: roles
        )
    }
    private func orderedRoles(
        _ active: [SealRolePlan], layout: AudioOutputLayout
    ) throws -> [SealRolePlan] {
        switch layout {
        case .mixed:
            guard active.count == 1, active[0].role == .mixed else {
                throw RecordingSealError.invalidLayout
            }
            return active
        case .separateTracks:
            guard active.allSatisfy({ $0.role != .mixed }) else {
                throw RecordingSealError.invalidLayout
            }
            let roles = [RecordingTrackRole.system, .microphone].compactMap { role in
                active.first { $0.role == role }
            }
            guard roles.count == active.count else { throw RecordingSealError.invalidLayout }
            return roles
        }
    }
    private func stage(
        plan: SealPlan, bundle: RecordingSegmentCheckpointBundle,
        transaction: RecordingOutputTransaction, segmentID: UUID,
        context: RecordingSealContext
    ) async throws -> (record: SegmentPortableRecord, candidate: SegmentPublicationCandidate) {
        var rawFiles: [URL] = []
        let encoded = try await encodeRoles(
            plan: plan, bundle: bundle, transaction: transaction,
            bitRate: context.bitRate, rawFiles: &rawFiles
        )
        let record = makeRecord(
            plan: plan, context: context, encoded: encoded,
            finalFileName: transaction.finalURL.lastPathComponent, segmentID: segmentID
        )
        var stagedFileURLs: [RecordingTrackRole: URL] = [:]
        var manifestURL: URL?
        for item in encoded {
            let destination = plan.isDirectory
                ? transaction.partialURL.appendingPathComponent("\(strings(for: item.role).token).m4a")
                : transaction.partialURL
            try await SegmentPortableMetadata.embed(record, from: item.result.url, to: destination)
            stagedFileURLs[item.role] = destination
        }
        if plan.isDirectory {
            let manifest = transaction.partialURL.appendingPathComponent("manifest.json")
            try writeManifest(record, to: manifest)
            manifestURL = manifest
        }
        try cleanupRawFiles(rawFiles)
        let hashes = try hashStagedFiles(
            record: record, stagedFileURLs: stagedFileURLs, manifestURL: manifestURL,
            stagingURL: transaction.partialURL, isDirectory: plan.isDirectory
        )
        let candidate = SegmentPublicationCandidate(
            segmentID: segmentID, segmentIndex: plan.segmentIndex,
            stagingURL: transaction.partialURL, reservedFinalURL: transaction.finalURL,
            isDirectory: plan.isDirectory, stagedFileURLs: stagedFileURLs,
            contentHashes: hashes, manifestURL: manifestURL,
            effectiveRange: RecordingSampleRange(
                startSample: record.startSample, sampleCount: record.sampleCount
            ),
            coverage: bundle.coverage
        )
        return (record, candidate)
    }
    private func encodeRoles(
        plan: SealPlan, bundle: RecordingSegmentCheckpointBundle,
        transaction: RecordingOutputTransaction, bitRate: Int?, rawFiles: inout [URL]
    ) async throws -> [EncodedRole] {
        var encoded: [EncodedRole] = []
        for rolePlan in plan.roles {
            try Task.checkCancellation()
            let rawURL = rawOutputURL(role: rolePlan.role, plan: plan, transaction: transaction)
            rawFiles.append(rawURL)
            let encoder = try AudioTrackEncoder(
                role: rolePlan.role, sampleRate: plan.sampleRate,
                channelCount: rolePlan.channelCount,
                bitRate: bitRate ?? (rolePlan.channelCount == 1 ? 96_000 : 160_000),
                outputURL: rawURL
            )
            try await encoder.beginSegment(plan.segmentIndex)
            var cursor = plan.segmentStartSample
            for commit in bundle.checkpoints.checkpoints {
                guard commit.trackURLs[rolePlan.role] != nil else { continue }
                let start = commit.range.startSample
                guard start >= cursor else { throw RecordingSealError.coverageMismatch }
                if start > cursor { try await encoder.appendSilence(frames: start - cursor) }
                try await encoder.append(commit)
                cursor = start + commit.range.sampleCount
            }
            if cursor < plan.segmentEndSample {
                try await encoder.appendSilence(frames: plan.segmentEndSample - cursor)
            }
            let result = try await encoder.finish()
            guard let verification = await encoder.verification else {
                throw RecordingSealError.coverageMismatch
            }
            let expected = SampleRange(
                startSample: plan.segmentStartSample,
                sampleCount: plan.segmentEndSample - plan.segmentStartSample
            )
            guard result.effectiveRange == expected,
                  result.insertedSilenceFrames == rolePlan.expectedSilenceFrames
            else { throw RecordingSealError.coverageMismatch }
            guard let track = bundle.coverage.tracks.first(where: {
                $0.role == strings(for: rolePlan.role).role
            }) else { throw RecordingSealError.coverageMismatch }
            encoded.append(
                EncodedRole(role: rolePlan.role, coverage: track, result: result, verification: verification)
            )
        }
        return encoded
    }
    private func makeRecord(
        plan: SealPlan, context: RecordingSealContext, encoded: [EncodedRole],
        finalFileName: String, segmentID: UUID
    ) -> SegmentPortableRecord {
        var tracks: [SegmentPortableRecord.Track] = []
        var missing: Set<RecordingSampleRange> = []
        for item in encoded {
            tracks.append(
                SegmentPortableRecord.Track(
                    role: strings(for: item.role).role, channelCount: item.coverage.channelCount,
                    fileName: plan.isDirectory ? "\(strings(for: item.role).token).m4a" : finalFileName,
                    validRange: RecordingSampleRange(
                        startSample: item.result.effectiveRange.startSample,
                        sampleCount: item.result.effectiveRange.sampleCount
                    ),
                    primingFrames: item.result.primingFrames,
                    remainderFrames: item.result.remainderFrames,
                    insertedSilenceFrames: item.result.insertedSilenceFrames,
                    encodedPacketCount: item.verification.encodedPacketCount,
                    decodedFrameCount: item.verification.decodedFrameCount
                )
            )
            missing.formUnion(item.coverage.missingRanges)
        }
        return SegmentPortableRecord(
            sessionID: context.sessionID, segmentID: segmentID, segmentIndex: plan.segmentIndex,
            kind: "audio", layout: plan.isDirectory ? "separateTracks" : "mixed",
            sampleRate: plan.sampleRate, startSample: plan.segmentStartSample,
            sampleCount: plan.segmentEndSample - plan.segmentStartSample, tracks: tracks,
            missingRanges: missing.sorted { $0.startSample < $1.startSample }
        )
    }
}
extension RecordingSealService {
    private func rawOutputURL(
        role: RecordingTrackRole, plan: SealPlan, transaction: RecordingOutputTransaction
    ) -> URL {
        let directory = plan.isDirectory
            ? transaction.partialURL
            : transaction.partialURL.deletingLastPathComponent()
        return directory.appendingPathComponent(".SnapGlass-\(UUID().uuidString)-\(strings(for: role).token).m4a")
    }
    private func cleanupRawFiles(_ urls: [URL]) throws {
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) } catch {
                throw RecordingSealError.invalidCandidate
            }
        }
    }
    private func writeManifest(_ record: SegmentPortableRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(record).write(to: url, options: .withoutOverwriting)
        } catch { throw RecordingSealError.metadataInvalid }
    }
    private func hashStagedFiles(
        record: SegmentPortableRecord, stagedFileURLs: [RecordingTrackRole: URL],
        manifestURL: URL?, stagingURL: URL, isDirectory: Bool
    ) throws -> [String: String] {
        if isDirectory {
            guard let manifestURL,
                  manifestURL.deletingLastPathComponent().standardizedFileURL
                    == stagingURL.standardizedFileURL
            else { throw RecordingSealError.manifestRequired }
            let expected = Set(record.tracks.map(\.fileName) + [manifestURL.lastPathComponent])
            guard Set(try visibleNames(in: stagingURL)) == expected else {
                throw RecordingSealError.invalidCandidate
            }
            var hashes: [String: String] = [:]
            for name in expected {
                hashes[name] = try hash(of: stagingURL.appendingPathComponent(name))
            }
            return hashes
        }
        guard record.tracks.count == 1, let stagedURL = stagedFileURLs.values.first else {
            throw RecordingSealError.invalidCandidate
        }
        return [record.tracks[0].fileName: try hash(of: stagedURL)]
    }
    private func makeSealedSegment(
        record: SegmentPortableRecord, candidate: SegmentPublicationCandidate,
        publishedURL: URL
    ) throws -> SealedSegment {
        var files: [RecordingTrackRole: URL] = [:]
        var trackMap: [RecordingTrackRole: Int] = [:]
        for (index, track) in record.tracks.enumerated() {
            let role = try audioRole(from: track.role)
            guard files[role] == nil else { throw RecordingSealError.metadataInvalid }
            files[role] = candidate.isDirectory
                ? publishedURL.appendingPathComponent(track.fileName)
                : publishedURL
            trackMap[role] = index
        }
        return SealedSegment(
            segmentID: record.segmentID, index: record.segmentIndex, files: files,
            manifestURL: candidate.isDirectory
                ? publishedURL.appendingPathComponent("manifest.json") : nil,
            effectiveRange: SampleRange(startSample: record.startSample, sampleCount: record.sampleCount),
            trackMap: trackMap, videoURL: record.videoURL, videoTrackIndex: record.videoTrackIndex
        )
    }
}
