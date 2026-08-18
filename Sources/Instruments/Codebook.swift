import Foundation
import AgentKit

// ─────────────────────────────────────────────────────────────
// Qualitative coding (ARCHITECTURE §20.3 Qualitative, P11.8).
//
// The quantitative half of M15 asks people to answer a fixed instrument. This
// half is the opposite: the text arrives first and the categories are built out
// of it, which is why the file is about a *codebook* rather than a form.
//
// Two things decide the shape of everything here.
//
// **κ needs units fixed before coding, not after.** Two coders who each choose
// where a passage begins are not agreeing or disagreeing about anything
// comparable — one of them found three segments where the other found two, and
// no arithmetic recovers a common denominator from that. So a `CodingUnit` is
// created once, from the transcript, and every coder labels the same list. That
// is the standard design for reporting intercoder reliability, and it is also
// the only one that can be checked.
//
// **A code that was never applied is still part of the codebook.** Dropping
// unused codes would make the codebook a description of the data rather than a
// record of the scheme somebody designed — and "we defined eleven codes and used
// nine" is a sentence a methods section should be able to make.
//
// Saturation is tracked, not judged. §20.3 asks to "follow the saturation of the
// data"; where it was reached is an argument the researcher makes, and a number
// this file produced would be quoted as though the software had decided.
// ─────────────────────────────────────────────────────────────

/// One category in the scheme.
public struct Code: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: Bilingual
    /// What counts as this code and what does not. Required in spirit and
    /// checked by `CodebookProblem`: a code with no definition is a word two
    /// coders will read differently, which shows up later as low κ that nobody
    /// can explain.
    public var definition: String
    /// The broader code this one sits under, for axial coding. `nil` is an open
    /// code that has not been grouped yet.
    public var parentID: String?
    /// Passages the author kept as the reference case for this code.
    public var examples: [String]

    public init(id: String = OpaqueID.make(OpaqueID.code),
                name: Bilingual,
                definition: String = "",
                parentID: String? = nil,
                examples: [String] = []) {
        self.id = id
        self.name = name
        self.definition = definition
        self.parentID = parentID
        self.examples = examples
    }
}

/// A passage to be coded — created once, coded by everybody.
public struct CodingUnit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// Which transcript it came from. A plain string because the transcripts
    /// live in M7 and this module does not reach for them; the id is enough to
    /// point back.
    public let documentID: String
    /// Where in that document, so a quotation in a manuscript can be traced to
    /// the passage it came from rather than to the whole interview.
    public let range: Range<Int>
    public var text: String

    public init(id: String = OpaqueID.make(OpaqueID.codingUnit),
                documentID: String, range: Range<Int>, text: String) {
        self.id = id
        self.documentID = documentID
        self.range = range
        self.text = text
    }
}

/// One coder's decision about one unit.
public struct CodeAssignment: Sendable, Codable, Equatable, Identifiable {
    public let unitID: String
    public let coder: String
    /// `nil` means this coder decided the passage carries none of the codes —
    /// which is a decision, and different from not having looked at it.
    public let codeID: String?
    public let at: Date

    public var id: String { "\(unitID)|\(coder)" }

    public init(unitID: String, coder: String, codeID: String?, at: Date = Date()) {
        self.unitID = unitID
        self.coder = coder
        self.codeID = codeID
        self.at = at
    }
}

public struct Codebook: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let projectID: ProjectID
    public var title: Bilingual
    public var codes: [Code]
    /// The order transcripts were coded in. Saturation is a claim about a
    /// sequence, so the sequence has to be recorded rather than inferred from
    /// whatever order a database returns rows in.
    public var documentOrder: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = OpaqueID.make(OpaqueID.codebook),
                projectID: ProjectID,
                title: Bilingual,
                codes: [Code] = [],
                documentOrder: [String] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.codes = codes
        self.documentOrder = documentOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func code(_ id: String) -> Code? { codes.first { $0.id == id } }

    /// Codes with no definition, and codes whose parent is not in the book.
    ///
    /// Reported rather than refused, for the same reason the blueprint reports
    /// rather than refuses: half-finished work has to be saveable, and the place
    /// to be strict is where a number gets published.
    public var problems: [CodebookProblem] {
        var found: [CodebookProblem] = []
        for code in codes {
            if code.definition.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(.undefined(code.id, code.name.thai))
            }
            if let parent = code.parentID, self.code(parent) == nil {
                found.append(.danglingParent(code.id, code.name.thai))
            }
        }
        return found
    }
}

public enum CodebookProblem: Sendable, Equatable {
    case undefined(String, String)
    case danglingParent(String, String)

    public var text: String {
        switch self {
        case .undefined(_, let name):
            localised("code “\(name)” has no definition — an undefined code is a word two coders each read their own way ", "A codebook problem. Placeholder: the code's name.")
                + localised("and it surfaces later as a low κ nobody can account for", "Ends the undefined-code problem.")
        case .danglingParent(_, let name):
            localised("code “\(name)” points at a parent code that is not in the codebook", "A codebook problem. Placeholder: the code's name.")
        }
    }
}
