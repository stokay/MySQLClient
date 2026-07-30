import AppKit

/// Shared look for every `NSTableView`-backed grid in the app (the main
/// editable table grid and the SQL query results grid) — kept in one place
/// so the two don't visually drift apart.

extension NSColor {
    /// A color that resolves differently depending on the app's *current*
    /// effective appearance (`AppearanceStore` sets `NSApp.appearance`
    /// directly, since this is a manual in-app override, not the system
    /// Light/Dark setting) — resolved fresh on every draw, not just once.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Row/column separator lines for the data grids. Settings-driven: the
    /// dynamic provider re-reads the stored hex pair on every draw, so a
    /// change in the Ayarlar window shows up without recreating anything.
    static let gridLineColor = NSColor.settingsColor(
        \.grid.gridLine,
        fallback: NSColor(red: 0xc5 / 255, green: 0xc5 / 255, blue: 0xc5 / 255, alpha: 1)
    )
}

/// Draws a flat custom background instead of the system header bezel, so
/// the header can use an app-chosen color pair instead of the system's.
final class ColoredHeaderCell: NSTableHeaderCell {
    static let backgroundColor = NSColor.settingsColor(
        \.grid.headerBackground,
        fallback: NSColor(red: 0x3c / 255, green: 0x3c / 255, blue: 0x3c / 255, alpha: 1)
    )
    static let textColor = NSColor.settingsColor(
        \.grid.headerText,
        fallback: NSColor(red: 0xc5 / 255, green: 0xc5 / 255, blue: 0xc5 / 255, alpha: 1)
    )
    static let separatorColor = NSColor(red: 0xcd / 255, green: 0xcd / 255, blue: 0xcd / 255, alpha: 1)

    /// Fully replacing `draw(withFrame:in:)` (for the custom background)
    /// also threw out AppKit's own between-header-cells separator, so it's
    /// redrawn by hand on the trailing edge.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Self.backgroundColor.setFill()
        cellFrame.fill()
        drawInterior(withFrame: cellFrame, in: controlView)

        Self.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
    }

    /// Fully custom (no `super` call) so the title is vertically centered —
    /// the default header cell draws it flush to the top of the frame.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let title = attributedStringValue
        let size = title.size()
        let textRect = NSRect(
            x: cellFrame.origin.x + 4,
            y: cellFrame.origin.y + (cellFrame.height - size.height) / 2,
            width: max(0, cellFrame.width - 8),
            height: size.height
        )
        title.draw(in: textRect)
    }

    @MainActor
    static func title(_ text: String, bold: Bool = true) -> NSAttributedString {
        let size = CGFloat(SettingsStore.shared.settings.grid.headerFontSize)
        return NSAttributedString(
            string: text,
            attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: textColor,
            ]
        )
    }
}

/// Draws the selected row's background in an app-chosen flat color instead
/// of the system's blue/gray selection highlight, and recolors its own
/// cells' text the instant `isSelected` changes.
///
/// Recoloring used to happen from `tableViewSelectionDidChange`, a
/// notification that fires *after* AppKit has already flipped the row to
/// its selected background — that gap between "background is now selected"
/// and "our delegate gets around to recoloring the text" was the flash.
/// Overriding `isSelected` here does both in the same synchronous step,
/// before any redraw happens.
final class SelectedColorRowView: NSTableRowView {
    static let selectedBackgroundColor = NSColor.settingsColor(
        \.grid.selectedRowBackground,
        fallback: NSColor(red: 0xdc / 255, green: 0xdc / 255, blue: 0xdc / 255, alpha: 1)
    )
    static let selectedTextColor = NSColor.settingsColor(
        \.grid.selectedRowText,
        fallback: NSColor(red: 0x22 / 255, green: 0x1a / 255, blue: 0x14 / 255, alpha: 1)
    )
    /// Unselected-row cell text — used to be a hardcoded `.labelColor` with
    /// no Settings knob.
    static let cellTextColor = NSColor.settingsColor(\.grid.cellTextColor, fallback: .labelColor)

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            recolorTextFields()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Self.selectedBackgroundColor.setFill()
        bounds.fill()
    }

    private func recolorTextFields() {
        for cellContainer in subviews {
            for subview in cellContainer.subviews {
                guard let textField = subview as? NSTextField else { continue }
                (textField.cell as? NSTextFieldCell)?.backgroundStyle = .normal
                textField.textColor = isSelected ? Self.selectedTextColor : Self.cellTextColor
            }
        }
    }
}

/// A row's `backgroundStyle` normally flips to `.emphasized` on selection,
/// which makes an `NSTextField` briefly auto-swap to the system's own
/// light/selected text color before an explicit `textColor` takes over —
/// the "flash" on mouse-click select. Forcing `.normal` makes AppKit skip
/// that auto-adjustment, so only the explicit color ever applies.
@MainActor
func applyGridTextColor(to textField: NSTextField, isSelected: Bool) {
    (textField.cell as? NSTextFieldCell)?.backgroundStyle = .normal
    textField.textColor = isSelected ? SelectedColorRowView.selectedTextColor : SelectedColorRowView.cellTextColor
}

/// A reusable text cell for the grids (`SpreadsheetGridView`,
/// `QueryResultGridView`) — one instance per column identifier, recycled by
/// `NSTableView.makeView(withIdentifier:owner:)` as rows scroll in and out,
/// instead of a fresh `NSTextField` + Auto Layout constraint pair allocated
/// for *every* cell on *every* scroll tick. That per-cell allocation was
/// the main reason large tables scrolled noticeably slower here than in
/// comparable SQL clients (DBeaver, SQLyog) — Auto Layout solving a new
/// constraint set per cell dominates the cost, far more than the actual
/// text drawing.
///
/// A plain `NSView`, not `NSTableCellView` — `NSTableCellView` has its own
/// automatic `backgroundStyle` propagation tied to row selection that kept
/// re-asserting itself over an explicit text color on the frame a row got
/// selected (the "flash"), even after forcing `.normal` on the cell.
/// Nothing here relies on `NSTableCellView`'s outlets, so the plain
/// container sidesteps that behavior entirely — see `SelectedColorRowView`.
final class GridTextCellView: NSView {
    let textField = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Reusable trash-button cell for the delete column — same reuse rationale
/// as `GridTextCellView`.
final class GridButtonCellView: NSView {
    let button: NSButton

    override init(frame frameRect: NSRect) {
        button = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Sil") ?? NSImage(), target: nil, action: nil)
        super.init(frame: frameRect)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Shared confirmation before a row's trash button actually deletes it —
/// used by both grids (`SpreadsheetGridView` and `QueryResultGridView`)
/// since a one-click, no-undo delete is easy to trigger by accident.
@MainActor
func confirmRowDeletion(in window: NSWindow?, onConfirm: @escaping () -> Void) {
    guard SettingsStore.shared.settings.general.confirmRowDeletion else {
        onConfirm()
        return
    }
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Bu satır silinsin mi?"
    alert.informativeText = "Bu işlem geri alınamaz."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Sil")
    alert.addButton(withTitle: "İptal")
    alert.buttons.first?.hasDestructiveAction = true
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        onConfirm()
    }
}
