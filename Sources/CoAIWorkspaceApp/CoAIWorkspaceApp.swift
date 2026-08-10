import SwiftUI
import AppKit
import Config
import Sidecar

@main
struct CoAIWorkspaceApp: App {
    @State private var environment = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Co-AI Workspace") {
            RootView(environment: environment)
                .frame(minWidth: 860, minHeight: 520)
                .task {
                    appDelegate.environment = environment
                    await environment.boot()
                }
        }
        .defaultSize(width: 1_040, height: 700)
        .windowResizability(.contentMinSize)
    }
}

/// Chat once the engine is up, boot status until then. Startup failures stay
/// visible instead of leaving an empty window with no explanation (v1 bug B4).
private struct RootView: View {
    let environment: AppEnvironment
    @State private var showingStatus = false

    var body: some View {
        Group {
            if let engine = environment.engine, !showingStatus {
                ChatView(engine: engine)
            } else {
                BootStatusView(environment: environment)
            }
        }
        .toolbar {
            if environment.engine != nil {
                Toggle(isOn: $showingStatus) {
                    Label("สถานะระบบ", systemImage: "heart.text.square")
                }
                .accessibilityLabel("สลับไปดูสถานะระบบ")
            }
        }
    }
}

/// Sidecars must be torn down on quit; SwiftUI alone gives no reliable hook.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var environment: AppEnvironment?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        Task { @MainActor in
            await environment.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
