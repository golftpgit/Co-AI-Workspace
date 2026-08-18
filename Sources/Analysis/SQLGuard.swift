import Foundation

// ─────────────────────────────────────────────────────────────
// The one place that decides whether a statement changes anything
// (ARCHITECTURE §12.5, P6.5).
//
// v1 had this logic twice — once in the notebook and once in the DB explorer,
// copied word for word — and the two drifted, so the same `DELETE` warned in
// one screen and ran silently in the other. There is nothing clever about the
// fix: the check is a value type with no screen, no store and no process
// attached, and both callers ask it the same question. `scripts/check.sh`
// fails the build if a mutating-verb table appears anywhere else.
//
// Two decisions worth stating:
//
//  • **Unknown verb means mutating.** A statement this file cannot name is
//    treated as though it changes data, the same way an unregistered tool is
//    scored High risk (§5.3). The cost of a needless confirmation is a click;
//    the cost of the other mistake is a table.
//  • **The split is a real tokeniser, not `split(separator: ";")`.** A
//    semicolon inside a string literal, an identifier or a comment does not end
//    a statement, and a guard that thinks it does will hand DuckDB half a
//    statement and report the wrong effect for the other half.
//
// What it deliberately does *not* do is authorise anything. The DB explorer is
// a direct user action and stays outside the approval gate by design (§14.2);
// this is a confirmation, shown to the person typing.
// ─────────────────────────────────────────────────────────────

/// How much of a statement's effect is worth stopping for.
public enum SQLEffect: Int, Sendable, Comparable, Codable {
    /// Reads only. Runs without asking.
    case read = 0
    /// Adds or changes rows, or creates something new.
    case write = 1
    /// Removes or overwrites something that is already there.
    case destructive = 2

    public static func < (lhs: SQLEffect, rhs: SQLEffect) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .read: localised("read only", "Label for a SQL statement that only reads.")
        case .write: localised("changes data", "Label for a SQL statement that writes.")
        case .destructive: localised("deletes or overwrites data", "Label for a destructive SQL statement.")
        }
    }
}

/// One statement out of whatever the user typed, with the guard's reading of it.
public struct SQLStatement: Sendable, Equatable, Identifiable {
    /// The statement as written, minus its terminating semicolon. This is what
    /// gets executed — the guard never rewrites SQL, it only reads it.
    public let text: String
    /// The leading keyword, upper-cased. Empty when the statement starts with
    /// something this file cannot name.
    public let verb: String
    public let effect: SQLEffect
    /// The table (or database) the statement acts on, where it can be read off
    /// the syntax. Nil is common and not an error.
    public let target: String?
    /// Why this was flagged, in the words the confirmation shows. Nil for reads.
    public let note: String?

    public var id: String { text }

    public init(text: String, verb: String, effect: SQLEffect,
                target: String? = nil, note: String? = nil) {
        self.text = text
        self.verb = verb
        self.effect = effect
        self.target = target
        self.note = note
    }
}

/// The guard's answer about a whole cell or editor buffer.
public struct SQLAssessment: Sendable, Equatable {
    public let statements: [SQLStatement]

    /// The worst thing in the buffer — a cell is confirmed as a whole, because
    /// running the first two statements and stopping to ask about the third
    /// leaves the data in a state nobody chose.
    public var effect: SQLEffect {
        statements.map(\.effect).max() ?? .read
    }

    public var needsConfirmation: Bool { effect > .read }

    /// The statements the confirmation has to spell out.
    public var mutating: [SQLStatement] { statements.filter { $0.effect > .read } }

    public var isEmpty: Bool { statements.isEmpty }

    /// One line for the top of the confirmation sheet.
    public var summary: String {
        guard !statements.isEmpty else { return localised("there is nothing to run", "Shown when the statement list is empty.") }
        let writes = statements.filter { $0.effect == .write }.count
        let destroys = statements.filter { $0.effect == .destructive }.count
        var parts = [localised("\(statements.count) statements", "How many statements are about to run. Placeholder: the count.")]
        if writes > 0 { parts.append(localised("\(writes) change data", "How many statements write. Placeholder: the count.")) }
        if destroys > 0 { parts.append(localised("\(destroys) delete or overwrite", "How many statements are destructive. Placeholder: the count.")) }
        if writes == 0 && destroys == 0 { parts.append(localised("read only", "Label for a SQL statement that only reads.")) }
        return parts.joined(separator: " · ")
    }
}

public enum SQLGuard {

    /// The statements in a buffer, in order, ready to run one at a time.
    ///
    /// `AnalysisStore.query` takes one statement on purpose: a cell that runs
    /// three and shows one table has hidden two results.
    public static func split(_ text: String) -> [String] {
        parse(text).map(\.text)
    }

    /// What running this buffer would do.
    public static func assess(_ text: String) -> SQLAssessment {
        SQLAssessment(statements: parse(text).map(classify))
    }

    // MARK: - classification

    /// Statements that only read. Anything not on this list is assumed to
    /// change something.
    private static let reading: Set<String> = [
        "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "SUMMARIZE", "PRAGMA",
        "VALUES", "TABLE", "FROM", "PIVOT", "UNPIVOT",
    ]

    /// Statements that remove or overwrite. `DELETE` and `UPDATE` are decided
    /// by whether they carry a WHERE, so they are not here.
    private static let removing: Set<String> = ["DROP", "TRUNCATE", "ALTER"]

    /// Words between a verb and the name it acts on.
    private static let modifiers: Set<String> = [
        "OR", "REPLACE", "TEMP", "TEMPORARY", "IF", "NOT", "EXISTS", "ALL", "ONLY",
        "INTO", "FROM", "TABLE", "VIEW", "INDEX", "SCHEMA", "SEQUENCE", "MACRO",
        "FUNCTION", "TYPE", "DATABASE", "SECRET", "SETTINGS", "PERSISTENT",
    ]

    private static func classify(_ statement: ParsedStatement) -> SQLStatement {
        let tokens = statement.tokens
        let leading = tokens.first?.word ?? ""
        // A CTE is not an effect: `WITH x AS (…) DELETE FROM t` deletes, and the
        // verb that says so sits inside the parentheses. Nothing else looks
        // past the first keyword — `EXPLAIN DELETE …` plans a delete without
        // running one, and a plan is a read.
        let verb = leading == "WITH"
            ? tokens.first { ["INSERT", "UPDATE", "DELETE", "MERGE"].contains($0.word) }?.word ?? "WITH"
            : leading
        // Everything below reads the statement at the verb's own nesting: for a
        // plain statement that is depth 0, and for a CTE that mutates it is the
        // inside of the parentheses the verb sits in.
        let verbIndex = tokens.firstIndex { $0.word == verb && !verb.isEmpty }
        let verbDepth = verbIndex.map { tokens[$0].depth } ?? 0
        let target = self.target(from: verbIndex, in: tokens)
        let named = target ?? localised("the named table", "Stands in for a table name the parser could not read.")
        let hasWhere = tokens.contains { $0.word == "WHERE" && $0.depth == verbDepth }

        func made(_ effect: SQLEffect, _ note: String?) -> SQLStatement {
            SQLStatement(text: statement.text, verb: verb, effect: effect,
                         target: target, note: note)
        }

        switch verb {
        case "DELETE":
            // The classic: a WHERE that was meant to be there and is not takes
            // the whole table with it.
            return hasWhere
                ? made(.write, localised("deletes matching rows in \(named)", "What a DELETE with a WHERE does. Placeholder: the table."))
                : made(.destructive, localised("no WHERE — deletes every row in \(named)", "What a DELETE without a WHERE does. Placeholder: the table."))
        case "UPDATE":
            return hasWhere
                ? made(.write, localised("changes matching rows in \(named)", "What an UPDATE with a WHERE does. Placeholder: the table."))
                : made(.destructive, localised("no WHERE — changes every row in \(named)", "What an UPDATE without a WHERE does. Placeholder: the table."))
        case "CREATE":
            // `OR REPLACE` is the difference between making something and
            // silently throwing away what was there under that name.
            let replaces = tokens.contains { $0.word == "REPLACE" && $0.depth == 0 }
            return replaces
                ? made(.destructive, localised("overwrites the existing \(named)", "What a CREATE OR REPLACE does. Placeholder: the table."))
                : made(.write, localised("creates \(named)", "What a CREATE does. Placeholder: the table."))
        case "INSERT":
            let replaces = tokens.contains { $0.word == "REPLACE" && $0.depth == 0 }
            return made(replaces ? .destructive : .write,
                        replaces ? localised("overwrites clashing rows in \(named)", "What an INSERT OR REPLACE does. Placeholder: the table.") : localised("adds rows to \(named)", "What an INSERT does. Placeholder: the table."))
        case "DROP":
            return made(.destructive, localised("drops \(named) entirely — the app cannot bring it back", "What a DROP does. Placeholder: the table."))
        case "TRUNCATE":
            return made(.destructive, localised("empties every row in \(named)", "What a TRUNCATE does. Placeholder: the table."))
        case "ALTER":
            return made(.destructive, localised("changes the structure of \(named)", "What an ALTER does. Placeholder: the table."))
        case "ATTACH":
            // §12.2 attaches read-only by default precisely because the data on
            // the other end is usually somebody else's.
            let readOnly = tokens.contains { $0.word == "READ_ONLY" }
            return made(.write, readOnly ? localised("attaches an outside database read-only", "What a read-only ATTACH does.")
                                         : localised("attaches an outside database with writing allowed", "What a writable ATTACH does."))
        case "COPY":
            return made(.write, localised("copies data to or from a file", "What a COPY does."))
        case "":
            return made(.write, localised("the statement starts with a quoted name — assumed to change data until proven otherwise", "Said when the statement's verb could not be read."))
        default:
            if reading.contains(verb) { return made(.read, nil) }
            if removing.contains(verb) { return made(.destructive, "\(verb) \(named)") }
            if verb == "WITH" { return made(.read, nil) }
            // Not a verb this file knows. Treated as mutating on purpose: the
            // list above is what we have checked, not what SQL contains.
            return made(.write, localised("\(verb) is a statement this guard does not know — assumed to change data until proven otherwise", "Said for an unrecognised SQL verb. Placeholder: the verb."))
        }
    }

    /// The name a statement acts on, read off the tokens between the verb and
    /// the first thing that is not a modifier.
    ///
    /// Only the leading name is read, so `main.readings` reports as `main` —
    /// enough to say which thing is about to change, and never enough to be
    /// mistaken for an executable identifier.
    private static func target(from verbIndex: Int?, in tokens: [SQLToken]) -> String? {
        // A statement that starts with a quoted name has no verb to look past;
        // the name itself is the only thing there is to report.
        guard let index = verbIndex else { return tokens.first?.text }
        let depth = tokens[index].depth
        for token in tokens[(index + 1)...] where token.depth == depth {
            // A quoted identifier has no keyword reading, so it is the name.
            if token.word.isEmpty { return token.text }
            if modifiers.contains(token.word) { continue }
            return token.text
        }
        return nil
    }

    // MARK: - tokenising

    struct SQLToken: Equatable {
        /// As written, with any surrounding quotes removed.
        let text: String
        /// Upper-cased for comparison — empty when the token was quoted, so a
        /// table honestly named "delete" is never read as a verb.
        let word: String
        /// Parenthesis nesting, so a WHERE inside a subquery is not mistaken
        /// for the statement's own.
        let depth: Int
    }

    struct ParsedStatement {
        let text: String
        let tokens: [SQLToken]
    }

    /// Splits on semicolons that are actually statement separators, and hands
    /// back the words of each statement with their nesting.
    ///
    /// Handles what DuckDB's own parser handles: `''` inside a string, `""`
    /// inside an identifier, `--` to end of line, nested `/* */`, and dollar
    /// quoting. Each of these can carry a semicolon, and each of them would
    /// otherwise cut a statement in half.
    static func parse(_ text: String) -> [ParsedStatement] {
        var statements: [ParsedStatement] = []
        var current = ""
        var tokens: [SQLToken] = []
        var depth = 0
        var word = ""
        let characters = Array(text)
        var index = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(SQLToken(text: word, word: word.uppercased(), depth: depth))
            word = ""
        }

        func flushStatement() {
            flushWord()
            var trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(";") { trimmed.removeLast() }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !tokens.isEmpty {
                statements.append(ParsedStatement(text: trimmed, tokens: tokens))
            }
            current = ""
            tokens = []
            depth = 0
        }

        while index < characters.count {
            let character = characters[index]

            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                flushWord()
                while index < characters.count, characters[index] != "\n" {
                    current.append(characters[index]); index += 1
                }
                continue
            }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                flushWord()
                var nesting = 0
                while index < characters.count {
                    if characters[index] == "/", index + 1 < characters.count,
                       characters[index + 1] == "*" {
                        nesting += 1; current += "/*"; index += 2; continue
                    }
                    if characters[index] == "*", index + 1 < characters.count,
                       characters[index + 1] == "/" {
                        nesting -= 1; current += "*/"; index += 2
                        if nesting == 0 { break }
                        continue
                    }
                    current.append(characters[index]); index += 1
                }
                continue
            }

            if character == "'" {
                flushWord()
                current.append(character); index += 1
                while index < characters.count {
                    if characters[index] == "'" {
                        if index + 1 < characters.count, characters[index + 1] == "'" {
                            current += "''"; index += 2; continue
                        }
                        current.append("'"); index += 1; break
                    }
                    current.append(characters[index]); index += 1
                }
                continue
            }

            if character == "\"" {
                flushWord()
                current.append(character); index += 1
                var identifier = ""
                while index < characters.count {
                    if characters[index] == "\"" {
                        if index + 1 < characters.count, characters[index + 1] == "\"" {
                            identifier.append("\""); current += "\"\""; index += 2; continue
                        }
                        current.append("\""); index += 1; break
                    }
                    identifier.append(characters[index])
                    current.append(characters[index])
                    index += 1
                }
                // No `word`: a quoted name is a name, whatever it spells.
                tokens.append(SQLToken(text: identifier, word: "", depth: depth))
                continue
            }

            if character == "$", let tag = dollarTag(characters, from: index) {
                flushWord()
                current += tag; index += tag.count
                while index < characters.count {
                    if characters[index] == "$", matches(tag, characters, at: index) {
                        current += tag; index += tag.count; break
                    }
                    current.append(characters[index]); index += 1
                }
                continue
            }

            switch character {
            case "(":
                flushWord(); depth += 1; current.append(character)
            case ")":
                flushWord(); depth = max(0, depth - 1); current.append(character)
            case ";":
                current.append(character)
                flushStatement()
            default:
                if character.isLetter || character.isNumber || character == "_" {
                    word.append(character)
                } else {
                    flushWord()
                }
                current.append(character)
            }
            index += 1
        }
        flushStatement()
        return statements
    }

    /// `$$` or `$tag$` at this position, or nil when the `$` is something else
    /// — a parameter marker, or part of an identifier.
    private static func dollarTag(_ characters: [Character], from index: Int) -> String? {
        var end = index + 1
        while end < characters.count,
              characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
            end += 1
        }
        guard end < characters.count, characters[end] == "$" else { return nil }
        return String(characters[index...end])
    }

    private static func matches(_ tag: String, _ characters: [Character], at index: Int) -> Bool {
        let tagCharacters = Array(tag)
        guard index + tagCharacters.count <= characters.count else { return false }
        return Array(characters[index..<(index + tagCharacters.count)]) == tagCharacters
    }
}
