import Foundation

// ─────────────────────────────────────────────────────────────
// P9.5 — how long the main actor stops for, measured rather than argued about.
//
// "The UI stays responsive" is the kind of claim that is always made and
// rarely measured. This measures one thing: **how late a piece of main-actor
// work runs when something else is already on the main actor**, against the
// same work with the heavy job moved off. A frame is 16.7 ms at 60 Hz, so a
// hop that lands 200 ms late is four skipped frames and a beachball.
//
// Compiled separately and run by hand, like the other probes in this repo.
// Numbers land in docs/VERIFICATION_LOG.md.
// ─────────────────────────────────────────────────────────────

@MainActor
final class Ticker {
    private(set) var worst: Duration = .zero
    private var running = true

    /// Schedules a main-actor hop every 5 ms and records how late each one is.
    /// That lateness is the thing a person experiences as a stutter.
    func run() async {
        let step = Duration.milliseconds(5)
        while running {
            let due = ContinuousClock.now + step
            try? await Task.sleep(until: due, clock: .continuous)
            let late = due.duration(to: .now)
            if late > worst { worst = late }
        }
    }

    func stop() { running = false }
}

func makeArchive(megabytes: Int) throws -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "ui-probe-\(UUID().uuidString).json")
    // A JSON array of strings, which is what a knowledge archive is a bigger
    // version of: parsing dominates, not the read.
    var text = "["
    let chunk = String(repeating: "ก", count: 512)
    let count = megabytes * 1024 * 1024 / 520
    text += (0..<count).map { _ in "\"\(chunk)\"" }.joined(separator: ",")
    text += "]"
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
func measure(_ label: String, work: @escaping @Sendable () async -> Void) async {
    let ticker = Ticker()
    let ticking = Task { await ticker.run() }
    let started = ContinuousClock.now
    await work()
    let elapsed = started.duration(to: .now)
    ticker.stop()
    _ = await ticking.value
    print(String(format: "%-38s worst main-actor stall %8.1f ms   (work took %6.0f ms)",
                 (label as NSString).utf8String!, Double(ticker.worst.components.attoseconds) / 1e15,
                 Double(elapsed.components.seconds) * 1000
                     + Double(elapsed.components.attoseconds) / 1e15))
}

@main
struct UIResponsivenessCheck {
    static func main() async throws {
        let megabytes = 24
        let url = try makeArchive(megabytes: megabytes)
        defer { try? FileManager.default.removeItem(at: url) }
        print("archive: \(megabytes) MB\n")

        await measure("decode on the main actor") {
            await MainActor.run {
                _ = try? JSONDecoder().decode([String].self, from: try! Data(contentsOf: url))
            }
        }

        await measure("decode off the main actor") {
            let decoded: [String]? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode([String].self, from: data)
            }.value
            _ = decoded
        }
    }
}
