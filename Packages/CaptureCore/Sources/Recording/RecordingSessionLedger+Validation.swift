import Foundation

/// Inputs shared by the per-file checks of a published segment.
struct PublishedFileValidation {
    let intent: RecordingPublishIntent
    let outputRoot: URL
    let verifyFiles: Bool
    let allowMissingFiles: Bool
}

extension RecordingSessionLedger {
    // MARK: Screen checkpoints

    func validateScreenCheckpoint(_ checkpoint: ScreenCheckpointRecord, allowMissing: Bool) throws {
        try Self.validateScreenCheckpoint(
            checkpoint, root: sessionRoot, fileManager: fileManager.value, allowMissing: allowMissing
        )
    }

    static func validateScreenCheckpoint(
        _ checkpoint: ScreenCheckpointRecord,
        root: URL,
        fileManager: FileManager,
        allowMissing: Bool
    ) throws {
        do {
            let videoPath = try RecordingLedgerFileSystem.validateChild(
                checkpoint.videoURL, under: root, allowingMissing: allowMissing
            )
            guard let expectedVideoHash = checkpoint.contentHashes[videoPath],
                  expectedVideoHash.count == 64,
                  expectedVideoHash.allSatisfy(\.isHexDigit)
            else { throw RecordingSessionLedgerError.invalidCheckpoint }

            var referencedPaths: Set<String> = [videoPath]
            if let audio = checkpoint.audioCheckpoint {
                guard audio.segmentIndex == checkpoint.segmentIndex,
                      audio.startSample >= 0, audio.sampleCount > 0,
                      !audio.trackFiles.isEmpty
                else { throw RecordingSessionLedgerError.invalidCheckpoint }
                for path in audio.trackFiles.values {
                    try RecordingLedgerFileSystem.validateRelativePath(path)
                    let url = try RecordingLedgerFileSystem.resolve(path, under: root, allowingMissing: allowMissing)
                    let relative = try RecordingLedgerFileSystem.validateChild(
                        url, under: root, allowingMissing: allowMissing
                    )
                    referencedPaths.insert(relative)
                }
            }
            guard referencedPaths == Set(checkpoint.contentHashes.keys) else {
                throw RecordingSessionLedgerError.invalidCheckpoint
            }
            for (relativePath, expectedHash) in checkpoint.contentHashes {
                try Self.validateScreenCheckpointFile(
                    relativePath, expectedHash: expectedHash,
                    root: root, fileManager: fileManager, allowMissing: allowMissing
                )
            }
        } catch let error as RecordingSessionLedgerError {
            throw error
        } catch {
            throw Self.mapPathError(error)
        }
    }

    private static func validateScreenCheckpointFile(
        _ relativePath: String,
        expectedHash: String,
        root: URL,
        fileManager: FileManager,
        allowMissing: Bool
    ) throws {
        try RecordingLedgerFileSystem.validateRelativePath(relativePath)
        guard expectedHash.count == 64, expectedHash.allSatisfy(\.isHexDigit) else {
            throw RecordingSessionLedgerError.invalidCheckpoint
        }
        let url = try RecordingLedgerFileSystem.resolve(
            relativePath, under: root, allowingMissing: allowMissing
        )
        if RecordingLedgerFileSystem.isRegularFile(url) {
            guard try RecordingLedgerFileSystem.sha256(of: url) == expectedHash else {
                throw RecordingSessionLedgerError.journalCorrupt
            }
        } else if !allowMissing || fileManager.fileExists(atPath: url.path) {
            throw RecordingSessionLedgerError.invalidCheckpoint
        }
    }

    // MARK: Publish intents

    func validate(_ intent: RecordingPublishIntent) throws {
        try Self.validateIntent(intent, fileManager: fileManager.value, replay: false)
    }

    static func validateIntent(
        _ intent: RecordingPublishIntent,
        fileManager: FileManager,
        replay: Bool
    ) throws {
        guard intent.segmentIndex >= 0, intent.effectiveRange.startSample >= 0,
              intent.effectiveRange.sampleCount > 0, intent.coverage.segmentIndex == intent.segmentIndex,
              intent.coverage.segmentStartSample == intent.effectiveRange.startSample,
              intent.coverage.segmentEndSample == intent.effectiveRange.endSample,
              !intent.contentHashes.isEmpty, intent.stagingURL.isFileURL, intent.reservedFinalURL.isFileURL,
              intent.stagingURL.standardizedFileURL.path != intent.reservedFinalURL.standardizedFileURL.path,
              intent.stagingURL.deletingLastPathComponent().standardizedFileURL
                == intent.reservedFinalURL.deletingLastPathComponent().standardizedFileURL
        else { throw RecordingSessionLedgerError.invalidPublication }
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(intent.stagingURL.deletingLastPathComponent())
            try RecordingLedgerFileSystem.validateNoSymlink(intent.stagingURL, allowingMissing: replay)
            try RecordingLedgerFileSystem.validateNoSymlink(intent.reservedFinalURL, allowingMissing: true)
            for (name, hash) in intent.contentHashes {
                try RecordingLedgerFileSystem.validateRelativePath(name)
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
            }
            guard intent.isDirectory || intent.contentHashes.count == 1,
                  intent.isDirectory || intent.contentHashes[intent.reservedFinalURL.lastPathComponent] != nil
            else { throw RecordingSessionLedgerError.invalidPublication }

            let stageExists = fileManager.fileExists(atPath: intent.stagingURL.path)
            let finalExists = fileManager.fileExists(atPath: intent.reservedFinalURL.path)
            if stageExists {
                try verifyIntentProduct(intent, at: intent.stagingURL, fileManager: fileManager)
            } else if !replay {
                throw RecordingSessionLedgerError.invalidPublication
            }
            if finalExists {
                try verifyIntentProduct(intent, at: intent.reservedFinalURL, fileManager: fileManager)
            } else if !replay && !stageExists {
                throw RecordingSessionLedgerError.invalidPublication
            }
        } catch { throw Self.mapPathError(error) }
    }

    private static func verifyIntentProduct(
        _ intent: RecordingPublishIntent,
        at productURL: URL,
        fileManager: FileManager
    ) throws {
        if intent.isDirectory {
            guard RecordingLedgerFileSystem.isDirectory(productURL) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            let visible = try fileManager.contentsOfDirectory(atPath: productURL.path)
                .filter { !$0.hasPrefix(".") }
            guard Set(visible) == Set(intent.contentHashes.keys) else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            for (name, expected) in intent.contentHashes {
                let file = try RecordingLedgerFileSystem.resolve(name, under: productURL)
                guard RecordingLedgerFileSystem.isRegularFile(file),
                      try RecordingLedgerFileSystem.sha256(of: file) == expected
                else { throw RecordingSessionLedgerError.invalidPublication }
            }
        } else {
            guard RecordingLedgerFileSystem.isRegularFile(productURL),
                  let expected = intent.contentHashes[intent.reservedFinalURL.lastPathComponent],
                  try RecordingLedgerFileSystem.sha256(of: productURL) == expected
            else { throw RecordingSessionLedgerError.invalidPublication }
        }
    }

    // MARK: Published segments

    func validate(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool = true
    ) throws {
        try Self.validatePublishedSegment(segment, against: intent, verifyFiles: verifyFiles)
    }

    static func validatePublishedSegment(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool = true,
        allowMissingFiles: Bool = false
    ) throws {
        try validatePublishedShape(segment, against: intent)
        try validatePublishedVideo(
            segment, against: intent, verifyFiles: verifyFiles, allowMissingFiles: allowMissingFiles
        )
        try validatePublishedFileMap(
            segment, against: intent, verifyFiles: verifyFiles, allowMissingFiles: allowMissingFiles
        )
    }

    private static func validatePublishedShape(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent
    ) throws {
        guard segment.id == intent.segmentID, segment.index == intent.segmentIndex,
              segment.startSample == intent.effectiveRange.startSample,
              segment.sampleCount == intent.effectiveRange.sampleCount,
              segment.state == .published,
              segment.videoURL != nil || !segment.files.isEmpty,
              Set(segment.files.keys).isSubset(of: ["mixed", "system", "microphone"]),
              Set(segment.trackMap.keys) == Set(segment.files.keys)
        else { throw RecordingSessionLedgerError.invalidPublication }
    }

    private static func validatePublishedVideo(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool,
        allowMissingFiles: Bool
    ) throws {
        guard let videoURL = segment.videoURL else {
            guard segment.videoTrackIndex == nil else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            return
        }
        guard !intent.isDirectory,
              videoURL.standardizedFileURL == intent.reservedFinalURL.standardizedFileURL,
              let videoTrackIndex = segment.videoTrackIndex, videoTrackIndex >= 0,
              segment.files.values.allSatisfy({
                  URL(fileURLWithPath: $0).lastPathComponent == videoURL.lastPathComponent
              })
        else { throw RecordingSessionLedgerError.invalidPublication }
        guard verifyFiles else { return }
        try validatePublishedVideoHash(videoURL, against: intent, allowMissingFiles: allowMissingFiles)
    }

    private static func validatePublishedVideoHash(
        _ videoURL: URL,
        against intent: RecordingPublishIntent,
        allowMissingFiles: Bool
    ) throws {
        guard let expectedHash = intent.contentHashes[intent.reservedFinalURL.lastPathComponent] else {
            throw RecordingSessionLedgerError.invalidPublication
        }
        let videoHashMatches: Bool
        if allowMissingFiles && !RecordingLedgerFileSystem.isRegularFile(videoURL) {
            videoHashMatches = true
        } else {
            videoHashMatches = try RecordingLedgerFileSystem.sha256(of: videoURL) == expectedHash
        }
        guard videoHashMatches else { throw RecordingSessionLedgerError.invalidPublication }
    }

    private static func validatePublishedFileMap(
        _ segment: PublishedSegment,
        against intent: RecordingPublishIntent,
        verifyFiles: Bool,
        allowMissingFiles: Bool
    ) throws {
        let context = PublishedFileValidation(
            intent: intent,
            outputRoot: intent.reservedFinalURL.deletingLastPathComponent(),
            verifyFiles: verifyFiles,
            allowMissingFiles: allowMissingFiles
        )
        var seen: Set<String> = []
        for relative in segment.files.values {
            try validatePublishedFile(relative, context: context, seen: &seen)
        }
    }

    private static func validatePublishedFile(
        _ relative: String,
        context: PublishedFileValidation,
        seen: inout Set<String>
    ) throws {
        do {
            try RecordingLedgerFileSystem.validateRelativePath(relative)
            let resolved = try RecordingLedgerFileSystem.resolve(
                relative,
                under: context.outputRoot,
                allowingMissing: context.allowMissingFiles
            )
            let fileName = URL(fileURLWithPath: relative).lastPathComponent
            let expected = context.intent.isDirectory
                ? context.intent.reservedFinalURL.appendingPathComponent(fileName)
                : context.intent.reservedFinalURL
            guard resolved.standardizedFileURL == expected.standardizedFileURL,
                  seen.insert(relative).inserted
            else { throw RecordingSessionLedgerError.invalidPublication }
            guard context.verifyFiles else { return }
            try validatePublishedFileHash(resolved, context: context)
        } catch { throw mapPathError(error) }
    }

    private static func validatePublishedFileHash(
        _ resolved: URL,
        context: PublishedFileValidation
    ) throws {
        guard RecordingLedgerFileSystem.isRegularFile(resolved) else {
            if !context.allowMissingFiles || RecordingLedgerFileSystem.mode(at: resolved) != nil {
                throw RecordingSessionLedgerError.invalidPublication
            }
            return
        }
        let expectedHash = context.intent.isDirectory
            ? context.intent.contentHashes[resolved.lastPathComponent]
            : context.intent.contentHashes[context.intent.reservedFinalURL.lastPathComponent]
        guard let expectedHash,
              try RecordingLedgerFileSystem.sha256(of: resolved) == expectedHash else {
            throw RecordingSessionLedgerError.invalidPublication
        }
    }

    // MARK: Adopted segments

    /// Validates an adopted segment: media must live inside the session root.
    static func validateAdoptedSegment(_ segment: PublishedSegment, sessionRoot: URL) throws {
        guard segment.state == .published, segment.index >= 0,
              segment.startSample >= 0, segment.sampleCount > 0,
              (segment.videoURL == nil) == (segment.videoTrackIndex == nil),
              segment.materialURL != nil || segment.videoURL != nil,
              !segment.files.isEmpty || segment.videoURL != nil,
              Set(segment.files.keys).isSubset(of: ["mixed", "system", "microphone"]),
              Set(segment.trackMap.keys) == Set(segment.files.keys)
        else { throw RecordingSessionLedgerError.invalidPublication }
        do {
            for relative in segment.files.values {
                try RecordingLedgerFileSystem.validateRelativePath(relative)
                let url = try RecordingLedgerFileSystem.resolve(relative, under: sessionRoot)
                guard RecordingLedgerFileSystem.isRegularFile(url) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
            }
            if let materialURL = segment.materialURL {
                let relative = try RecordingLedgerFileSystem.validateChild(materialURL, under: sessionRoot)
                guard segment.files.values.contains(relative) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
            }
            if let videoURL = segment.videoURL {
                _ = try RecordingLedgerFileSystem.validateChild(videoURL, under: sessionRoot)
                guard RecordingLedgerFileSystem.isRegularFile(videoURL) else {
                    throw RecordingSessionLedgerError.invalidPublication
                }
            }
        } catch let error as RecordingSessionLedgerError {
            throw error
        } catch {
            throw Self.mapPathError(error)
        }
    }

    /// Resolves the media of an adopted segment, newest file first per track role.
    static func adoptedMaterialURLs(_ segment: PublishedSegment, sessionRoot: URL) throws -> [URL] {
        let ordered = RecordingCheckpointWriter.roleOrder.compactMap { role -> URL? in
            let name = roleName(role)
            guard let relative = segment.files[name] else { return nil }
            return try? RecordingLedgerFileSystem.resolve(relative, under: sessionRoot)
        }
        if ordered.isEmpty, let materialURL = segment.materialURL {
            return (try? RecordingLedgerFileSystem.validateChild(materialURL, under: sessionRoot))
                .map { _ in [materialURL] } ?? []
        }
        return ordered
    }
}
