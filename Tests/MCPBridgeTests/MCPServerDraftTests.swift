import Testing
import Foundation
import AgentKit
@testable import MCPBridge

// ─────────────────────────────────────────────────────────────
// The MCP server editor's rules (ARCHITECTURE §6.2).
//
// The two that matter both fail the same way: the server starts, something is
// subtly wrong with how it was launched, and nothing on screen points at the
// field that caused it.
// ─────────────────────────────────────────────────────────────

@Suite("MCP server draft")
struct MCPServerDraftTests {

    // `--root "/Users/me/My Papers"` split on spaces is three arguments. The
    // server then serves the wrong directory or refuses to start, and the
    // quotes are the last thing anybody suspects.
    @Test("a quoted argument with a space in it stays one argument")
    func quotedArgumentsSurvive() {
        var draft = MCPServerDraft()
        draft.argumentsText = #"-y some-mcp --root "/Users/me/My Papers" --verbose"#
        #expect(draft.arguments == ["-y", "some-mcp", "--root",
                                    "/Users/me/My Papers", "--verbose"])
    }

    @Test("single quotes work too, and runs of spaces do not make empty arguments")
    func singleQuotesAndPadding() {
        var draft = MCPServerDraft()
        draft.argumentsText = "  -y   'my server'   --flag  "
        #expect(draft.arguments == ["-y", "my server", "--flag"])
    }

    @Test("an explicitly empty quoted argument is kept")
    func emptyQuotedArgument() {
        var draft = MCPServerDraft()
        draft.argumentsText = #"--prefix "" --end"#
        #expect(draft.arguments == ["--prefix", "", "--end"])
    }

    @Test("environment mappings are read one per line, and half a line is dropped")
    func parsesEnvironment() {
        var draft = MCPServerDraft()
        draft.environmentText = """
            WEATHER_API_KEY = MY_WEATHER_KEY
            OTHER=SECOND_NAME
            this line has no separator
            EMPTY =
            """
        #expect(draft.environmentVariables == ["WEATHER_API_KEY": "MY_WEATHER_KEY",
                                               "OTHER": "SECOND_NAME"])
    }

    // Every tool this server offers is called `mcp__<namespace>__…`, and the
    // namespace keeps only ASCII letters, digits and `-`. Two servers named
    // entirely in Thai both become `server`, and their tools then collide.
    @Test("a name with no ASCII in it is warned about, because its tools would collide")
    func namespaceCollisionIsWarned() {
        var draft = MCPServerDraft(name: "งานวิจัย", command: "npx")
        #expect(draft.namespace == "server")
        #expect(draft.warnings.contains { $0.contains("mcp__server__") })

        draft.name = "งานวิจัย weather"
        #expect(draft.namespace == "weather")
        #expect(draft.warnings.isEmpty)
    }

    @Test("a server with no command cannot be saved")
    func commandIsRequired() {
        var draft = MCPServerDraft(name: "weather", command: "")
        #expect(draft.canSave == false)
        draft.command = "npx"
        #expect(draft.canSave)
    }

    @Test("a name is required — it becomes the prefix on every tool")
    func nameIsRequired() {
        let draft = MCPServerDraft(name: "", command: "npx")
        #expect(draft.canSave == false)
    }

    // §6.2 says so in a comment; this says it where somebody is about to do it.
    @Test("an absolute command path is warned about, not refused")
    func absolutePathWarns() {
        let draft = MCPServerDraft(name: "weather", command: "/opt/homebrew/bin/npx")
        #expect(draft.canSave)
        #expect(draft.warnings.contains { $0.contains("เครื่องถัดไป") })
    }

    @Test("a working directory that does not exist is warned about")
    func missingDirectoryWarns() {
        let draft = MCPServerDraft(name: "weather", command: "npx",
                                   workingDirectory: "/definitely/not/here")
        #expect(draft.warnings.contains { $0.contains("โฟลเดอร์") })
    }

    @Test("editing keeps the id, so saving updates rather than adding a second server")
    func editKeepsIdentity() {
        let original = MCPServerConfig(name: "weather", command: "npx",
                                       arguments: ["-y", "weather-mcp"],
                                       environmentVariables: ["KEY": "MY_KEY"])
        var draft = MCPServerDraft(original)
        draft.name = "weather-2"

        let updated = draft.config(id: original.id)
        #expect(updated.id == original.id)
        #expect(updated.arguments == ["-y", "weather-mcp"])
        #expect(updated.environmentVariables == ["KEY": "MY_KEY"])
    }

    // Including an argument that has a space in it, which the round trip has to
    // re-quote or it comes back as two.
    @Test("a draft made from a config round-trips it")
    func roundTrips() {
        let original = MCPServerConfig(name: "papers", command: "uvx",
                                       arguments: ["--root", "/Users/me/My Papers"],
                                       workingDirectory: nil,
                                       environmentVariables: ["A": "B"],
                                       isEnabled: false)
        let rebuilt = MCPServerDraft(original).config(id: original.id)
        #expect(rebuilt == original)
    }
}
