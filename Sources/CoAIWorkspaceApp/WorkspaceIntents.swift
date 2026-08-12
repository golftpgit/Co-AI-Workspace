import Foundation
import AppIntents
import Channels

// ─────────────────────────────────────────────────────────────
// App Intents (ARCHITECTURE §14.3, P7.5) — the feature v1 did not have.
//
// These structs are deliberately the thinnest thing in the app. Every intent
// does the same three things: find the channel, ask it, say what came back.
// The waiting, the correlation, the "this is stuck at an approval" distinction
// and the timeout all live in `AppIntentsChannel`, in a module with tests,
// because none of that can be checked from here — an intent's `perform()` is
// only reachable with an app bundle Siri can see.
//
// **What is not here is as deliberate.** No intent runs a tool, chooses a
// model or approves anything. An intent produces text that goes to the same
// `AgentTurnRunner` as the chat window, and the hook chain decides the rest.
// Siri is a way in, not a way around (§8.2).
// ─────────────────────────────────────────────────────────────

/// How an intent finds the running workspace. Set once, when the engine is
/// built; nil before that, which is the answer `.notRunning` exists for.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    var channel: AppIntentsChannel?
    private init() {}
}

private func ask(_ text: String, timeout: Duration = .seconds(60)) async -> String {
    guard let channel = await MainActor.run(body: { IntentBridge.shared.channel }) else {
        return IntentAnswer.notRunning.spoken
    }
    return await channel.ask(text, timeout: timeout).spoken
}

struct AskWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "ถาม Co-AI Workspace"
    static let description = IntentDescription(
        "ถามคำถามกับ workspace แล้วได้คำตอบกลับ เหมือนพิมพ์ในหน้าสนทนา")
    /// The app has to be running for there to be an engine at all, and
    /// launching it takes longer than Siri will wait — so the answer for a
    /// cold start is "still starting", not a blank screen.
    static let openAppWhenRun = false

    @Parameter(title: "คำถาม", requestValueDialog: "อยากถามอะไร")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await ask(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct ProjectProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "สรุปความคืบหน้าโปรเจกต์"
    static let description = IntentDescription("สรุปว่าโปรเจกต์ที่ระบุไปถึงไหนแล้ว")
    static let openAppWhenRun = false

    @Parameter(title: "โปรเจกต์", requestValueDialog: "โปรเจกต์ไหน")
    var project: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await ask("สรุปความคืบหน้าของโปรเจกต์ \(project) แบบสั้น ๆ")
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Research takes minutes, and Siri will not wait minutes. So this one hands
/// the work over and says that it did — a Shortcut that reports "started" and
/// is telling the truth is more useful than one that reports "finished" after
/// timing out.
struct StartResearchIntent: AppIntent {
    static let title: LocalizedStringResource = "เริ่มงานวิจัย"
    static let description = IntentDescription(
        "สั่งให้ทีมเริ่มค้นเรื่องที่ระบุ แล้วมาดูผลในแอปทีหลัง")
    static let openAppWhenRun = false

    @Parameter(title: "หัวข้อ", requestValueDialog: "อยากให้ค้นเรื่องอะไร")
    var topic: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let channel = IntentBridge.shared.channel else {
            return .result(dialog: IntentDialog(stringLiteral: IntentAnswer.notRunning.spoken))
        }
        // A short wait, for the honest reason: long enough to find out the
        // workspace took the job, short enough that Siri is still listening.
        let answer = await channel.ask("เริ่มงานวิจัยเรื่อง \(topic)", timeout: .seconds(20))
        let spoken: String
        switch answer {
        case .answered(let text): spoken = text
        case .timedOut: spoken = "เริ่มค้นเรื่อง \(topic) ให้แล้ว ผลอยู่ในแอป"
        case .needsApproval, .notRunning: spoken = answer.spoken
        }
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

/// The phrases Siri listens for. `applicationName` is what makes them work
/// without the user having to say the bundle name exactly.
struct WorkspaceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskWorkspaceIntent(),
                    phrases: ["ถาม \(.applicationName)",
                              "Ask \(.applicationName)"],
                    shortTitle: "ถาม workspace",
                    systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: ProjectProgressIntent(),
                    phrases: ["สรุปความคืบหน้าใน \(.applicationName)",
                              "Project progress in \(.applicationName)"],
                    shortTitle: "ความคืบหน้า",
                    systemImageName: "chart.bar.doc.horizontal")
        AppShortcut(intent: StartResearchIntent(),
                    phrases: ["เริ่มงานวิจัยใน \(.applicationName)",
                              "Start research in \(.applicationName)"],
                    shortTitle: "เริ่มงานวิจัย",
                    systemImageName: "magnifyingglass")
    }
}
