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
