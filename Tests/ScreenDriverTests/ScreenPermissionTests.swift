import Testing
import Foundation
@testable import ScreenDriver

// ─────────────────────────────────────────────────────────────
// P17.3 — the permission that disappears when the app is rebuilt.
//
// §23.2 rule 2: TCC keys permission to the binary's signature, this app is
// ad-hoc signed (R11), and the symptom of a rebuild is a driver that worked
// last week doing nothing at all with no message anywhere. "Turn it on" is
// useless advice to somebody looking at a switch that is already on — the entry
// has to be removed and re-added — so the two states have to be told apart.
// ─────────────────────────────────────────────────────────────

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("coai-permission-\(UUID().uuidString).json")
}

@Suite("Permission this process cannot give itself")
struct ScreenPermissionTests {

    @Test("a permission that was granted and is now missing is reported as revoked")
    func revocationIsToldApartFromNeverGranted() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ScreenPermissionReader(rememberingIn: file)

        // Yesterday, on the previous build.
        reader.remember([.accessibility, .screenRecording])
        // Today, after `swift build` re-signed the binary.
        let state = ScreenPermission(granted: [],
                                     revoked: reader.lastKnown().subtracting([]))

        #expect(state.revoked.contains(.accessibility))
        let message = state.instructions.joined(separator: "\n")
        #expect(message.contains("เคยอนุญาตไว้แล้วแต่ตอนนี้ใช้ไม่ได้"))
        #expect(message.contains("เอารายการเดิมออก"),
                "telling somebody to switch on a switch that is already on")
        #expect(message.contains("ลายเซ็น"))
    }

    @Test("a first run says where to go, and what each permission is for")
    func firstRunSaysWhereToGo() {
        let state = ScreenPermission(granted: [])
        let message = state.instructions.joined(separator: "\n")
        #expect(state.canDrive == false)
        // The exact pane, because "grant accessibility permission" is not an
        // instruction anybody can follow on a machine they have not set up.
        #expect(message.contains("การช่วยการเข้าถึง"))
        #expect(message.contains("การบันทึกหน้าจอ"))
        #expect(message.contains("หาและกดปุ่มบนหน้าจอ"))
    }

    @Test("accessibility alone is enough to drive; a picture is a bonus")
    func screenRecordingIsNotRequired() {
        // §23.3 asks for an AX snapshot *and* an image. The snapshot is the
        // part that has to be there — a driver refusing to work because it
        // cannot take a photograph would be refusing over the weaker evidence.
        let state = ScreenPermission(granted: [.accessibility])
        #expect(state.canDrive)
        #expect(state.canCapture == false)
        #expect(state.instructions.count == 1)
    }

    @Test("what was once granted is never forgotten, or a revocation reads as a first run")
    func memoryOnlyGrows() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = ScreenPermissionReader(rememberingIn: file)

        reader.remember([.accessibility])
        reader.remember([])          // today: nothing is granted
        #expect(reader.lastKnown() == [.accessibility],
                "forgetting makes tomorrow's revocation look like a first run")
    }

    @Test("with no memory file the reader still answers, it just cannot spot a revocation")
    func worksWithoutMemory() {
        let reader = ScreenPermissionReader()
        #expect(reader.lastKnown().isEmpty)
        // Deliberately *not* calling `read()` here. It asks the window server
        // whether this process may capture the screen, and under `swift test`
        // that is a question from a process with no GUI connection on whichever
        // thread the suite happens to be running — which crashed the whole test
        // binary, taking every other suite with it. The live read belongs to a
        // real app run; what is testable here is everything around it.
    }
}
