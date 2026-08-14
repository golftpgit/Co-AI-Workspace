import Testing
import Foundation
import AgentKit
import Instruments
import OLTP
@testable import FieldServer

// ─────────────────────────────────────────────────────────────
// Rounds of collection (ARCHITECTURE §20.7, P11.7).
//
// A round is a claim about a population: "these 84 nurses answered between the
// 3rd and the 14th". Everything here defends that claim against the two ways
// software erodes it —
//
//   • closing lived only in the running server, so quitting the app brought a
//     closed round back open;
//   • stopping the server closed the round, so shutting the laptop for the night
//     ended data collection and there was no way to resume it.
//
// Both make the dates in a methods section untrue, and neither is visible from a
// test that never restarts anything.
// ─────────────────────────────────────────────────────────────

private let project = ProjectID("pj_waves")

private func approvedInstrument() throws -> PublishedInstrument {
    let question = ResearchQuestion(text: Bilingual("ความเครียดเป็นอย่างไร"))
    let construct = Construct(name: Bilingual("ความเครียด"), definition: "ความกดดัน",
                              researchQuestionID: question.id)
    let instrument = Instrument(
        projectID: project, title: Bilingual("แบบสอบถาม"),
        researchQuestions: [question], constructs: [construct],
        items: [Item(prompt: Bilingual("ฉันเครียด"),
                     kind: .likert(levels: (1...5).map { Bilingual("ระดับ \($0)") }),
                     constructID: construct.id, order: 1)],
        consent: ConsentText(purpose: Bilingual("ศึกษา"),
                             whatIsCollected: Bilingual("คะแนน"),
                             voluntary: Bilingual("สมัครใจ"),
                             contact: "r@example.ac.th"),
        ethics: .approved(committee: "กรรมการ", number: "COA-3", date: Date(),
                          declaredBy: "ผู้วิจัย"))
    let reviewed = instrument.itemsUnderContentReview
    let ratings = reviewed.flatMap { item in
        ["ก", "ข", "ค"].map {
            ExpertRating(itemID: item.id, expert: $0, congruence: 1, relevance: 4)
        }
    }
    return try InstrumentGate.approve(
        instrument,
        validity: ContentValidity.assess(ratings: ratings, itemIDs: reviewed.map(\.id)),
        by: "ผู้วิจัย")
}

private func answer(_ published: PublishedInstrument) -> HTTPRequest {
    let item = published.instrument.ordered[0].id
    let body = "__consent=yes&__instrument=\(published.instrument.id)&__version=1&\(item)=4"
    return HTTPRequest(method: "POST", path: "/submit",
                       headers: ["content-type": "application/x-www-form-urlencoded"],
                       body: Data(body.utf8))
}

@Suite("Collection rounds")
struct WaveTests {

    private func store() async throws -> (ResponseStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try await ResponseStore(path: directory.appending(path: "responses.sqlite")),
                directory)
    }

    @Test("stopping the server for the night does not end data collection")
    func stoppingDoesNotCloseTheRound() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let evening = FieldServerHost(store: store)
        _ = try await evening.start(serving: published, port: 0)
        _ = await evening.handle(answer(published), from: "192.168.1.5")
        let firstWave = await evening.currentWave?.id
        await evening.stop()

        let rounds = try await store.waves(instrument: published.instrument.id, version: 1)
        #expect(rounds.count == 1)
        #expect(rounds[0].isOpen)

        // Next morning, same laptop. This is one round, not two — counting it as
        // two would split one population across two rows of the write-up.
        let morning = FieldServerHost(store: store)
        _ = try await morning.start(serving: published, port: 0)
        defer { Task { await morning.stop() } }
        #expect(await morning.currentWave?.id == firstWave)
        _ = await morning.handle(answer(published), from: "192.168.1.6")

        let after = try await store.waves(instrument: published.instrument.id, version: 1)
        #expect(after.count == 1)
        #expect(after[0].submissions == 2)
    }

    @Test("a round that was closed stays closed after a restart")
    func closingSurvivesARestart() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FieldServerHost(store: store)
        _ = try await first.start(serving: published, port: 0)
        _ = await first.handle(answer(published), from: "192.168.1.5")
        await first.closeWave()
        let closedWave = try #require(await first.currentWave?.id)
        await first.stop()

        #expect(try await store.waveIsOpen(id: closedWave) == false)

        // Restarting the app used to bring it back open, which turns "we stopped
        // collecting on the 14th" into something nobody can show.
        let second = FieldServerHost(store: store)
        _ = try await second.start(serving: published, port: 0)
        defer { Task { await second.stop() } }
        let newWave = try #require(await second.currentWave?.id)
        #expect(newWave != closedWave)

        let rounds = try await store.waves(instrument: published.instrument.id, version: 1)
        #expect(rounds.count == 2)
        // The closed one keeps its count and its closing date.
        let closed = try #require(rounds.first { $0.id == closedWave })
        #expect(!closed.isOpen)
        #expect(closed.submissions == 1)
    }

    @Test("a round has one closing date, and re-closing does not move it")
    func closingIsIdempotent() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = FieldServerHost(store: store)
        _ = try await host.start(serving: published, port: 0)
        defer { Task { await host.stop() } }
        await host.closeWave()
        let first = try #require(try await store.waves(instrument: published.instrument.id,
                                                       version: 1).first?.closedAt)
        try await Task.sleep(for: .milliseconds(20))
        await host.closeWave()
        let second = try #require(try await store.waves(instrument: published.instrument.id,
                                                        version: 1).first?.closedAt)
        // "When did collection stop" has to keep the same answer.
        #expect(first == second)
    }

    @Test("answers name the round they belong to")
    func submissionsCarryTheirRound() async throws {
        let published = try approvedInstrument()
        let (store, directory) = try await store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FieldServerHost(store: store)
        _ = try await first.start(serving: published, port: 0)
        _ = await first.handle(answer(published), from: "192.168.1.5")
        let wave1 = try #require(await first.currentWave?.id)
        await first.closeWave()
        await first.stop()

        let second = FieldServerHost(store: store)
        _ = try await second.start(serving: published, port: 0)
        defer { Task { await second.stop() } }
        _ = await second.handle(answer(published), from: "192.168.1.6")
        let wave2 = try #require(await second.currentWave?.id)

        let submissions = try await store.submissions(instrument: published.instrument.id,
                                                      version: 1)
        #expect(submissions.count == 2)
        #expect(submissions[0].waveID == wave1)
        #expect(submissions[1].waveID == wave2)
    }
}
