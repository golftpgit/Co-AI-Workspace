import Foundation

// ─────────────────────────────────────────────────────────────
// P9.4 — the four ways this app breaks on a real machine, said in words
// somebody can act on: the sidecar dies, an endpoint disappears, a file is
// corrupt, the disk is full.
//
// The Done-when is "every case has a readable error and does not crash". The
// second half was already true — there is no `fatalError` and no `try!`
// anywhere in `Sources` outside the check executables. The first half was not:
// a full disk arrived at the user as
//
//     "You can’t save the file “channels.json” because the volume … is out of
//      space." — NSCocoaErrorDomain 640
//
// in English, in the middle of a Thai screen, and — worse — through code paths
// that mostly say "บันทึกไม่สำเร็จ: \(error)" and leave it there. The thing
// that separates these four from ordinary errors is that **three of them are
// not the user's fault and none of them are fixed by pressing the button
// again**, so a message ending in "ลองใหม่อีกครั้ง" is actively wrong.
//
// The codes below are measured on this machine, not looked up:
//
//     full disk        NSCocoaErrorDomain 640   ← NSPOSIXErrorDomain 28
//     no permission    NSCocoaErrorDomain 513   ← NSPOSIXErrorDomain 13
//     nothing on port  NSURLErrorDomain -1004 (cannotConnectToHost)
//     corrupt file     DecodingError
//
// **What `isTransient` is for.** Retrying a timeout is sensible; retrying a
// write to a full disk is a loop that ends with the user believing the app is
// broken rather than the disk being full. Anything that offers a retry button
// asks this first.
// ─────────────────────────────────────────────────────────────

public struct ReadableFailure: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// The disk is full. Nothing was written.
        case outOfSpace
        /// The file or folder exists and this app is not allowed to touch it.
        case notPermitted
        /// Something on disk will not parse. `backup` is where the original was
        /// kept, when it was — see `FileStoreSafety`.
        case fileUnreadable(backup: String?)
        /// A local service — SurrealDB, SearXNG, a kernel — is not answering.
        case serviceDown(name: String)
        /// It answered too slowly, or not at all in time.
        case timedOut
        /// Genuinely unclassified. Kept as its own case rather than folded into
        /// one of the others, because a wrong confident explanation costs more
        /// than an honest "ไม่ทราบสาเหตุ".
        case unknown
    }

    public let kind: Kind
    /// What happened. One sentence, no error codes in it.
    public let what: String
    /// The next thing to do, concretely. Never "ลองใหม่" on its own.
    public let whatToDo: String
    /// The raw error, kept for the log and for a details disclosure — not for
    /// the first line a person reads.
    public let detail: String

    /// Whether trying the same thing again could plausibly work.
    public var isTransient: Bool {
        switch kind {
        case .timedOut, .serviceDown: true
        case .outOfSpace, .notPermitted, .fileUnreadable, .unknown: false
        }
    }

    public init(kind: Kind, what: String, whatToDo: String, detail: String) {
        self.kind = kind
        self.what = what
        self.whatToDo = whatToDo
        self.detail = detail
    }

    /// The whole thing as one line, for a log or a compact status row.
    public var summary: String { "\(what) — \(whatToDo)" }

    // ─────────────────────────────────────────────────────────
    // Classification
    // ─────────────────────────────────────────────────────────

    /// Explains an error in terms of the thing that was being attempted.
    ///
    /// - Parameter doing: what the app was in the middle of, as a Thai noun
    ///   phrase — "บันทึกรายการแหล่งข้อมูล". It goes into the sentence, because
    ///   "out of space" without saying *what did not get saved* leaves the
    ///   person unsure whether they lost anything.
    public static func explain(_ error: any Error, doing: String) -> ReadableFailure {
        let detail = "\(error)"

        if error is DecodingError {
            return ReadableFailure(
                kind: .fileUnreadable(backup: nil),
                what: "ไฟล์ของ\(doing) อ่านไม่ออก — รูปแบบข้างในไม่ตรงกับที่โปรแกรมรู้จัก",
                whatToDo: "ถ้าเคยแก้ไฟล์นี้เองให้ตรวจดูก่อน · "
                    + "ถ้าไม่เคย แปลว่าไฟล์เสีย และของเดิมถูกสำรองไว้ให้แล้ว",
                detail: detail)
        }

        let ns = error as NSError
        if let posix = posixCode(of: ns) {
            switch posix {
            case 28: return outOfSpace(doing: doing, detail: detail)      // ENOSPC
            case 13, 1: return notPermitted(doing: doing, detail: detail) // EACCES, EPERM
            case 61: return serviceDown(name: doing, detail: detail)      // ECONNREFUSED
            default: break
            }
        }

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case 640: return outOfSpace(doing: doing, detail: detail)
            case 513, 257: return notPermitted(doing: doing, detail: detail)
            // A file that is not there is not the same as one that will not
            // parse, and both are ordinary — the caller decides which of them
            // is worth telling anybody about.
            case 4, 260:
                return ReadableFailure(
                    kind: .unknown,
                    what: "ไม่พบไฟล์ของ\(doing)",
                    whatToDo: "ถ้าเพิ่งย้ายหรือลบโฟลเดอร์ข้อมูล ให้ชี้กลับไปที่เดิม",
                    detail: detail)
            default: break
            }
        }

        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet:
                return serviceDown(name: doing, detail: detail)
            case .timedOut:
                return ReadableFailure(
                    kind: .timedOut,
                    what: "\(doing) ใช้เวลานานเกินกำหนดจนต้องหยุดรอ",
                    whatToDo: "ปลายทางอาจกำลังโหลดโมเดลอยู่ — รออีกสักครู่แล้วลองใหม่ได้",
                    detail: detail)
            default: break
            }
        }

        return ReadableFailure(
            kind: .unknown,
            what: "\(doing) ไม่สำเร็จ",
            whatToDo: "ดูรายละเอียดข้างล่าง แล้วถ้าเกิดซ้ำให้บันทึกข้อความนี้ไว้",
            detail: detail)
    }

    /// What to put on screen, given that most errors in this app are already
    /// sentences somebody wrote in Thai.
    ///
    /// `WorkspaceFiles` refusing a save because the file changed on disk, a
    /// gate declining a tool, a connector naming its missing password — those
    /// are better than anything this type could say about them, and running
    /// them through `explain` would flatten them all into "ไม่สำเร็จ". So only
    /// the errors that came from the operating system get translated, and
    /// everything else is passed through untouched.
    public static func message(for error: any Error, doing: String) -> String {
        let failure = explain(error, doing: doing)
        guard failure.kind != .unknown else { return "\(error)" }
        return failure.summary
    }

    /// The variant for a file store that managed to keep a copy of the
    /// unreadable original — which changes the advice completely, because the
    /// data is not gone.
    public static func unreadableFile(doing: String, backup: String?,
                                      detail: String = "") -> ReadableFailure {
        ReadableFailure(
            kind: .fileUnreadable(backup: backup),
            what: "ไฟล์ของ\(doing) อ่านไม่ออก",
            whatToDo: backup.map {
                "ของเดิมถูกสำรองไว้ที่ \($0) แล้ว — ยังไม่มีอะไรหาย เปิดดูได้"
            } ?? "เริ่มจากรายการว่างไปก่อน และอย่าเพิ่งบันทึกทับถ้ายังต้องการของเดิม",
            detail: detail)
    }

    /// A list file written by a build newer than this one (P9.2).
    ///
    /// Deliberately not `unreadableFile`: that one says "we kept a copy and
    /// replaced it", and this one must say the opposite — the file is fine,
    /// it is *this* app that is behind, and nothing has been written over. The
    /// advice is the difference between the two.
    public static func newerSchema(doing: String, version: Int) -> ReadableFailure {
        ReadableFailure(
            kind: .fileUnreadable(backup: nil),
            what: "ไฟล์ของ\(doing) ถูกเขียนโดยแอปรุ่นใหม่กว่านี้ (เวอร์ชัน \(version))",
            whatToDo: "รอบนี้ใช้รายการว่างไปก่อน และ**ไม่ได้เขียนทับไฟล์นั้น** — "
                + "เปิดด้วยรุ่นใหม่กว่าแล้วของเดิมยังอยู่ครบ",
            detail: doing)
    }

    public static func serviceDown(name: String, detail: String = "") -> ReadableFailure {
        ReadableFailure(
            kind: .serviceDown(name: name),
            what: "\(name) ไม่ตอบ",
            whatToDo: "ดูหน้าสถานะว่าบริการนี้ยังทำงานอยู่ไหม — "
                + "ถ้าเพิ่งหยุดไป ระบบจะพยายามเปิดใหม่ให้เอง",
            detail: detail)
    }

    private static func outOfSpace(doing: String, detail: String) -> ReadableFailure {
        ReadableFailure(
            kind: .outOfSpace,
            // Says what did *not* happen, because that is the question.
            what: "ดิสก์เต็ม — \(doing) ยังไม่ถูกบันทึก",
            // Deliberately not "ลองใหม่อีกครั้ง": on a full disk that is a loop.
            whatToDo: "ต้องมีที่ว่างก่อน ลบไฟล์ที่ไม่ใช้แล้วค่อยสั่งอีกครั้ง · "
                + "ของเดิมบนดิสก์ยังอยู่ครบ ไม่ได้ถูกเขียนทับ",
            detail: detail)
    }

    private static func notPermitted(doing: String, detail: String) -> ReadableFailure {
        ReadableFailure(
            kind: .notPermitted,
            what: "ไม่ได้รับอนุญาตให้เขียนไฟล์ของ\(doing)",
            whatToDo: "ตรวจสิทธิ์ของโฟลเดอร์ข้อมูล — "
                + "ถ้าเพิ่งย้ายโฟลเดอร์มาจากเครื่องอื่นหรือจากดิสก์สำรอง มักเป็นเพราะเรื่องนี้",
            detail: detail)
    }

    /// The POSIX code hiding under a Cocoa error, which is where the useful
    /// distinction usually is: 640 and 513 both arrive as "write failed".
    private static func posixCode(of error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain { return error.code }
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(of: under)
        }
        return nil
    }
}
