import Foundation

/// Suggests a `DraftColumn` name/type/length for each column of a CSV or
/// Excel file's sample rows — backs "Import Columns from File…" in the
/// Create Table form. Deliberately a *suggestion*, not a guarantee: this
/// only fills in `DraftColumnsEditor`'s rows, which stay plain editable
/// fields afterward — reviewing (and correcting) the result before hitting
/// Create is expected, not optional, and no data from the file is written
/// anywhere. Creating the table afterward makes an empty table, exactly
/// like typing the columns by hand would.
enum ColumnTypeInference {
    /// `rows[0]` is treated as the header if `hasHeaderRow`; every other
    /// row is a data sample used only to guess type/length/nullability —
    /// none of it is imported. A missing or blank header name becomes
    /// `Column N`, matching `TableImportViewModel
    /// .refreshColumnMappings()`'s positional-placeholder convention.
    static func inferColumns(fromRows rows: [[String]], hasHeaderRow: Bool = true) -> [DraftColumn] {
        guard !rows.isEmpty else { return [] }
        let header = hasHeaderRow ? rows[0] : nil
        let dataRows = hasHeaderRow ? Array(rows.dropFirst()) : rows
        let columnCount = rows.map(\.count).max() ?? 0

        return (0..<columnCount).map { index in
            let rawName = (header?.indices.contains(index) == true) ? header![index] : ""
            let name = normalizedIdentifier(rawName, fallback: String(localized: "Column \(index + 1)"))
            let values = dataRows.map { $0.indices.contains(index) ? $0[index] : "" }
            return draftColumn(name: name, sampleValues: values)
        }
    }

    // MARK: - Identifier normalization

    /// Anything that isn't a letter/digit/underscore becomes `_` (spaces,
    /// punctuation, currency symbols in a header like `"Price ($)"`), runs
    /// of `_` collapse to one, and leading/trailing `_` are trimmed —
    /// close enough to a valid SQL identifier to be usable as-is, while
    /// staying recognizably derived from the original header.
    static func normalizedIdentifier(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var result = String(mapped)
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? fallback : result
    }

    // MARK: - Per-column type inference

    private static func draftColumn(name: String, sampleValues: [String]) -> DraftColumn {
        var column = DraftColumn()
        column.name = name

        let nonEmptyValues = sampleValues.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Suggested only when *every* sampled row (not just the non-empty
        // ones) actually had a value — one blank cell in the sample is
        // reason enough to leave the column nullable.
        column.isNotNull = !nonEmptyValues.isEmpty && nonEmptyValues.count == sampleValues.count

        guard !nonEmptyValues.isEmpty else {
            column.dataType = "VARCHAR"
            column.length = "255"
            return column
        }

        if let integerType = integerType(for: nonEmptyValues) {
            column.dataType = integerType
            return column
        }
        if let precisionAndScale = decimalPrecisionAndScale(for: nonEmptyValues) {
            column.dataType = "DECIMAL"
            column.length = "\(precisionAndScale.precision),\(precisionAndScale.scale)"
            return column
        }
        if nonEmptyValues.allSatisfy(isDateOnly) {
            column.dataType = "DATE"
            return column
        }
        if nonEmptyValues.allSatisfy(isDateTime) {
            column.dataType = "DATETIME"
            return column
        }

        let maxLength = nonEmptyValues.map(\.count).max() ?? 0
        if maxLength > 1000 {
            column.dataType = "TEXT"
        } else {
            column.dataType = "VARCHAR"
            column.length = String(suggestedVarcharLength(forMaxObservedLength: maxLength))
        }
        return column
    }

    /// `INT` if every sampled value fits a signed 32-bit range (MySQL's
    /// own `INT`), `BIGINT` otherwise — never a smaller type: guessing
    /// `TINYINT`/`SMALLINT` from a small sample risks a real import later
    /// hitting a value the suggestion didn't anticipate, and the cost of
    /// guessing too wide is just a few extra bytes per row.
    private static func integerType(for values: [String]) -> String? {
        guard values.allSatisfy(isPlainInteger) else { return nil }
        let fitsInt32 = values.allSatisfy { Int32($0) != nil }
        return fitsInt32 ? "INT" : "BIGINT"
    }

    private static func isPlainInteger(_ value: String) -> Bool {
        var digits = Substring(value)
        if digits.first == "-" { digits.removeFirst() }
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// `nil` unless *every* value has a decimal point with digits on both
    /// sides — a mixed column (some plain integers, some decimals) isn't
    /// safely summarized as one `DECIMAL`, so it falls through to the
    /// integer/text checks instead of guessing.
    private static func decimalPrecisionAndScale(for values: [String]) -> (precision: Int, scale: Int)? {
        var maxIntegerDigits = 0
        var maxScale = 0
        for value in values {
            var digits = Substring(value)
            if digits.first == "-" { digits.removeFirst() }
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
                  !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else {
                return nil
            }
            maxIntegerDigits = max(maxIntegerDigits, parts[0].count)
            maxScale = max(maxScale, parts[1].count)
        }
        // MySQL's DECIMAL(M, D) precision M counts digits on both sides of
        // the point; its hard ceiling is 65.
        let precision = min(65, maxIntegerDigits + maxScale)
        return (precision, min(maxScale, 30))
    }

    private static func isDateOnly(_ value: String) -> Bool {
        matches(value, pattern: #"^\d{4}-\d{2}-\d{2}$"#)
    }

    private static func isDateTime(_ value: String) -> Bool {
        matches(value, pattern: #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$"#)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Rounds up to one of a handful of conventional `VARCHAR` sizes
    /// rather than the exact observed maximum — a sample is never a
    /// guarantee of the file's true longest value, and a round number is
    /// what a human would type by hand anyway.
    private static func suggestedVarcharLength(forMaxObservedLength length: Int) -> Int {
        let buckets = [20, 50, 100, 255, 500, 1000]
        return buckets.first { $0 >= length } ?? 1000
    }
}
