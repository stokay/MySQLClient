import XCTest
import MySQLNIO
import NIOCore
@testable import MySQLMacClient

/// MySQL gives `TEXT` and `BLOB` the same wire type codes, so `RowValue`
/// has to decide between them itself. Getting that wrong is not cosmetic:
/// calling a `TEXT` column binary made it unreadable in the grid and
/// base64-encoded in every export, while calling a `BLOB` textual would
/// write mojibake over the real bytes on the first edit.
///
/// Hermetic — builds `MySQLData` values directly, no server involved.
final class RowValueTests: XCTestCase {
    private func blobData(_ bytes: [UInt8]) -> MySQLData {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return MySQLData(type: .blob, format: .binary, buffer: buffer)
    }

    func testBlobTypedColumnHoldingUTF8IsReadAsText() throws {
        let value = RowValue(mysqlData: blobData(Array("hello".utf8)))
        XCTAssertEqual(value, .text("hello"))
        XCTAssertEqual(value.editableText, "hello", "the editor must get the real text")
        XCTAssertEqual(value.displayString, "<5 bytes>", "the grid shows a placeholder, not the multi-line value")
    }

    /// The app's own data is Turkish; a multi-byte payload must survive the
    /// decode intact rather than being cut at a byte boundary.
    func testBlobTypedColumnKeepsMultibyteCharacters() throws {
        let turkish = "Şanlıurfa güncelleme — çığır"
        let value = RowValue(mysqlData: blobData(Array(turkish.utf8)))
        XCTAssertEqual(value, .text(turkish))
        XCTAssertEqual(value.editableText, turkish)
    }

    func testGenuinelyBinaryBlobStaysBinary() throws {
        // PNG magic number: 0x89 is never a valid UTF-8 leading byte.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let value = RowValue(mysqlData: blobData(png))
        XCTAssertEqual(value, .blob(Data(png)))
        XCTAssertEqual(value.displayString, "<8 bytes>")
    }

    /// The safety property behind classifying on a *strict* decode: text
    /// that was accepted as text must go back to the server as the exact
    /// bytes it arrived as.
    func testTextClassifiedValueRoundTripsToIdenticalBytes() throws {
        let original = "satır1\nsatır2\tsekme — ünicode ✓"
        let value = RowValue(mysqlData: blobData(Array(original.utf8)))
        guard let buffer = value.mysqlData.buffer else {
            return XCTFail("a text value must encode back to a buffer")
        }
        XCTAssertEqual(Array(buffer.readableBytesView), Array(original.utf8))
    }

    func testEmptyBlobIsEmptyStringNotNull() throws {
        let value = RowValue(mysqlData: blobData([]))
        XCTAssertEqual(value, .text(""))
        XCTAssertFalse(value.isNull, "an empty TEXT value is not SQL NULL")
    }

    func testMissingBufferIsNull() throws {
        let value = RowValue(mysqlData: MySQLData(type: .blob, format: .binary, buffer: nil))
        XCTAssertTrue(value.isNull)
    }
}
