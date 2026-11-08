import Foundation
import Testing

@testable import CaptureCore

struct RecordingOutputTransactionTests {
    @Test func createsHiddenPartialInsideTheDestinationDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transaction = try makeTransaction(in: directory)

        #expect(transaction.partialURL.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
        #expect(transaction.partialURL.lastPathComponent.hasPrefix("."))
        #expect(FileManager.default.fileExists(atPath: transaction.partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
        #expect(transaction.finalURL.lastPathComponent.range(
            of: #"^SnapGlass_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.mp4$"#,
            options: .regularExpression
        ) != nil)
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

        let transaction = try makeTransaction(in: directory)
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

    private func makeTransaction(in directory: URL) throws -> RecordingOutputTransaction {
        try RecordingOutputTransaction(
            destinationDirectory: directory,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingOutputTransactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
