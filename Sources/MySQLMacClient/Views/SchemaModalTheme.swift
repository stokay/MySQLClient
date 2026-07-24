import SwiftUI

/// Shared visual language for the schema-editing modals (Yeni Tablo, Alter
/// Table) and the column grid they both embed (`DraftColumnsEditor`) — a
/// deliberately more custom-drawn, indigo-accented look (rounded corners,
/// hand-drawn checkboxes/buttons) rather than the native-control styling
/// used elsewhere in the app (`visibleFieldBorder`, system checkboxes).
///
/// Reads `colorScheme` from the environment, which reflects the app's own
/// manual Light/Dark toggle (`AppearanceStore` sets `.preferredColorScheme`
/// at the window root) — not the system appearance directly, same source
/// every other themed view in the app already uses.
struct SchemaModalTheme {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// Behind the whole sheet.
    var windowBackground: Color { isDark ? Color(hex: 0x1a1b26) : Color(hex: 0xf3f3f8) }
    /// Behind a titled section (the columns grid, the header form).
    var cardBackground: Color { isDark ? Color(hex: 0x20212d) : .white }
    /// Behind an individual text field.
    var fieldBackground: Color { isDark ? Color(hex: 0x282a38) : .white }
    var fieldBorder: Color { isDark ? Color(hex: 0x3a3c4d) : Color(hex: 0xd8d9e3) }
    var sectionBorder: Color { isDark ? Color(hex: 0x2c2d3a) : Color(hex: 0xe3e4ec) }
    /// The indigo accent — primary buttons, checked checkboxes.
    var accent: Color { isDark ? Color(hex: 0x7c6ff0) : Color(hex: 0x6350e0) }
    var textPrimary: Color { isDark ? Color(hex: 0xe7e7ee) : Color(hex: 0x1c1d26) }
    var textSecondary: Color { isDark ? Color(hex: 0x8b8d98) : Color(hex: 0x6b6d78) }
    /// The table name next to "Alter Table" in the title.
    var amber: Color { isDark ? Color(hex: 0xe0af68) : Color(hex: 0xb8791a) }
    /// Behind the SQL Önizleme box — a shade darker/lighter than
    /// `cardBackground` so it reads as its own recessed panel.
    var previewBackground: Color { isDark ? Color(hex: 0x14151f) : Color(hex: 0xf7f7fb) }
}

// MARK: - Buttons

/// "Oluştur"/"Uygula"/"Kolon Ekle" — solid accent fill.
struct SchemaPrimaryButtonStyle: ButtonStyle {
    let theme: SchemaModalTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

/// "İptal" — outlined, no fill.
struct SchemaSecondaryButtonStyle: ButtonStyle {
    let theme: SchemaModalTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.fieldBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

/// A plain icon-only button (row delete, row reorder) recolored to the
/// theme's secondary text tone instead of the system's default tint.
struct SchemaIconButtonStyle: ButtonStyle {
    let theme: SchemaModalTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.textSecondary)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

// MARK: - Checkbox

/// A hand-drawn checkbox (filled accent square + checkmark when on)
/// replacing `.toggleStyle(.checkbox)`'s native box, so it follows the
/// theme's accent color instead of the system's blue/graphite.
struct SchemaCheckboxToggleStyle: ToggleStyle {
    let theme: SchemaModalTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(configuration.isOn ? theme.accent : theme.fieldBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(configuration.isOn ? theme.accent : theme.fieldBorder, lineWidth: 1)
                )
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Field border

private struct SchemaFieldBorder: ViewModifier {
    let theme: SchemaModalTheme
    var padding: CGFloat = 6
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, padding)
            .padding(.vertical, padding * 0.6)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(theme.fieldBackground))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(theme.fieldBorder, lineWidth: 1))
    }
}

extension View {
    func schemaFieldBorder(theme: SchemaModalTheme, padding: CGFloat = 6, cornerRadius: CGFloat = 6) -> some View {
        modifier(SchemaFieldBorder(theme: theme, padding: padding, cornerRadius: cornerRadius))
    }

    /// The card behind a titled section (columns grid, header form, SQL
    /// preview) — same rounded-card treatment, different fill per section.
    func schemaCard(theme: SchemaModalTheme, fill: Color? = nil, cornerRadius: CGFloat = 10) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill ?? theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(theme.sectionBorder, lineWidth: 1))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
