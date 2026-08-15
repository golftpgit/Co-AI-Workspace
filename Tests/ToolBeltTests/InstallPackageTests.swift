import Testing
import Foundation
import AgentKit
import CoreEngine
import Execution
@testable import ToolBelt

// ─────────────────────────────────────────────────────────────
// The tool that downloads and runs somebody else's code (§10, P8.4).
//
// `RiskScorer` has carried this tool's classification since P1 with a note
// saying it was not built because there had to be a network policy first. The
// tests that matter are therefore not "does pip work" — they are the four
// refusals, and the one about reproducibility.
//
// The refusal worth reading twice is `nameLooksLikeAFlag`. Passing argv instead
// of a shell line stops `pandas; rm -rf ~`, and this project has said so since
// `ProcessSpec.shell` was written. It does **not** stop `--target=/elsewhere`,
// because that is not a shell injection — it is a perfectly ordinary argument
// that the package manager reads as an option. Argv defends the shell; this
// defends the command.
// ─────────────────────────────────────────────────────────────

@Suite("What may be installed")
struct PackageRequestTests {

    @Test("an ordinary name and version become one specifier per manager")
    func buildsSpecifiers() throws {
        let pip = try PackageRequest.checked(manager: "pip", name: "pandas", version: "2.2.1")
        #expect(pip.specifier == "pandas==2.2.1")
        let npm = try PackageRequest.checked(manager: "npm", name: "lodash", version: "4.17.21")
        #expect(npm.specifier == "lodash@4.17.21")
        #expect(try PackageRequest.checked(manager: "pip", name: "pandas").specifier == "pandas")
    }

    // The one argv does not cover.
    @Test("a name that is really an option is refused, and says why that is different")
    func flagNameRefused() {
        #expect(throws: PackageInstallError.nameLooksLikeAFlag("--target=/tmp/elsewhere")) {
            try PackageRequest.checked(manager: "pip", name: "--target=/tmp/elsewhere")
        }
        #expect(throws: PackageInstallError.nameLooksLikeAFlag("-e")) {
            try PackageRequest.checked(manager: "pip", name: "-e")
        }
    }

    @Test("a path is refused — this installs from a registry, not from the disk")
    func pathRefused() {
        for name in ["../evil", "/tmp/thing", "dir/pkg", "a\\b"] {
            #expect(throws: (any Error).self) {
                try PackageRequest.checked(manager: "pip", name: name)
            }
        }
    }

    // Belt and braces: argv already means these cannot become a second command,
    // but a name containing them is somebody trying, and that is worth refusing
    // rather than installing a package that does not exist.
    @Test("shell punctuation in a name is refused even though argv would survive it")
    func shellCharactersRefused() {
        for name in ["pandas; rm -rf ~", "pandas && curl x", "pandas`id`", "a b"] {
            #expect(throws: (any Error).self) {
                try PackageRequest.checked(manager: "pip", name: name)
            }
        }
    }

    @Test("an unknown manager names the ones that exist")
    func unknownManager() {
        #expect(throws: PackageInstallError.unknownManager("cargo")) {
            try PackageRequest.checked(manager: "cargo", name: "serde")
        }
    }

    // A wheel is unpacked; an sdist runs its own setup.py during installation.
    @Test("pip is told to take wheels only, unless source builds were asked for")
    func onlyBinaryByDefault() throws {
        let directory = URL(fileURLWithPath: "/tmp/pkgs")
        let safe = try PackageRequest.checked(manager: "pip", name: "pandas")
        #expect(safe.arguments(into: directory).contains("--only-binary"))

        let allowed = try PackageRequest.checked(manager: "pip", name: "pandas",
                                                 allowSourceBuild: true)
        #expect(allowed.arguments(into: directory).contains("--only-binary") == false)
    }

    // Into the project, never into the machine: a study whose library was
    // installed system-wide is one whose environment moved under it.
    @Test("both managers are pointed at the given directory")
    func installsIntoTheProject() throws {
        let directory = URL(fileURLWithPath: "/tmp/pj/python-packages")
        let pip = try PackageRequest.checked(manager: "pip", name: "pandas")
        #expect(pip.arguments(into: directory).contains("--target"))
        #expect(pip.arguments(into: directory).contains("/tmp/pj/python-packages"))

        let npm = try PackageRequest.checked(manager: "npm", name: "lodash")
        #expect(npm.arguments(into: directory).contains("--prefix"))
    }

    // The name is the last argument, so nothing it contains can be read as an
    // option for something that comes after it.
    @Test("the package name is the final argument")
    func nameIsLast() throws {
        let request = try PackageRequest.checked(manager: "pip", name: "pandas", version: "2.2.1")
        #expect(request.arguments(into: URL(fileURLWithPath: "/tmp")).last == "pandas==2.2.1")
    }
}

@Suite("Reading what was actually installed")
struct PackageOutputReaderTests {

    // `pandas` today and `pandas` in six months are different software. The
    // request usually has no version, which is exactly when this matters.
    @Test("pip's summary line gives the resolved version, not the requested one")
    func readsPipVersion() {
        let output = """
            Collecting pandas
            Installing collected packages: numpy, pandas
            Successfully installed numpy-1.26.4 pandas-2.2.1
            """
        #expect(PackageOutputReader.resolvedVersion(of: "pandas", manager: .pip,
                                                    in: output) == "2.2.1")
        #expect(PackageOutputReader.resolvedVersion(of: "numpy", manager: .pip,
                                                    in: output) == "1.26.4")
    }

    // Copied from a real run rather than from memory of the format:
    //   python3 -m pip install --target … --only-binary :all: six==1.16.0
    @Test("the exact output real pip produced is read correctly")
    func readsMeasuredPipOutput() {
        let output = """
            Collecting six==1.16.0
              Downloading six-1.16.0-py2.py3-none-any.whl.metadata (1.8 kB)
            Downloading six-1.16.0-py2.py3-none-any.whl (11 kB)
            Installing collected packages: six
            Successfully installed six-1.16.0
            """
        #expect(PackageOutputReader.resolvedVersion(of: "six", manager: .pip,
                                                    in: output) == "1.16.0")
    }

    // Also measured: what pip says when `--only-binary :all:` leaves nothing
    // installable. This is the message the refusal has to recognise.
    @Test("pip's real no-wheel message is recognised as the source-build case")
    func recognisesMeasuredRefusal() {
        let output = """
            ERROR: Could not find a version that satisfies the requirement thing (from versions: none)
            ERROR: No matching distribution found for thing
            """
        #expect(PackageOutputReader.needsSourceBuild(output))
    }

    // pip normalises underscores to hyphens on the way out.
    @Test("a name written with underscores still matches what pip prints")
    func matchesNormalisedNames() {
        let output = "Successfully installed scikit-learn-1.4.0"
        #expect(PackageOutputReader.resolvedVersion(of: "scikit_learn", manager: .pip,
                                                    in: output) == "1.4.0")
    }

    @Test("npm's added line gives the version")
    func readsNpmVersion() {
        #expect(PackageOutputReader.resolvedVersion(of: "lodash", manager: .npm,
                                                    in: "+ lodash@4.17.21") == "4.17.21")
    }

    // The honest answer when the output says nothing, rather than echoing back
    // what was asked for as though it had been confirmed.
    @Test("output with no version yields nil, and the record says so out loud")
    func absentVersionIsSaidOutLoud() {
        #expect(PackageOutputReader.resolvedVersion(of: "pandas", manager: .pip,
                                                    in: "done") == nil)
        let record = InstalledPackage(manager: .pip, name: "pandas", resolvedVersion: nil,
                                      installedAt: Date(), directory: "/tmp")
        #expect(record.summary.contains("ทำซ้ำไม่ได้"))
    }

    @Test("the no-wheel failure is recognised, because it is the one the caller can fix")
    func recognisesSourceBuildRefusal() {
        #expect(PackageOutputReader.needsSourceBuild(
            "ERROR: Could not find a version that satisfies the requirement thing"))
        #expect(PackageOutputReader.needsSourceBuild("Killed: 9") == false)
    }
}

@Suite("install_package through the gate")
struct InstallPackageToolTests {

    private func tool() -> InstallPackageTool {
        InstallPackageTool(registry: ProcessRegistry(),
                           directoryForScope: { scope in
                               guard case .project = scope else { return nil }
                               return URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appending(path: "pkgs")
                           })
    }

    // The refusals happen in `precheck`, which the gate runs *before* it asks a
    // person — so a malformed call goes back to the model instead of becoming
    // an approval prompt somebody has to read carefully.
    @Test("a flag-shaped package name is refused before anybody is asked to approve it")
    func refusedAtPrecheck() {
        let context = ToolContext(scope: .project(ProjectID("pj")))
        #expect(throws: (any Error).self) {
            try tool().precheck(argumentsJSON: #"{"manager":"pip","package":"--target=/tmp/x"}"#,
                                context: context)
        }
    }

    // Installing into General would be installing into no project's environment.
    @Test("with no project open there is nowhere to install, and it says so")
    func needsAProject() {
        #expect(throws: (any Error).self) {
            try tool().precheck(argumentsJSON: #"{"manager":"pip","package":"pandas"}"#,
                                context: ToolContext(scope: .central))
        }
    }

    @Test("a well-formed call passes precheck")
    func acceptsAGoodCall() throws {
        try tool().precheck(argumentsJSON: #"{"manager":"pip","package":"pandas","version":"2.2.1"}"#,
                            context: ToolContext(scope: .project(ProjectID("pj"))))
    }

    // The declaration is not what protects anything — the chain scores it
    // independently (§5.3), and this is the tool where that matters most.
    @Test("the hook chain scores it high on its own, whatever the tool declares")
    func scoredHighIndependently() {
        let scorer = DefaultRiskScorer()
        let assessment = scorer.score(toolName: "install_package",
                                      declared: .low,
                                      argumentsJSON: #"{"package":"pandas"}"#,
                                      context: ToolContext(scope: .project(ProjectID("pj"))))
        #expect(assessment.level == .high)
    }
}
