import XCTest
@testable import MySQLMacClient

@MainActor
final class AtomicFileWriterTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var destination: URL { directory.appendingPathComponent("out.txt") }

    /// No `.tmp-` sibling should survive a run, success or failure —
    /// checked by listing the directory and filtering out `destination`
    /// itself.
    private func tempSiblingsRemaining() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 != destination.lastPathComponent }
    }

    func testSuccessWritesDestinationAndLeavesNoTempSibling() async throws {
        try await AtomicFileWriter.write(to: destination) { fileHandle in
            fileHandle.write(Data("hello".utf8))
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
        XCTAssertEqual(tempSiblingsRemaining(), [])
    }

    /// Regression guard: the temp sibling used to be named `.out.txt.tmp-…`
    /// (leading dot) — macOS auto-sets the BSD hidden flag on dot-prefixed
    /// files at creation, and `replaceItemAt` carried that flag onto the
    /// final `destination`, making a successfully-written file invisible in
    /// Finder while still showing up fine via `ls`/`FileManager`.
    func testSuccessLeavesDestinationVisibleNotHidden() async throws {
        try await AtomicFileWriter.write(to: destination) { fileHandle in
            fileHandle.write(Data("hello".utf8))
        }

        let resourceValues = try destination.resourceValues(forKeys: [.isHiddenKey])
        XCTAssertEqual(resourceValues.isHidden, false)
    }

    func testSuccessAtomicallyReplacesExistingDestinationContent() async throws {
        try Data("old content".utf8).write(to: destination)

        try await AtomicFileWriter.write(to: destination) { fileHandle in
            fileHandle.write(Data("new content".utf8))
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new content")
        XCTAssertEqual(tempSiblingsRemaining(), [])
    }

    /// The core regression guard: a pre-existing file must survive a
    /// failed write completely unchanged — not truncated, not deleted.
    func testBodyThrowingLeavesAPreexistingDestinationUntouched() async throws {
        try Data("must survive".utf8).write(to: destination)

        struct DeliberateFailure: Error {}
        await XCTAssertThrowsErrorAsync(try await AtomicFileWriter.write(to: destination) { fileHandle in
            fileHandle.write(Data("partial write that must never land".utf8))
            throw DeliberateFailure()
        })

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "must survive")
        XCTAssertEqual(tempSiblingsRemaining(), [])
    }

    func testBodyThrowingWhenDestinationDoesNotExistYetCreatesNothing() async throws {
        struct DeliberateFailure: Error {}
        await XCTAssertThrowsErrorAsync(try await AtomicFileWriter.write(to: destination) { _ in
            throw DeliberateFailure()
        })

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(tempSiblingsRemaining(), [])
    }

    /// `CancellationError` is just another thrown error as far as this
    /// type is concerned — commit only ever happens on a normal return.
    func testCancellationLeavesAPreexistingDestinationUntouched() async throws {
        try Data("must survive cancellation".utf8).write(to: destination)

        await XCTAssertThrowsErrorAsync(try await AtomicFileWriter.write(to: destination) { fileHandle in
            fileHandle.write(Data("should not land".utf8))
            throw CancellationError()
        })

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "must survive cancellation")
        XCTAssertEqual(tempSiblingsRemaining(), [])
    }
}

/// `XCTAssertThrowsError` has no async form in this project's XCTest
/// version — this is the minimal equivalent for an `async throws`
/// expression. `@MainActor` because every call site's closure captures
/// main-actor-isolated test state; a nonisolated helper can't accept that
/// closure under Swift 6 strict concurrency.
@MainActor
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
