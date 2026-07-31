import SwiftUI

/// The Ayarlar window content (native `Settings` scene): three tabs plus a
/// global "Varsayılanlara Sıfırla". Host-agnostic — nothing here assumes
/// the Settings scene, so it could be presented as a sheet if ever needed.
struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("Genel", systemImage: "gearshape") }
            sidebarTab
                .tabItem { Label("Kenar Çubuğu", systemImage: "sidebar.leading") }
            gridTab
                .tabItem { Label("Veri Izgarası", systemImage: "tablecells") }
            editorTab
                .tabItem { Label("SQL Editörü", systemImage: "terminal") }
        }
        .scenePadding()
        .frame(minWidth: 520, idealWidth: 560)
    }

    // MARK: - Genel

    private var generalTab: some View {
        Form {
            Picker("Tema", selection: $appearanceStore.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Toggle("Satır silmeden önce onay iste", isOn: $settingsStore.settings.general.confirmRowDeletion)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Kenar Çubuğu (tree view)

    private var sidebarTab: some View {
        Form {
            sizeStepper("Yazı boyutu", value: $settingsStore.settings.sidebar.fontSize, range: 10...20)
            sizeStepper("Satır aralığı", value: $settingsStore.settings.sidebar.rowVerticalPadding, range: 0...12)

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Yazı rengi", \.sidebar.textColor)

            // Eleven rows would push the rest of the tab (and the reset
            // button) off a reasonably-sized window, so they start folded.
            DisclosureGroup("Ağaç ikon renkleri") {
                adaptiveColorRow("Veritabanı", \.sidebar.databaseIcon)
                adaptiveColorRow("Tablolar grubu", \.sidebar.tablesGroupIcon)
                adaptiveColorRow("Tablo adları", \.sidebar.tableIcon)
                adaptiveColorRow("Kolonlar", \.sidebar.columnsIcon)
                adaptiveColorRow("İndeksler", \.sidebar.indexesIcon)
                adaptiveColorRow("View'lar grubu", \.sidebar.viewsGroupIcon)
                adaptiveColorRow("View adları", \.sidebar.viewIcon)
                adaptiveColorRow("Procedure'lar grubu", \.sidebar.proceduresGroupIcon)
                adaptiveColorRow("Procedure adları", \.sidebar.procedureIcon)
                adaptiveColorRow("Function'lar grubu", \.sidebar.functionsGroupIcon)
                adaptiveColorRow("Function adları", \.sidebar.functionIcon)
            }
            .padding(.top, 4)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Veri Izgarası

    private var gridTab: some View {
        Form {
            sizeStepper("Satır yüksekliği", value: $settingsStore.settings.grid.rowHeight, range: 16...40)
            sizeStepper("Hücre yazı boyutu", value: $settingsStore.settings.grid.cellFontSize, range: 9...20)
            sizeStepper("Başlık yazı boyutu", value: $settingsStore.settings.grid.headerFontSize, range: 10...22)

            LabeledContent("Varsayılan sayfa boyutu") {
                TextField("", value: $settingsStore.settings.grid.defaultPageSize, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Başlık zemin rengi", \.grid.headerBackground)
            adaptiveColorRow("Başlık yazı rengi", \.grid.headerText)
            adaptiveColorRow("Izgara çizgi rengi", \.grid.gridLine)
            adaptiveColorRow("Hücre yazı rengi", \.grid.cellTextColor)
            adaptiveColorRow("Seçili satır zemin rengi", \.grid.selectedRowBackground)
            adaptiveColorRow("Seçili satır yazı rengi", \.grid.selectedRowText)

            Divider().padding(.vertical, 4)

            Text("İnfo Görünümü")
                .font(.headline)
            sizeStepper("Yazı boyutu", value: $settingsStore.settings.info.fontSize, range: 9...20)
            adaptiveColorRow("Yazı rengi", \.info.textColor)

            resetSection
        }
        .padding(16)
    }

    // MARK: - SQL Editörü

    private var editorTab: some View {
        Form {
            sizeStepper("Yazı boyutu", value: $settingsStore.settings.editor.fontSize, range: 9...24)
            Toggle("Anahtar kelimeleri otomatik BÜYÜK yaz", isOn: $settingsStore.settings.editor.autoUppercaseKeywords)
            Toggle("Satır numaralarını göster", isOn: $settingsStore.settings.editor.showLineNumbers)

            LabeledContent("Varsayılan SELECT LIMIT") {
                TextField("", value: $settingsStore.settings.editor.defaultSelectLimit, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            Divider().padding(.vertical, 4)

            sizeStepper("Durum/hata mesajı yazı boyutu", value: $settingsStore.settings.editor.statusFontSize, range: 10...20)
            adaptiveColorRow("Hata mesajı rengi", \.editor.errorColor)

            Divider().padding(.vertical, 4)

            adaptiveColorRow("Anahtar kelime rengi", \.editor.keywordColor)
            adaptiveColorRow("Metin ('...') rengi", \.editor.stringColor)
            adaptiveColorRow("Yorum (--) rengi", \.editor.commentColor)

            resetSection
        }
        .padding(16)
    }

    // MARK: - Shared pieces

    private func sizeStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
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

    private func adaptiveColorRow(_ title: String, _ keyPath: WritableKeyPath<AppSettings, AdaptiveColorSetting>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 14) {
                ColorPicker("Açık", selection: AdaptiveColorSetting.binding(settingsStore, keyPath, dark: false))
                ColorPicker("Koyu", selection: AdaptiveColorSetting.binding(settingsStore, keyPath, dark: true))
            }
            .font(.callout)
        }
    }

    private var resetSection: some View {
        HStack {
            Spacer()
            Button("Varsayılanlara Sıfırla", role: .destructive) {
                settingsStore.resetToDefaults()
            }
            .padding(.top, 8)
        }
    }
}
