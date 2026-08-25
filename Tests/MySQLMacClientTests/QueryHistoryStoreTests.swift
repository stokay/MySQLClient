import XCTest
@testable import MySQLMacClient

/// Pure persistence — no database needed. Each test gets its own temp file
/// so nothing touches the real history under Application Support.
@MainActor
final class QueryHistoryStoreTests: XCTestCase {
    private var tempFileURL: URL!
    private let profileA = UUID()
    private let profileB = UUID()

    override func setUp() {
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-history-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFileURL)
    }

    func testRecordedQueriesComeBackNewestFirst() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 1", profileID: profileA)
        store.record("SELECT 2", profileID: profileA)

        XCTAssertEqual(store.entries(for: profileA).map(\.sql), ["SELECT 2", "SELECT 1"])
    }

    func testHistoryPersistsAcrossStoreInstances() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT name FROM widgets", profileID: profileA, database: "mydb")

        let reloaded = QueryHistoryStore(fileURL: tempFileURL)
        let entry = reloaded.entries(for: profileA).first
        XCTAssertEqual(entry?.sql, "SELECT name FROM widgets")
        XCTAssertEqual(entry?.database, "mydb")
    }

    /// History is per connection profile: a query typed against one server
    /// must never surface while connected to another.
    func testProfilesKeepSeparateHistories() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 'a'", profileID: profileA)
        store.record("SELECT 'b'", profileID: profileB)

        XCTAssertEqual(store.entries(for: profileA).map(\.sql), ["SELECT 'a'"])
        XCTAssertEqual(store.entries(for: profileB).map(\.sql), ["SELECT 'b'"])
    }

    /// Re-running the query that's already newest refreshes its timestamp
    /// instead of adding a duplicate — otherwise hammering ⌘↩ on one query
    /// would evict the whole list.
    func testRerunningTheNewestQueryUpdatesItInsteadOfDuplicating() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        store.record("SELECT 1", profileID: profileA, at: first)
        store.record("SELECT 1", profileID: profileA, at: second)

        XCTAssertEqual(store.entries(for: profileA).count, 1)
        XCTAssertEqual(store.entries(for: profileA).first?.executedAt, second)
    }

    /// ...but the same query run again *after* something else is a genuinely
    /// new entry, not a silent merge with the older one.
    func testTheSameQueryAfterAnotherIsRecordedAgain() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 1", profileID: profileA)
        store.record("SELECT 2", profileID: profileA)
        store.record("SELECT 1", profileID: profileA)

        XCTAssertEqual(store.entries(for: profileA).map(\.sql), ["SELECT 1", "SELECT 2", "SELECT 1"])
    }

    func testHistoryIsCappedPerProfileKeepingTheNewest() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        let overflow = QueryHistoryStore.maximumEntriesPerProfile + 10
        for i in 1...overflow {
            store.record("SELECT \(i)", profileID: profileA)
        }

        let entries = store.entries(for: profileA)
        XCTAssertEqual(entries.count, QueryHistoryStore.maximumEntriesPerProfile)
        XCTAssertEqual(entries.first?.sql, "SELECT \(overflow)", "en yeni sorgu başta kalmalı")
        XCTAssertFalse(entries.contains { $0.sql == "SELECT 1" }, "en eskiler düşmeli")
    }

    /// The cap is per profile, so a busy connection can't evict a quiet
    /// one's history.
    func testCapDoesNotEvictAnotherProfilesHistory() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 'quiet'", profileID: profileB)
        for i in 1...(QueryHistoryStore.maximumEntriesPerProfile + 5) {
            store.record("SELECT \(i)", profileID: profileA)
        }

        XCTAssertEqual(store.entries(for: profileB).map(\.sql), ["SELECT 'quiet'"])
    }

    func testBlankQueriesAreNotRecorded() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("   \n  ", profileID: profileA)
        XCTAssertTrue(store.entries(for: profileA).isEmpty)
    }

    /// A many-megabyte pasted script (e.g. a SQL dump run once) must never
    /// land in history — `save()` re-writes the whole profile's list to
    /// disk on every `record()` call, so one giant entry would make every
    /// *later* query pay a multi-megabyte JSON encode too.
    func testOversizedSQLIsNotRecorded() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        let huge = String(repeating: "x", count: QueryHistoryStore.maximumRecordedSQLLength + 1)
        store.record(huge, profileID: profileA)
        XCTAssertTrue(store.entries(for: profileA).isEmpty)

        // ...and a normal-sized query right at/under the limit still is.
        let fits = String(repeating: "x", count: QueryHistoryStore.maximumRecordedSQLLength)
        store.record(fits, profileID: profileA)
        XCTAssertEqual(store.entries(for: profileA).count, 1)
    }

    func testRecordedSQLIsTrimmed() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("\n  SELECT 1  \n", profileID: profileA)
        XCTAssertEqual(store.entries(for: profileA).first?.sql, "SELECT 1")
    }

    func testClearRemovesOnlyTheGivenProfile() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 'a'", profileID: profileA)
        store.record("SELECT 'b'", profileID: profileB)

        store.clear(profileID: profileA)

        XCTAssertTrue(store.entries(for: profileA).isEmpty)
        XCTAssertEqual(store.entries(for: profileB).map(\.sql), ["SELECT 'b'"])
        XCTAssertTrue(QueryHistoryStore(fileURL: tempFileURL).entries(for: profileA).isEmpty, "silme kalıcı olmalı")
    }

    func testClearAllEmptiesEveryProfile() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("SELECT 'a'", profileID: profileA)
        store.record("SELECT 'b'", profileID: profileB)

        store.clearAll()

        XCTAssertTrue(store.entries(for: profileA).isEmpty)
        XCTAssertTrue(store.entries(for: profileB).isEmpty)
    }

    func testCorruptFileFallsBackToEmptyHistory() throws {
        try Data("bozuk { json".utf8).write(to: tempFileURL)
        let store = QueryHistoryStore(fileURL: tempFileURL)

        XCTAssertTrue(store.entries(for: profileA).isEmpty)
        // ...and stays usable rather than wedged.
        store.record("SELECT 1", profileID: profileA)
        XCTAssertEqual(store.entries(for: profileA).map(\.sql), ["SELECT 1"])
    }

    /// History written before `source` existed must still load — the user
    /// already has such a file, and a decode failure would silently wipe
    /// it. Those entries were all typed in the console at the time.
    func testHistoryWrittenBeforeSourceExistedStillLoads() throws {
        // A `[UUID: [Entry]]` dictionary doesn't JSON-encode as an object:
        // non-String keys become a flat array of alternating key/value, so
        // this mirrors the real file's shape rather than the obvious one.
        let legacy = """
        [
          "\(profileA.uuidString)",
          [
            {
              "id": "7EBAD724-0741-4657-8973-640091775E41",
              "sql": "SELECT * FROM `t` LIMIT 1000;",
              "executedAt": 807206655.599992,
              "database": "mydb"
            }
          ]
        ]
        """
        try Data(legacy.utf8).write(to: tempFileURL)

        let store = QueryHistoryStore(fileURL: tempFileURL)
        let entry = store.entries(for: profileA).first
        XCTAssertEqual(entry?.sql, "SELECT * FROM `t` LIMIT 1000;")
        XCTAssertEqual(entry?.database, "mydb")
        XCTAssertEqual(entry?.source, .console, "eski kayıtlar konsol sorgusu sayılmalı")
    }

    /// Same statement text from the console and from a UI action are
    /// different entries — collapsing them would hide one of the two.
    func testSameSQLFromDifferentSourcesIsNotMerged() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        store.record("DELETE FROM `t` WHERE `id` = '1'", profileID: profileA, source: .console)
        store.record("DELETE FROM `t` WHERE `id` = '1'", profileID: profileA, source: .app)

        XCTAssertEqual(store.entries(for: profileA).count, 2)
        XCTAssertEqual(store.entries(for: profileA).map(\.source), [.app, .console])
    }

    func testMissingFileStartsEmpty() {
        let store = QueryHistoryStore(fileURL: tempFileURL)
        XCTAssertTrue(store.entries(for: profileA).isEmpty)
    }

    // MARK: - Menu preview

    func testSingleLinePreviewCollapsesWhitespace() {
        let entry = QueryHistoryEntry(sql: "SELECT a,\n       b\nFROM  t")
        XCTAssertEqual(entry.singleLinePreview(), "SELECT a, b FROM t")
    }

    /// A recalled `CREATE PROCEDURE` script is hundreds of characters; the
    /// menu item has to stay a menu item.
    func testSingleLinePreviewIsClipped() {
        let entry = QueryHistoryEntry(sql: String(repeating: "x", count: 200))
        let preview = entry.singleLinePreview(maxLength: 20)
        XCTAssertEqual(preview.count, 21, "20 karakter + kırpma işareti")
        XCTAssertTrue(preview.hasSuffix("…"))
    }
}
