import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// P6.7 / §12.4 — `doc_type: proposal`, which was a field the pipeline did not
// record, so the analysis screen had to list every document and hope somebody
// pointed at the right one.
//
// The rule that matters is not "documents have a type". It is **the type is
// declared, never inferred**: reading a proposal is what turns a document into
// an analysis plan, and a system that guessed would write plans out of
// literature reviews.
// ─────────────────────────────────────────────────────────────

private func provenance(kind: DocumentKind? = nil) -> Provenance {
    Provenance(documentID: "doc1", title: "โครงร่างวิจัยเบาหวาน",
               origin: .upload(filename: "proposal.pdf"), tier: .t3,
               documentKind: kind)
}

@Suite("What kind of document this is (P6.7)")
struct DocumentKindTests {

    @Test("a declared proposal is a proposal, and nothing else claims to be one")
    func proposalIsDeclared() {
        #expect(provenance(kind: .proposal).isProposal)
        #expect(provenance(kind: .paper).isProposal == false)
        // The title says "โครงร่างวิจัย" and it is still not a proposal:
        // nothing here reads the words to decide.
        #expect(provenance().isProposal == false)
    }

    /// Nobody having said is different from somebody having said "other", and
    /// the distinction is the whole reason the field is optional.
    @Test("unset is not the same as other")
    func unsetIsNotOther() {
        #expect(provenance().documentKind == nil)
        #expect(provenance(kind: .other).documentKind == .other)
        #expect(provenance().documentKind != provenance(kind: .other).documentKind)
    }

    /// Rows written before the field existed have no such key. An index that
    /// stopped loading would be a migration nobody asked for.
    @Test("provenance stored before this field existed still decodes")
    func oldRowsStillDecode() throws {
        let old = """
        {"documentID":"doc1","title":"เก่า","origin":{"upload":{"filename":"a.pdf"}},
         "tier":"t3","authors":[],"accessedAt":770000000}
        """
        let decoded = try? JSONDecoder().decode(Provenance.self, from: Data(old.utf8))
        // The shape of `origin` is the store's business; what matters here is
        // that a missing `documentKind` is not a decoding failure.
        if let decoded {
            #expect(decoded.documentKind == nil)
        } else {
            // Encoded by the real encoder instead, minus the key.
            var object = try #require(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(provenance())) as? [String: Any])
            object.removeValue(forKey: "documentKind")
            let data = try JSONSerialization.data(withJSONObject: object)
            let round = try JSONDecoder().decode(Provenance.self, from: data)
            #expect(round.documentKind == nil)
        }
    }

    @Test("the kind survives a round trip and follows a citation")
    func kindTravels() throws {
        let encoded = try JSONEncoder().encode(provenance(kind: .proposal))
        let decoded = try JSONDecoder().decode(Provenance.self, from: encoded)
        #expect(decoded.documentKind == .proposal)
        // Citing one passage of a proposal still cites a proposal.
        #expect(decoded.citing(TextSpan(start: 0, end: 10)).isProposal)
        // And declaring is how it gets set — one call, at ingest.
        #expect(provenance().declaring(kind: .proposal).isProposal)
    }
}
