import Foundation
import Compression

/// Reads the central directory of a ZIP archive and extracts individual
/// entries by name — the read-side mirror of `MinimalZipWriter`, but unlike
/// it, has to handle both "stored" (method 0) and "deflated" (method 8)
/// entries: a real-world `.xlsx` from Excel, Numbers, Google Sheets or
/// LibreOffice is essentially always DEFLATE-compressed, whereas this app's
/// own writer only ever produces stored entries. Nothing else — no ZIP64,
/// no encryption, no multi-disk archives, no archive comment — `.xlsx`
/// files never use any of those.
struct MinimalZipReader {
    enum ReaderError: Error {
        case notAZipArchive
        case corruptEntry(String)
        case entryNotFound(String)
        case unsupportedCompressionMethod(String, UInt16)
    }

    private struct CentralEntry {
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private let fileHandle: FileHandle
    private let entriesByName: [String: CentralEntry]

    init(fileHandle: FileHandle) throws {
        self.fileHandle = fileHandle
        let fileSize = try fileHandle.seekToEnd()

        // Fixed 22-byte record, no trailing archive comment — true for
        // every .xlsx produced by any real tool.
        let eocdSize: UInt64 = 22
        guard fileSize >= eocdSize else { throw ReaderError.notAZipArchive }
        try fileHandle.seek(toOffset: fileSize - eocdSize)
        guard let eocd = try fileHandle.read(upToCount: Int(eocdSize)), eocd.count == Int(eocdSize),
              eocd.readUInt32LE(at: 0) == 0x0605_4b50 else {
            throw ReaderError.notAZipArchive
        }
        let entryCount = Int(eocd.readUInt16LE(at: 10))
        let centralDirectorySize = eocd.readUInt32LE(at: 12)
        let centralDirectoryOffset = eocd.readUInt32LE(at: 16)

        try fileHandle.seek(toOffset: UInt64(centralDirectoryOffset))
        guard let centralDirectory = try fileHandle.read(upToCount: Int(centralDirectorySize)),
              centralDirectory.count == Int(centralDirectorySize) else {
            throw ReaderError.notAZipArchive
        }

        var entries: [String: CentralEntry] = [:]
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= centralDirectory.count,
                  centralDirectory.readUInt32LE(at: cursor) == 0x0201_4b50 else {
                throw ReaderError.corruptEntry("central directory")
            }
            let method = centralDirectory.readUInt16LE(at: cursor + 10)
            let compressedSize = centralDirectory.readUInt32LE(at: cursor + 20)
            let uncompressedSize = centralDirectory.readUInt32LE(at: cursor + 24)
            let nameLength = Int(centralDirectory.readUInt16LE(at: cursor + 28))
            let extraLength = Int(centralDirectory.readUInt16LE(at: cursor + 30))
            let commentLength = Int(centralDirectory.readUInt16LE(at: cursor + 32))
            let localHeaderOffset = centralDirectory.readUInt32LE(at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= centralDirectory.count else {
                throw ReaderError.corruptEntry("central directory entry name")
            }
            let nameData = centralDirectory.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = CentralEntry(
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entriesByName = entries
    }

    /// Reads, and if needed inflates, one named entry's content.
    func data(named name: String) throws -> Data {
        guard let entry = entriesByName[name] else {
            throw ReaderError.entryNotFound(name)
        }

        try fileHandle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let localHeader = try fileHandle.read(upToCount: 30), localHeader.count == 30,
              localHeader.readUInt32LE(at: 0) == 0x0403_4b50 else {
            throw ReaderError.corruptEntry(name)
        }
        let localNameLength = UInt64(localHeader.readUInt16LE(at: 26))
        let localExtraLength = UInt64(localHeader.readUInt16LE(at: 28))
        try fileHandle.seek(toOffset: UInt64(entry.localHeaderOffset) + 30 + localNameLength + localExtraLength)

        guard let rawData = try fileHandle.read(upToCount: Int(entry.compressedSize)),
              rawData.count == Int(entry.compressedSize) else {
            throw ReaderError.corruptEntry(name)
        }

        switch entry.compressionMethod {
        case 0:
            return rawData
        case 8:
            return try Self.inflate(rawData, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw ReaderError.unsupportedCompressionMethod(name, entry.compressionMethod)
        }
    }

    /// Raw DEFLATE (RFC 1951) — what a ZIP method-8 entry actually
    /// contains, no zlib or gzip wrapper. `COMPRESSION_ZLIB` is Apple's
    /// (confusingly named) constant for exactly that raw format, not a
    /// zlib-wrapped stream.
    private static func inflate(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let bytesWritten = output.withUnsafeMutableBytes { outputPtr -> Int in
            compressed.withUnsafeBytes { inputPtr -> Int in
                guard let outputBase = outputPtr.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase, uncompressedSize,
                    inputBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard bytesWritten == uncompressedSize else {
            throw ReaderError.corruptEntry("inflate produced \(bytesWritten) bytes, expected \(uncompressedSize)")
        }
        return output
    }
}

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
