import Testing
import Foundation
@testable import AutomationCore

/// Tests for CLIHandlers that verify unimplemented stubs return expected failure messages.
///
/// These tests validate that handlers which are not yet fully implemented
/// return a consistent non-success "not yet implemented" response rather than crashing
/// or producing a misleading successful exit. Full integration tests require real
/// images and system permissions and are out of scope here.
struct CLIHandlersUnimplementedTests {

    private let handlers = CLIHandlers()

    // MARK: - handleCapture (stub)

    @Test func handleCapture_returnsPlaceholder() async throws {
        let result = try await handlers.handleCapture(mode: "area", output: nil)
        #expect(!result.success)
        #expect(result.exitCode == ExitCode.general.rawValue)
        #expect(result.output.contains("尚未实现"))
    }

    @Test func handleCapture_includesMode() async throws {
        let result = try await handlers.handleCapture(mode: "fullscreen", output: nil)
        #expect(result.output.contains("fullscreen"))
    }

    // MARK: - handleHistory (stub)

    @Test func handleHistory_list_returnsPlaceholder() async throws {
        let result = try await handlers.handleHistory(subcommand: .list)
        #expect(!result.success)
        #expect(result.exitCode == ExitCode.general.rawValue)
        #expect(result.output.contains("尚未实现"))
        #expect(result.output.contains("list"))
    }

    @Test func handleHistory_search_returnsPlaceholder() async throws {
        let result = try await handlers.handleHistory(subcommand: .search)
        #expect(!result.success)
        #expect(result.output.contains("search"))
    }

    @Test func handleHistory_delete_returnsPlaceholder() async throws {
        let result = try await handlers.handleHistory(subcommand: .delete)
        #expect(!result.success)
        #expect(result.output.contains("delete"))
    }

    @Test func handleHistory_export_returnsPlaceholder() async throws {
        let result = try await handlers.handleHistory(subcommand: .export)
        #expect(!result.success)
        #expect(result.output.contains("export"))
    }

    @Test func handleHistory_clear_returnsPlaceholder() async throws {
        let result = try await handlers.handleHistory(subcommand: .clear)
        #expect(!result.success)
        #expect(result.output.contains("clear"))
    }
}
