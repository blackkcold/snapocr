import AVFoundation
import CryptoKit
import Darwin
import Foundation

extension RecordingSealService {
    func validateCandidatePaths(_ candidate: SegmentPublicationCandidate) throws {
        let staging = candidate.stagingURL.standardizedFileURL
        let final = candidate.reservedFinalURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard candidate.effectiveRange.sampleCount > 0, !candidate.contentHashes.isEmpty,
            !candidate.stagedFileURLs.isEmpty,
            candidate.isDirectory == (candidate.manifestURL != nil),
            staging.path != final.path,
            staging.deletingLastPathComponent().path == final.deletingLastPathComponent().path,
            fileManager.fileExists(
                atPath: final.deletingLastPathComponent().path, isDirectory: &isDirectory
            ), isDirectory.boolValue
        else { throw RecordingSealError.invalidCandidate }
        if candidate.isDirectory {
            guard Set(candidate.stagedFileURLs.keys).isSubset(of: [.system, .microphone]),
                let manifest = candidate.manifestURL?.standardizedFileURL,
                manifest.deletingLastPathComponent().path == staging.path
            else { throw RecordingSealError.invalidCandidate }
            for url in candidate.stagedFileURLs.values {
                guard url.standardizedFileURL.deletingLastPathComponent().path == staging.path else {
                    throw RecordingSealError.invalidCandidate
                }
            }
        } else {
            guard Set(candidate.stagedFileURLs.keys) == [.mixed] else {
                throw RecordingSealError.invalidCandidate
            }
            guard Set(candidate.contentHashes.keys) == [final.lastPathComponent] else {
                throw RecordingSealError.invalidCandidate
            }
            for url in candidate.stagedFileURLs.values {
                guard url.standardizedFileURL.path == staging.path else {
                    throw RecordingSealError.invalidCandidate
                }
            }
        }
    }
    func verifyProduct(
        at productURL: URL, candidate: SegmentPublicationCandidate, isFinal: Bool
    ) async throws -> SegmentPortableRecord {
        if candidate.isDirectory {
            return try await verifyDirectoryProduct(at: productURL, candidate: candidate, isFinal: isFinal)
        }
        return try await verifySingleProduct(at: productURL, candidate: candidate, isFinal: isFinal)
    }
    private func verifyDirectoryProduct(
        at productURL: URL, candidate: SegmentPublicationCandidate, isFinal: Bool
    ) async throws -> SegmentPortableRecord {
        guard isRealDirectory(productURL) else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.stagingNotDirectory
        }
        let manifestURL = productURL.appendingPathComponent("manifest.json")
        guard isRealRegularFile(manifestURL) else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.manifestMissing
        }
        let record = try readManifest(manifestURL)
        try verifyRecord(record, candidate: candidate)
        let names = Set(record.tracks.map(\.fileName) + ["manifest.json"])
        guard Set(candidate.contentHashes.keys) == names else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.invalidCandidate
        }
        guard Set(try visibleNames(in: productURL)) == names else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.invalidCandidate
        }
        for name in names {
            let url = productURL.appendingPathComponent(name)
            guard isRealRegularFile(url) else {
                throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.stagedFileMissing
            }
            guard try hash(of: url) == candidate.contentHashes[name] else {
                throw RecordingSealError.hashMismatch
            }
        }
        return record
    }
    private func verifySingleProduct(
        at productURL: URL, candidate: SegmentPublicationCandidate, isFinal: Bool
    ) async throws -> SegmentPortableRecord {
        guard isRealRegularFile(productURL) else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.stagingNotRegularFile
        }
        let record = try await SegmentPortableMetadata.read(from: productURL)
        try verifyRecord(record, candidate: candidate)
        let expectedName: String
        if isFinal {
            expectedName = productURL.lastPathComponent
        } else {
            guard candidate.contentHashes.count == 1, let key = candidate.contentHashes.keys.first else {
                throw RecordingSealError.invalidCandidate
            }
            expectedName = key
        }
        guard record.tracks.count == 1, record.tracks[0].fileName == expectedName else {
            throw isFinal ? RecordingSealError.existingFinalMismatch : RecordingSealError.metadataInvalid
        }
        guard let hashValue = candidate.contentHashes[expectedName],
            try hash(of: productURL) == hashValue
        else { throw RecordingSealError.hashMismatch }
        return record
    }
    private func verifyRecord(
        _ record: SegmentPortableRecord, candidate: SegmentPublicationCandidate
    ) throws {
        guard record.schemaVersion == SegmentPortableRecord.currentSchemaVersion,
            record.segmentID == candidate.segmentID,
            record.segmentIndex == candidate.segmentIndex, record.kind == "audio",
            record.startSample == candidate.effectiveRange.startSample,
            record.sampleCount == candidate.effectiveRange.sampleCount,
            record.sampleCount > 0
        else { throw RecordingSealError.metadataInvalid }
        let coverage = candidate.coverage
        guard coverage.segmentIndex == candidate.segmentIndex,
            coverage.segmentStartSample == record.startSample,
            coverage.segmentEndSample == record.startSample + record.sampleCount,
            Set(coverage.tracks.map(\.role)).count == coverage.tracks.count
        else { throw RecordingSealError.coverageMismatch }
        var coverageByRole: [RecordingTrackRole: RecordingTrackCoverage] = [:]
        for track in coverage.tracks { coverageByRole[try audioRole(from: track.role)] = track }
        let active = coverage.tracks.filter(\.wasActive)
        guard coverageByRole.count == coverage.tracks.count, active.count == record.tracks.count else {
            throw RecordingSealError.coverageMismatch
        }
        var recordRoles: Set<RecordingTrackRole> = []
        for track in record.tracks {
            let role = try audioRole(from: track.role)
            guard recordRoles.insert(role).inserted, let roleCoverage = coverageByRole[role],
                roleCoverage.wasActive, roleCoverage.channelCount == track.channelCount,
                roleCoverage.sampleRate == record.sampleRate,
                track.validRange
                    == RecordingSampleRange(
                        startSample: record.startSample, sampleCount: record.sampleCount
                    ),
                track.primingFrames >= 0, track.remainderFrames >= 0,
                track.insertedSilenceFrames >= 0, track.encodedPacketCount > 0,
                track.decodedFrameCount == record.sampleCount
            else { throw RecordingSealError.metadataInvalid }
        }
        guard recordRoles == Set(candidate.stagedFileURLs.keys),
            Set(record.missingRanges) == Set(active.flatMap(\.missingRanges)),
            record.videoURL == nil, record.videoTrackIndex == nil
        else { throw RecordingSealError.metadataInvalid }
        switch record.layout {
        case "mixed":
            guard recordRoles == [.mixed] else { throw RecordingSealError.invalidLayout }
        case "separateTracks":
            guard recordRoles.isSubset(of: [.system, .microphone]) else {
                throw RecordingSealError.invalidLayout
            }
        default: throw RecordingSealError.metadataInvalid
        }
    }
    private func readManifest(_ url: URL) throws -> SegmentPortableRecord {
        do {
            return try JSONDecoder().decode(SegmentPortableRecord.self, from: Data(contentsOf: url))
        } catch { throw RecordingSealError.metadataInvalid }
    }
    func visibleNames(in directory: URL) throws -> [String] {
        do {
            return try fileManager.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }.sorted()
        } catch { throw RecordingSealError.stagingNotDirectory }
    }
    func hash(of url: URL) throws -> String {
        do { return try Self.sha256(of: url) } catch { throw RecordingSealError.stagedFileMissing }
    }
    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func isRealRegularFile(_ url: URL) -> Bool {
        lstatStatus(url).map { $0.st_mode & S_IFMT == S_IFREG } ?? false
    }
    private func isRealDirectory(_ url: URL) -> Bool {
        lstatStatus(url).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
    }
    private func lstatStatus(_ url: URL) -> stat? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        return result == 0 ? status : nil
    }
    func strings(for role: RecordingTrackRole) -> (role: String, token: String) {
        switch role {
        case .mixed: ("mixed", "mixed")
        case .system: ("system", "system")
        case .microphone: ("microphone", "mic")
        }
    }
    func audioRole(from string: String) throws -> RecordingTrackRole {
        switch string {
        case "mixed": .mixed
        case "system": .system
        case "microphone": .microphone
        default: throw RecordingSealError.metadataInvalid
        }
    }
}
