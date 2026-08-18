import SwiftUI
import AppKit
import RBridge

// ─────────────────────────────────────────────────────────────
// The R bridge, on a screen (§12.7, P14.1).
//
// The Done-when names two machines, and this view is judged on the second:
// **on a machine without R, it says what to install** — the name of the thing,
// where it comes from, and what to do next. Not "connection refused", not a
// red light with no sentence beside it.
//
// It writes the script and hands over the command; it never starts R itself,
// and it never installs a package. Both of those are in the file that
// generates the bridge, with the reasons.
// ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class RBridgeViewModel {
    private(set) var status: RSetupStatus?
    /// What `health` said last time it was asked, as a sentence either way.
    private(set) var health: String?
    private(set) var isHealthy = false
    private(set) var scriptPath: String?
    private(set) var problem: String?

    private let directory: URL
    private let probe = RProbe()

    init(directory: URL) {
        self.directory = directory
    }

    var startCommand: String {
        BridgeScript.startCommand(scriptPath: scriptPath ?? directory
            .appending(path: BridgeScript.fileName).path(percentEncoded: false))
    }

    func refresh() async {
        status = await probe.status()
        switch await RBridgeClient(scriptPath: startCommand).health() {
        case .success(let version):
            isHealthy = true
            health = t("The bridge is answering — R \(version)",
                       "Status of the R bridge. Placeholder is the R version.")
        case .failure(let error):
            isHealthy = false
            health = error.description
        }
    }

    /// Writes `r-bridge.R` where the analysis files live. Existing edits are
    /// kept; the file belongs to whoever opened it last.
    func writeScript() {
        do {
            scriptPath = try BridgeScript.write(into: directory).path(percentEncoded: false)
            problem = nil
        } catch {
            problem = t("Could not write the file: \(String(describing: error))",
                        "Status message. Placeholder is the underlying error.")
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(startCommand, forType: .string)
    }
}

struct RBridgeSection: View {
    @Bindable var model: RBridgeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.box) {
            SectionHeading(
                title: t("R bridge", "Heading of the R bridge section."),
                help: t("Runs R code with the same R you use in RStudio — the app does not start it for you: you start it, and you can stop it whenever you like (§12.7)",
                        "Explains what the R bridge is and who is in control of it."),
                action: (title: t("Check again", "Button that re-verifies every bound number."),
                         run: { Task { await model.refresh() } }))

            if let status = model.status {
                Text(status.nextStep)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: Space.row) {
                // The light says a word as well as a colour: a red dot on its
                // own is a state, not information.
                Image(systemName: model.isHealthy ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.isHealthy ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(model.health ?? t("not checked yet", "R bridge status before it has been probed."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isHealthy
                                ? t("the bridge is running", "Screen-reader label for a healthy R bridge.")
                                : t("the bridge is not running", "Screen-reader label for an unavailable R bridge."))

            HStack(spacing: Space.row) {
                Button(t("Create r-bridge.R", "Button that writes the bridge script.")) {
                    model.writeScript()
                }
                    .accessibilityHint(t("writes the bridge script into the analysis folder without overwriting one you have edited",
                                         "Screen-reader hint on the create-script button."))
                Button(t("Copy the start command", "Button that copies the command that starts the bridge.")) {
                    model.copyCommand()
                }
                    .accessibilityHint(t("copies a command to paste into a terminal to start the bridge",
                                         "Screen-reader hint on the copy-command button."))
            }

            Text(model.startCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .contentBox()

            // P14.4's half that belongs on a screen: the bridge runs as you,
            // in your home directory, with your library paths. Somebody
            // deciding whether to open it needs that said plainly.
            Text(localised: "The bridge runs with your own permissions, sees every file you see, and uses your R libraries — so code sent to it is always classed high risk and stops to ask first, exactly like `run_shell` · it listens on 127.0.0.1 only, so no other machine on the network can call it",
                 "States what the R bridge can reach and why it is high risk.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task { await model.refresh() }
    }
}
