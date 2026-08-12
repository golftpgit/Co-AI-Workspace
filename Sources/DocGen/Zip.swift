import Foundation

// ─────────────────────────────────────────────────────────────
// A zip archive, written by hand (ARCHITECTURE §14.1, P7.6).
//
// `.docx` and `.pptx` are zip files of XML, so producing one means producing a
// zip. The reader side (P2.3) shells out to `/usr/bin/unzip`; the writer does
// not, for two reasons: laying parts out in a temporary directory and shelling
// out to `zip` puts a filesystem dance and a process in the path of "save this
// document", and the App Sandbox is a worse place to discover that than a test
// is. The format is small enough to write correctly.
//
// **Stored, not deflated.** Method 0 is a legal zip entry and every reader
// accepts it, including Word's. A generated report is kilobytes of XML; trading
// a compressor — and the class of bug that comes with one — for a file that is
// three times smaller than nothing is not a trade worth making. If a document
// with embedded images ever makes this matter, `Compression`'s raw zlib is the
// place to add it, and the CRC below already does the hard part.
// ─────────────────────────────────────────────────────────────

struct ZipArchive {
    private struct Entry {
        let name: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var payload = Data()

    /// Order matters by convention: `[Content_Types].xml` is expected first in
    /// an OOXML package, and some readers are less forgiving than the spec.
    mutating func add(_ name: String, _ contents: String) {
        add(name, Data(contents.utf8))
    }

    mutating func add(_ name: String, _ data: Data) {
        let offset = UInt32(payload.count)
        let crc = ZipArchive.crc32(data)
        payload.append(Self.localHeader(name: name, data: data, crc: crc))
        payload.append(data)
        entries.append(Entry(name: name, data: data, crc: crc, offset: offset))
    }

    func build() -> Data {
        var archive = payload
        let directoryOffset = UInt32(archive.count)
        for entry in entries {
            archive.append(Self.centralHeader(entry))
        }
        let directorySize = UInt32(archive.count) - directoryOffset

        var end = Data()
        end.append(number: 0x0605_4b50 as UInt32)        // end of central directory
        end.append(number: 0 as UInt16)                  // this disk
        end.append(number: 0 as UInt16)                  // disk with the directory
        end.append(number: UInt16(entries.count))
        end.append(number: UInt16(entries.count))
        end.append(number: directorySize)
        end.append(number: directoryOffset)
        end.append(number: 0 as UInt16)                  // no comment
        archive.append(end)
        return archive
    }

    // MARK: - headers

    private static func localHeader(name: String, data: Data, crc: UInt32) -> Data {
        var header = Data()
        header.append(number: 0x0403_4b50 as UInt32)
        header.append(number: 20 as UInt16)              // version needed
        header.append(number: 0 as UInt16)               // flags
        header.append(number: 0 as UInt16)               // method 0: stored
        header.append(number: 0 as UInt16)               // time
        header.append(number: 0 as UInt16)               // date
        header.append(number: crc)
        header.append(number: UInt32(data.count))        // compressed
        header.append(number: UInt32(data.count))        // uncompressed
        header.append(number: UInt16(name.utf8.count))
        header.append(number: 0 as UInt16)               // extra field
        header.append(contentsOf: Array(name.utf8))
        return header
    }

    private static func centralHeader(_ entry: Entry) -> Data {
        var header = Data()
        header.append(number: 0x0201_4b50 as UInt32)
        header.append(number: 20 as UInt16)              // version made by
        header.append(number: 20 as UInt16)              // version needed
        header.append(number: 0 as UInt16)               // flags
        header.append(number: 0 as UInt16)               // method 0: stored
        header.append(number: 0 as UInt16)               // time
        header.append(number: 0 as UInt16)               // date
        header.append(number: entry.crc)
        header.append(number: UInt32(entry.data.count))
        header.append(number: UInt32(entry.data.count))
        header.append(number: UInt16(entry.name.utf8.count))
        header.append(number: 0 as UInt16)               // extra
        header.append(number: 0 as UInt16)               // comment
        header.append(number: 0 as UInt16)               // disk number
        header.append(number: 0 as UInt16)               // internal attributes
        header.append(number: 0 as UInt32)               // external attributes
        header.append(number: entry.offset)
        header.append(contentsOf: Array(entry.name.utf8))
        return header
    }

    // MARK: - CRC-32

    /// The standard CRC-32 (polynomial 0xEDB88320), built once.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    /// Little-endian, which is what every field in a zip is.
    mutating func append<T: FixedWidthInteger>(number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
