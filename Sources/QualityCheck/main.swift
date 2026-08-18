import Foundation
import AgentKit
import LLMProviders
import CoreEngine

// ─────────────────────────────────────────────────────────────
// How good the judgements are, on the model that is actually serving (P9.1,
// and the measurement P15.7 is waiting on).
//
// `routing.golden` and `risk.golden` pin the decisions the system makes *before*
// it asks a model. This is the other half: the decisions it makes *with* one.
// Those cannot be a byte-exact golden file — the same prompt does not produce
// the same sentence twice, and a check that demands it teaches people to
// regenerate the file rather than read it (E7/E8).
//
// So what is pinned is **accuracy against cases with a known answer**, and the
// floor it must not drop below. The cases are conflict judgements because that
// is where being wrong is expensive and quiet: a card wrongly filed is noise a
// person learns to dismiss, and a real contradiction wrongly dismissed is two
// papers disagreeing about a dose with nothing on screen ever saying so.
//
// An executable rather than a test for the reason every probe here is one: it
// needs an endpoint, and it takes minutes. `check.sh --full` runs it.
//
//     swift run QualityCheck [http://host:8000/v1]
// ─────────────────────────────────────────────────────────────

/// One case, and what a competent reader would answer.
struct Case: Sendable {
    let name: String
    let a: String
    let b: String
    let topic: String
    /// Whether the two really contradict each other.
    let contradicts: Bool
    /// Why this case is here — printed beside a wrong answer, because a score
    /// with no example is a number nobody can act on.
    let matters: String
}

let cases: [Case] = [
    // ── genuine contradictions ────────────────────────────────
    Case(name: "เวลาให้ยาก่อนผ่าตัด",
         a: "ควรให้ยาปฏิชีวนะป้องกันภายใน 60 นาทีก่อนลงมีด",
         b: "ควรให้ยาปฏิชีวนะป้องกันอย่างน้อย 2 ชั่วโมงก่อนลงมีด",
         topic: "เวลาให้ยาปฏิชีวนะป้องกันก่อนผ่าตัด",
         contradicts: true,
         matters: "ช่วงเวลาที่ทับกันไม่ได้ ในคำแนะนำเดียวกัน"),
    Case(name: "ขนาดยาต่างกัน",
         a: "ผู้ใหญ่ควรได้ cefazolin 2 กรัมก่อนผ่าตัด",
         b: "ผู้ใหญ่ควรได้ cefazolin 1 กรัมก่อนผ่าตัด",
         topic: "ขนาด cefazolin ก่อนผ่าตัด",
         contradicts: true,
         matters: "ขนาดยาที่ต่างกันสองเท่า สำหรับประชากรเดียวกัน"),
    Case(name: "ให้ซ้ำหรือไม่",
         a: "ไม่ต้องให้ยาปฏิชีวนะซ้ำหลังผ่าตัดเสร็จ",
         b: "ต้องให้ยาปฏิชีวนะต่ออีก 24 ชั่วโมงหลังผ่าตัด",
         topic: "การให้ยาต่อหลังผ่าตัด",
         contradicts: true,
         matters: "ทำกับไม่ทำ ในคำถามเดียวกัน"),
    Case(name: "ข้ามภาษา",
         a: "Prophylactic antibiotics should be given within 60 minutes of incision",
         b: "ควรให้ยาปฏิชีวนะป้องกันก่อนลงมีดอย่างน้อยสามชั่วโมง",
         topic: "timing of surgical prophylaxis",
         contradicts: true,
         matters: "ขัดกันจริง แต่คนละภาษา — เกณฑ์ต้องไม่ปล่อยผ่านเพราะอ่านคนละสคริปต์"),

    // ── not contradictions ────────────────────────────────────
    Case(name: "พูดเรื่องเดียวกันคนละคำ",
         a: "ควรให้ยาปฏิชีวนะป้องกันภายใน 1 ชั่วโมงก่อนลงมีด",
         b: "แนะนำให้ยาป้องกันในช่วง 60 นาทีก่อนเริ่มผ่าตัด",
         topic: "เวลาให้ยาปฏิชีวนะป้องกัน",
         contradicts: false,
         matters: "เหมือนกันทุกอย่าง ต่างแค่ถ้อยคำ — ถ้าอันนี้ขึ้นการ์ด คลังจะเต็มไปด้วยขยะ"),
    Case(name: "คนละคำถาม",
         a: "ควรให้ยาปฏิชีวนะป้องกันภายใน 60 นาทีก่อนลงมีด",
         b: "ควรโกนขนบริเวณผ่าตัดด้วยเครื่องตัด ไม่ใช่มีดโกน",
         topic: "การเตรียมผู้ป่วยก่อนผ่าตัด",
         contradicts: false,
         matters: "คนละคำถามกันคนละเรื่อง — ต้องถูกปฏิเสธด้วยเกณฑ์ ไม่ใช่ด้วยความไม่มั่นใจ"),
    Case(name: "คนละประชากร",
         a: "ผู้ใหญ่ควรได้ cefazolin 2 กรัมก่อนผ่าตัด",
         b: "เด็กควรได้ cefazolin 30 มก./กก. ก่อนผ่าตัด",
         topic: "ขนาด cefazolin",
         contradicts: false,
         matters: "ตัวเลขต่างกันเพราะประชากรต่างกัน — ทั้งคู่ถูกในบริบทของตัวเอง"),
    Case(name: "เสริมกัน ไม่ได้ค้าน",
         a: "ควรให้ยาปฏิชีวนะป้องกันภายใน 60 นาทีก่อนลงมีด",
         b: "ควรเลือกยาให้ครอบคลุมเชื้อที่พบบ่อยในการผ่าตัดชนิดนั้น",
         topic: "หลักการให้ยาป้องกัน",
         contradicts: false,
         matters: "สองด้านของคำแนะนำเดียวกัน — เวลา กับ การเลือกยา"),
]

// ── endpoint ────────────────────────────────────────────────
let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
let endpointText = argument
    ?? ProcessInfo.processInfo.environment["COAI_TEST_ENDPOINT"]
    ?? "http://192.168.1.205:8000/v1"
guard let baseURL = URL(string: endpointText) else {
    print("   ✗ ใช้ URL นี้ไม่ได้: \(endpointText)")
    exit(1)
}

print("── endpoint ──")
let executor = VLLMExecutor(identifier: "tier1", baseURL: baseURL, model: "")
guard await executor.isAvailable() else {
    // Not a failure: a laptop away from the LAN is a real state, and the round
    // that skipped it says so out loud rather than passing quietly.
    print("   ⊘ ข้าม: \(baseURL.absoluteString) ไม่ตอบ — ไม่มีอะไรให้วัด")
    exit(0)
}
let modelName = (try? await executor.resolveModel()) ?? "(ไม่ทราบชื่อ)"
print("   \(baseURL.absoluteString) · \(modelName)")

let router = ModelRouter(executors: [executor])
let detector = ConflictDetector(router: router)

// ── the run ─────────────────────────────────────────────────
print("")
print("── การตัดสินข้อขัดแย้ง (\(cases.count) เคส) ──")

struct Outcome: Sendable {
    let kase: Case
    let said: Bool
    let detail: String
    let correct: Bool
    let seconds: Double
}

var outcomes: [Outcome] = []
for kase in cases {
    let started = ContinuousClock.now
    let result = await detector.examine(kase.a, kase.b, about: kase.topic)
    let seconds = Double(started.duration(to: .now).components.seconds)

    let said: Bool
    let detail: String
    switch result {
    case .success(let finding):
        said = finding.contradicts
        detail = "ขัดกัน · ความมั่นใจ \(String(format: "%.2f", finding.confidence))"
    case .failure(let why):
        said = false
        detail = switch why {
        case .differentQuestion: "ไม่ขัด — คนละคำถาม"
        case .notMutuallyExclusive: "ไม่ขัด — อยู่ด้วยกันได้"
        case .differentContext: "ไม่ขัด — คนละบริบท"
        case .notConfidentEnough(let c): "ไม่ขัด — ไม่มั่นใจพอ (\(String(format: "%.2f", c)))"
        case .modelSaidNo: "ไม่ขัด — โมเดลบอกว่าไม่"
        case .modelUnavailable: "⚠ เรียกโมเดลไม่ได้"
        case .unparseable: "⚠ อ่านคำตอบไม่ออก"
        case .truncated(let n): "⚠ คำตอบไม่จบ — หมดโควตาที่ \(n) โทเคน"
        }
    }
    let correct = said == kase.contradicts
    outcomes.append(Outcome(kase: kase, said: said, detail: detail,
                            correct: correct, seconds: seconds))
    let mark = correct ? "✓" : "✗"
    print("   \(mark) \(kase.name) — \(detail) [\(String(format: "%.0f", seconds))s]")
    if !correct {
        print("       ควรตอบ: \(kase.contradicts ? "ขัดกัน" : "ไม่ขัดกัน") — \(kase.matters)")
    }
}

// ── the score, and the floor ────────────────────────────────
let correct = outcomes.filter(\.correct).count
let total = outcomes.count
let contradictionCases = outcomes.filter { $0.kase.contradicts }
let agreementCases = outcomes.filter { !$0.kase.contradicts }
let missed = contradictionCases.filter { !$0.correct }.count       // false negatives
let spurious = agreementCases.filter { !$0.correct }.count          // false positives

print("")
print("── คะแนน ──")
print("   ถูก \(correct)/\(total)")
print("   ข้อขัดแย้งจริงที่ *พลาด*: \(missed)/\(contradictionCases.count)   ← แพงที่สุด: ไม่มีอะไรบนหน้าจอบอกว่ามีเรื่องต้องตัดสิน")
print("   คู่ที่ไม่ขัดแต่ถูกฟ้อง: \(spurious)/\(agreementCases.count)   ← ถูกกว่า แต่ทำให้คนเลิกอ่านการ์ด")

/// The recorded floor, beside this file so a change to it is a visible diff.
let floorFile = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "quality.floor")
let recorded = (try? String(contentsOf: floorFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)

if ProcessInfo.processInfo.environment["COAI_QUALITY_UPDATE"] == "1" {
    try? "\(correct)".write(to: floorFile, atomically: true, encoding: .utf8)
    print("")
    print("   บันทึกพื้นใหม่: \(correct)/\(total) — อ่าน diff ก่อน commit")
    exit(0)
}

guard let recorded, let floor = Int(recorded) else {
    print("")
    print("   ⊘ ยังไม่มีพื้นที่บันทึกไว้ — ตั้งด้วย COAI_QUALITY_UPDATE=1 swift run QualityCheck")
    exit(0)
}

print("   พื้นที่บันทึกไว้: \(floor)/\(total)")
if correct < floor {
    print("")
    print("   ✗ คุณภาพตกจากที่เคยวัดได้ (\(correct) < \(floor))")
    print("     ถ้าเปลี่ยนโมเดลหรือ prompt โดยตั้งใจ ให้รันด้วย COAI_QUALITY_UPDATE=1 ในคอมมิตเดียวกัน")
    exit(1)
}
print("")
print("   ✓ คุณภาพไม่ต่ำกว่าที่เคยวัดได้")
