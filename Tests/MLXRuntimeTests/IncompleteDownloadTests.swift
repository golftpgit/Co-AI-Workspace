import Testing
import Foundation
@testable import MLXRuntime

// ─────────────────────────────────────────────────────────────
// P5.2's remainder — a download somebody cancelled is still on the disk.
//
// `installed()` is right to hide it: a half-downloaded 17 GB checkpoint that
// reads as ready is a crash at load time. But hidden and gone are different
// things, and the files still count against the quota the screen shows. The
// only way to remove them was a terminal, which is the thing this app exists
// not to need.
// ─────────────────────────────────────────────────────────────

private func makeDirectory() -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "models-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ name: String, _ text: String, into directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
}

/// A download that stopped after config and one shard of three.
private func partialModel(named name: String, under root: URL) -> URL {
    let directory = root.appending(path: name)
    write("config.json", #"{"model_type":"qwen3"}"#, into: directory)
    write("tokenizer_config.json", #"{"chat_template":"{{ x }}"}"#, into: directory)
    write("model.safetensors.index.json",
          #"{"weight_map":{"a":"model-00001-of-00003.safetensors","b":"model-00002-of-00003.safetensors","c":"model-00003-of-00003.safetensors"}}"#,
          into: directory)
    write("model-00001-of-00003.safetensors", String(repeating: "x", count: 2048), into: directory)
    return directory
}

@Suite("Downloads that stopped halfway (P5.2)")
struct IncompleteDownloadTests {

    @Test("a half-finished download is found, sized, and says what it is missing")
    func partialDownloadIsListed() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = partialModel(named: "Qwen3-8B-4bit", under: root)

        let catalog = LocalModelCatalog(searchPaths: [root])
        let leftovers = catalog.incompleteDownloads(ownRoot: root)

        #expect(leftovers.count == 1)
        let leftover = try #require(leftovers.first)
        // `/private/var` vs `/var` is the same directory through a symlink,
        // so the name is what is compared.
        #expect(leftover.directory.lastPathComponent == partial.lastPathComponent)
        #expect(leftover.bytes > 2000)
        // Two shards short — said in words, because "incomplete" tells nobody
        // whether this was nearly finished or barely started.
        #expect(leftover.missing.contains("2"))
        #expect(leftover.isOurs)
    }

    /// The two lists must never contain the same directory: one is what can be
    /// loaded, the other is what cannot.
    @Test("a complete model is not reported as a leftover")
    func completeModelsAreNotLeftovers() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Complete-4bit")
        write("config.json", #"{"model_type":"qwen3"}"#, into: directory)
        write("tokenizer_config.json", #"{"chat_template":"{{ x }}"}"#, into: directory)
        write("model.safetensors", "weights", into: directory)

        let catalog = LocalModelCatalog(searchPaths: [root])
        #expect(catalog.incompleteDownloads(ownRoot: root).isEmpty)
    }

    @Test("a folder that is not a model download is left alone")
    func unrelatedFoldersAreIgnored() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write("notes.txt", "ของผมเอง", into: root.appending(path: "งานเขียน"))

        let catalog = LocalModelCatalog(searchPaths: [root])
        #expect(catalog.incompleteDownloads(ownRoot: root).isEmpty)
    }

    /// Somebody else's library is somebody else's to tidy.
    @Test("a leftover in another program's library is listed and not deletable")
    func otherLibrariesAreReportedNotDeleted() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = makeDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        _ = partialModel(named: "Someone-Elses-8B", under: elsewhere)

        let catalog = LocalModelCatalog(searchPaths: [elsewhere])
        let leftover = try #require(catalog.incompleteDownloads(ownRoot: root).first)
        #expect(leftover.isOurs == false)
        #expect(throws: IncompleteDownloadError.self) {
            try catalog.remove(leftover)
        }
        #expect(FileManager.default.fileExists(atPath: leftover.directory.path(percentEncoded: false)))
    }

    @Test("removing our own leftover takes the whole directory")
    func removingWorks() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = partialModel(named: "Qwen3-8B-4bit", under: root)

        let catalog = LocalModelCatalog(searchPaths: [root])
        let leftover = try #require(catalog.incompleteDownloads(ownRoot: root).first)
        try catalog.remove(leftover)

        #expect(FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)) == false)
        #expect(catalog.incompleteDownloads(ownRoot: root).isEmpty)
    }
}
