import SwiftUI
import AppKit

/// A plain `TextEditor` can't color individual words, so the SQL panel uses
/// this `NSTextView` wrapper instead — reserved-word highlighting is
/// reapplied to the whole buffer on every edit. Queries are short enough
/// that re-highlighting from scratch each keystroke is cheap; this isn't
/// meant to scale to editing large scripts.
/// Bridges the SQL editor's undo stack to SwiftUI so toolbar buttons can
/// drive it and stay correctly enabled/disabled. The stack itself is the
/// coordinator's dedicated `UndoManager` (see `undoManager(for:)`), not the
/// window's shared one — otherwise "undo" in the query panel could revert
/// an unrelated grid-cell edit.
@MainActor
final class SQLEditorUndoProxy: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private weak var manager: UndoManager?
    private weak var textView: NSTextView?
    // Tokens are removed in `deinit`, which is nonisolated — same escape
    // hatch as the grids' key monitors.
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    func attach(manager: UndoManager, textView: NSTextView) {
        guard manager !== self.manager else { return }
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens = []
        self.manager = manager
        self.textView = textView

        // `.checkpoint` is what fires during typing (group open but not
        // yet closed) — without it the Undo button stays disabled until
        // the user clicks elsewhere.
        let names: [Notification.Name] = [
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerCheckpoint,
        ]
        for name in names {
            observerTokens.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func undo() {
        // Typing is coalesced into an open group until something ends it;
        // the menu's own undo: action breaks it implicitly, a direct
        // `manager.undo()` does not — without this, undoing mid-typing
        // could swallow more (or less) than the last burst of typing.
        textView?.breakUndoCoalescing()
        manager?.undo()
        refresh()
    }

    func redo() {
        textView?.breakUndoCoalescing()
        manager?.redo()
        refresh()
    }

    private func refresh() {
        canUndo = manager?.canUndo ?? false
        canRedo = manager?.canRedo ?? false
    }
}

struct SQLTextView: NSViewRepresentable {
    let undoProxy: SQLEditorUndoProxy
    /// Observed so settings changes re-invoke `updateNSView` (font, ruler
    /// visibility, syntax re-highlight).
    @EnvironmentObject private var settingsStore: SettingsStore
    @Binding var text: String
    /// One-shot signal: when set, its text is inserted at the *current*
    /// cursor position (double-clicking a table/column in the sidebar sets
    /// this) and the binding is cleared back to `nil` right after.
    @Binding var pendingInsertion: String?
    /// One-shot like `pendingInsertion`, but the text is appended after the
    /// editor's existing content (separated by a blank line) and left
    /// *selected*, so Çalıştır immediately targets just the new statement.
    @Binding var pendingAppend: String?
    /// Mirrors the editor's current selection (nil when the selection is
    /// empty) so "Çalıştır" can execute only the selected statement. Bound
    /// to a plain non-`@Published` var on the view model on purpose — see
    /// `TableDataViewModel.querySelectedText`.
    @Binding var selectedText: String?

    static let keywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set",
        "delete", "create", "table", "alter", "drop", "index", "primary", "key",
        "foreign", "references", "join", "inner", "left", "right", "outer", "cross", "on",
        "group", "by", "order", "having", "limit", "offset", "as", "and", "or",
        "not", "null", "is", "in", "like", "between", "distinct", "union", "all",
        "exists", "case", "when", "then", "else", "end", "asc", "desc", "default",
        "auto_increment", "unique", "constraint", "cascade", "view", "trigger",
        "procedure", "function", "database", "schema", "show", "describe", "explain",
        "truncate", "replace", "use", "column", "add", "modify", "change", "if",
    ]

    // Settings-driven: dynamic providers re-read the stored hex on every
    // draw (see `NSColor.settingsColor`).
    static let keywordColor = NSColor.settingsColor({ $0.editor.keywordColor }, fallback: .systemBlue)
    static let stringLiteralColor = NSColor.settingsColor({ $0.editor.stringColor }, fallback: .systemGreen)
    static let commentColor = NSColor.settingsColor({ $0.editor.commentColor }, fallback: .systemGray)

    @MainActor
    static var editorFont: NSFont {
        .monospacedSystemFont(ofSize: CGFloat(SettingsStore.shared.settings.editor.fontSize), weight: .regular)
    }

    @MainActor
    static var editorBoldFont: NSFont {
        .monospacedSystemFont(ofSize: CGFloat(SettingsStore.shared.settings.editor.fontSize), weight: .bold)
    }

    private static let keywordRegex = try! NSRegularExpression(
        pattern: #"\b(\#(keywords.joined(separator: "|")))\b"#,
        options: [.caseInsensitive]
    )
    private static let stringLiteralRegex = try! NSRegularExpression(pattern: #"'[^']*'|"[^"]*""#)
    private static let commentRegex = try! NSRegularExpression(pattern: #"--[^\n]*"#)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.font = Self.editorFont
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        context.coordinator.highlight(textView)

        // Non-wrapping editor: the text container is effectively unbounded
        // in width, so a long statement extends rightward behind its own
        // horizontal scroller instead of wrapping onto extra lines (which
        // ate the panel's fixed height as the window narrowed). The
        // convenience initializer's `autoresizingMask = [.width]` is kept:
        // the frame still grows with the clip view when the window widens
        // (so the editor background always covers the full pane), while
        // `isHorizontallyResizable` lets it grow further to fit long lines.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        // Painted by the scroll view (not left transparent as before):
        // with a non-wrapping text view the frame can be narrower than the
        // clip area, and this keeps the whole editor pane uniformly
        // text-background-colored instead of showing a seam to its right.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let rulerView = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = settingsStore.settings.editor.showLineNumbers

        context.coordinator.textView = textView
        context.coordinator.rulerView = rulerView
        undoProxy.attach(manager: context.coordinator.editorUndoManager, textView: textView)
        return scrollView
    }

    /// The `pendingInsertion != nil` branch used to clear the binding
    /// *asynchronously* after also manually re-syncing `text`/highlighting.
    /// That manual `text = textView.string` assignment made SwiftUI call
    /// `updateNSView` again immediately — before the async clear had run —
    /// so this branch re-entered and inserted the same text again, and
    /// again, in a tight synchronous loop with no yield back to the run
    /// loop. The text ballooned every cycle, `highlight()` re-scanned the
    /// ever-growing string with regex on every cycle, and the whole
    /// machine froze hard enough to force a restart.
    ///
    /// Fix: clear `pendingInsertion` *synchronously, before* triggering
    /// anything that could cascade back into this method, and don't
    /// manually touch `text`/`highlight()` at all here — `insertText(_:)`
    /// goes through the normal AppKit editing pipeline and already fires
    /// `textDidChange` below, which does that syncing exactly like real
    /// typing would. By the time any re-entrant call arrives,
    /// `pendingInsertion` is already `nil`.
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        // Applied only when the editor settings actually changed — this
        // method also runs on every keystroke, and re-fonting/highlighting
        // unconditionally would be wasted work (and would fight the
        // field's own typing pipeline).
        let editorSettings = settingsStore.settings.editor
        if context.coordinator.lastAppliedEditorSettings != editorSettings {
            context.coordinator.lastAppliedEditorSettings = editorSettings
            textView.font = Self.editorFont
            nsView.rulersVisible = editorSettings.showLineNumbers
            context.coordinator.highlight(textView)
        }

        if let insertion = pendingInsertion {
            pendingInsertion = nil
            textView.window?.makeFirstResponder(textView)
            textView.insertText(insertion, replacementRange: textView.selectedRange())
            return
        }

        // Same one-shot discipline as `pendingInsertion` (cleared
        // synchronously before any mutation that could re-enter this
        // method — see that branch's history for why that ordering is
        // non-negotiable).
        if let appendText = pendingAppend {
            pendingAppend = nil
            textView.window?.makeFirstResponder(textView)

            let existing = textView.string
            let separator: String
            if existing.isEmpty {
                separator = ""
            } else if existing.hasSuffix("\n\n") {
                separator = ""
            } else if existing.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            let endRange = NSRange(location: (existing as NSString).length, length: 0)
            textView.insertText(separator + appendText, replacementRange: endRange)

            // Select just the template (not the separator), so ⌘↩ runs
            // exactly the appended statement.
            let start = endRange.location + (separator as NSString).length
            textView.setSelectedRange(NSRange(location: start, length: (appendText as NSString).length))
            textView.scrollRangeToVisible(textView.selectedRange())
            return
        }

        guard textView.string != text else { return }
        textView.string = text
        context.coordinator.highlight(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedText: $selectedText)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        let selectedText: Binding<String?>
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        /// Fingerprint of the last editor settings applied to the text
        /// view, so `updateNSView` only re-fonts/re-highlights on actual
        /// settings changes (it also runs on every keystroke).
        var lastAppliedEditorSettings = SettingsStore.shared.settings.editor

        /// The editor's own isolated undo stack, handed to the text view
        /// via the `undoManager(for:)` delegate method below.
        let editorUndoManager = UndoManager()

        init(text: Binding<String>, selectedText: Binding<String?>) {
            self.text = text
            self.selectedText = selectedText
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editorUndoManager
        }

        /// Re-entrancy guard: registering the uppercase replacements with
        /// the undo system (`didChangeText()`) re-posts this same
        /// notification mid-loop, and letting that nested call run
        /// `uppercaseKeywords` again would corrupt the outer loop's ranges.
        private var isApplyingKeywordCase = false

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isApplyingKeywordCase else { return }
            if SettingsStore.shared.settings.editor.autoUppercaseKeywords {
                uppercaseKeywords(in: textView)
            }
            text.wrappedValue = textView.string
            highlight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            selectedText.wrappedValue = range.length > 0
                ? (textView.string as NSString).substring(with: range)
                : nil
        }

        /// Rewrites any reserved word to its uppercase form in place. Runs
        /// before `highlight()`'s coloring pass so the two always agree —
        /// "the blue ones are always uppercase" is the point, not just a
        /// visual effect. Uppercasing ASCII keywords never changes their
        /// character count, so the caret position is restorable verbatim
        /// afterward instead of jumping around while typing.
        ///
        /// Each replacement goes through `shouldChangeText`/`didChangeText`
        /// so the undo manager records it in the *same undo group* as the
        /// keystroke that triggered it — ⌘Z then reverts the keystroke and
        /// the auto-uppercase together. The old direct
        /// `storage.replaceCharacters` bypassed undo entirely, which would
        /// have made undo restore typed characters while leaving half-
        /// uppercased keyword fragments behind.
        private func uppercaseKeywords(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let nsString = storage.string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            let savedSelection = textView.selectedRanges

            var replacements: [(NSRange, String)] = []
            for match in SQLTextView.keywordRegex.matches(in: storage.string, range: fullRange) {
                let word = nsString.substring(with: match.range)
                let upper = word.uppercased()
                if word != upper {
                    replacements.append((match.range, upper))
                }
            }
            guard !replacements.isEmpty else { return }

            isApplyingKeywordCase = true
            defer { isApplyingKeywordCase = false }
            for (range, replacement) in replacements.reversed() {
                guard textView.shouldChangeText(in: range, replacementString: replacement) else { continue }
                storage.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            textView.selectedRanges = savedSelection
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let string = storage.string
            let fullRange = NSRange(location: 0, length: (string as NSString).length)

            storage.beginEditing()
            storage.setAttributes(
                [.font: SQLTextView.editorFont, .foregroundColor: NSColor.labelColor],
                range: fullRange
            )
            for match in SQLTextView.keywordRegex.matches(in: string, range: fullRange) {
                storage.addAttributes(
                    [.foregroundColor: SQLTextView.keywordColor, .font: SQLTextView.editorBoldFont],
                    range: match.range
                )
            }
            for match in SQLTextView.stringLiteralRegex.matches(in: string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: SQLTextView.stringLiteralColor, range: match.range)
            }
            for match in SQLTextView.commentRegex.matches(in: string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: SQLTextView.commentColor, range: match.range)
            }
            storage.endEditing()

            // `highlight` runs after every text mutation (typing and
            // programmatic), so it doubles as the "line count may have
            // changed" hook for the gutter.
            rulerView?.needsDisplay = true
        }
    }
}

/// Line-number gutter for the SQL editor. `NSRulerView` already tracks the
/// client view's scrolling; this only has to draw the right number next to
/// each line's first fragment.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// The line clicked when a gutter drag started — dragging selects from
    /// here to wherever the pointer is now, in either direction.
    private var dragAnchorLineRange: NSRange?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Click-to-select-line

    /// Clicking a line number selects that whole line; dragging up or down
    /// extends the selection over the lines in between — the gutter
    /// behavior of every code editor. The selection goes through the text
    /// view itself, so `textViewDidChangeSelection` picks it up and ⌘↩ then
    /// runs exactly the selected lines.
    override func mouseDown(with event: NSEvent) {
        guard let textView, let range = lineRange(at: event) else { return }
        dragAnchorLineRange = range
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let textView, let anchor = dragAnchorLineRange, let range = lineRange(at: event) else { return }
        let union = NSUnionRange(anchor, range)
        textView.setSelectedRange(union)
        // Keeps dragging past the top/bottom edge scrolling the document
        // rather than stopping at whatever was already visible.
        textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorLineRange = nil
    }

    /// The character range of the whole line under a gutter event, `nil`
    /// when the geometry isn't available yet.
    private func lineRange(at event: NSEvent) -> NSRange? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }

        let pointInRuler = convert(event.locationInWindow, from: nil)
        let pointInTextView = convert(pointInRuler, to: textView)
        // Glyph lookup wants text-container coordinates, which the text
        // view's inset is offset from.
        let containerPoint = NSPoint(
            x: 0,
            y: pointInTextView.y - textView.textContainerInset.height
        )

        let content = textView.string as NSString
        guard content.length > 0 else { return NSRange(location: 0, length: 0) }

        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return content.lineRange(for: NSRange(location: min(characterIndex, content.length - 1), length: 0))
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.gridLineColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // Converting from the text view's coordinates bakes in the scroll
        // offset, so numbers stay glued to their lines while scrolling.
        let textViewOriginInRuler = convert(NSPoint.zero, from: textView).y
        let insetHeight = textView.textContainerInset.height

        func drawNumber(_ lineNumber: Int, atLineTop lineTop: CGFloat, lineHeight: CGFloat) {
            let label = NSAttributedString(string: String(lineNumber), attributes: attributes)
            let size = label.size()
            let y = lineTop + insetHeight + textViewOriginInRuler + (lineHeight - size.height) / 2
            guard y + size.height >= 0, y <= bounds.maxY else { return }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 5, y: y))
        }

        let content = textView.string as NSString
        var lineNumber = 1
        var characterIndex = 0
        while characterIndex < content.length {
            let lineRange = content.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let firstFragmentHeight = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil).height
            drawNumber(lineNumber, atLineTop: lineRect.minY, lineHeight: firstFragmentHeight)
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // The "extra line fragment" is the caret line after a trailing
        // newline — and the only line at all in an empty document.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let extraRect = layoutManager.extraLineFragmentRect
            drawNumber(lineNumber, atLineTop: extraRect.minY, lineHeight: extraRect.height)
        }
    }
}
