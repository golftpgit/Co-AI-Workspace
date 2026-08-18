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

// **Why these strings are English literals rather than `t(...)`.**
//
// An intent's `title`, `description` and `@Parameter(title:)` are
// `LocalizedStringResource`, and they are read twice: once by
// `appintentsmetadataprocessor` at build time, to write the metadata Siri and
// Shortcuts index, and once at run time against **`Bundle.main`** — not this
// module's bundle. `t(...)` returns a `String` that has already been looked up
// in the module catalogue, which is the wrong bundle and the wrong moment.
//
// Making them translatable therefore needs a strings table in the app's own
// bundle, which is a second catalogue with its own build step. Until that
// exists these are English only, deliberately, and this comment is the record
// of that rather than a silence somebody has to rediscover (2026-08-18).

struct AskWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Co-AI Workspace"
    static let description = IntentDescription(
        "Ask the workspace a question and get an answer back, the same as typing in Chat")
    /// The app has to be running for there to be an engine at all, and
    /// launching it takes longer than Siri will wait — so the answer for a
    /// cold start is "still starting", not a blank screen.
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await ask(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct ProjectProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarise project progress"
    static let description = IntentDescription("Summarise how far the named project has got")
    static let openAppWhenRun = false

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await ask(t("Briefly summarise the progress of the project \(project)",
                                 "Prompt sent to the model by the progress-summary intent. Placeholder is the project name."))
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Research takes minutes, and Siri will not wait minutes. So this one hands
/// the work over and says that it did — a Shortcut that reports "started" and
/// is telling the truth is more useful than one that reports "finished" after
/// timing out.
struct StartResearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Start research"
    static let description = IntentDescription(
        "Tell the team to start researching a topic, and look at the result in the app later")
    static let openAppWhenRun = false

    @Parameter(title: "Topic", requestValueDialog: "What should it research?")
    var topic: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let channel = IntentBridge.shared.channel else {
            return .result(dialog: IntentDialog(stringLiteral: IntentAnswer.notRunning.spoken))
        }
        // A short wait, for the honest reason: long enough to find out the
        // workspace took the job, short enough that Siri is still listening.
        let answer = await channel.ask(t("Start research on \(topic)",
                                         "Prompt sent to the team by the start-research intent. Placeholder is the topic."),
                                       timeout: .seconds(20))
        let spoken: String
        switch answer {
        case .answered(let text): spoken = text
        case .timedOut: spoken = t("Research on \(topic) has started — the result is in the app",
                                   "Spoken reply when the team is still working. Placeholder is the topic.")
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
                    phrases: ["Ask \(.applicationName)",
                              "Ask \(.applicationName)"],
                    shortTitle: "Ask the workspace",
                    systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: ProjectProgressIntent(),
                    phrases: ["Summarise progress in \(.applicationName)",
                              "Project progress in \(.applicationName)"],
                    shortTitle: "Progress",
                    systemImageName: "chart.bar.doc.horizontal")
        AppShortcut(intent: StartResearchIntent(),
                    phrases: ["Start research in \(.applicationName)",
                              "Start research in \(.applicationName)"],
                    shortTitle: "Start research",
                    systemImageName: "magnifyingglass")
    }
}
