import Testing
import Foundation
@testable import AgentKit

// ─────────────────────────────────────────────────────────────
// P9.4's Done-when, one case at a time.
//
// Three of the four conditions are made for real here rather than described:
// a directory this process genuinely cannot write to, a file that genuinely
// will not parse, a port with genuinely nothing behind it. Errors written by
// hand would only prove that the classifier agrees with my memory of what
// macOS returns, which is the thing worth doubting.
//
// The fourth — a full disk — needs a mounted volume with no room on it, which
// a test suite must not go and create on somebody's machine. It is measured
// instead, once, with the numbers written down: `hdiutil` a 2 MB image, write
// 5 MB at it, and Foundation returns NSCocoaErrorDomain 640 wrapping
// NSPOSIXErrorDomain 28. Both of those are asserted below from the shape that
// measurement produced.
// ─────────────────────────────────────────────────────────────

private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "readable-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Readable failures — the four cases P9.4 names")
struct ReadableFailureTests {

    // Measured: 2 MB disk image, 5 MB write.
    //   NSCocoaErrorDomain 640 → NSUnderlyingError NSPOSIXErrorDomain 28
    @Test("a full disk says the save did not happen, and does not suggest trying again")
    func outOfSpace() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 640,
                            userInfo: [NSUnderlyingErrorKey: posix])

        let failure = ReadableFailure.explain(cocoa, doing: "บันทึกรายการแหล่งข้อมูล")
        #expect(failure.kind == .outOfSpace)
        // The question a person actually has: did I lose it?
        #expect(failure.what.contains("ยังไม่ถูกบันทึก"))
        // Retrying a write to a full disk is a loop, so nothing may offer it.
        #expect(failure.isTransient == false)
        #expect(failure.whatToDo.contains("ลองใหม่อีกครั้ง") == false)
    }

    @Test("a bare POSIX ENOSPC is recognised too, not only the Cocoa wrapper")
    func outOfSpaceBare() {
        let failure = ReadableFailure.explain(NSError(domain: NSPOSIXErrorDomain, code: 28),
                                              doing: "เขียนไฟล์")
        #expect(failure.kind == .outOfSpace)
    }

    // Real: a directory this process is genuinely not allowed to write into.
    @Test("a folder we may not write to is reported as permission, not as a mystery")
    func notPermitted() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)

        do {
            try Data("x".utf8).write(to: directory.appending(path: "f.json"), options: .atomic)
            // Running as root would make this pass for the wrong reason.
            Issue.record("the write unexpectedly succeeded, so nothing was proven")
        } catch {
            let failure = ReadableFailure.explain(error, doing: "บันทึกการตั้งค่า")
            #expect(failure.kind == .notPermitted)
            #expect(failure.isTransient == false)
            #expect(failure.what.contains("บันทึกการตั้งค่า"))
        }
    }

    // Real: bytes that are not JSON.
    @Test("a corrupt file is reported as unreadable, and the advice mentions the backup")
    func corruptFile() {
        do {
            _ = try JSONDecoder().decode([String].self, from: Data("{ not json".utf8))
            Issue.record("that decoded, somehow")
        } catch {
            let failure = ReadableFailure.explain(error, doing: "รายชื่อบอท")
            guard case .fileUnreadable = failure.kind else {
                Issue.record("a corrupt file was classified as \(failure.kind)")
                return
            }
            #expect(failure.isTransient == false)
        }

        // And when the store did manage to keep a copy, the advice changes to
        // the only thing the person cares about: nothing is gone.
        let kept = ReadableFailure.unreadableFile(doing: "รายชื่อบอท",
                                                  backup: "channels.unreadable.json")
        #expect(kept.whatToDo.contains("channels.unreadable.json"))
        #expect(kept.whatToDo.contains("ยังไม่มีอะไรหาย"))
    }

    // Real: port 1 on loopback, where nothing listens.
    @Test("a service that is not running is reported as down, and is worth retrying")
    func serviceDown() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/v1/models")!)
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
            Issue.record("something answered on port 1")
        } catch {
            let failure = ReadableFailure.explain(error, doing: "SurrealDB")
            #expect(failure.kind == .serviceDown(name: "SurrealDB"))
            // Unlike the disk being full, this one really can fix itself — the
            // sidecar manager restarts it.
            #expect(failure.isTransient)
        }
    }

    @Test("a timeout is its own thing, and says why waiting longer might help")
    func timedOut() {
        let failure = ReadableFailure.explain(URLError(.timedOut), doing: "ถามโมเดล")
        #expect(failure.kind == .timedOut)
        #expect(failure.isTransient)
    }

    // The case that matters most for trust: when we do not know, say so rather
    // than picking the nearest-looking explanation.
    @Test("an error nothing recognises is not dressed up as one of the four")
    func unknownStaysUnknown() {
        struct Odd: Error {}
        let failure = ReadableFailure.explain(Odd(), doing: "อะไรสักอย่าง")
        #expect(failure.kind == .unknown)
        #expect(failure.isTransient == false)
        // The raw text is still available for whoever has to debug it.
        #expect(failure.detail.contains("Odd"))
    }

    // Every explanation has to name what was being attempted. "ดิสก์เต็ม" on
    // its own leaves the person not knowing what they lost.
    @Test("every explanation names the thing that was being done")
    func alwaysNamesTheOperation() {
        let errors: [any Error] = [
            NSError(domain: NSPOSIXErrorDomain, code: 28),
            NSError(domain: NSCocoaErrorDomain, code: 513),
            URLError(.timedOut),
            URLError(.cannotConnectToHost),
        ]
        for error in errors {
            let failure = ReadableFailure.explain(error, doing: "งานที่กำลังทำ")
            #expect(failure.what.contains("งานที่กำลังทำ"),
                    "\(failure.kind) does not say what was being attempted")
        }
    }
}
