import Foundation
import Testing

@testable import CaptureCore

struct DirectoryOutputSafetyTests {
  private let stem = "Audio_2027-01-15_10-30-00"

  @Test func directoryPrepareRejectsSymlinkReplacement() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let target = try makeDirectory(named: "external-target", in: root)
    let markerData = Data("external target content".utf8)
    try markerData.write(to: target.appendingPathComponent("marker.txt"))

    let transaction = try makeDirectoryTransaction(in: destination)
    try replaceWithSymlink(stagingURL: transaction.partialURL, targetURL: target)

    let error = captureTransactionError { try transaction.prepareForWriting() }

    #expect(error == .partialFileMissing)
    #expect(try Data(contentsOf: target.appendingPathComponent("marker.txt")) == markerData)
    #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: transaction.partialURL.path
      ) == target.path)
  }

  @Test func directoryWriterFinishRejectsSymlinkReplacement() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let target = try makeDirectory(named: "external-target", in: root)
    let markerData = Data("external target content".utf8)
    try markerData.write(to: target.appendingPathComponent("marker.txt"))

    let transaction = try makeDirectoryTransaction(in: destination)
    try transaction.prepareForWriting()
    try replaceWithSymlink(stagingURL: transaction.partialURL, targetURL: target)

    let error = captureTransactionError { try transaction.markWriterFinished() }

    #expect(error == .partialFileMissing)
    #expect(try Data(contentsOf: target.appendingPathComponent("marker.txt")) == markerData)
    #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
  }

  @Test func directoryPublishRejectsSymlinkReplacement() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let target = try makeDirectory(named: "external-target", in: root)
    let markerData = Data("external target content".utf8)
    try markerData.write(to: target.appendingPathComponent("marker.txt"))

    let transaction = try makeDirectoryTransaction(in: destination)
    try transaction.prepareForWriting()
    try Data("staged segment".utf8).write(
      to: transaction.partialURL.appendingPathComponent("manifest.json")
    )
    try transaction.markWriterFinished()
    try replaceWithSymlink(stagingURL: transaction.partialURL, targetURL: target)

    #expect(!transaction.isPublishable)
    let error = captureTransactionError { _ = try transaction.publish() }

    #expect(error == .partialFileMissing)
    #expect(try Data(contentsOf: target.appendingPathComponent("marker.txt")) == markerData)
    #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
  }

  @Test func directoryDiscardRemovesDanglingSymlinkWithoutFollowingIt() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let siblingFile = root.appendingPathComponent("sibling.txt")
    let siblingData = Data("unrelated sibling".utf8)
    try siblingData.write(to: siblingFile)
    let danglingTarget = root.appendingPathComponent("missing-target", isDirectory: true)

    let transaction = try makeDirectoryTransaction(in: destination)
    try FileManager.default.removeItem(at: transaction.partialURL)
    try FileManager.default.createSymbolicLink(
      at: transaction.partialURL,
      withDestinationURL: danglingTarget
    )

    try transaction.discardPartial()

    #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
    #expect(
      (try? FileManager.default.destinationOfSymbolicLink(
        atPath: transaction.partialURL.path
      )) == nil)
    #expect(!FileManager.default.fileExists(atPath: danglingTarget.path))
    #expect(try Data(contentsOf: siblingFile) == siblingData)
    #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
  }

  @Test func directoryDiscardRemovesOwnedSymlinkWithoutDeletingTarget() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let target = try makeDirectory(named: "external-target", in: root)
    let markerData = Data("external target content".utf8)
    try markerData.write(to: target.appendingPathComponent("marker.txt"))

    let transaction = try makeDirectoryTransaction(in: destination)
    try FileManager.default.removeItem(at: transaction.partialURL)
    try FileManager.default.createSymbolicLink(
      at: transaction.partialURL,
      withDestinationURL: target
    )

    try transaction.discardPartial()

    #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
    #expect(try Data(contentsOf: target.appendingPathComponent("marker.txt")) == markerData)
    #expect(!FileManager.default.fileExists(atPath: transaction.finalURL.path))
  }

  @Test func publicRequestInitializerPublishesSingleFile() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try makeDirectory(named: "destination", in: root)
    let request = try RecordingOutputRequest(
      destinationDirectory: destination,
      stem: stem,
      segmentIndex: 0,
      shape: .singleFile(fileExtension: "M4A")
    )

    let transaction = try RecordingOutputTransaction(
      request: request,
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: TimeZone(secondsFromGMT: 0) ?? .current
    )
    #expect(!transaction.isDirectoryOutput)
    #expect(transaction.finalURL.lastPathComponent == "\(stem)-00.m4a")

    try transaction.prepareForWriting()
    let mediaData = Data("public request single-file media".utf8)
    try mediaData.write(to: transaction.partialURL)
    try transaction.markWriterFinished()
    let publishedURL = try transaction.publish()

    #expect(publishedURL == transaction.finalURL)
    #expect(try Data(contentsOf: publishedURL) == mediaData)
    #expect(!FileManager.default.fileExists(atPath: transaction.partialURL.path))
  }

  private func makeDirectoryTransaction(in directory: URL) throws -> RecordingOutputTransaction {
    let request = try RecordingOutputRequest(
      destinationDirectory: directory,
      stem: stem,
      segmentIndex: 0,
      shape: .directory
    )
    return try RecordingOutputTransaction(
      request: request,
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: TimeZone(secondsFromGMT: 0) ?? .current
    )
  }

  private func replaceWithSymlink(stagingURL: URL, targetURL: URL) throws {
    try FileManager.default.removeItem(at: stagingURL)
    try FileManager.default.createSymbolicLink(at: stagingURL, withDestinationURL: targetURL)
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

  private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RecordingOutputDirectorySafetyTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeDirectory(named name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
