import Testing
import Foundation
import AgentKit
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// `read_file` / `write_file` (C6, AUDIT F-9).
//
// The safety rules are `WorkspaceFiles`' and are tested there; what these
// prove is that the tools do not go around them — which is the only way this
// pair can become dangerous, and the way a second implementation would.
// ─────────────────────────────────────────────────────────────

private func sandbox() -> URL {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "filetools-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Arguments built rather than written by hand: a Thai passage has newlines in
/// it, and a newline inside a hand-written JSON string literal is not JSON —
/// which is a failure in the test, not in the tool.
private func args(_ pairs: [String: String]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: pairs), encoding: .utf8)!
}

private func context(_ root: URL?) -> ToolContext {
    ToolContext(scope: .central, workingDirectory: root, conversationID: "t")
}

@Suite("read_file / write_file")
struct FileToolsTests {
    @Test("writes a new file, then reads back exactly what was written")
    func roundTrip() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let write = WriteFileTool()
        let read = ReadFileTool()

        let thai = "บรรทัดแรก\nบรรทัดที่สอง — มีสระและวรรณยุกต์ครบ"
        _ = try await write.call(
            argumentsJSON: args(["path": "note.md", "content": thai]), context: context(root))
        let out = try await read.call(argumentsJSON: #"{"path":"note.md"}"#, context: context(root))
        #expect(out.text == thai, "สิ่งที่อ่านกลับมาไม่ตรงกับที่เขียนไป")
    }

    @Test("a path outside the folder is refused, not clamped")
    func refusesEscape() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = ReadFileTool()
        await #expect(throws: ToolError.self) {
            _ = try await read.call(argumentsJSON: #"{"path":"../../../etc/hosts"}"#,
                                    context: context(root))
        }
        let write = WriteFileTool()
        await #expect(throws: ToolError.self) {
            _ = try await write.call(
                argumentsJSON: #"{"path":"../escaped.txt","content":"x"}"#, context: context(root))
        }
        #expect(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appending(path: "escaped.txt")
                .path(percentEncoded: false)) == false,
            "การเขียนที่ถูกปฏิเสธ ยังสร้างไฟล์นอกโฟลเดอร์")
    }

    @Test("reading a file that is not there says so, rather than returning nothing")
    func missingFileIsAnError() async throws {
        let root = sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = ReadFileTool()
        await #expect(throws: ToolError.self) {
            _ = try await read.call(argumentsJSON: #"{"path":"nope.md"}"#, context: context(root))
        }
    }

    @Test("with no folder chosen, both refuse instead of guessing one")
    func noWorkspace() async throws {
        let read = ReadFileTool()
        let write = WriteFileTool()
        await #expect(throws: ToolError.self) {
            _ = try await read.call(argumentsJSON: #"{"path":"a.md"}"#, context: context(nil))
        }
        await #expect(throws: ToolError.self) {
            _ = try await write.call(argumentsJSON: #"{"path":"a.md","content":"x"}"#,
                                     context: context(nil))
        }
    }

    @Test("the two sit at different risk levels, because they are different acts")
    func riskIsNotShared() {
        // Reading inside a chosen folder is not worth interrupting somebody for;
        // replacing their file is. One level for both is how one of them ends
        // up wrong (§5.3).
        #expect(ReadFileTool().riskLevel == .low)
        #expect(WriteFileTool().riskLevel == .high)
    }
}
