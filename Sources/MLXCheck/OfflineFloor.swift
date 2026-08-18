import Foundation
import LLMProviders
import CoreEngine
import MLXRuntime

// ─────────────────────────────────────────────────────────────
// P5.4 — Tier 0.5 as the guaranteed floor (ARCHITECTURE §9.2 rule 4).
//
// The acceptance test in the plan is "cut the network entirely, and the system
// still works". Cutting the machine's network from a check script would be
// rude and unrepeatable, so the network is removed the way the system will
// actually meet it: the endpoint is there in the configuration and nothing
// answers on it. That is what an outage, a closed laptop lid and an unpaid
// bill all look like from inside the app.
//
// What has to survive is not "chat still replies". It is the *high-impact*
// work: routing and conflict detection are exactly the paths the router keeps
// off the on-device model (E.7), so with the endpoint gone they have nowhere
// to run except Tier 0.5 — and their failure mode is silence, not an error
// (an unreachable model must never read as "these two sources agree").
// ─────────────────────────────────────────────────────────────

enum OfflineFloor {
    /// An endpoint that is configured and unreachable — port 9 is the discard
    /// service and refuses instantly, so the check does not wait on a timeout.
    static let deadEndpoint = URL(string: "http://127.0.0.1:9/v1")!

    /// One chain for every case, the way the app has one.
    ///
    /// It used to be built per call, and the second case then failed with the
    /// model reported `unavailable` — because the *first* case had loaded the
    /// weights into a different `LocalTier`, and admission control asks about
    /// free memory, which those weights were now occupying. Two tiers for one
    /// model double-count it. `Engine` builds exactly one, so a check that
    /// builds several was not testing the thing that ships (E.46).
    private static let shared = MemoisedRouter()

    actor MemoisedRouter {
        private var routers: [String: ModelRouter] = [:]
        func router(for model: LocalModel) -> ModelRouter {
            if let existing = routers[model.name] { return existing }
            let made = ModelRouter(executors: [
                OnDeviceExecutor(),
                LocalTier(model: model),
                VLLMExecutor(baseURL: deadEndpoint, model: "gx10-27b"),
            ])
            routers[model.name] = made
            return made
        }
    }

    static func router(with model: LocalModel) async -> ModelRouter {
        await shared.router(for: model)
    }

    /// High-impact work with the network gone. Must land on Tier 0.5.
    static func routesConsequentialWork(_ model: LocalModel) async throws -> String {
        var request = LLMRequest(messages: [
            .init(.system, "Route the request to a specialist in a research AI team."),
            .init(.user, "ช่วยหางานวิจัยเรื่องวัคซีน mRNA ในผู้สูงอายุ"),
        ])
        request.responseSchema = (name: "Routing", schemaJSON: routingSchema)
        request.maxTokens = 2_048
        request.timeout = 180

        let completion = try await router(with: model).complete(request, policy: .consequential)
        guard completion.tier == .localMLX else {
            throw OfflineFailure("answered by \(completion.producedBy) on \(completion.tier), "
                                 + "not by the local model")
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(completion.structuredText.utf8)) as? [String: Any],
              let role = object["role"] as? String else {
            throw OfflineFailure("no JSON: \(completion.structuredText.prefix(120))")
        }
        return "\(completion.producedBy) → role=\(role)"
    }

    /// The half of §11.6 that fails silently when no model can serve it. With
    /// the endpoint down this is the case U13 described: without Tier 0.5 the
    /// answer for every document is "no conflicts", with no error anywhere.
    static func detectsConflictsOffline(_ model: LocalModel) async throws -> String {
        let router = await router(with: model)
        let detector = ConflictDetector(router: router)
        let finding = await detector.detect(
            "ผู้ป่วยเบาหวานชนิดที่ 2 ควรได้รับ metformin 500 มก. วันละสองครั้งเป็นยาเริ่มต้น",
            "ห้ามใช้ metformin เป็นยาเริ่มต้นในผู้ป่วยเบาหวานชนิดที่ 2 ทุกกรณี",
            about: "ยาเริ่มต้นสำหรับเบาหวานชนิดที่ 2")

        if let finding, finding.contradicts {
            return String(format: "ยกการ์ดขึ้นมา — confidence %.2f", finding.confidence)
        }

        // `nil` has two very different causes, and only one of them is a P5.4
        // failure. The model saying "these agree" — or saying it with too
        // little confidence to raise a card — is a *judgement*, and a 4B model
        // on a 16 GB laptop is allowed a weak one; §9.4 already says a model
        // this size is a fallback, not an analyst. The model never answering
        // at all is the silence U13 describes, where an unreachable tier reads
        // as "no conflicts found" for every document in the library.
        //
        // So the offline floor is proven by the answer arriving, and the
        // quality of that answer is reported rather than asserted.
        let verdict = try await rawVerdict(router: router)
        return "โมเดลตอบแล้ว (แต่ยังไม่ยกการ์ด): \(verdict)"
    }

    /// The detector's own question, asked through the same router, so a nil
    /// finding can be explained instead of merely reported.
    private static func rawVerdict(router: ModelRouter) async throws -> String {
        var request = LLMRequest(messages: [
            .init(.system, "ตอบว่าข้อความสองชิ้นขัดแย้งกันหรือไม่"),
            .init(.user, """
            A: ผู้ป่วยเบาหวานชนิดที่ 2 ควรได้รับ metformin 500 มก. วันละสองครั้งเป็นยาเริ่มต้น
            B: ห้ามใช้ metformin เป็นยาเริ่มต้นในผู้ป่วยเบาหวานชนิดที่ 2 ทุกกรณี
            """),
        ])
        request.responseSchema = (name: "Verdict", schemaJSON: #"""
        {"type":"object",
         "properties":{"contradicts":{"type":"boolean"},"confidence":{"type":"number"}},
         "required":["contradicts","confidence"]}
        """#)
        request.maxTokens = 512
        request.timeout = 120

        let completion = try await router.complete(request, policy: .consequential)
        guard completion.tier == .localMLX else {
            throw OfflineFailure("answered by \(completion.producedBy), not the local model")
        }
        return String(completion.structuredText.prefix(120))
    }

    /// Everything above, but proving the endpoint really is unreachable first —
    /// otherwise a passing run might just mean LM Studio was still up.
    static func endpointIsDown() async throws -> String {
        let executor = VLLMExecutor(baseURL: deadEndpoint, model: "gx10-27b")
        guard await executor.isAvailable() == false else {
            throw OfflineFailure("something is answering on the dead endpoint")
        }
        return "unreachable, as intended"
    }

    static let routingSchema = #"""
    {"type":"object",
     "properties":{"role":{"type":"string","enum":["researcher","analyst","engineer","writer"]},
                   "needsClarification":{"type":"boolean"}},
     "required":["role","needsClarification"]}
    """#
}

struct OfflineFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
