import Foundation

/// Streaming RFC4180 CSV reader — the inverse of `CSVExporter`. Reads a
/// file in fixed-size chunks through a small byte-level state machine, so
/// a quoted field can contain the delimiter or a literal newline without
/// losing row boundaries, and a multi-gigabyte file is never held in
/// memory as one `String`/`[[String]]`.
///
/// `fieldTerminator`/`fieldEnclosure`/`fieldEscape` are each read as at
/// most their first UTF-8 byte — every default and every realistic value
/// (`,`/`;`/`\t`, `"`, `\`) is exactly one ASCII byte, matching
/// `CSVExportOptions`. Scanning at the byte level is still correct for
/// multi-byte UTF-8 field *content* (Turkish characters, etc.), since a
/// UTF-8 continuation byte is always ≥ 0x80 and can never collide with an
/// ASCII delimiter byte.
enum CSVImportParser {
    struct Options: Equatable {
        var fieldTerminator: String = ","
        var fieldEnclosure: String = "\""
        var fieldEscape: String = ""
    }

    struct EmptyFieldTerminator: Error {}

    /// Reads the whole file, calling `onRow` once per complete row (the
    /// header row included — callers that treat the first row as a header
    /// skip it themselves). Whatever `onRow` throws propagates immediately,
    /// without reading further.
    ///
    /// `onRow` is `async` — not because parsing itself awaits anything, but
    /// so a caller can `await service.execute(...)` directly as each batch
    /// of rows comes in (mirroring `TableExportViewModel.fetchPages`'s
    /// `onPage` callback) instead of buffering the whole file in memory
    /// first.
    static func parse(
        fileHandle: FileHandle,
        options: Options,
        chunkSize: Int = 1 << 16,
        onRow: @MainActor (_ rowIndex: Int, _ fields: [String]) async throws -> Void
    ) async throws {
        guard let terminatorByte = options.fieldTerminator.utf8.first else {
            throw EmptyFieldTerminator()
        }
        let enclosureByte = options.fieldEnclosure.utf8.first
        let escapeByte = options.fieldEscape.utf8.first

        var state = FieldState.beforeField
        var fieldBytes: [UInt8] = []
        var fields: [String] = []
        var rowIndex = 0
        var pendingCRSkipsNextLF = false
        var sawByteSinceRowBoundary = false
        var isFirstChunk = true

        func finalizeField() {
            fields.append(String(decoding: fieldBytes, as: UTF8.self))
            fieldBytes.removeAll(keepingCapacity: true)
        }

        func finalizeRow() async throws {
            finalizeField()
            try await onRow(rowIndex, fields)
            rowIndex += 1
            fields.removeAll(keepingCapacity: true)
            sawByteSinceRowBoundary = false
        }

        func process(_ byte: UInt8) async throws {
            if pendingCRSkipsNextLF {
                pendingCRSkipsNextLF = false
                if byte == 0x0A { return }
            }
            sawByteSinceRowBoundary = true

            switch state {
            case .beforeField:
                if let enclosureByte, byte == enclosureByte {
                    state = .inQuotedField
                    return
                }
                state = .inUnquotedField
                try await process(byte)

            case .inUnquotedField:
                switch byte {
                case terminatorByte:
                    finalizeField()
                    state = .beforeField
                case 0x0D:
                    try await finalizeRow()
                    pendingCRSkipsNextLF = true
                    state = .beforeField
                case 0x0A:
                    try await finalizeRow()
                    state = .beforeField
                default:
                    fieldBytes.append(byte)
                }

            case .inQuotedField:
                if let escapeByte, byte == escapeByte {
                    state = .inQuotedFieldEscaped
                } else if let enclosureByte, byte == enclosureByte {
                    state = .inQuotedFieldQuoteSeen
                } else {
                    fieldBytes.append(byte)
                }

            case .inQuotedFieldEscaped:
                fieldBytes.append(byte)
                state = .inQuotedField

            case .inQuotedFieldQuoteSeen:
                if let enclosureByte, byte == enclosureByte {
                    // Doubled enclosure inside a quoted field (RFC4180) —
                    // one literal enclosure character, still quoted.
                    fieldBytes.append(byte)
                    state = .inQuotedField
                } else {
                    // The quote actually closed the field; re-dispatch this
                    // byte as ordinary (now-unquoted) trailing content.
                    state = .inUnquotedField
                    try await process(byte)
                }
            }
        }

        while true {
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var bytes = [UInt8](chunk)
            if isFirstChunk {
                isFirstChunk = false
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                if bytes.starts(with: bom) {
                    bytes.removeFirst(bom.count)
                }
            }
            for byte in bytes {
                try await process(byte)
            }
        }

        // The file ended without a trailing row terminator (or ended right
        // on a lone empty quoted field) — flush whatever was accumulated
        // as one final row.
        if sawByteSinceRowBoundary {
            try await finalizeRow()
        }
    }

    private enum FieldState: Equatable {
        case beforeField
        case inUnquotedField
        case inQuotedField
        case inQuotedFieldEscaped
        case inQuotedFieldQuoteSeen
    }

    private struct StopParsing: Error {}

    /// Reads only the first `limit` rows — stops as soon as they've been
    /// collected instead of scanning the rest of a potentially huge file.
    static func preview(fileHandle: FileHandle, options: Options, limit: Int) async throws -> [[String]] {
        var result: [[String]] = []
        do {
            try await parse(fileHandle: fileHandle, options: options) { _, fields in
                result.append(fields)
                if result.count >= limit {
                    throw StopParsing()
                }
            }
        } catch is StopParsing {
            // Expected early exit once `limit` rows are collected.
        }
        return result
    }
}
