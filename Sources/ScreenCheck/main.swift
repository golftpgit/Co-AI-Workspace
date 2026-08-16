import Foundation
import AppKit
import ScreenDriver

// ─────────────────────────────────────────────────────────────
// Driving a real screen, once somebody has granted the permission
// (§23.2 rule 1 — the system cannot give itself this: P15.1/P17.1/P8.7).
//
// An executable rather than a test, for the reason every probe in this repo is
// one: it needs a real user session with real permission granted, and a suite
// that only passes on one machine is not a suite. What it prints is what the
// accessibility tree actually says, which is the same thing VoiceOver reads —
// so an element with no label here is an element VoiceOver announces as
// nothing.
// ─────────────────────────────────────────────────────────────

@main
struct ScreenCheck {
    static func main() async throws {
        let permission = ScreenPermissionReader().read()
        print("accessibility: \(permission.canDrive ? "granted" : "NOT granted")")
        print("screen recording: \(permission.canCapture ? "granted" : "not granted")")
        guard permission.canDrive else {
            print("  · \(ScreenPermission.Capability.accessibility.settingsPane)")
            return
        }

        // Which app to read: an argument, or this process. Never guessed —
        // a driver that silently drove the wrong app is worse than one that
        // refused (§23.2).
        let name = CommandLine.arguments.dropFirst().first
        let pid: pid_t
        if let name {
            guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == name || $0.bundleIdentifier == name }) else {
                print("no running app called '\(name)'")
                return
            }
            pid = app.processIdentifier
            print("target: \(app.localizedName ?? name) (pid \(pid))")
        } else {
            pid = ProcessInfo.processInfo.processIdentifier
            print("target: this process (pass an app name to read another)")
        }

        let navigator = AXNavigator(pid: pid)
        do {
            let snapshot = try await navigator.snapshot()
            print("window: \(snapshot.windowTitle)")
            let spoken = snapshot.spokenLines
            print("what a screen reader would announce — \(spoken.count) lines")
            for line in spoken.prefix(30) { print("  \(line)") }

            // The P8.7 question, answered from the tree rather than by asking
            // somebody to listen: a control VoiceOver reaches and cannot name.
            // AppKit's own scrollbar parts are unlabelled by design and
            // VoiceOver announces them by role. Counting them would put four
            // permanent failures in every report, which is how a report stops
            // being read (measured: E.30).
            let silent = snapshot.root.flattened.filter { element in
                Self.interactive.contains(element.role)
                    && element.label.isEmpty && (element.value ?? "").isEmpty
                    && !Self.isSystemChrome(element, in: snapshot.root)
            }
            print("\ninteractive elements with nothing to announce: \(silent.count)")
            for element in silent.prefix(20) {
                // The nearest labelled ancestor, because "an unlabelled button
                // at 1463,267" is a coordinate and "the unlabelled button
                // inside the tool card" is a place in the source.
                let where_ = Self.context(of: element, in: snapshot.root)
                print("  [\(element.role)] at "
                      + (element.centre.map { "\(Int($0.x)),\(Int($0.y))" } ?? "—")
                      + " — inside: \(where_)")
            }
            // Neighbours, when asked: an unlabelled control is identified by
            // what sits beside it far more easily than by its coordinates.
            if CommandLine.arguments.contains("--neighbours") {
                print("\nbuttons, by position:")
                for element in snapshot.root.flattened
                where element.role == "AXButton" || element.role == "AXMenuButton" {
                    guard let centre = element.centre else { continue }
                    print("  \(Int(centre.x)),\(Int(centre.y))  "
                          + (element.label.isEmpty ? "—" : element.label))
                }
            }
        } catch {
            print("could not read the screen: \(error)")
        }
    }

    /// Whether this is furniture AppKit drew rather than a control this app
    /// did. Measured, not assumed (E.30): the four unlabelled buttons in the
    /// first run were scrollbar parts and two more were the window's own close
    /// and minimise, all of which VoiceOver announces by role. Counting them
    /// would put six permanent failures in every report, which is how a report
    /// stops being read.
    static let systemSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
        "AXToolbarButton", "AXIncrementArrow", "AXDecrementArrow",
        "AXIncrementPage", "AXDecrementPage",
    ]

    static func isSystemChrome(_ target: ScreenElement, in root: ScreenElement) -> Bool {
        if let subrole = target.subrole, systemSubroles.contains(subrole) { return true }
        return context(of: target, in: root).contains("AXScrollBar")
    }

    /// The nearest labelled thing above an element, which is what turns a
    /// coordinate into somewhere in the source.
    static func context(of target: ScreenElement, in root: ScreenElement) -> String {
        func walk(_ element: ScreenElement, trail: [String]) -> [String]? {
            // Roles as well as labels: a button whose only ancestors are
            // `AXScrollBar` is AppKit's own chrome, and telling that apart
            // from one of ours is the whole question.
            let here = trail + [element.label.isEmpty
                                ? element.role : "\(element.role) “\(element.label)”"]
            if element.centre == target.centre && element.role == target.role { return here }
            for child in element.children {
                if let found = walk(child, trail: here) { return found }
            }
            return nil
        }
        let trail = walk(root, trail: []) ?? []
        return trail.suffix(4).joined(separator: " › ")
    }

    /// Roles a person can act on. A label-less `AXGroup` is layout; a
    /// label-less `AXButton` is a button VoiceOver announces as "button".
    static let interactive: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTabGroup", "AXLink",
    ]
}
