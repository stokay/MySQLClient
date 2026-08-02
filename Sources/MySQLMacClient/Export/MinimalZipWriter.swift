import Foundation

/// A minimal ZIP archive writer supporting only the "stored" (method 0, no
/// compression) entry type — sufficient for a hand-rolled `.xlsx`, which
/// just needs a valid ZIP container, not a small file size. Skipping
/// compression entirely sidesteps `Compression` framework's stream-setup/
/// chunking for a first version; table exports here are small-to-medium, so
/// correctness (opens cleanly in Excel/Numbers) matters far more than
/// output size.
///
/// Three fixed-layout record types per the ZIP spec (PKWARE APPNOTE), no
/// compression codec involved: a local file header + raw data per entry,
/// then one central directory header per entry, then a single
/// end-of-central-directory record. CRC-32 is still computed and written
/// correctly — readers validate it even for stored entries.
struct MinimalZipWriter {
    private struct Entry {
        let name: String
        let size: UInt32
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    private var entries: [Entry] = []
    private var cursor: UInt32 = 0
    private var localSections = Data()

    /// A fixed, valid (non-zero) MS-DOS date/time — the exact timestamp on
    /// a hand-rolled export's internal zip entries has no bearing on
    /// correctness, so there's no reason to wire in the real wall-clock
    /// time.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x21 // 1980-01-01

    mutating func addEntry(name: String, data: Data) {
        let crc = Self.crc32(data)
        let nameBytes = Array(name.utf8)
        let offset = cursor

        var local = Data()
        local.appendUInt32LE(0x0403_4b50)
        local.appendUInt16LE(20) // version needed to extract
        local.appendUInt16LE(0) // general purpose bit flag
        local.appendUInt16LE(0) // compression method: stored
        local.appendUInt16LE(Self.dosTime)
        local.appendUInt16LE(Self.dosDate)
        local.appendUInt32LE(crc)
        local.appendUInt32LE(UInt32(data.count)) // compressed size == uncompressed for "stored"
        local.appendUInt32LE(UInt32(data.count))
        local.appendUInt16LE(UInt16(nameBytes.count))
        local.appendUInt16LE(0) // extra field length
        local.append(contentsOf: nameBytes)
        local.append(data)

        localSections.append(local)
        entries.append(Entry(name: name, size: UInt32(data.count), crc32: crc, localHeaderOffset: offset))
        cursor += UInt32(local.count)
    }

    /// Serializes local file headers + central directory + EOCD record.
    /// Call once, after every `addEntry`.
    func finalize() -> Data {
        var centralDirectory = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            centralDirectory.appendUInt32LE(0x0201_4b50)
            centralDirectory.appendUInt16LE(20) // version made by
            centralDirectory.appendUInt16LE(20) // version needed to extract
            centralDirectory.appendUInt16LE(0) // general purpose bit flag
            centralDirectory.appendUInt16LE(0) // compression method
            centralDirectory.appendUInt16LE(Self.dosTime)
            centralDirectory.appendUInt16LE(Self.dosDate)
            centralDirectory.appendUInt32LE(entry.crc32)
            centralDirectory.appendUInt32LE(entry.size)
            centralDirectory.appendUInt32LE(entry.size)
            centralDirectory.appendUInt16LE(UInt16(nameBytes.count))
            centralDirectory.appendUInt16LE(0) // extra field length
            centralDirectory.appendUInt16LE(0) // file comment length
            centralDirectory.appendUInt16LE(0) // disk number start
            centralDirectory.appendUInt16LE(0) // internal file attributes
            centralDirectory.appendUInt32LE(0) // external file attributes
            centralDirectory.appendUInt32LE(entry.localHeaderOffset)
            centralDirectory.append(contentsOf: nameBytes)
        }

        var eocd = Data()
        eocd.appendUInt32LE(0x0605_4b50)
        eocd.appendUInt16LE(0) // number of this disk
        eocd.appendUInt16LE(0) // disk where central directory starts
        eocd.appendUInt16LE(UInt16(entries.count)) // records on this disk
        eocd.appendUInt16LE(UInt16(entries.count)) // total records
        eocd.appendUInt32LE(UInt32(centralDirectory.count))
        eocd.appendUInt32LE(cursor) // offset of central directory, from archive start
        eocd.appendUInt16LE(0) // comment length

        var result = localSections
        result.append(centralDirectory)
        result.append(eocd)
        return result
    }

    // MARK: - CRC-32 (IEEE 802.3 / zlib polynomial), table-driven

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
