import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfSessionDirectoryTests {
    @Test func directoryNamesCarryTheOwnerPID() {
        let sessionID = UUID()
        let name = ScreenshotShelfSessionDirectoryPolicy.directoryName(
            ownerPID: 1_234,
            sessionID: sessionID
        )

        #expect(name.hasPrefix("session-"))
        #expect(ScreenshotShelfSessionDirectoryPolicy.ownerPID(fromDirectoryName: name) == 1_234)
    }

    @Test func legacyNamesHaveNoOwner() {
        let name = "session-\(UUID().uuidString)"
        #expect(ScreenshotShelfSessionDirectoryPolicy.ownerPID(fromDirectoryName: name) == nil)
    }

    @Test func unrelatedNamesHaveNoOwner() {
        #expect(ScreenshotShelfSessionDirectoryPolicy.ownerPID(fromDirectoryName: "notes.txt") == nil)
        #expect(ScreenshotShelfSessionDirectoryPolicy.ownerPID(fromDirectoryName: "session-") == nil)
        #expect(ScreenshotShelfSessionDirectoryPolicy.ownerPID(fromDirectoryName: "session-abc-def") == nil)
    }

    @Test func liveOwnersAreNeverSwept() {
        let name = ScreenshotShelfSessionDirectoryPolicy.directoryName(
            ownerPID: getpid(),
            sessionID: UUID()
        )
        let now = Date()

        #expect(
            !ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: name,
                modifiedAt: .distantPast,
                now: now,
                grace: 0,
                legacyGrace: 0
            )
        )
    }

    @Test func deadOwnersAreSweptOnlyAfterTheGrace() {
        let name = ScreenshotShelfSessionDirectoryPolicy.directoryName(
            ownerPID: deadProcessID(),
            sessionID: UUID()
        )
        let now = Date()

        #expect(
            !ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: name,
                modifiedAt: now,
                now: now,
                grace: 60,
                legacyGrace: 0
            )
        )
        #expect(
            ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: name,
                modifiedAt: now.addingTimeInterval(-61),
                now: now,
                grace: 60,
                legacyGrace: 0
            )
        )
    }

    @Test func legacyDirectoriesWaitForTheLegacyGrace() {
        let name = "session-\(UUID().uuidString)"
        let now = Date()

        #expect(
            !ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: name,
                modifiedAt: now.addingTimeInterval(-3_600),
                now: now,
                grace: 0,
                legacyGrace: 24 * 60 * 60
            )
        )
        #expect(
            ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: name,
                modifiedAt: now.addingTimeInterval(-25 * 60 * 60),
                now: now,
                grace: 0,
                legacyGrace: 24 * 60 * 60
            )
        )
    }

    @Test func unrelatedDirectoriesAreNeverSwept() {
        #expect(
            !ScreenshotShelfSessionDirectoryPolicy.shouldSweep(
                directoryName: "notes",
                modifiedAt: .distantPast,
                now: Date(),
                grace: 0,
                legacyGrace: 0
            )
        )
    }

    /// Returns a process id that is guaranteed to be dead: a child that already exited.
    private func deadProcessID() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do {
            try process.run()
            process.waitUntilExit()
            return process.processIdentifier
        } catch {
            return Int32.max
        }
    }
}
