import Foundation

/// The 3-way "SQL OLARAK AKTAR" mode selector in the DB Backup dialog.
enum DatabaseBackupMode: String, CaseIterable, Identifiable {
    case structureOnly, dataOnly, structureAndData

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .structureOnly: return "Yalnız yapı"
        case .dataOnly: return "Yalnız veri"
        case .structureAndData: return "Yapı + veri"
        }
    }
}

/// "KAYNAĞI ETKİLEYEN SEÇENEKLER" — how the live source database is read
/// during the dump. Both false by default, matching the reference dialog.
///
/// Deliberately just these two: a third checkbox in the reference image
/// ("Dump öncesi logları temizle") mapped to `RESET MASTER` in real MySQL —
/// a replication-affecting, elevated-privilege operation with no safe
/// equivalent worth exposing here, so it was dropped rather than
/// reinterpreted into something that silently doesn't do what its label
/// promises.
struct DatabaseBackupSourceOptions: Equatable {
    var lockTablesForReading = false
    var useSingleTransaction = false
}

/// "DOSYAYA YAZILAN SEÇENEKLER" — what ends up written into the generated
/// `.sql` file. Defaults match the reference dialog's checked/unchecked
/// state.
struct DatabaseBackupFileOptions: Equatable {
    var includeUseStatement = true
    var includeCreateDatabaseStatement = true
    /// Also emits the matching `SET FOREIGN_KEY_CHECKS=1;` at the end of
    /// the file — the reference dialog only shows one checkbox for this,
    /// but leaving the session with checks disabled after the dump file
    /// finishes replaying would be a real, easy-to-miss footgun.
    var setForeignKeyChecksToZero = true
    var lockInsertStatements = false
    var useExtendedInserts = true
    var includeDropStatements = false
}

struct DatabaseBackupOptions: Equatable {
    var mode: DatabaseBackupMode = .structureAndData
    var source = DatabaseBackupSourceOptions()
    var file = DatabaseBackupFileOptions()
}
