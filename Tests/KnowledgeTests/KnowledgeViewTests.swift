import Testing
import Foundation
import AgentKit
@testable import Knowledge

// ─────────────────────────────────────────────────────────────
// One graph, six views (ARCHITECTURE §21.2, P12.1–P12.5).
//
// The Done-when for P12.2 is "six roles genuinely search the same knowledge
// base differently", and for P12.3 it is that turning `policy` off in a
// manifest changes nothing. The second is the one worth building the type
// around: a role that cannot see the rules it is bound by will break them, and
// the manifest line that did it would read like a typo.
// ─────────────────────────────────────────────────────────────

private func chunk(_ text: String,
                   scope: Scope = .project(ProjectID("pj")),
                   tier: SourceTier? = .t3,
                   authors: [String] = ["ผู้เขียน ก"],
                   year: Int? = 2023,
                   entities: [String] = [],
                   origin: Origin? = nil) -> IndexedChunk {
    let provenance: Provenance
    if let tier {
        provenance = Provenance(documentID: "doc_\(abs(text.hashValue))", title: "เอกสาร",
                                origin: origin ?? .upload(filename: "a.pdf"), tier: tier,
                                authors: authors, year: year)
    } else if case .userAuthored(let run) = origin {
        provenance = Provenance.authored(documentID: "doc_\(abs(text.hashValue))",
                                         title: "ผลการรัน", runID: run)
    } else {
        provenance = Provenance.fieldwork(documentID: "doc_\(abs(text.hashValue))",
                                          title: "INT-01", participantCode: "P-1",
                                          collectedAt: Date())
    }
    return IndexedChunk(id: "c_\(UUID().uuidString)", text: text, scope: scope,
                        provenance: provenance, embedding: nil, embeddingProfileID: nil,
                        contentHash: UUID().uuidString, entities: entities)
}

@Suite("Knowledge view — policy cannot be switched off")
struct PolicyAlwaysVisibleTests {

    // P12.3, at the type level: there is no way to *express* a view without
    // policy, so no manifest can produce one.
    @Test("a view that asks for project only still searches policy")
    func policyIsUnioned() {
        let view = KnowledgeView(scopes: [.project])
        #expect(view.visibleScopes.contains(.policy))
    }

    @Test("a manifest that explicitly lists scopes without policy is corrected, and says so")
    func manifestCannotExcludePolicy() throws {
        let json = #"{"scopes":["project","central"],"min_tier":"t3"}"#
        let view = try JSONDecoder().decode(KnowledgeView.self, from: Data(json.utf8))
        #expect(view.visibleScopes.contains(.policy))
        // Corrected, and not silently: a manifest that asked for something it
        // did not get should be able to say so next to the role.
        #expect(view.policyWasAddedBack)
    }

    // Every one of the six, because "policy is always added" is the kind of
    // claim that is true for five roles and forgotten for the sixth.
    @Test("all six standard views can see policy", arguments: Role.allCases)
    func everyRoleSeesPolicy(role: Role) {
        #expect(KnowledgeView.standard(for: role).visibleScopes.contains(.policy))
    }

    // The subtler half: policy chunks must survive the *other* filters too. A
    // rule has no author, no year and no tier, so the Writer's completeness
    // rule and the Researcher's tier floor would each drop it.
    @Test("a policy chunk survives filters that would exclude it on any other scope",
          arguments: Role.allCases)
    func policySurvivesEveryFilter(role: Role) {
        let rule = chunk("ห้ามส่งข้อมูลผู้ป่วยออกนอกเครื่อง",
                         scope: .policy, tier: nil, authors: [], year: nil)
        #expect(KnowledgeView.standard(for: role).admits(rule),
                "\(role) cannot see the rules it is bound by")
    }
}

@Suite("Knowledge view — the six roles differ")
struct RoleViewDifferenceTests {

    /// One knowledge base, the six roles asked the same question.
    private func library() -> KnowledgeIndex {
        var index = KnowledgeIndex()
        try? index.insert(contentsOf: [
            chunk("randomised controlled trial of burnout among nurses",
                  tier: .t1, entities: ["study"]),
            chunk("blog post about nurse burnout with no review",
                  tier: .t5, entities: ["study"]),
            chunk("variable definition for burnout score in the codebook",
                  tier: .t3, entities: ["variable", "codebook"]),
            chunk("burnout api error handling in the module",
                  tier: .t4, year: 2025, entities: ["api", "module"]),
            chunk("burnout summary produced by the analysis run",
                  tier: nil, origin: .userAuthored(runID: "run_1")),
            chunk("burnout interview passage", tier: nil),
            chunk("ห้ามเผยแพร่ข้อมูลผู้เข้าร่วม burnout", scope: .policy,
                  tier: nil, authors: [], year: nil),
        ])
        return index
    }

    // P12.2's Done-when, in one assertion: the same question, six answers.
    @Test("the same query returns different chunks for different roles")
    func rolesSeeDifferentThings() {
        let index = library()
        var seen: [Role: Set<String>] = [:]
        for role in Role.allCases {
            let results = index.search("burnout", scope: .project(ProjectID("pj")),
                                       view: .standard(for: role), limit: 10)
            seen[role] = Set(results.map(\.chunk.text))
        }
        // Not all identical — which is the whole claim.
        #expect(Set(seen.values.map { $0.sorted().joined() }).count > 1)
        // And every role saw the rule.
        for (role, texts) in seen {
            #expect(texts.contains { $0.contains("ห้ามเผยแพร่") },
                    "\(role) did not see the policy chunk")
        }
    }

    // P12.4. Filtered at retrieval, so the Writer never builds a paragraph
    // around a citation it cannot complete.
    @Test("the Writer never sees a chunk it could not cite")
    func writerSeesOnlyCitableChunks() {
        let results = library().search("burnout", scope: .project(ProjectID("pj")),
                                       view: .standard(for: .writer), limit: 10)
        for result in results where result.chunk.scope != .policy {
            #expect(KnowledgeView.hasCompleteProvenance(result.chunk),
                    "the Writer was shown “\(result.chunk.text)”, which has no complete citation")
        }
        #expect(results.contains { $0.chunk.text.contains("interview") } == false)
    }

    // P12.5. A review that reads the maker's sources reaches the maker's
    // conclusion.
    @Test("the Reviewer sees evidence and rules, not the material the maker worked from")
    func reviewerSeesEvidenceOnly() {
        let results = library().search("burnout", scope: .project(ProjectID("pj")),
                                       view: .standard(for: .reviewer), limit: 10)
        for result in results where result.chunk.scope != .policy {
            guard case .userAuthored = result.chunk.provenance.origin else {
                Issue.record("the Reviewer was shown “\(result.chunk.text)”")
                return
            }
        }
        #expect(results.contains { $0.chunk.text.contains("analysis run") })
    }

    // The Researcher's floor is real: a T5 blog does not become a source
    // because it was the only thing that matched.
    @Test("the Researcher's tier floor excludes a weak source even when it matches well")
    func researcherFloorHolds() {
        let results = library().search("burnout", scope: .project(ProjectID("pj")),
                                       view: .standard(for: .researcher), limit: 10)
        #expect(results.contains { $0.chunk.text.contains("blog post") } == false)
        #expect(results.contains { $0.chunk.text.contains("randomised") })
    }

    // Primary data is not on the tier scale (§11.3); asking for "at least T3
    // published sources" is not asking to be shown an interview.
    @Test("a tier floor excludes untiered primary data rather than admitting it")
    func untieredIsNotBelowTheFloor() {
        let view = KnowledgeView(minTier: .t3)
        #expect(view.admits(chunk("interview passage", tier: nil)) == false)
    }

    // §5.1 at the retrieval layer: the lead does not do the work.
    @Test("the Team Lead walks no hops")
    func leadStaysAtTheSummary() {
        #expect(KnowledgeView.standard(for: .teamLead).hops == 0)
    }
}

@Suite("Knowledge view — reading it out of a manifest")
struct KnowledgeViewDecodingTests {

    // The P8.4 lesson: Codable's synthesised decoder makes every field
    // required, which rejects a manifest for being ordinary.
    @Test("a manifest that mentions one field decodes, with sensible everything else")
    func partialManifestDecodes() throws {
        let view = try JSONDecoder().decode(KnowledgeView.self,
                                            from: Data(#"{"min_tier":"t2"}"#.utf8))
        #expect(view.minTier == .t2)
        #expect(view.hops == 1)
        #expect(view.visibleScopes.contains(.policy))
        #expect(view.requiresCompleteProvenance == false)
    }

    @Test("an empty object is a valid view")
    func emptyObjectDecodes() throws {
        let view = try JSONDecoder().decode(KnowledgeView.self, from: Data("{}".utf8))
        #expect(view.visibleScopes == [.project, .central, .policy])
    }

    @Test("the full manifest shape from §21.2 decodes as written")
    func fullManifestDecodes() throws {
        let json = """
            {"scopes":["project","central"],
             "entity_types":["study","construct"],
             "min_tier":"t3","hops":2,
             "boost":["systematic_review","rct"],
             "prefer_after":2020}
            """
        let view = try JSONDecoder().decode(KnowledgeView.self, from: Data(json.utf8))
        #expect(view.entityTypes == ["study", "construct"])
        #expect(view.minTier == .t3)
        #expect(view.hops == 2)
        #expect(view.preferAfter == 2020)
        #expect(view.boost.contains("rct"))
    }

    // What is written back is what will be searched, not what was asked for.
    @Test("encoding writes the scopes that will actually be used")
    func encodesEffectiveScopes() throws {
        let data = try JSONEncoder().encode(KnowledgeView(scopes: [.project]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("policy"))
    }
}
