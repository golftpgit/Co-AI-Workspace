import Foundation
import AgentKit
import LLMProviders
import CoreEngine

// ─────────────────────────────────────────────────────────────
// How many streams Tier 1 can really take (ARCHITECTURE §17.1, P15.5).
//
// **The number this produces is the one P16 needs.** §22's organisation has a
// span of control — how many specialists a lead may run at once — and the
// figure in the literature is seven, borrowed from ICS, where the subordinates
// are people. Here they are streams on one GPU, and the honest ceiling is
// whatever this machine's answers stop being usable at. Guessing it high makes
// a three-layer organisation that deadlocks in front of a user; guessing it low
// wastes the machine.
//
// An executable rather than a test for the same reason as `MLXCheck`: it needs
// hardware that a laptop running `swift test` does not have, and it takes
// minutes. Run it deliberately:
//
//     swift run TierOneCheck [http://host:8000/v1] [maxTokens]
//
// It goes through `ModelRouter`, not `URLSession`, so what is measured is the
// path the app actually takes — the governor, the availability cache and the
// escalation chain included.
// ─────────────────────────────────────────────────────────────

let arguments = CommandLine.arguments
let endpointArgument = arguments.count > 1 ? arguments[1] : nil
let endpointText = endpointArgument
    ?? ProcessInfo.processInfo.environment["COAI_TEST_ENDPOINT"]
    ?? "http://192.168.1.205:8000/v1"
let maxTokens = arguments.count > 2 ? (Int(arguments[2]) ?? 128) : 128

guard let baseURL = URL(string: endpointText) else {
    print("   ✗ ใช้ URL นี้ไม่ได้: \(endpointText)")
    exit(1)
}

print("── endpoint ──")
print("   \(baseURL.absoluteString)")

// The model name comes from the server (P15.1): an empty name means "whatever
// this one is serving", which is also what makes this script survive a
// checkpoint swap.
let executor = VLLMExecutor(identifier: "tier1", baseURL: baseURL, model: "")
guard await executor.isAvailable() else {
    print("   ⊘ ข้าม: \(baseURL.absoluteString) ไม่ตอบ — ไม่มีอะไรให้วัด")
    exit(0)
}
let modelName = (try? await executor.resolveModel()) ?? "(ไม่ทราบชื่อ)"
print("   เสิร์ฟ \(modelName) · หน้าต่าง \(executor.capabilities.contextWindow)")

let loadReader = ServerLoadReader(baseURL: baseURL)
if let idle = await loadReader.read() {
    print("   คิวก่อนเริ่มวัด: กำลังรัน \(idle.running) · รอ \(idle.waiting)")
    if !idle.isIdle {
        // Somebody else on the LAN is using it. Said out loud rather than
        // measured over the top of them: numbers taken while another workload
        // is resident are not this machine's ceiling, they are today's weather.
        print("   ! เครื่องไม่ว่าง — ตัวเลขข้างล่างจะต่ำกว่าความจริง")
    }
} else {
    print("   ! /metrics อ่านไม่ได้ — วัดได้แต่เวลา ไม่เห็นคิวจริง")
}

let router = ModelRouter(executors: [executor])

/// One request, timed. Identical across levels so the only thing that changes
/// is how many are in flight.
func ask(_ index: Int) async -> (seconds: Double, tokens: Int, failed: String?) {
    var request = LLMRequest(messages: [
        .init(.system, "ตอบสั้นที่สุดเท่าที่ตอบได้"),
        .init(.user, "ข้อ \(index): 17 + 25 เท่ากับเท่าไร"),
    ])
    request.maxTokens = maxTokens
    request.temperature = 0
    request.timeout = 240

    let startedAt = Date()
    do {
        let completion = try await router.complete(request)
        return (Date().timeIntervalSince(startedAt),
                completion.usage?.completionTokens ?? 0, nil)
    } catch {
        return (Date().timeIntervalSince(startedAt), 0, "\(error)")
    }
}

/// Watches the queue while a level runs, so the depth reported is the one that
/// existed during the work rather than after it drained.
actor Peak {
    private(set) var running = 0
    private(set) var waiting = 0
    func note(_ load: ServerLoad) {
        running = max(running, load.running)
        waiting = max(waiting, load.waiting)
    }
}

struct Level {
    let streams: Int
    let wall: Double
    let slowest: Double
    let median: Double
    let tokens: Int
    let peakRunning: Int
    let peakWaiting: Int
    let failures: Int

    var tokensPerSecond: Double { wall > 0 ? Double(tokens) / wall : 0 }
}

func measure(streams: Int) async -> Level {
    let peak = Peak()
    let sampler = Task {
        while !Task.isCancelled {
            if let load = await loadReader.read(timeout: 2) { await peak.note(load) }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    let startedAt = Date()
    var timings: [Double] = []
    var tokens = 0
    var failures = 0
    await withTaskGroup(of: (seconds: Double, tokens: Int, failed: String?).self) { group in
        for index in 0..<streams { group.addTask { await ask(index) } }
        for await result in group {
            timings.append(result.seconds)
            tokens += result.tokens
            if let failed = result.failed {
                failures += 1
                print("     ✗ \(failed.prefix(120))")
            }
        }
    }
    let wall = Date().timeIntervalSince(startedAt)
    sampler.cancel()

    let sorted = timings.sorted()
    return Level(streams: streams,
                 wall: wall,
                 slowest: sorted.last ?? 0,
                 median: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                 tokens: tokens,
                 peakRunning: await peak.running,
                 peakWaiting: await peak.waiting,
                 failures: failures)
}

print("")
print("── หลายสายพร้อมกัน (\(maxTokens) โทเคน/คำขอ) ──")
print("   สาย | เวลารวม | ช้าสุด | กลาง | โทเคน/วิ | คิวสูงสุด (รัน/รอ) | ล้มเหลว")

/// Which levels to walk, e.g. `1,4,6,8,12`. Six and twelve are worth asking for
/// by hand: Foundation's own per-host connection limit sits between them.
let requested = arguments.count > 3
    ? arguments[3].split(separator: ",").compactMap { Int($0) }
    : [1, 2, 4, 8]

var levels: [Level] = []
for streams in requested {
    let level = await measure(streams: streams)
    levels.append(level)
    print(String(format: "   %3d | %6.1fs | %5.1fs | %4.1fs | %7.1f | %d/%d | %d",
                 level.streams, level.wall, level.slowest, level.median,
                 level.tokensPerSecond, level.peakRunning, level.peakWaiting,
                 level.failures))
}

print("")
print("── สรุปสำหรับ P16 ──")

guard let single = levels.first else { exit(0) }

// The ceiling is where a person's answer stops arriving in a usable time, not
// where throughput peaks: batching keeps total tokens/second climbing long
// after each individual answer has become slow enough to abandon.
let ceiling = 2.5
let usable = levels.filter { $0.failures == 0 && $0.median <= single.median * ceiling }
let widest = usable.map(\.streams).max() ?? 1
print(String(format: "   สายเดียวตอบใน %.1f วิ · เกณฑ์ที่ยังรับได้ = ไม่เกิน %.1f เท่า (%.1f วิ)",
             single.median, ceiling, single.median * ceiling))
print("   **span of control ที่วัดได้จริง = \(widest) สายขนาน**"
      + (widest >= 8 ? " (ยังไม่ถึงเพดาน — ลองมากกว่า 8)" : ""))
if let best = levels.max(by: { $0.tokensPerSecond < $1.tokensPerSecond }) {
    print(String(format: "   ปริมาณงานรวมสูงสุดที่ %d สาย: %.1f โทเคน/วินาที (สายเดียวได้ %.1f)",
                 best.streams, best.tokensPerSecond, single.tokensPerSecond))
}
if levels.contains(where: { $0.peakRunning == 0 && $0.peakWaiting == 0 }) {
    print("   ! คิวอ่านได้เป็น 0 ตลอด — /metrics อาจปิดอยู่ ตัวเลขคิวข้างบนจึงไม่ใช่หลักฐาน")
}

// ─────────────────────────────────────────────────────────────
// P15.4 — does the prefix cache actually pay?
//
// The server was started with `--enable-prefix-caching`, and the app is built
// so the stable part of a conversation comes first: one system message, then a
// tool list sorted by name, then the history in order. That is a *claim* about
// how the prompt is assembled. What follows is the measurement, because "the
// prefix should be cached now" is exactly the kind of sentence this project has
// been wrong about before.
//
// Three requests, and the third is the control:
//
//   1. a long prefix, never seen before      → cold
//   2. the same prefix, one short turn added → should hit the cache
//   3. a different prefix of the same length → cold again, proving that (2) was
//      the cache and not the server merely being warmed up
// ─────────────────────────────────────────────────────────────

/// Time to the first token, which is what a person actually waits for. The
/// tokens after it arrive at the generation rate measured above.
func timeToFirstToken(_ messages: [LLMMessage]) async -> (ttft: Double, failed: String?) {
    var request = LLMRequest(messages: messages)
    request.maxTokens = 16
    request.temperature = 0
    request.timeout = 240

    let startedAt = Date()
    do {
        let (_, _, events) = try await router.stream(request)
        for try await event in events {
            switch event {
            case .textDelta, .reasoningDelta:
                return (Date().timeIntervalSince(startedAt), nil)
            default:
                continue
            }
        }
        return (Date().timeIntervalSince(startedAt), "สตรีมจบโดยไม่มีโทเคนเลย")
    } catch {
        return (Date().timeIntervalSince(startedAt), "\(error)")
    }
}

/// Long enough that the prefix is worth caching — a real conversation with a
/// document pasted into it is this size and larger.
func filler(_ seed: String, paragraphs: Int = 40) -> String {
    (1...paragraphs).map { index in
        "ย่อหน้า \(index) ของ\(seed): "
            + String(repeating: "ข้อมูลพื้นฐานของโครงการวิจัยนี้ถูกบันทึกไว้เพื่ออ้างอิงภายหลัง ", count: 6)
    }.joined(separator: "\n")
}

print("")
print("── prefix cache (P15.4) ──")

let sharedPrefix: [LLMMessage] = [
    .init(.system, "คุณเป็นผู้ช่วยวิจัย ตอบสั้นที่สุดเท่าที่ตอบได้"),
    .init(.user, filler("โครงการ ก")),
    .init(.assistant, "รับทราบครับ"),
]

let cold = await timeToFirstToken(sharedPrefix + [.init(.user, "สรุปสั้น ๆ ว่าเอกสารนี้เกี่ยวกับอะไร")])
let warm = await timeToFirstToken(sharedPrefix + [
    .init(.user, "สรุปสั้น ๆ ว่าเอกสารนี้เกี่ยวกับอะไร"),
    .init(.assistant, "เป็นบันทึกอ้างอิงของโครงการ"),
    .init(.user, "แล้วย่อหน้าแรกพูดถึงอะไร"),
])
let other = await timeToFirstToken([
    .init(.system, "คุณเป็นผู้ช่วยวิจัย ตอบสั้นที่สุดเท่าที่ตอบได้"),
    .init(.user, filler("โครงการ ข")),
    .init(.assistant, "รับทราบครับ"),
    .init(.user, "สรุปสั้น ๆ ว่าเอกสารนี้เกี่ยวกับอะไร"),
])

for (label, result) in [("คำขอแรก (เย็น)", cold),
                        ("คำขอที่สอง prefix เดิม", warm),
                        ("prefix อื่น ยาวเท่ากัน (ตัวคุม)", other)] {
    if let failed = result.failed {
        print("   ✗ \(label): \(failed.prefix(120))")
    } else {
        print(String(format: "   %-32@ TTFT %.2f วินาที", label as NSString, result.ttft))
    }
}

if cold.failed == nil, warm.failed == nil, other.failed == nil {
    let saved = (1 - warm.ttft / cold.ttft) * 100
    print(String(format: "   prefix เดิมเร็วขึ้น %.0f%% · prefix อื่นใช้ %.2f วินาที (ควรใกล้เคียงคำขอแรก)",
                 saved, other.ttft))
    if warm.ttft < cold.ttft * 0.7 && other.ttft > warm.ttft * 1.3 {
        print("   ✓ prefix cache ทำงานจริง และตัวคุมยืนยันว่าไม่ใช่แค่เครื่องอุ่นขึ้น")
    } else {
        print("   ! ยังไม่เห็นผลของ prefix cache อย่างชัดเจน — อย่าเพิ่งอ้างว่ามันช่วย")
    }
}

// ─────────────────────────────────────────────────────────────
// P18.1 — do the criteria survive contact with the model that runs them?
//
// The unit tests prove what the detector does with an answer. They cannot prove
// that this model, reading Thai and English side by side, answers the three
// conditions sensibly — and the symptom that started §11.7 was precisely a
// model answering confidently about a language it could not read.
//
// Eight pairs, the same ones the embedding calibration uses (E.25): four are
// one sentence in two languages, four genuinely disagree across languages. A
// card for any of the first four is the bug. No card for any of the second four
// is the opposite failure, and just as reportable.
// ─────────────────────────────────────────────────────────────

let translations: [(String, String)] = [
    ("การนอนหลับที่เพียงพอช่วยลดความเสี่ยงของโรคหัวใจในผู้ใหญ่",
     "Adequate sleep reduces the risk of heart disease in adults"),
    ("การออกกำลังกายสม่ำเสมอช่วยควบคุมระดับน้ำตาลในเลือดของผู้ป่วยเบาหวานชนิดที่ 2",
     "Regular exercise helps control blood glucose in patients with type 2 diabetes"),
    ("ผู้สูงอายุควรได้รับวัคซีนไข้หวัดใหญ่ทุกปีเพื่อลดการเข้ารักษาในโรงพยาบาล",
     "Older adults should receive an annual influenza vaccine to reduce hospital admissions"),
    ("การสูบบุหรี่เพิ่มความเสี่ยงของมะเร็งปอดอย่างมีนัยสำคัญ",
     "Smoking significantly increases the risk of lung cancer"),
]

let disagreements: [(String, String)] = [
    ("ผู้ใหญ่ควรนอนอย่างน้อยวันละ 7 ชั่วโมงเพื่อสุขภาพหัวใจที่ดี",
     "Adults need no more than four hours of sleep for good heart health"),
    ("ผู้ป่วยเบาหวานชนิดที่ 2 ควรเริ่มยา metformin เป็นยาตัวแรกเสมอ",
     "Metformin should never be used as first-line therapy in type 2 diabetes"),
    ("วัคซีนไข้หวัดใหญ่ลดอัตราการเข้ารักษาในโรงพยาบาลของผู้สูงอายุ",
     "Influenza vaccination has no effect on hospital admissions in older adults"),
    ("การสูบบุหรี่เพิ่มความเสี่ยงของมะเร็งปอด",
     "Smoking has no measurable association with lung cancer risk"),
]

print("")
print("── เกณฑ์ข้อขัดแย้งกับโมเดลจริง (P18.1) ──")

let detector = ConflictDetector(router: router)

var falseCards = 0
for (thai, english) in translations {
    let outcome = await detector.examine(thai, english)
    switch outcome {
    case .success(let finding):
        falseCards += 1
        print(String(format: "   ✗ คำแปลถูกยกเป็นการ์ด (%.2f): %@",
                     finding.confidence, String(finding.explanation.prefix(70))))
    case .failure(let reason):
        print("   ✓ คำแปลไม่ถูกยก — \(reason)")
    }
}

var missed = 0
for (thai, english) in disagreements {
    let outcome = await detector.examine(thai, english)
    switch outcome {
    case .success(let finding):
        print(String(format: "   ✓ ขัดแย้งจริงถูกยก (%.2f)", finding.confidence))
    case .failure(let reason):
        missed += 1
        print("   ✗ ขัดแย้งจริงถูกมองข้าม — \(reason)")
    }
}

print("")
print("   คำแปลที่ถูกยกผิด \(falseCards)/\(translations.count) "
      + "· ข้อขัดแย้งจริงที่พลาด \(missed)/\(disagreements.count)")
if falseCards == 0 && missed == 0 {
    print("   ✓ เกณฑ์ §11.7 ทำงานกับโมเดลนี้จริง")
} else if falseCards > 0 {
    print("   ! ยังยกคำแปลเป็นการ์ดอยู่ — อาการเดิมของ §11.7 ยังไม่หาย")
} else {
    print("   ! เกณฑ์แน่นเกินไปกับโมเดลนี้ — ข้อขัดแย้งจริงหลุด ซึ่งเป็นความเสียหายอีกด้าน")
}
