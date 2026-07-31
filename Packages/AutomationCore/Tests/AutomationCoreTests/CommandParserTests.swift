import Testing
import Foundation
@testable import AutomationCore

struct CommandParserTests {

    private let parser = CommandParser()

    // MARK: - capture

    @Test func parse_capture_default() throws {
        let cmd = try parser.parse(["capture"])
        if case .capture(let mode, let output) = cmd {
            #expect(mode == nil)
            #expect(output == nil)
        } else {
            Issue.record("Expected .capture")
        }
    }

    @Test func parse_capture_withMode() throws {
        let cmd = try parser.parse(["capture", "--mode", "fullscreen"])
        if case .capture(let mode, _) = cmd {
            #expect(mode == "fullscreen")
        } else {
            Issue.record("Expected .capture")
        }
    }

    @Test func parse_capture_withOutput() throws {
        let cmd = try parser.parse(["capture", "--output", "/tmp/shot.png"])
        if case .capture(_, let output) = cmd {
            #expect(output == "/tmp/shot.png")
        } else {
            Issue.record("Expected .capture")
        }
    }

    // MARK: - ocr

    @Test func parse_ocr_file_subcommand() throws {
        let cmd = try parser.parse(["ocr", "file", "/path/to/image.png"])
        if case .ocr(let file, _, _, _, _) = cmd {
            #expect(file == "/path/to/image.png")
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_file_withEngine() throws {
        let cmd = try parser.parse(["ocr", "file", "/path.png", "--engine", "tesseract"])
        if case .ocr(_, let engine, _, _, _) = cmd {
            #expect(engine == "tesseract")
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_file_withLang() throws {
        let cmd = try parser.parse(["ocr", "file", "/path.png", "--lang", "chi_sim"])
        if case .ocr(_, _, let languages, _, _) = cmd {
            #expect(languages == ["chi_sim"])
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_file_withDevCompare() throws {
        let cmd = try parser.parse(["ocr", "file", "/path.png", "--dev-compare"])
        if case .ocr(_, _, _, let devCompare, _) = cmd {
            #expect(devCompare)
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_file_withFormat() throws {
        let cmd = try parser.parse(["ocr", "file", "/path.png", "--format", "json"])
        if case .ocr(_, _, _, _, let format) = cmd {
            #expect(format == "json")
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_flag_syntax() throws {
        let cmd = try parser.parse(["ocr", "--file", "/path.png"])
        if case .ocr(let file, _, _, _, _) = cmd {
            #expect(file == "/path.png")
        } else {
            Issue.record("Expected .ocr")
        }
    }

    @Test func parse_ocr_missingFile() {
        expectAutomationError(.missingArgument, performing: { try parser.parse(["ocr"]) })
    }

    // MARK: - barcode

    @Test func parse_barcode_file_subcommand() throws {
        let cmd = try parser.parse(["barcode", "file", "/path.png"])
        if case .barcode(let file, _, _) = cmd {
            #expect(file == "/path.png")
        } else {
            Issue.record("Expected .barcode")
        }
    }

    @Test func parse_barcode_withTypes() throws {
        let cmd = try parser.parse(["barcode", "file", "/path.png", "--types", "qr,code128"])
        if case .barcode(_, let types, _) = cmd {
            #expect(types == ["qr", "code128"])
        } else {
            Issue.record("Expected .barcode")
        }
    }

    @Test func parse_barcode_flag_syntax() throws {
        let cmd = try parser.parse(["barcode", "--file", "/path.png"])
        if case .barcode(let file, _, _) = cmd {
            #expect(file == "/path.png")
        } else {
            Issue.record("Expected .barcode")
        }
    }

    @Test func parse_barcode_missingFile() {
        expectAutomationError(.missingArgument, performing: { try parser.parse(["barcode"]) })
    }

    // MARK: - history

    @Test func parse_history_default() throws {
        let cmd = try parser.parse(["history"])
        if case .history(let sub) = cmd {
            #expect(sub == .list)
        } else {
            Issue.record("Expected .history")
        }
    }

    @Test func parse_history_search() throws {
        let cmd = try parser.parse(["history", "search"])
        if case .history(let sub) = cmd {
            #expect(sub == .search)
        } else {
            Issue.record("Expected .history")
        }
    }

    @Test func parse_history_delete() throws {
        let cmd = try parser.parse(["history", "delete"])
        if case .history(let sub) = cmd {
            #expect(sub == .delete)
        } else {
            Issue.record("Expected .history")
        }
    }

    @Test func parse_history_export() throws {
        let cmd = try parser.parse(["history", "export"])
        if case .history(let sub) = cmd {
            #expect(sub == .export)
        } else {
            Issue.record("Expected .history")
        }
    }

    @Test func parse_history_clear() throws {
        let cmd = try parser.parse(["history", "clear"])
        if case .history(let sub) = cmd {
            #expect(sub == .clear)
        } else {
            Issue.record("Expected .history")
        }
    }

    // MARK: - dev

    @Test func parse_dev_logs() throws {
        let cmd = try parser.parse(["dev", "logs"])
        if case .dev(let sub) = cmd {
            if case .logs(let format, let output) = sub {
                #expect(format == nil)
                #expect(output == nil)
            } else {
                Issue.record("Expected .logs subcommand")
            }
        } else {
            Issue.record("Expected .dev")
        }
    }

    @Test func parse_dev_logs_withFormat() throws {
        let cmd = try parser.parse(["dev", "logs", "--format", "json"])
        if case .dev(let sub) = cmd {
            if case .logs(let format, _) = sub {
                #expect(format == "json")
            } else {
                Issue.record("Expected .logs subcommand")
            }
        } else {
            Issue.record("Expected .dev")
        }
    }

    @Test func parse_dev_compare() throws {
        let cmd = try parser.parse(["dev", "compare", "/path.png"])
        if case .dev(let sub) = cmd {
            if case .compare(let file, _) = sub {
                #expect(file == "/path.png")
            } else {
                Issue.record("Expected .compare subcommand")
            }
        } else {
            Issue.record("Expected .dev")
        }
    }

    @Test func parse_dev_missingSubcommand() {
        expectAutomationError(.invalidCommand, performing: { try parser.parse(["dev"]) })
    }

    // MARK: - preferences

    @Test func parse_preferences() throws {
        let cmd = try parser.parse(["preferences"])
        if case .preferences(let key, let value) = cmd {
            #expect(key == nil)
            #expect(value == nil)
        } else {
            Issue.record("Expected .preferences")
        }
    }

    @Test func parse_preferences_withKey() throws {
        let cmd = try parser.parse(["preferences", "--key", "saveFullText"])
        if case .preferences(let key, _) = cmd {
            #expect(key == "saveFullText")
        } else {
            Issue.record("Expected .preferences")
        }
    }

    // MARK: - errors

    @Test func parse_emptyArguments() {
        expectAutomationError(.invalidCommand, performing: { try parser.parse([]) })
    }

    @Test func parse_unknownCommand() {
        expectAutomationError(.invalidCommand, performing: { try parser.parse(["unknown"]) })
    }

    // MARK: - helpText

    @Test func helpText_containsExpectedSections() {
        let help = CommandParser.helpText()
        #expect(help.contains("SnapGlass CLI"))
        #expect(help.contains("ocr"))
        #expect(help.contains("barcode"))
        #expect(help.contains("capture"))
        #expect(help.contains("history"))
        #expect(help.contains("dev"))
        #expect(help.contains("退出码"))
    }

    private enum ExpectedAutomationError {
        case missingArgument
        case invalidCommand
    }

    private func expectAutomationError(_ expected: ExpectedAutomationError, performing operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected AutomationError")
        } catch let error as AutomationError {
            switch (expected, error) {
            case (.missingArgument, .missingArgument), (.invalidCommand, .invalidCommand):
                break
            default:
                Issue.record("Unexpected AutomationError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
