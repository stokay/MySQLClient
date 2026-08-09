import SwiftUI

/// Compact Sistem/Açık/Koyu menu — placed on both the connection form and
/// the status bar so the override is reachable whether or not you're
/// connected yet.
struct AppearancePickerView: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        Menu {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    appearanceStore.mode = mode
                } label: {
                    HStack {
                        Label(mode.label, systemImage: mode.systemImage)
                        if appearanceStore.mode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: appearanceStore.mode.systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Appearance: \(appearanceStore.mode.label)")
    }
}
