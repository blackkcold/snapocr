import Foundation
import Testing

@testable import CaptureCore

struct RecordingOutputTransactionTests {
    @Test func createsHiddenPartialInsideTheDestinationDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transaction = try makeTransaction(in: directory)

        let partialDirectory = transaction.partialURL
            .deletingLastPathComponent()
            .standardizedFileURL
        #expect(partialDirectory.path == directory.standardizedFileURL.path)
        #expect(transaction.partialURL.lastPathComponent.hasPrefix("."))
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
        #expect(transaction.finalURL.lastPathComponent.range(
            of: #"^SnapGlass_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.mp4$"#,
            options: .regularExpression
        ) != nil)
    }

    @Test func discardRemovesAReservedPartialAfterStartFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = try makeTransaction(in: directory)
        let partialURL = transaction.partialURL

        try transaction.discardPartial()

        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
    }

    @Test func discardRemovesNonemptyHeaderOnlyPartialAndBlocksPublication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = try makeTransaction(in: directory)
        try transaction.prepareForWriting()
        try Data("MP4 header without an accepted video frame".utf8).write(to: transaction.partialURL)

        try transaction.discardPartial()

        #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
        #expect(captureTransactionError { try transaction.markWriterFinished() } == .invalidState)
        #expect(captureTransactionError { _ = try transaction.publish() } == .writerNotFinished)
    }

    @Test func addsNumericCollisionSuffixWithoutOverwritingAnExistingRecording() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeTransaction(in: directory)
        let preservedData = Data("existing recording".utf8)
        try preservedData.write(to: first.finalURL)

        let second = try makeTransaction(in: directory)

        #expect(second.finalURL != first.finalURL)
        #expect(second.finalURL.lastPathComponent.range(
            of: #"^SnapGlass_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_2\.mp4$"#,
            options: .regularExpression
        ) != nil)
        #expect(try Data(contentsOf: first.finalURL) == preservedData)
    }

    @Test func publishesOnlyAfterWriterFinishAndThenRemovesThePartial() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var publicationAttempts = 0
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { sourceURL, destinationURL in
                publicationAttempts += 1
                do {
                    try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
                    return .succeeded
                } catch {
                    return .failed
                }
            },
            exclusiveRenameSupported: { _ in false },
            exclusiveRenameOperation: { _, _ in .failed }
        )
        let transaction = try makeTransaction(in: directory, publisher: publisher)
        try transaction.prepareForWriting()
        let writerData = Data("finished media".utf8)
        try writerData.write(to: transaction.partialURL)

        #expect(throws: RecordingOutputTransactionError.self) {
            try transaction.publish()
        }
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))

        try transaction.markWriterFinished()
        let publishedURL = try transaction.publish()

        #expect(publishedURL == transaction.finalURL)
        #expect(try Data(contentsOf: publishedURL) == writerData)
        #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(captureTransactionError { _ = try transaction.publish() } == .writerNotFinished)
        #expect(publicationAttempts == 1)
    }

    @Test func failedPublicationRetainsThePartialAndExistingDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transaction = try makeTransaction(in: directory)
        try transaction.prepareForWriting()
        let partialData = Data("recoverable partial".utf8)
        try partialData.write(to: transaction.partialURL)
        let existingData = Data("do not overwrite".utf8)
        try existingData.write(to: transaction.finalURL)
        try transaction.markWriterFinished()

        #expect(throws: RecordingOutputTransactionError.self) {
            try transaction.publish()
        }

        #expect(try Data(contentsOf: transaction.partialURL) == partialData)
        #expect(try Data(contentsOf: transaction.finalURL) == existingData)
    }

    @Test func publisherFallsBackToExclusiveRenameAfterHardLinkFailure() throws {
        var operations: [String] = []
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in
                operations.append("hard-link")
                return .unsupported
            },
            exclusiveRenameSupported: { _ in
                operations.append("capability-check")
                return true
            },
            exclusiveRenameOperation: { _, _ in
                operations.append("exclusive-rename")
                return .succeeded
            }
        )

        let method = try publisher.publish(
            partialURL: URL(fileURLWithPath: "/recordings/partial.mp4"),
            finalURL: URL(fileURLWithPath: "/recordings/final.mp4")
        )

        #expect(method == .exclusiveRename)
        #expect(operations == ["hard-link", "capability-check", "exclusive-rename"])
    }

    @Test func publisherFailsClosedWhenNeitherAtomicOperationIsSupported() {
        var renameAttempted = false
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .unsupported },
            exclusiveRenameSupported: { _ in false },
            exclusiveRenameOperation: { _, _ in
                renameAttempted = true
                return .succeeded
            }
        )

        let error = captureTransactionError {
            _ = try publisher.publish(
                partialURL: URL(fileURLWithPath: "/recordings/partial.mp4"),
                finalURL: URL(fileURLWithPath: "/recordings/final.mp4")
            )
        }

        #expect(error == .unsupportedDestination)
        #expect(!renameAttempted)
    }

    @Test func publisherFailsClosedWhenExclusiveRenameRejectsTheOperation() {
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .unsupported },
            exclusiveRenameSupported: { _ in true },
            exclusiveRenameOperation: { _, _ in .unsupported }
        )

        let error = captureTransactionError {
            _ = try publisher.publish(
                partialURL: URL(fileURLWithPath: "/recordings/partial.mp4"),
                finalURL: URL(fileURLWithPath: "/recordings/final.mp4")
            )
        }

        #expect(error == .unsupportedDestination)
    }

    @Test func publisherDoesNotAttemptRenameWhenFinalNameAlreadyExists() {
        var renameAttempted = false
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .destinationExists },
            exclusiveRenameSupported: { _ in true },
            exclusiveRenameOperation: { _, _ in
                renameAttempted = true
                return .succeeded
            }
        )

        let error = captureTransactionError {
            _ = try publisher.publish(
                partialURL: URL(fileURLWithPath: "/recordings/partial.mp4"),
                finalURL: URL(fileURLWithPath: "/recordings/final.mp4")
            )
        }

        #expect(error == .destinationAlreadyExists)
        #expect(!renameAttempted)
    }

    @Test func transactionFailsClosedAndRetainsPartialWhenAtomicPublicationIsUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .unsupported },
            exclusiveRenameSupported: { _ in false },
            exclusiveRenameOperation: { _, _ in .unsupported }
        )
        let transaction = try makeTransaction(in: directory, publisher: publisher)
        try transaction.prepareForWriting()
        let partialData = Data("finished recording".utf8)
        try partialData.write(to: transaction.partialURL)
        try transaction.markWriterFinished()

        let error = captureTransactionError { _ = try transaction.publish() }

        #expect(error == .unsupportedDestination)
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
        #expect(try Data(contentsOf: transaction.partialURL) == partialData)
    }

    @Test func transactionPublishesByExclusiveRenameWhenHardLinksAreUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .unsupported },
            exclusiveRenameSupported: { _ in true }
        )
        let transaction = try makeTransaction(in: directory, publisher: publisher)
        try transaction.prepareForWriting()
        let recordingData = Data("exclusive rename recording".utf8)
        try recordingData.write(to: transaction.partialURL)
        try transaction.markWriterFinished()

        let publishedURL = try transaction.publish()

        #expect(publishedURL == transaction.finalURL)
        #expect(try Data(contentsOf: publishedURL) == recordingData)
        #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
    }

    @Test func exclusiveRenameCollisionDoesNotOverwriteExistingRecording() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in .unsupported },
            exclusiveRenameSupported: { _ in true }
        )
        let transaction = try makeTransaction(in: directory, publisher: publisher)
        try transaction.prepareForWriting()
        let partialData = Data("finished recording".utf8)
        try partialData.write(to: transaction.partialURL)
        let existingData = Data("do not overwrite".utf8)
        try existingData.write(to: transaction.finalURL)
        try transaction.markWriterFinished()

        let error = captureTransactionError { _ = try transaction.publish() }

        #expect(error == .destinationAlreadyExists)
        #expect(try Data(contentsOf: transaction.partialURL) == partialData)
        #expect(try Data(contentsOf: transaction.finalURL) == existingData)
    }

    @Test func exclusiveCreateRetriesUUIDCollisionWithoutReplacingExistingPartial() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collidedID = UUID()
        let nextID = UUID()
        let existingPartial = directory.appendingPathComponent(".SnapGlass-\(collidedID.uuidString).mp4.partial")
        let existingData = Data("another transaction".utf8)
        try existingData.write(to: existingPartial)
        var identifiers = [collidedID, nextID]
        let transaction = try makeTransaction(in: directory, identifierProvider: {
            identifiers.removeFirst()
        })

        #expect(transaction.partialURL.lastPathComponent == ".SnapGlass-\(nextID.uuidString).mp4.partial")
        #expect(try Data(contentsOf: existingPartial) == existingData)
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
    }

    @Test func transactionsReserveDifferentPartialPathsForTheSameTimestamp() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeTransaction(in: directory)
        let second = try makeTransaction(in: directory)

        #expect(first.partialURL != second.partialURL)
        #expect(first.finalURL == second.finalURL)
    }

}

extension RecordingOutputTransactionTests {
    @Test func segmentedSingleFileStartsWith00AndUsesExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = "Audio_2027-01-15_10-30-00"

        let first = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: 0, shape: .singleFile(fileExtension: "M4A"), in: directory)
        )
        let second = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: 1, in: directory)
        )
        let hundredth = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: 100, in: directory)
        )

        #expect(first.finalURL.lastPathComponent == "\(stem)-00.m4a")
        #expect(second.finalURL.lastPathComponent == "\(stem)-01.m4a")
        #expect(hundredth.finalURL.lastPathComponent == "\(stem)-100.m4a")
        #expect(first.partialURL.lastPathComponent.hasPrefix(".SnapGlass-"))
        #expect(first.partialURL.lastPathComponent.hasSuffix(".m4a.partial"))
        #expect(first.partialURL.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path)
        #expect(!first.isDirectoryOutput)
    }

    @Test func segmentedSingleFileDoesNotTruncateSegmentIndexesBeyondInt32() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = "Audio_2027-01-15_10-30-00"
        let beyondInt32 = Int(Int32.max) + 1

        let beyond = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: beyondInt32, in: directory)
        )
        let maximum = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: Int.max, in: directory)
        )

        #expect(beyond.finalURL.lastPathComponent == "\(stem)-\(beyondInt32).m4a")
        #expect(beyond.finalURL.lastPathComponent.hasPrefix("\(stem)-2147483648"))
        #expect(maximum.finalURL.lastPathComponent == "\(stem)-\(Int.max).m4a")
        #expect(beyond.partialURL.lastPathComponent.hasPrefix(".SnapGlass-"))
    }

    @Test func segmentedSingleFileCollisionUsesSuffixAfterSegment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = "Audio_2027-01-15_10-30-00"
        let existingURL = directory.appendingPathComponent("\(stem)-00.m4a")
        let preservedData = Data("existing segment".utf8)
        try preservedData.write(to: existingURL)

        let transaction = try makeRequestTransaction(
            try makeRequest(stem: stem, segmentIndex: 0, in: directory)
        )

        #expect(transaction.finalURL.lastPathComponent == "\(stem)-00_2.m4a")
        #expect(try Data(contentsOf: existingURL) == preservedData)
    }

    @Test func requestRejectsNegativeSegmentIndex() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())

        #expect(throws: RecordingOutputRequestError.negativeSegmentIndex) {
            _ = try RecordingOutputRequest(
                destinationDirectory: directory,
                stem: "Audio_2027-01-15_10-30-00",
                segmentIndex: -1,
                shape: .singleFile(fileExtension: "m4a")
            )
        }
        #expect(throws: RecordingOutputRequestError.negativeSegmentIndex) {
            _ = try RecordingOutputRequest(
                destinationDirectory: directory,
                stem: "Audio_2027-01-15_10-30-00",
                segmentIndex: Int.min,
                shape: .directory
            )
        }
    }

    @Test func requestRejectsPathEscapingStemAndExtension() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())

        #expect(throws: RecordingOutputRequestError.emptyStem) {
            _ = try RecordingOutputRequest(
                destinationDirectory: directory,
                stem: "",
                segmentIndex: 0,
                shape: .singleFile(fileExtension: "m4a")
            )
        }
        for stem in ["../x", "a/b", "a\\b", "..", ".", ".hidden", "a\0b"] {
            #expect(throws: RecordingOutputRequestError.invalidStem) {
                _ = try RecordingOutputRequest(
                    destinationDirectory: directory,
                    stem: stem,
                    segmentIndex: 0,
                    shape: .singleFile(fileExtension: "m4a")
                )
            }
        }
        for fileExtension in [".m4a", "", "m4a.", "m/4", "m\\4", "m4a ", "m 4"] {
            #expect(throws: RecordingOutputRequestError.invalidFileExtension) {
                _ = try RecordingOutputRequest(
                    destinationDirectory: directory,
                    stem: "Audio_2027-01-15_10-30-00",
                    segmentIndex: 0,
                    shape: .singleFile(fileExtension: fileExtension)
                )
            }
        }

        let normalized = try? RecordingOutputRequest(
            destinationDirectory: directory,
            stem: "Audio_2027-01-15_10-30-00",
            segmentIndex: 0,
            shape: .singleFile(fileExtension: "M4A")
        )
        #expect(normalized?.shape == .singleFile(fileExtension: "m4a"))
    }

    @Test func directoryOutputUsesHiddenSameParentStaging() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = "Audio_2027-01-15_10-30-00"

        let transaction = try makeDirectoryTransaction(stem: stem, in: directory)
        var stagingIsDirectory: ObjCBool = false

        #expect(transaction.isDirectoryOutput)
        #expect(transaction.partialURL.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path)
        #expect(transaction.partialURL.lastPathComponent.hasPrefix("."))
        #expect(transaction.partialURL.lastPathComponent.hasSuffix(".staging"))
        #expect(FileManager.default.fileExists(
            atPath: transaction.partialURL.path,
            isDirectory: &stagingIsDirectory
        ))
        #expect(stagingIsDirectory.boolValue)
        #expect(transaction.finalURL.lastPathComponent == "\(stem)-00")
        #expect(transaction.finalURL.pathExtension.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))

        try transaction.prepareForWriting()
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))

        try FileManager.default.removeItem(at: transaction.partialURL)
        #expect(captureTransactionError { try transaction.markWriterFinished() } == .partialFileMissing)
    }

    @Test func directoryPublishIsAtomicRenameAndDoesNotOverwrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = "Audio_2027-01-15_10-30-00"
        let existingFinal = directory.appendingPathComponent("\(stem)-00", isDirectory: true)
        try FileManager.default.createDirectory(at: existingFinal, withIntermediateDirectories: false)
        let existingData = Data("existing segment manifest".utf8)
        try existingData.write(to: existingFinal.appendingPathComponent("manifest.json"))

        let transaction = try makeDirectoryTransaction(stem: stem, in: directory)

        #expect(transaction.finalURL.lastPathComponent == "\(stem)-00_2")

        try transaction.prepareForWriting()
        let stagedData = Data("staged segment manifest".utf8)
        try stagedData.write(to: transaction.partialURL.appendingPathComponent("manifest.json"))

        try FileManager.default.createDirectory(
            at: transaction.finalURL,
            withIntermediateDirectories: false
        )
        let raceData = Data("race winner manifest".utf8)
        try raceData.write(to: transaction.finalURL.appendingPathComponent("manifest.json"))
        try transaction.markWriterFinished()

        let error = captureTransactionError { _ = try transaction.publish() }

        #expect(error == .destinationAlreadyExists)
        #expect(try Data(contentsOf: existingFinal.appendingPathComponent("manifest.json"))
            == existingData)
        #expect(try Data(contentsOf: transaction.finalURL.appendingPathComponent("manifest.json"))
            == raceData)
        #expect(try Data(contentsOf: transaction.partialURL.appendingPathComponent("manifest.json"))
            == stagedData)
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
    }

    @Test func directoryPublishFailureRetainsOwnedStaging() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let directoryPublisher = AtomicDirectoryOutputPublisher(
            exclusiveRenameSupported: { _ in true },
            exclusiveRenameOperation: { _, _ in .failed }
        )
        let transaction = try makeDirectoryTransaction(
            in: directory,
            directoryPublisher: directoryPublisher
        )
        try transaction.prepareForWriting()
        let stagedData = Data("recoverable staging".utf8)
        try stagedData.write(to: transaction.partialURL.appendingPathComponent("manifest.json"))
        try transaction.markWriterFinished()

        let error = captureTransactionError { _ = try transaction.publish() }

        #expect(error == .publicationFailed)
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(try Data(contentsOf: transaction.partialURL.appendingPathComponent("manifest.json"))
            == stagedData)
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
    }

    @Test func directoryPublishFailsClosedWhenExclusiveRenameIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var renameAttempted = false
        let directoryPublisher = AtomicDirectoryOutputPublisher(
            exclusiveRenameSupported: { _ in false },
            exclusiveRenameOperation: { _, _ in
                renameAttempted = true
                return .succeeded
            }
        )
        let transaction = try makeDirectoryTransaction(
            in: directory,
            directoryPublisher: directoryPublisher
        )
        try transaction.prepareForWriting()
        let stagedData = Data("unsupported destination staging".utf8)
        try stagedData.write(to: transaction.partialURL.appendingPathComponent("manifest.json"))
        try transaction.markWriterFinished()

        let error = captureTransactionError { _ = try transaction.publish() }

        #expect(error == .unsupportedDestination)
        #expect(!renameAttempted)
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(try Data(contentsOf: transaction.partialURL.appendingPathComponent("manifest.json"))
            == stagedData)
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
    }

    @Test func directoryPublishNeverAttemptsHardLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var operations: [String] = []
        let filePublisher = AtomicRecordingOutputPublisher(
            hardLinkOperation: { _, _ in
                operations.append("hard-link")
                return .succeeded
            },
            exclusiveRenameSupported: { _ in
                operations.append("file-capability")
                return false
            },
            exclusiveRenameOperation: { _, _ in
                operations.append("file-rename")
                return .failed
            }
        )
        let directoryPublisher = AtomicDirectoryOutputPublisher(
            exclusiveRenameSupported: { _ in
                operations.append("capability-check")
                return true
            },
            exclusiveRenameOperation: { _, _ in
                operations.append("exclusive-rename")
                return .succeeded
            }
        )
        let transaction = try makeDirectoryTransaction(
            in: directory,
            filePublisher: filePublisher,
            directoryPublisher: directoryPublisher
        )
        try transaction.prepareForWriting()
        try Data("manifest".utf8).write(to: transaction.partialURL.appendingPathComponent("manifest.json"))
        try transaction.markWriterFinished()

        let publishedURL = try transaction.publish()

        #expect(publishedURL == transaction.finalURL)
        #expect(operations == ["capability-check", "exclusive-rename"])
        #expect(!operations.contains("hard-link"))
    }

    @Test func directoryPublishRenamesStagingToFinal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transaction = try makeDirectoryTransaction(in: directory)
        try transaction.prepareForWriting()
        let manifestData = Data("sealed segment".utf8)
        try manifestData.write(to: transaction.partialURL.appendingPathComponent("manifest.json"))
        try transaction.markWriterFinished()

        let publishedURL = try transaction.publish()

        var finalIsDirectory: ObjCBool = false
        #expect(publishedURL == transaction.finalURL)
        #expect(FileManager.default.fileExists(
            atPath: publishedURL.path,
            isDirectory: &finalIsDirectory
        ))
        #expect(finalIsDirectory.boolValue)
        #expect(try Data(contentsOf: publishedURL.appendingPathComponent("manifest.json"))
            == manifestData)
        #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
    }

    @Test func directoryDiscardRemovesOnlyOwnedStaging() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let siblingURL = directory.appendingPathComponent("unrelated.txt")
        let siblingData = Data("unrelated".utf8)
        try siblingData.write(to: siblingURL)
        let transaction = try makeDirectoryTransaction(in: directory)
        let stagingURL = transaction.partialURL

        try transaction.discardPartial()

        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(try Data(contentsOf: siblingURL) == siblingData)
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
    }

    @Test func oldInitializerStillUsesLegacyMP4Naming() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let first = try RecordingOutputTransaction(
            destinationDirectory: directory,
            now: now,
            timeZone: timeZone
        )
        #expect(!first.isDirectoryOutput)
        #expect(first.finalURL.lastPathComponent.range(
            of: #"^SnapGlass_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.mp4$"#,
            options: .regularExpression
        ) != nil)

        let preservedData = Data("existing legacy mp4".utf8)
        try preservedData.write(to: first.finalURL)
        let second = try RecordingOutputTransaction(
            destinationDirectory: directory,
            now: now,
            timeZone: timeZone
        )
        #expect(second.finalURL.lastPathComponent.range(
            of: #"^SnapGlass_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_2\.mp4$"#,
            options: .regularExpression
        ) != nil)
        #expect(try Data(contentsOf: first.finalURL) == preservedData)
    }

    private func makeRequest(
        stem: String = "Audio_2027-01-15_10-30-00",
        segmentIndex: Int = 0,
        shape: RecordingOutputRequest.Shape = .singleFile(fileExtension: "m4a"),
        in directory: URL
    ) throws -> RecordingOutputRequest {
        try RecordingOutputRequest(
            destinationDirectory: directory,
            stem: stem,
            segmentIndex: segmentIndex,
            shape: shape
        )
    }

    private func makeDirectoryTransaction(
        stem: String = "Audio_2027-01-15_10-30-00",
        in directory: URL,
        filePublisher: AtomicRecordingOutputPublisher = AtomicRecordingOutputPublisher(),
        directoryPublisher: AtomicDirectoryOutputPublisher = AtomicDirectoryOutputPublisher(),
        identifierProvider: @escaping () -> UUID = UUID.init
    ) throws -> RecordingOutputTransaction {
        try makeRequestTransaction(
            try makeRequest(stem: stem, shape: .directory, in: directory),
            filePublisher: filePublisher,
            directoryPublisher: directoryPublisher,
            identifierProvider: identifierProvider
        )
    }

    private func makeRequestTransaction(
        _ request: RecordingOutputRequest,
        filePublisher: AtomicRecordingOutputPublisher = AtomicRecordingOutputPublisher(),
        directoryPublisher: AtomicDirectoryOutputPublisher = AtomicDirectoryOutputPublisher(),
        identifierProvider: @escaping () -> UUID = UUID.init
    ) throws -> RecordingOutputTransaction {
        try RecordingOutputTransaction(
            request: request,
            identifierProvider: identifierProvider,
            filePublisher: filePublisher,
            directoryPublisher: directoryPublisher
        )
    }

}

private extension RecordingOutputTransactionTests {
    private func makeTransaction(
        in directory: URL,
        publisher: AtomicRecordingOutputPublisher = AtomicRecordingOutputPublisher(),
        identifierProvider: @escaping () -> UUID = UUID.init
    ) throws -> RecordingOutputTransaction {
        try RecordingOutputTransaction(
            destinationDirectory: directory,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            identifierProvider: identifierProvider,
            publisher: publisher
        )
    }

    private func captureTransactionError(
        _ operation: () throws -> Void
    ) -> RecordingOutputTransactionError? {
        do {
            try operation()
        } catch let error as RecordingOutputTransactionError {
            return error
        } catch {
            return nil
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingOutputTransactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
