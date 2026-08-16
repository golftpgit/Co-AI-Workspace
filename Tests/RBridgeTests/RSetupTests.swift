import Testing
import Foundation
@testable import RBridge

// ─────────────────────────────────────────────────────────────
// P14.1 — the machine without R is the case that matters.
//
// A setup helper is judged on the machine where the thing is missing. On a
// machine that already works, every implementation looks the same.
//
// These tests never call R. The bridge was driven against the real R on this
// machine and written down (E.28); a test suite that needs R installed would
// fail on the first machine that does not have it — which is precisely the
// situation this feature is for.
// ─────────────────────────────────────────────────────────────

private func probe(locate: String? = "/usr/local/bin/Rscript",
                   version: String? = "4.5.3",
                   packages: String? = "httpuv jsonlite MASS") -> RProbe {
    RProbe(locate: { _ in locate },
           run: { _, arguments in
               arguments.last?.contains("getRversion") == true ? version : packages
           })
}

@Suite("Setting up the R bridge (P14.1)")
struct RSetupTests {

    @Test("no R on the machine says what to install, not what failed")
    func missingRSaysWhatToInstall() async {
        let status = await probe(locate: nil).status()
        guard case .notInstalled = status else {
            Issue.record("expected notInstalled, got \(status)")
            return
        }
        #expect(status.nextStep.contains("cran.r-project.org"))
        // The words a person would have been left with otherwise.
        #expect(status.nextStep.contains("not found") == false)
        #expect(status.nextStep.contains("connection") == false)
    }

    /// The distinction that decides whether somebody spends an afternoon
    /// reinstalling a working R.
    @Test("missing packages is not missing R")
    func missingPackagesIsItsOwnState() async {
        let status = await probe(packages: "MASS ggplot2").status()
        guard case .missingPackages(_, _, let missing) = status else {
            Issue.record("expected missingPackages, got \(status)")
            return
        }
        #expect(missing == ["httpuv", "jsonlite"])
        #expect(status.nextStep.contains("install.packages"))
        #expect(status.nextStep.contains("ติดตั้ง R") == false)
    }

    /// §12.7 and P14.4 agree: installing packages changes the person's machine
    /// and needs their say-so. A helper that installs its own dependencies to
    /// turn its own light green is the failure mode.
    @Test("the helper says how to install and does not install")
    func theHelperDoesNotInstall() async {
        let status = await probe(packages: "MASS").status()
        #expect(status.nextStep.contains("ระบบไม่ติดตั้งให้เอง"))
    }

    @Test("an R that will not answer is reported as broken, not as absent")
    func brokenInstallIsSeparate() async {
        let status = await probe(version: "").status()
        guard case .unusable = status else {
            Issue.record("expected unusable, got \(status)")
            return
        }
        #expect(status.nextStep.contains("ติดตั้งทับ"))
        #expect(status.isReady == false)
    }

    @Test("R with both packages is ready, and says so with the version it found")
    func readyNamesTheVersion() async {
        let status = await probe().status()
        #expect(status.isReady)
        #expect(status.nextStep.contains("4.5.3"))
    }

    @Test("every state has a next step — that is the whole point of the type")
    func everyStateSaysWhatToDo() {
        let states: [RSetupStatus] = [
            .ready(version: "4.5.3", path: "/usr/local/bin/Rscript"),
            .missingPackages(version: "4.5.3", path: "/x", missing: ["httpuv"]),
            .notInstalled(searched: ["/usr/local/bin"]),
            .unusable(path: "/x", detail: "ล้มตอนเรียก"),
        ]
        for state in states {
            #expect(state.nextStep.count > 20, "\(state) has no usable next step")
        }
    }
}

@Suite("The generated bridge script (P14.1)")
struct BridgeScriptTests {

    /// The bridge evaluates arbitrary R. On any interface but loopback that is
    /// a shell for whoever else is on the network.
    @Test("the bridge listens on loopback and nowhere else")
    func loopbackOnly() {
        #expect(BridgeScript.contents.contains("runServer(\"127.0.0.1\""))
        #expect(BridgeScript.contents.contains("0.0.0.0") == false)
    }

    @Test("an R error comes back as R's own message, not as a server failure")
    func rErrorsAreReported() {
        // The script must catch and report; a bare `runServer` would return 500
        // with nothing in it, and R's message is the only thing that says which
        // line was wrong.
        #expect(BridgeScript.contents.contains("conditionMessage(e)"))
        #expect(BridgeScript.contents.contains("tryCatch(run_code"))
    }

    @Test("the copyable command carries a non-default port with it")
    func commandCarriesThePort() {
        #expect(BridgeScript.startCommand(scriptPath: "/tmp/r-bridge.R")
                == "Rscript /tmp/r-bridge.R")
        #expect(BridgeScript.startCommand(scriptPath: "/tmp/r-bridge.R", port: 8791)
                .contains("CO_AI_R_BRIDGE_PORT=8791"))
        // A path with a space that is not quoted is a command that runs the
        // wrong file, or nothing.
        #expect(BridgeScript.startCommand(scriptPath: "/Users/a b/r-bridge.R")
                .contains("\"/Users/a b/r-bridge.R\""))
    }

    /// The header tells the person the file is theirs to edit. A helper that
    /// then rewrites it on the next launch is lying in a comment.
    @Test("a script the person edited is not overwritten")
    func editsSurvive() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "r-bridge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try BridgeScript.write(into: directory)
        try "# ของผมเอง\n".write(to: url, atomically: true, encoding: .utf8)

        _ = try BridgeScript.write(into: directory)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# ของผมเอง\n")

        // And asking for it back is possible, because that is the way out of
        // an edit that broke the bridge.
        _ = try BridgeScript.write(into: directory, overwrite: true)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("runServer"))
    }
}
