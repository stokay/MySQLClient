import SwiftUI

/// The Ayarlar window content (native `Settings` scene): three tabs plus a
/// global "Varsayılanlara Sıfırla". Host-agnostic — nothing here assumes
/// the Settings scene, so it could be presented as a sheet if ever needed.
struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var languageStore: LanguageStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            sidebarTab
                .tabItem { Label("Sidebar", systemImage: "sidebar.leading") }
            gridTab
                .tabItem { Label("Data Grid", systemImage: "tablecells") }
            editorTab
                .tabItem { Label("SQL Editor", systemImage: "terminal") }
        }
        .scenePadding()
        .frame(minWidth: 520, idealWidth: 560)
    }

    // MARK: - Genel

    private var generalTab: some View {
        Form {
            Picker("Theme", selection: $appearanceStore.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Toggle("Ask for confirmation before deleting a row", isOn: $settingsStore.settings.general.confirmRowDeletion)

            Divider().padding(.vertical, 4)

            languagePicker

            Divider().padding(.vertical, 4)

            sizeStepper("Main toolbar icon size", value: $settingsStore.settings.general.toolbarIconSize, range: 20...36)
            sizeStepper("Table toolbar icon size", value: $settingsStore.settings.general.gridToolbarIconSize, range: 20...36)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Kenar Çubuğu (tree view)

    private var sidebarTab: some View {
        Form {
            sizeStepper("Font size", value: $settingsStore.settings.sidebar.fontSize, range: 10...20)
            sizeStepper("Row spacing", value: $settingsStore.settings.sidebar.rowVerticalPadding, range: 0...12)

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Text color", \.sidebar.textColor)

            // Eleven rows would push the rest of the tab (and the reset
            // button) off a reasonably-sized window, so they start folded.
            DisclosureGroup("Tree icon colors") {
                adaptiveColorRow("Database", \.sidebar.databaseIcon)
                adaptiveColorRow("Tables group", \.sidebar.tablesGroupIcon)
                adaptiveColorRow("Table names", \.sidebar.tableIcon)
                adaptiveColorRow("Columns", \.sidebar.columnsIcon)
                adaptiveColorRow("Indexes", \.sidebar.indexesIcon)
                adaptiveColorRow("Views group", \.sidebar.viewsGroupIcon)
                adaptiveColorRow("View names", \.sidebar.viewIcon)
                adaptiveColorRow("Procedures group", \.sidebar.proceduresGroupIcon)
                adaptiveColorRow("Procedure names", \.sidebar.procedureIcon)
                adaptiveColorRow("Functions group", \.sidebar.functionsGroupIcon)
                adaptiveColorRow("Function names", \.sidebar.functionIcon)
            }
            .padding(.top, 4)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Veri Izgarası

    private var gridTab: some View {
        Form {
            sizeStepper("Row height", value: $settingsStore.settings.grid.rowHeight, range: 16...40)
            sizeStepper("Cell font size", value: $settingsStore.settings.grid.cellFontSize, range: 9...20)
            sizeStepper("Header font size", value: $settingsStore.settings.grid.headerFontSize, range: 10...22)

            LabeledContent("Default page size") {
                TextField("", value: $settingsStore.settings.grid.defaultPageSize, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Header background color", \.grid.headerBackground)
            adaptiveColorRow("Header text color", \.grid.headerText)
            adaptiveColorRow("Grid line color", \.grid.gridLine)
            adaptiveColorRow("Cell text color", \.grid.cellTextColor)
            adaptiveColorRow("Selected row background color", \.grid.selectedRowBackground)
            adaptiveColorRow("Selected row text color", \.grid.selectedRowText)

            Divider().padding(.vertical, 4)

            Text("Info View")
                .font(.headline)
            sizeStepper("Font size", value: $settingsStore.settings.info.fontSize, range: 9...20)
            adaptiveColorRow("Text color", \.info.textColor)

            resetSection
        }
        .padding(16)
    }

    // MARK: - SQL Editörü

    private var editorTab: some View {
        Form {
            sizeStepper("Font size", value: $settingsStore.settings.editor.fontSize, range: 9...24)
            Toggle("Automatically UPPERCASE keywords", isOn: $settingsStore.settings.editor.autoUppercaseKeywords)
            Toggle("Show line numbers", isOn: $settingsStore.settings.editor.showLineNumbers)

            LabeledContent("Default SELECT LIMIT") {
                TextField("", value: $settingsStore.settings.editor.defaultSelectLimit, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            Divider().padding(.vertical, 4)

            Toggle("Save query history", isOn: $settingsStore.settings.editor.saveQueryHistory)
            LabeledContent("Query history") {
                Button("Clear History for All Connections", role: .destructive) {
                    QueryHistoryStore.shared.clearAll()
                }
            }
            // Queries can carry sensitive literals, and history is kept per
            // connection — so the opt-out and a way to wipe it belong next
            // to each other, in plain sight rather than buried.
            Text("History is kept only on this Mac, up to \(QueryHistoryStore.maximumEntriesPerProfile) queries per connection.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            sizeStepper("Status/error message font size", value: $settingsStore.settings.editor.statusFontSize, range: 10...20)
            adaptiveColorRow("Error message color", \.editor.errorColor)

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Keyword color", \.editor.keywordColor)
            adaptiveColorRow("String ('...') color", \.editor.stringColor)
            adaptiveColorRow("Comment (--) color", \.editor.commentColor)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Language

    /// The relaunch hint is shown only after the selection diverges from
    /// what the running process actually loaded — including when the user
    /// changes their mind and picks the original language back, at which
    /// point it correctly disappears again.
    @ViewBuilder
    private var languagePicker: some View {
        Picker("Language", selection: $languageStore.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.label).tag(language)
            }
        }

        if languageStore.needsRelaunch {
            Text("Restart the app for the language change to take effect.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared pieces

    private func sizeStepper(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Stepper(
                    value: value,
                    in: range,
                    step: 1
                ) {
                    Text("\(Int(value.wrappedValue)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func adaptiveColorRow(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<AppSettings, AdaptiveColorSetting>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 14) {
                ColorPicker("Light", selection: AdaptiveColorSetting.binding(settingsStore, keyPath, dark: false))
                ColorPicker("Dark", selection: AdaptiveColorSetting.binding(settingsStore, keyPath, dark: true))
            }
            .font(.callout)
        }
    }

    private var resetSection: some View {
        HStack {
            Spacer()
            Button("Reset to Defaults", role: .destructive) {
                settingsStore.resetToDefaults()
            }
            .padding(.top, 8)
        }
    }
}
