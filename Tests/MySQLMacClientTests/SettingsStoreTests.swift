import XCTest
@testable import MySQLMacClient

/// Pure persistence/formatting tests — no database needed. Each test uses
/// its own temp file URL, never the real settings.json or the shared
/// singleton.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private var tempFileURL: URL!

    override func setUp() {
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFileURL)
    }

    func testFreshStoreStartsWithDefaults() {
        let store = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(store.settings.grid.rowHeight, 20)
        XCTAssertEqual(store.settings.grid.defaultPageSize, 1000)
        XCTAssertTrue(store.settings.editor.autoUppercaseKeywords)
        XCTAssertTrue(store.settings.general.confirmRowDeletion)
        XCTAssertEqual(store.settings.sidebar.fontSize, 13)
        XCTAssertEqual(store.settings.sidebar.rowVerticalPadding, 4)
        XCTAssertEqual(store.settings.editor.statusFontSize, 13)
        XCTAssertEqual(store.settings.info.fontSize, 12)
        XCTAssertEqual(store.settings.grid.cellTextColor.light, "#000000")
        XCTAssertEqual(store.settings.grid.cellTextColor.dark, "#ffffff")
        XCTAssertEqual(store.settings.sidebar.textColor.light, "#000000")
        XCTAssertEqual(store.settings.sidebar.textColor.dark, "#ffffff")
    }

    func testSidebarTextColorPersists() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.sidebar.textColor.light = "#654321"
        store.settings.sidebar.textColor.dark = "#fedcba"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.sidebar.textColor.light, "#654321")
        XCTAssertEqual(reloaded.settings.sidebar.textColor.dark, "#fedcba")
    }

    func testSidebarTextColorFallsBackToDefaultWhenMissingFromOldSettingsFile() throws {
        try Data(#"{"sidebar": {"fontSize": 16}}"#.utf8).write(to: tempFileURL)

        let store = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(store.settings.sidebar.fontSize, 16)
        XCTAssertEqual(store.settings.sidebar.textColor, AppSettings.Sidebar().textColor)
    }

    func testSidebarIconColorsPersist() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.sidebar.databaseIcon.light = "#112233"
        store.settings.sidebar.functionIcon.dark = "#445566"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.sidebar.databaseIcon.light, "#112233")
        XCTAssertEqual(reloaded.settings.sidebar.functionIcon.dark, "#445566")
    }

    /// Every icon color has to survive a settings.json written before they
    /// existed — one missing key must not wipe the rest of the sidebar
    /// settings or hand back an empty color string.
    func testSidebarIconColorsFallBackToDefaultsWhenMissingFromOldSettingsFile() throws {
        try Data(#"{"sidebar": {"fontSize": 15}}"#.utf8).write(to: tempFileURL)

        let store = SettingsStore(fileURL: tempFileURL)
        let defaults = AppSettings.Sidebar()
        XCTAssertEqual(store.settings.sidebar.fontSize, 15)
        XCTAssertEqual(store.settings.sidebar.databaseIcon, defaults.databaseIcon)
        XCTAssertEqual(store.settings.sidebar.tablesGroupIcon, defaults.tablesGroupIcon)
        XCTAssertEqual(store.settings.sidebar.tableIcon, defaults.tableIcon)
        XCTAssertEqual(store.settings.sidebar.columnsIcon, defaults.columnsIcon)
        XCTAssertEqual(store.settings.sidebar.indexesIcon, defaults.indexesIcon)
        XCTAssertEqual(store.settings.sidebar.viewsGroupIcon, defaults.viewsGroupIcon)
        XCTAssertEqual(store.settings.sidebar.viewIcon, defaults.viewIcon)
        XCTAssertEqual(store.settings.sidebar.proceduresGroupIcon, defaults.proceduresGroupIcon)
        XCTAssertEqual(store.settings.sidebar.procedureIcon, defaults.procedureIcon)
        XCTAssertEqual(store.settings.sidebar.functionsGroupIcon, defaults.functionsGroupIcon)
        XCTAssertEqual(store.settings.sidebar.functionIcon, defaults.functionIcon)
    }

    /// The shipped defaults are a per-kind palette, not one uniform gray:
    /// a fresh install (and "Varsayılanlara Sıfırla") must land on distinct
    /// hues, and light/dark must differ where the palette says so.
    func testSidebarIconColorDefaultsAreADistinctPalette() {
        let defaults = AppSettings.Sidebar()

        XCTAssertEqual(defaults.databaseIcon, AdaptiveColorSetting(light: "#1002e3", dark: "#5fd2f7"))
        XCTAssertEqual(defaults.tablesGroupIcon, AdaptiveColorSetting(light: "#00b665", dark: "#15ec82"))
        XCTAssertEqual(defaults.indexesIcon, AdaptiveColorSetting(light: "#ed321c", dark: "#fef12a"))

        // A routine's group row and its children share a color on purpose.
        XCTAssertEqual(defaults.procedureIcon, defaults.proceduresGroupIcon)
        XCTAssertEqual(defaults.functionIcon, defaults.functionsGroupIcon)
        XCTAssertEqual(defaults.viewIcon, defaults.viewsGroupIcon)

        // ...but the categories are distinguishable from each other.
        let lightColors = [
            defaults.databaseIcon, defaults.tablesGroupIcon, defaults.tableIcon,
            defaults.columnsIcon, defaults.indexesIcon, defaults.viewsGroupIcon,
            defaults.proceduresGroupIcon, defaults.functionsGroupIcon,
        ].map(\.light)
        XCTAssertEqual(Set(lightColors).count, lightColors.count, "her kategori kendi rengine sahip olmalı")
    }

    /// The eleven icon colors are independent knobs — setting one must not
    /// move another (easy to get wrong when they share a default).
    func testSidebarIconColorsAreIndependent() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.sidebar.tableIcon.light = "#ff0000"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.sidebar.tableIcon.light, "#ff0000")
        XCTAssertEqual(reloaded.settings.sidebar.viewIcon, AppSettings.Sidebar().viewIcon)
        XCTAssertEqual(reloaded.settings.sidebar.databaseIcon, AppSettings.Sidebar().databaseIcon)
    }

    func testCellTextColorPersists() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.grid.cellTextColor.light = "#123456"
        store.settings.grid.cellTextColor.dark = "#abcdef"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.grid.cellTextColor.light, "#123456")
        XCTAssertEqual(reloaded.settings.grid.cellTextColor.dark, "#abcdef")
    }

    func testCellTextColorFallsBackToDefaultWhenMissingFromOldSettingsFile() throws {
        // Simulates a settings.json written before `cellTextColor` existed.
        try Data(#"{"grid": {"rowHeight": 24}}"#.utf8).write(to: tempFileURL)

        let store = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(store.settings.grid.rowHeight, 24)
        XCTAssertEqual(store.settings.grid.cellTextColor, AppSettings.Grid().cellTextColor)
    }

    func testInfoSettingsPersist() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.info.fontSize = 14
        store.settings.info.textColor.dark = "#ffffff"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.info.fontSize, 14)
        XCTAssertEqual(reloaded.settings.info.textColor.dark, "#ffffff")
    }

    func testSidebarAndStatusSettingsPersist() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.sidebar.fontSize = 16
        store.settings.sidebar.rowVerticalPadding = 8
        store.settings.editor.statusFontSize = 15
        store.settings.editor.errorColor.light = "#aa0000"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.sidebar.fontSize, 16)
        XCTAssertEqual(reloaded.settings.sidebar.rowVerticalPadding, 8)
        XCTAssertEqual(reloaded.settings.editor.statusFontSize, 15)
        XCTAssertEqual(reloaded.settings.editor.errorColor.light, "#aa0000")
    }

    func testChangesPersistAcrossStoreInstances() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.grid.rowHeight = 28
        store.settings.editor.autoUppercaseKeywords = false
        store.settings.grid.selectedRowBackground.dark = "#123456"

        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings.grid.rowHeight, 28)
        XCTAssertFalse(reloaded.settings.editor.autoUppercaseKeywords)
        XCTAssertEqual(reloaded.settings.grid.selectedRowBackground.dark, "#123456")
    }

    func testMissingKeysFallBackToDefaults() throws {
        // An old settings.json knowing only one nested field.
        try Data(#"{"grid": {"rowHeight": 30}}"#.utf8).write(to: tempFileURL)

        let store = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(store.settings.grid.rowHeight, 30)
        XCTAssertEqual(store.settings.grid.cellFontSize, 12, "eksik alan varsayılana düşmeli")
        XCTAssertEqual(store.settings.editor.fontSize, 13, "eksik bölüm varsayılana düşmeli")
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("bozuk { json".utf8).write(to: tempFileURL)
        let store = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(store.settings, .defaults)
    }

    func testResetToDefaultsPersists() {
        let store = SettingsStore(fileURL: tempFileURL)
        store.settings.editor.fontSize = 18
        store.resetToDefaults()

        XCTAssertEqual(store.settings, .defaults)
        let reloaded = SettingsStore(fileURL: tempFileURL)
        XCTAssertEqual(reloaded.settings, .defaults)
    }

    func testHexRoundTrip() {
        let color = NSColor(hexString: "#3c8a2f")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString, "#3c8a2f")
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(NSColor(hexString: "3c8a2f"))
        XCTAssertNil(NSColor(hexString: "#zzzzzz"))
        XCTAssertNil(NSColor(hexString: "#fff"))
        XCTAssertNil(NSColor(hexString: ""))
    }
}
