import SwiftUI

/// Recent queries for this connection, newest first. Selecting one
/// *appends* it to the editor (rather than replacing the contents), so
/// recalling a query can never discard something half-written — the same
/// non-destructive behavior the sidebar's SQL templates use.
///
/// Lives in the window's own toolbar next to Yeni Bağlantı/Yeni Tablo/
/// Ayarlar rather than in the SQL panel's row: the history is a property of
/// the connection, not of the editor, and the panel's toolbar is a
/// horizontal scroller where one more item pushed the run/return controls
/// off the right edge on a narrow window.
struct QueryHistoryMenu: View {
    @ObservedObject var console: SQLConsoleViewModel
    /// The history list lives in the store, not in `console`, so observing
    /// only `console` would leave the menu showing a stale list until some
    /// unrelated published change happened to redraw this view. Observed
    /// here so a newly recorded query shows up on its own.
    @ObservedObject private var queryHistoryStore = QueryHistoryStore.shared
    @EnvironmentObject private var settingsStore: SettingsStore

    /// Capped at 20 here: the full 200 live in the store, but a menu that
    /// long is unusable, and the older entries are better served by a
    /// searchable list if one is ever added.
    var body: some View {
        let entries = Array(console.queryHistory.prefix(20))
        return Menu {
            if entries.isEmpty {
                Text("Geçmiş boş")
            } else {
                ForEach(entries) { entry in
                    Button {
                        console.isQueryPanelVisible = true
                        console.pendingQueryAppend = entry.sql
                    } label: {
                        // The icon separates queries you typed from the
                        // statements the app ran for a UI action — they
                        // read very differently in a mixed list.
                        Label(entry.singleLinePreview(), systemImage: entry.sourceSymbolName)
                    }
                }

                Divider()

                Button("Geçmişi Temizle", role: .destructive) {
                    console.clearQueryHistory()
                }
            }
        } label: {
            // Sized through the `NSImage` rather than a `.frame`: a menu's
            // label in the toolbar lays out from the image's natural size
            // and ignores the frame, so the 500 px artwork drew full size
            // and swallowed the window.
            Image.bundled(
                "query_history",
                fallbackSystemImage: "clock.arrow.circlepath",
                pointSize: settingsStore.settings.general.toolbarIconSize
            )
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Geçmiş: bu bağlantıda çalıştırılan son sorgular — seçilen sorgu editörün sonuna eklenir")
    }
}
