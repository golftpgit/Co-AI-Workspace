import Testing
import Foundation
import AgentKit
import Knowledge
import LLMProviders
@testable import CoreEngine

// ─────────────────────────────────────────────────────────────
// The graph must contain only what the documents say. These drive a scripted
// model so the *guard* is under test, not a particular model's judgement —
// including the case where the model makes something up.
// ─────────────────────────────────────────────────────────────

private struct ScriptedExecutor: LLMExecutor {
    let identifier = "scripted"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: false,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    let json: String

    func isAvailable() async -> Bool { true }
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(json))
            continuation.yield(.finished(reason: "stop"))
            continuation.finish()
        }
    }
}

private struct DeadExecutor: LLMExecutor {
    let identifier = "dead"
    let tier: ModelTier = .selfHosted
    let capabilities = LLMCapabilities(contextWindow: 32_000, supportsTools: false,
                                       supportsStructuredOutput: true,
                                       supportsStreaming: true, supportsVision: false)
    func isAvailable() async -> Bool { false }
    func respond(to request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("offline")) }
    }
}

private func extractor(saying json: String) -> RelationExtractor {
    RelationExtractor(router: ModelRouter(executors: [ScriptedExecutor(json: json)]))
}

private func chunk(_ text: String, id: String = "c1") -> IndexedChunk {
    IndexedChunk(id: id, text: text, scope: .central,
                 provenance: Provenance(documentID: "doc_1", title: "เอกสาร",
                                        origin: .upload(filename: "doc.pdf"), tier: .t2))
}

@Suite("Relation extraction")
struct RelationExtractorTests {
    @Test("a relation the text states is kept, attached to its chunk")
    func statedRelationIsKept() async {
        let source = chunk("กรมควบคุมโรค เผยแพร่ แนวทางการรักษาโรคเบาหวาน ฉบับปรับปรุง")
        let relations = await extractor(saying: #"""
        {"relations":[{"subject":"กรมควบคุมโรค","predicate":"เผยแพร่",
                       "object":"แนวทางการรักษาโรคเบาหวาน"}]}
        """#).relations(in: source)

        #expect(relations.count == 1)
        #expect(relations.first?.subject == "กรมควบคุมโรค")
        #expect(relations.first?.predicate == "เผยแพร่")
        // Traceable to the passage that supports it — an unfalsifiable graph
        // is not knowledge.
        #expect(relations.first?.chunkID == "c1")
    }

    @Test("a relation the text does not contain is dropped")
    func inventedRelationIsDropped() async {
        // The failure this guard exists for: a model filling in what it knows
        // about the subject rather than what the document says.
        let source = chunk("กรมควบคุมโรค เผยแพร่ แนวทางการรักษาโรคเบาหวาน")
        let relations = await extractor(saying: #"""
        {"relations":[{"subject":"องค์การอนามัยโลก","predicate":"รับรอง",
                       "object":"แนวทางการรักษาโรคเบาหวาน"}]}
        """#).relations(in: source)

        #expect(relations.isEmpty, "an entity absent from the chunk reached the graph")
    }

    @Test("both ends have to be present, not just one")
    func partiallyGroundedRelationIsDropped() async {
        let source = chunk("กรมควบคุมโรค เผยแพร่ แนวทางการรักษาโรคเบาหวาน")
        let relations = await extractor(saying: #"""
        {"relations":[{"subject":"กรมควบคุมโรค","predicate":"ร่วมมือกับ",
                       "object":"กระทรวงการคลัง"}]}
        """#).relations(in: source)
        #expect(relations.isEmpty)
    }

    @Test("a chunk that states nothing produces nothing")
    func emptyResultIsEmpty() async {
        let relations = await extractor(saying: #"{"relations":[]}"#)
            .relations(in: chunk("ข้อความทั่วไปที่ไม่ได้ระบุความสัมพันธ์ใดเป็นพิเศษเลย"))
        #expect(relations.isEmpty)
    }

    @Test("unparseable output does not become a relation")
    func garbageIsDropped() async {
        let relations = await extractor(saying: "ไม่แน่ใจครับ")
            .relations(in: chunk("กรมควบคุมโรค เผยแพร่ แนวทางการรักษา"))
        #expect(relations.isEmpty)
    }

    @Test("a self-referential relation is dropped")
    func selfRelationIsDropped() async {
        let relations = await extractor(saying: #"""
        {"relations":[{"subject":"เบาหวาน","predicate":"คือ","object":"เบาหวาน"}]}
        """#).relations(in: chunk("เบาหวาน เป็นภาวะเรื้อรังที่พบบ่อยในผู้สูงอายุ"))
        #expect(relations.isEmpty)
    }

    @Test("an unavailable model yields nothing rather than a wrong graph")
    func unavailableModelYieldsNothing() async {
        let extractor = RelationExtractor(router: ModelRouter(executors: [DeadExecutor()]))
        #expect(await extractor.relations(in: chunk("กรมควบคุมโรค เผยแพร่ แนวทาง")).isEmpty)
    }

    @Test("relations across chunks stay attached to the right one")
    func relationsKeepTheirChunk() async {
        let extractor = extractor(saying: #"""
        {"relations":[{"subject":"อินซูลิน","predicate":"ใช้รักษา","object":"เบาหวาน"}]}
        """#)
        let relations = await extractor.relations(in: [
            chunk("อินซูลิน ใช้รักษา เบาหวาน ในผู้ป่วยผู้ใหญ่", id: "c1"),
            chunk("อินซูลิน ใช้รักษา เบาหวาน ชนิดที่สองด้วย", id: "c2"),
        ])
        #expect(relations.count == 2)
        #expect(Set(relations.map(\.chunkID)) == ["c1", "c2"])
    }
}
