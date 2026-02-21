import AppKit
import SwiftUI

class EditorScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let docView = documentView { return window?.makeFirstResponder(docView) ?? true }
        return super.becomeFirstResponder()
    }
}

class CustomTextView: NSTextView {
    static let editorFontSize: CGFloat = 15
    private static let imageThumbnailWidth: CGFloat = 56
    private static let imageThumbnailMaxHeight: CGFloat = 34
    private var isNormalizingAttachments = false
    private var isNormalizingListParagraphStyles = false

    private static func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }

    private func normalizedTypingAttributes(base: [NSAttributedString.Key: Any]? = nil) -> [NSAttributedString.Key: Any] {
        var attrs = base ?? typingAttributes
        attrs[.foregroundColor] = Theme.editorTextNSColor
        if attrs[.font] == nil {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular)
        }
        if attrs[.paragraphStyle] == nil {
            attrs[.paragraphStyle] = Self.defaultParagraphStyle()
        }
        return attrs
    }

    private func applyPaste(text: String) {
        let selection = selectedRange()
        let attrs = normalizedTypingAttributes()
        let insertion = NSAttributedString(string: text, attributes: attrs)
        textStorage?.replaceCharacters(in: selection, with: insertion)
        let cursor = selection.location + insertion.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = attrs
        didChangeText()
    }

    private func applyPaste(attributed attributedText: NSAttributedString) {
        let selection = selectedRange()
        let normalized = normalizePastedAttributedText(attributedText)
        textStorage?.replaceCharacters(in: selection, with: normalized)
        let cursor = selection.location + normalized.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = normalizedTypingAttributes()
        didChangeText()
    }

    private func normalizePastedAttributedText(_ value: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: value)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            var normalized = attrs

            // Drop source background highlights so paste matches editor surface.
            normalized.removeValue(forKey: .backgroundColor)

            if attrs[.attachment] == nil {
                let sourceFont = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: Self.editorFontSize)
                normalized[.font] = monospacedFontPreservingTraits(from: sourceFont)
                normalized[.foregroundColor] = Theme.editorTextNSColor
            }

            let paragraph = ((attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            normalized[.paragraphStyle] = paragraph

            mutable.setAttributes(normalized, range: range)
        }

        return mutable
    }

    private func monospacedFontPreservingTraits(from font: NSFont) -> NSFont {
        var result = NSFont.monospacedSystemFont(ofSize: max(1, font.pointSize), weight: .regular)
        let traits = font.fontDescriptor.symbolicTraits

        if traits.contains(.bold),
           let converted = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) as NSFont? {
            result = converted
        }
        if traits.contains(.italic),
           let converted = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) as NSFont? {
            result = converted
        }
        return result
    }

    func resetTypingAttributesForCurrentSelection() {
        guard let textStorage else {
            typingAttributes = normalizedTypingAttributes()
            return
        }

        guard textStorage.length > 0 else {
            typingAttributes = normalizedTypingAttributes()
            return
        }

        let cursor = max(0, min(selectedRange().location, textStorage.length - 1))
        let attrs = textStorage.attributes(at: cursor, effectiveRange: nil)
        typingAttributes = normalizedTypingAttributes(base: attrs)
    }

    func applyThemeTextColorTransition(from oldColor: NSColor?, to newColor: NSColor) {
        guard let textStorage else {
            typingAttributes[.foregroundColor] = newColor
            insertionPointColor = newColor
            return
        }
        guard let oldColor else {
            typingAttributes[.foregroundColor] = newColor
            insertionPointColor = newColor
            return
        }

        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let current = value as? NSColor else { return }
            if self.shouldAutoThemeRecolor(current: current, oldThemeColor: oldColor) {
                textStorage.addAttribute(.foregroundColor, value: newColor, range: range)
            }
        }
        typingAttributes[.foregroundColor] = newColor
        insertionPointColor = newColor
    }

    private func areColorsEquivalent(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let l = lhs.usingColorSpace(.deviceRGB), let r = rhs.usingColorSpace(.deviceRGB) else { return false }
        let tolerance: CGFloat = 0.02
        return abs(l.redComponent - r.redComponent) <= tolerance &&
               abs(l.greenComponent - r.greenComponent) <= tolerance &&
               abs(l.blueComponent - r.blueComponent) <= tolerance &&
               abs(l.alphaComponent - r.alphaComponent) <= tolerance
    }

    private func shouldAutoThemeRecolor(current: NSColor, oldThemeColor: NSColor) -> Bool {
        if areColorsEquivalent(current, oldThemeColor) {
            return true
        }
        // Legacy default before themes was pure white; convert it during theme changes too.
        if areColorsEquivalent(current, .white) {
            return true
        }
        return false
    }

    override func paste(_ sender: Any?) {
        if let attributed = NSPasteboard.general.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString,
           attributed.length > 0 {
            applyPaste(attributed: attributed)
            return
        }
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else {
            super.paste(sender)
            return
        }
        applyPaste(text: pasted)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else { return }
        applyPaste(text: pasted)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteAsPlainText(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Make list indent/outdent deterministic for Tab/Shift+Tab regardless of command routing.
        if event.keyCode == 48, handleListTab(outdent: event.modifierFlags.contains(.shift)) {
            return
        }
        // Backspace on nested list markers should outdent one level.
        if event.keyCode == 51, handleListBackspace() {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let clickedIndex = self.characterIndexForInsertion(at: point)
        if let ns = textStorage, clickedIndex >= 0, clickedIndex < ns.length,
           let linkValue = ns.attribute(.link, at: clickedIndex, effectiveRange: nil) {
            if let url = linkValue as? URL {
                NSWorkspace.shared.open(url)
                return
            } else if let linkString = linkValue as? String, let url = URL(string: linkString) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        if let attachmentIndex = attachmentCharacterIndex(at: point), handleImageTap(at: attachmentIndex) {
            // Keep insertion point out of oversized attachment line.
            setSelectedRange(NSRange(location: min((string as NSString).length, attachmentIndex + 1), length: 0))
            if let delegate = self.delegate as? RichTextEditorView.Coordinator { delegate.saveState() }
            return
        }

        let characterIndex = self.characterIndexForInsertion(at: point)
        
        let text = self.string as NSString
        if characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineString = text.substring(with: lineRange)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)
            let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
            
            // Check if click happened directly on the circle
            let circleLocation = lineRange.location + leadingWhitespace.utf16.count
            if characterIndex == circleLocation || characterIndex == circleLocation + 1 {
                if trimmed.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    let greenDot = NSAttributedString(string: "◉", attributes: [
                        .font: NSFont.systemFont(ofSize: Self.editorFontSize),
                        .foregroundColor: NSColor.systemGreen
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: greenDot)
                        // Force the space immediately after the dot to be white so typing inherits white
                        if circleLocation + 1 < textStorage.length {
                            textStorage.addAttribute(.foregroundColor, value: Theme.editorTextNSColor, range: NSRange(location: circleLocation + 1, length: 1))
                        }
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    self.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator { delegate.saveState() }
                    return
                } else if trimmed.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "○", attributes: [
                        .font: NSFont.systemFont(ofSize: Self.editorFontSize),
                        .foregroundColor: Theme.editorTextNSColor
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: whiteCircle)
                        if circleLocation + 1 < textStorage.length {
                            textStorage.addAttribute(.foregroundColor, value: Theme.editorTextNSColor, range: NSRange(location: circleLocation + 1, length: 1))
                        }
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    self.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator { delegate.saveState() }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        normalizeListParagraphStylesIfNeeded()
        normalizeImageAttachmentsIfNeeded()
        refreshDetectedLinks()
        super.didChangeText()
    }

    func normalizeListParagraphStylesIfNeeded() {
        guard !isNormalizingListParagraphStyles else { return }
        guard let textStorage, textStorage.length > 0 else { return }

        isNormalizingListParagraphStyles = true
        defer { isNormalizingListParagraphStyles = false }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            guard let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            guard !paragraph.textLists.isEmpty else { return }
            paragraph.textLists = []
            textStorage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }

    func refreshDetectedLinks() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let text = textStorage.string
        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            // Preserve custom anchor links; only auto-apply where no link exists yet.
            let hasLink = textStorage.attribute(.link, at: match.range.location, effectiveRange: nil) != nil
            if !hasLink {
                textStorage.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    func normalizeImageAttachmentsIfNeeded() {
        guard !isNormalizingAttachments else { return }
        guard let textStorage else { return }
        isNormalizingAttachments = true
        defer { isNormalizingAttachments = false }

        let wholeRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: wholeRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            self.applyImageSize(to: attachment, range: range, targetWidth: Self.imageThumbnailWidth, preserveExpanded: false)
        }
    }

    private func handleImageTap(at characterIndex: Int) -> Bool {
        guard let textStorage,
              characterIndex >= 0,
              characterIndex < textStorage.length,
              let attachment = textStorage.attribute(.attachment, at: characterIndex, effectiveRange: nil) as? NSTextAttachment else {
            return false
        }

        let image = attachment.image ?? decodedImage(from: attachment)
        if let image {
            NotificationCenter.default.post(
                name: NSNotification.Name("NotsyPreviewImage"),
                object: nil,
                userInfo: ["image": image]
            )
        }
        return true
    }

    private func attachmentCharacterIndex(at pointInView: NSPoint) -> Int? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let insertionIndex = characterIndexForInsertion(at: pointInView)
        let candidates = [insertionIndex, insertionIndex - 1, insertionIndex + 1]
            .filter { $0 >= 0 && $0 < textStorage.length }

        for idx in candidates {
            guard textStorage.attribute(.attachment, at: idx, effectiveRange: nil) is NSTextAttachment else { continue }
            if let rect = attachmentRect(for: idx),
               rect.insetBy(dx: -6, dy: -6).contains(pointInView) {
                return idx
            }
        }
        return nil
    }

    private func attachmentRect(for characterIndex: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let charRange = NSRange(location: characterIndex, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    private func applyImageSize(to attachment: NSTextAttachment, range: NSRange, targetWidth: CGFloat, preserveExpanded: Bool) {
        let maxWidth = min(targetWidth, availableImageWidth())
        guard maxWidth > 0 else { return }

        if preserveExpanded, attachment.bounds.width > Self.imageThumbnailWidth + 2 {
            return
        }

        if attachment.image == nil, let decoded = decodedImage(from: attachment) {
            attachment.image = decoded
        }

        let imageSize = attachment.image?.size ?? attachment.attachmentCell?.cellSize() ?? .zero
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let widthScale = maxWidth / imageSize.width
        let heightScale = Self.imageThumbnailMaxHeight / imageSize.height
        let scale = min(1.0, widthScale, heightScale)
        let newSize = NSSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
        attachment.bounds = NSRect(origin: .zero, size: newSize)

        // Refresh layout for the single attachment run.
        textStorage?.edited([.editedAttributes], range: range, changeInLength: 0)
    }

    private func availableImageWidth() -> CGFloat {
        let inset = textContainerInset.width * 2
        return max(120, bounds.width - inset - 24)
    }

    private func decodedImage(from attachment: NSTextAttachment) -> NSImage? {
        if let data = attachment.fileWrapper?.regularFileContents {
            return NSImage(data: data)
        }
        return nil
    }

    private func handleListTab(outdent: Bool) -> Bool {
        let selected = selectedRange()
        guard selected.length == 0 else { return false }

        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let probeLocation = max(0, min(selected.location, ns.length) - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probeLocation, length: 0))
        let lineString = ns.substring(with: lineRange)
        let leadingStripped = String(lineString.drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .newlines)
        guard leadingStripped.hasPrefix("•") || leadingStripped.hasPrefix("○") || leadingStripped.hasPrefix("◉") || leadingStripped.hasPrefix("-") else { return false }

        if outdent {
            if lineString.hasPrefix("\t") {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: 1))
            } else if lineString.hasPrefix("    ") {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: 4))
            } else {
                return false
            }
        } else {
            insertText("\t", replacementRange: NSRange(location: lineRange.location, length: 0))
        }

        if let delegate = self.delegate as? RichTextEditorView.Coordinator {
            delegate.saveState()
        }
        return true
    }

    private func handleListBackspace() -> Bool {
        let selected = selectedRange()
        guard selected.length == 0 else { return false }

        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let probeLocation = max(0, min(selected.location, ns.length) - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probeLocation, length: 0))
        let lineString = ns.substring(with: lineRange)
        let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
        let leadingStripped = String(lineString.drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .newlines)

        guard !leadingWhitespace.isEmpty else { return false }
        guard leadingStripped.hasPrefix("•") || leadingStripped.hasPrefix("○") || leadingStripped.hasPrefix("◉") || leadingStripped.hasPrefix("-") else { return false }

        let markerStart = lineRange.location + leadingWhitespace.utf16.count
        let markerEnd = markerStart + 2
        let cursor = selected.location
        if cursor > markerEnd { return false }

        let outdentLength: Int
        if leadingWhitespace.hasSuffix("\t") {
            outdentLength = 1
        } else if leadingWhitespace.hasSuffix("    ") {
            outdentLength = 4
        } else {
            outdentLength = 1
        }
        insertText("", replacementRange: NSRange(location: markerStart - outdentLength, length: outdentLength))
        if let delegate = self.delegate as? RichTextEditorView.Coordinator {
            delegate.saveState()
        }
        return true
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caretRect = rect
        caretRect.size.width = 1

        let font = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: Self.editorFontSize)
        let normalHeight = ceil(font.ascender - font.descender + font.leading)

        // When cursor sits on an attachment line, AppKit can report a very tall caret rect.
        // Clamp it to a normal text line height so typing next to images feels natural.
        if caretRect.height > normalHeight * 1.8 {
            caretRect.origin.y = caretRect.maxY - normalHeight - 2
            caretRect.size.height = normalHeight
        }

        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
    }
}

struct RichTextEditorView: NSViewRepresentable {
    var note: Note
    var store: NoteStore
    @Binding var editorState: EditorState
    var themeVariantRaw: String

    private var themeEditorTextColor: NSColor {
        Theme.palette(for: NotsyThemeVariant(rawValue: themeVariantRaw) ?? .bluish).editorText
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorScrollView {
        let textView = CustomTextView(usingTextLayoutManager: false) 
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: Int.max, height: Int.max)
        textView.textContainerInset = NSSize(width: 8, height: 16)

        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.insertionPointColor = themeEditorTextColor
        textView.drawsBackground = false
        textView.usesFontPanel = true
        textView.usesRuler = true

        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 4
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular),
            .foregroundColor: themeEditorTextColor,
            .paragraphStyle: defaultStyle
        ]

        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(note.stringRepresentation)
        textView.normalizeListParagraphStylesIfNeeded()
        textView.refreshDetectedLinks()
        textView.normalizeImageAttachmentsIfNeeded()
        textView.resetTypingAttributesForCurrentSelection()
        context.coordinator.lastAppliedEditorTextColor = themeEditorTextColor
        context.coordinator.currentNoteID = note.id

        return scrollView
    }

    func updateNSView(_ nsView: EditorScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // ALWAYS update the parent reference so text changes apply to the active Note!
        context.coordinator.parent = self
        if let customTextView = textView as? CustomTextView {
            let newThemeTextColor = themeEditorTextColor
            customTextView.applyThemeTextColorTransition(from: context.coordinator.lastAppliedEditorTextColor, to: newThemeTextColor)
            context.coordinator.lastAppliedEditorTextColor = newThemeTextColor
        }

        if context.coordinator.currentNoteID != note.id {
            context.coordinator.isUpdating = true
            context.coordinator.currentNoteID = note.id

            textView.textStorage?.setAttributedString(note.stringRepresentation)
            if let customTextView = textView as? CustomTextView {
                customTextView.normalizeListParagraphStylesIfNeeded()
                customTextView.refreshDetectedLinks()
                customTextView.normalizeImageAttachmentsIfNeeded()
            }

            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: length, length: 0))
            if let customTextView = textView as? CustomTextView {
                customTextView.resetTypingAttributesForCurrentSelection()
            }

            context.coordinator.updateFormattingState(for: textView)
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorView
        var currentNoteID: UUID?
        var isUpdating = false
        weak var textView: NSTextView?
        var lastAppliedEditorTextColor: NSColor = Theme.editorTextNSColor
        private var findQuery: String = ""
        private var findMatches: [NSRange] = []
        private var currentFindIndex: Int = -1

        init(_ parent: RichTextEditorView) { 
            self.parent = parent 
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleToolbarAction(_:)), name: NSNotification.Name("NotsyToolbarAction"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleEditorFindAction(_:)), name: NSNotification.Name("NotsyEditorFindAction"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleApplyLinkEditor(_:)), name: NSNotification.Name("NotsyApplyLinkEditor"), object: nil)
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func handleToolbarAction(_ notification: Notification) {
            guard let action = notification.userInfo?["action"] as? String,
                  let textView = self.textView,
                  textView.window?.isKeyWindow == true else { return }
            
            textView.window?.makeFirstResponder(textView)
            
            if action == "bold" {
                let sender = NSMenuItem()
                if self.parent.editorState.isBold {
                    sender.tag = Int(NSFontTraitMask.unboldFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                } else {
                    sender.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                }
                saveState()
            } else if action == "italic" {
                let sender = NSMenuItem()
                if self.parent.editorState.isItalic {
                    sender.tag = Int(NSFontTraitMask.unitalicFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                } else {
                    sender.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                }
                saveState()
            } else if action == "underline" {
                textView.underline(nil)
                saveState()
            } else if action == "strikethrough" {
                toggleStrikethrough()
            } else if action == "list" {
                toggleList(isCheckbox: false)
            } else if action == "checkbox" {
                toggleList(isCheckbox: true)
            } else if action == "font-sans" {
                applyFontStyle(.sans)
            } else if action == "font-serif" {
                applyFontStyle(.serif)
            } else if action == "font-mono" {
                applyFontStyle(.mono)
            } else if action == "font-size-down" {
                applyFontSize(delta: -1)
            } else if action == "font-size-up" {
                applyFontSize(delta: 1)
            } else if action == "font-size-default" {
                applyFontSize(defaultSize: CustomTextView.editorFontSize)
            } else if action == "link" {
                openLinkEditor()
            } else if action == "color-white" {
                applyTextColor(.white)
            } else if action == "color-yellow" {
                applyTextColor(.systemYellow)
            } else if action == "color-blue" {
                applyTextColor(.systemBlue)
            } else if action == "color-green" {
                applyTextColor(.systemGreen)
            } else if action == "color-custom" {
                if let color = notification.userInfo?["nsColor"] as? NSColor {
                    applyTextColor(color)
                }
            }
        }

        @objc func handleEditorFindAction(_ notification: Notification) {
            guard let action = notification.userInfo?["action"] as? String else { return }
            switch action {
            case "update":
                let query = (notification.userInfo?["query"] as? String) ?? ""
                updateFindQuery(query)
            case "next":
                findNext()
            case "prev":
                findPrevious()
            case "close":
                clearFindHighlights()
                findQuery = ""
                findMatches = []
                currentFindIndex = -1
            default:
                break
            }
        }

        @objc func handleApplyLinkEditor(_ notification: Notification) {
            guard let textView = self.textView,
                  textView.window?.isKeyWindow == true else { return }
            let text = (notification.userInfo?["text"] as? String) ?? ""
            let url = (notification.userInfo?["url"] as? String) ?? ""
            applyHyperlink(text: text, url: url)
        }

        private func updateFindQuery(_ query: String) {
            guard let textView = self.textView else { return }
            findQuery = query
            clearFindHighlights()
            findMatches = []
            currentFindIndex = -1

            guard !query.isEmpty else { return }

            let nsText = textView.string as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound || found.length == 0 { break }
                findMatches.append(found)
                let nextLocation = found.location + found.length
                searchRange = NSRange(location: nextLocation, length: max(0, nsText.length - nextLocation))
            }

            applyFindHighlights()
            if !findMatches.isEmpty {
                currentFindIndex = 0
                revealCurrentFindMatch()
            }
        }

        private func findNext() {
            guard !findMatches.isEmpty else { return }
            currentFindIndex = (currentFindIndex + 1) % findMatches.count
            revealCurrentFindMatch()
        }

        private func findPrevious() {
            guard !findMatches.isEmpty else { return }
            currentFindIndex = (currentFindIndex - 1 + findMatches.count) % findMatches.count
            revealCurrentFindMatch()
        }

        private func applyFindHighlights() {
            guard let textView = self.textView,
                  let layoutManager = textView.layoutManager else { return }
            for range in findMatches {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.18), forCharacterRange: range)
            }
        }

        private func revealCurrentFindMatch() {
            guard let textView = self.textView,
                  let layoutManager = textView.layoutManager,
                  currentFindIndex >= 0,
                  currentFindIndex < findMatches.count else { return }

            applyFindHighlights()
            let range = findMatches[currentFindIndex]
            layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }

        private func clearFindHighlights() {
            guard let textView = self.textView,
                  let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        }

        private func applyTextColor(_ color: NSColor) {
            guard let textView = self.textView else { return }
            let selected = textView.selectedRange()
            if selected.length > 0 {
                textView.textStorage?.addAttribute(.foregroundColor, value: color, range: selected)
            }
            textView.typingAttributes[.foregroundColor] = color
            saveState()
        }

        private func openLinkEditor() {
            guard let textView = self.textView else { return }

            let selected = textView.selectedRange()
            let nsText = textView.string as NSString
            let selectedText: String = {
                guard selected.length > 0,
                      selected.location + selected.length <= nsText.length else { return "" }
                return nsText.substring(with: selected)
            }()
            let existingLink: String = {
                guard selected.location < nsText.length,
                      let value = textView.textStorage?.attribute(.link, at: selected.location, effectiveRange: nil) else { return "" }
                if let url = value as? URL { return url.absoluteString }
                if let string = value as? String { return string }
                return ""
            }()

            NotificationCenter.default.post(
                name: NSNotification.Name("NotsyOpenLinkEditor"),
                object: nil,
                userInfo: ["text": selectedText, "url": existingLink]
            )
        }

        private func applyHyperlink(text: String, url: String) {
            guard let textView = self.textView,
                  let normalizedURL = normalizedURL(from: url) else { return }
            let selected = textView.selectedRange()
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if selected.length > 0 {
                if !trimmedText.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: (textView.typingAttributes[.font] as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular),
                        .foregroundColor: (textView.typingAttributes[.foregroundColor] as? NSColor) ?? Theme.editorTextNSColor,
                        .link: normalizedURL
                    ]
                    let attributed = NSAttributedString(string: trimmedText, attributes: attrs)
                    textView.textStorage?.replaceCharacters(in: selected, with: attributed)
                    textView.setSelectedRange(NSRange(location: selected.location + trimmedText.utf16.count, length: 0))
                } else {
                    textView.textStorage?.addAttribute(.link, value: normalizedURL, range: selected)
                }
            } else {
                let anchor = trimmedText.isEmpty ? anchorText(from: normalizedURL) : trimmedText
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: (textView.typingAttributes[.font] as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular),
                    .foregroundColor: (textView.typingAttributes[.foregroundColor] as? NSColor) ?? Theme.editorTextNSColor,
                    .link: normalizedURL
                ]
                let attributed = NSAttributedString(string: anchor, attributes: attrs)
                textView.textStorage?.replaceCharacters(in: selected, with: attributed)
                textView.setSelectedRange(NSRange(location: selected.location + anchor.utf16.count, length: 0))
            }

            saveState()
        }

        private func normalizedURL(from value: String) -> URL? {
            guard !value.isEmpty else { return nil }
            if let direct = URL(string: value), direct.scheme != nil {
                return direct
            }
            return URL(string: "https://\(value)")
        }

        private func anchorText(from url: URL) -> String {
            guard let host = url.host, !host.isEmpty else { return url.absoluteString }
            let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let parts = withoutWWW.split(separator: ".")
            if let first = parts.first, !first.isEmpty {
                return String(first)
            }
            return withoutWWW
        }

        private func toggleStrikethrough() {
            guard let textView = self.textView else { return }
            let selected = textView.selectedRange()
            let current = (textView.typingAttributes[.strikethroughStyle] as? Int ?? 0) > 0
            let newValue = current ? 0 : NSUnderlineStyle.single.rawValue

            if selected.length > 0 {
                textView.textStorage?.addAttribute(.strikethroughStyle, value: newValue, range: selected)
            }
            textView.typingAttributes[.strikethroughStyle] = newValue
            saveState()
        }

        private func applyFontStyle(_ style: EditorFontStyle) {
            guard let textView = self.textView else { return }
            let selected = textView.selectedRange()

            if selected.length > 0, let textStorage = textView.textStorage {
                textStorage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                    let current = (value as? NSFont) ?? (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                    textStorage.addAttribute(.font, value: self.font(for: style, basedOn: current), range: range)
                }
            } else {
                let current = (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                textView.typingAttributes[.font] = font(for: style, basedOn: current)
            }
            saveState()
        }

        private func font(for style: EditorFontStyle, basedOn current: NSFont) -> NSFont {
            let size = current.pointSize
            let traits = current.fontDescriptor.symbolicTraits
            let base: NSFont
            switch style {
            case .sans:
                base = NSFont.systemFont(ofSize: size)
            case .serif:
                base = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
            case .mono:
                base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }

            var updated = base
            if traits.contains(.bold), let bold = NSFontManager.shared.convert(updated, toHaveTrait: .boldFontMask) as NSFont? {
                updated = bold
            }
            if traits.contains(.italic), let italic = NSFontManager.shared.convert(updated, toHaveTrait: .italicFontMask) as NSFont? {
                updated = italic
            }
            return updated
        }

        private func applyFontSize(delta: CGFloat? = nil, defaultSize: CGFloat? = nil) {
            guard let textView = self.textView else { return }
            let selected = textView.selectedRange()

            func resized(_ font: NSFont) -> NSFont {
                let currentSize = font.pointSize
                let target = defaultSize ?? max(11, min(28, currentSize + (delta ?? 0)))
                return NSFont(descriptor: font.fontDescriptor, size: target) ?? font
            }

            if selected.length > 0, let textStorage = textView.textStorage {
                textStorage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                    let current = (value as? NSFont)
                        ?? (textView.typingAttributes[.font] as? NSFont)
                        ?? NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular)
                    textStorage.addAttribute(.font, value: resized(current), range: range)
                }
            } else {
                let current = (textView.typingAttributes[.font] as? NSFont)
                    ?? NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular)
                textView.typingAttributes[.font] = resized(current)
            }
            saveState()
        }
        
        func saveState() {
            guard let textView = self.textView else { return }
            updateFormattingState(for: textView)
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges(noteID: parent.note.id)
        }
        
        func toggleList(isCheckbox: Bool) {
            guard let textView = self.textView else { return }
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            
            var start = selectedRange.location
            let end = selectedRange.location + selectedRange.length
            var lineRanges: [NSRange] = []
            
            while start <= end {
                let range = text.lineRange(for: NSRange(location: start, length: 0))
                lineRanges.append(range)
                start = range.location + range.length
                if start >= text.length { break }
            }
            
            textView.undoManager?.beginUndoGrouping()
            
            let bulletStr = "• "
            let checkStr = "○ "
            let checkedStr = "◉ "
            
            for lineRange in lineRanges.reversed() {
                let lineString = text.substring(with: lineRange)
                let trimmed = lineString.trimmingCharacters(in: .whitespaces)
                let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
                
                if isCheckbox {
                    if trimmed.hasPrefix(checkStr) {
                        textView.insertText(checkedStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: checkStr.utf16.count))
                        textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: 1))
                    } else if trimmed.hasPrefix(checkedStr) {
                        textView.insertText("", replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: checkedStr.utf16.count))
                    } else if trimmed.hasPrefix(bulletStr) {
                        textView.insertText(checkStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: bulletStr.utf16.count))
                    } else {
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 { continue }
                        textView.insertText(checkStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: 0))
                    }
                } else {
                    if trimmed.hasPrefix(bulletStr) {
                        textView.insertText("", replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: bulletStr.utf16.count))
                    } else if trimmed.hasPrefix(checkStr) {
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: checkStr.utf16.count))
                    } else if trimmed.hasPrefix(checkedStr) {
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: checkedStr.utf16.count))
                    } else {
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 { continue }
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: 0))
                    }
                }
            }
            
            // Prevent checkbox marker green from becoming typing color.
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
            }
            
            textView.undoManager?.endUndoGrouping()
            saveState()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            // Prevent checked-checkbox green from leaking into newly typed text.
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
            }
            parent.note.update(with: textView.attributedString())
            if !findQuery.isEmpty {
                updateFindQuery(findQuery)
            }
            var didAutoUpdateTitle = false
            if parent.note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let hasContent = !parent.note.plainTextCache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasContent {
                    parent.store.updateTitle(noteID: parent.note.id, title: contentBasedTitle(from: parent.note.plainTextCache))
                    didAutoUpdateTitle = true
                }
            }
            if !didAutoUpdateTitle {
                parent.store.saveNoteChanges(noteID: parent.note.id)
            }
        }

        private func contentBasedTitle(from text: String) -> String {
            let lines = text.components(separatedBy: .newlines)

            for rawLine in lines {
                let cleaned = cleanedCandidateTitleLine(from: rawLine)
                guard !cleaned.isEmpty else { continue }
                guard cleaned.range(of: "[[:alnum:]]", options: .regularExpression) != nil else { continue }
                return truncateTitle(cleaned)
            }

            return "New Note"
        }

        private func cleanedCandidateTitleLine(from line: String) -> String {
            var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return "" }

            cleaned = cleaned.replacingOccurrences(
                of: #"^\s*(?:[-*•]+|\d+[.)]|[○◉]|#+)\s+"#,
                with: "",
                options: .regularExpression
            )
            cleaned = cleaned.replacingOccurrences(of: #"`+"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func truncateTitle(_ title: String, maxLength: Int = 52) -> String {
            guard title.count > maxLength else { return title }

            let prefix = String(title.prefix(maxLength))
            if let lastSpace = prefix.lastIndex(of: " ") {
                let wordBoundedLength = prefix.distance(from: prefix.startIndex, to: lastSpace)
                if wordBoundedLength >= 20 {
                    return String(prefix[..<lastSpace]) + "..."
                }
            }

            return prefix + "..."
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateFormattingState(for: textView)
        }
        
        func updateFormattingState(for textView: NSTextView) {
            // Aggressively prevent green text inheritance when moving cursor
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
            }
            
            var attrs: [NSAttributedString.Key: Any]
            if textView.selectedRange().length > 0 {
                attrs = textView.textStorage?.attributes(at: textView.selectedRange().location, effectiveRange: nil) ?? [:]
            } else {
                attrs = textView.typingAttributes
            }
            
            var isBold = false
            var isItalic = false
            var isUnderline = false
            var isStrikethrough = false
            var isBullet = false
            var isCheckbox = false
            var fontStyle: EditorFontStyle = .mono
            
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
                if traits.contains(.monoSpace) || font.fontName.lowercased().contains("mono") || font.fontName.lowercased().contains("menlo") {
                    fontStyle = .mono
                } else if font.familyName?.lowercased().contains("times") == true || font.fontName.lowercased().contains("serif") {
                    fontStyle = .serif
                } else {
                    fontStyle = .sans
                }
            }
            if let underlineStyle = attrs[.underlineStyle] as? Int, underlineStyle > 0 {
                isUnderline = true
            }
            if let strikeStyle = attrs[.strikethroughStyle] as? Int, strikeStyle > 0 {
                isStrikethrough = true
            }
            
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let location = min(selectedRange.location, max(0, text.length))
            if text.length > 0 {
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                let lineString = text.substring(with: lineRange)
                let trimmed = lineString.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("• ") { isBullet = true }
                else if trimmed.hasPrefix("○ ") || trimmed.hasPrefix("◉ ") { isCheckbox = true }
            }
            
            DispatchQueue.main.async {
                let newState = EditorState(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, isStrikethrough: isStrikethrough, isBullet: isBullet, isCheckbox: isCheckbox, fontStyle: fontStyle)
                if self.parent.editorState != newState {
                    self.parent.editorState = newState
                }
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }

            // Space near list marker indents list item one level (Notion-style).
            if replacement == " " {
                let text = textView.string as NSString
                let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
                let lineString = text.substring(with: lineRange)
                let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
                let markerColumn = leadingWhitespace.count
                let chars = Array(lineString)
                if chars.count >= markerColumn + 2 {
                    let marker = chars[markerColumn]
                    let markerSpacer = chars[markerColumn + 1]
                    let isListMarker = (marker == "•" || marker == "○" || marker == "◉") && markerSpacer == " "
                    if isListMarker {
                        let markerStart = lineRange.location + leadingWhitespace.utf16.count
                        let markerEnd = markerStart + 2
                        if affectedCharRange.location <= markerEnd {
                            textView.insertText("\t", replacementRange: NSRange(location: lineRange.location, length: 0))
                            saveState()
                            return false
                        }
                    }
                }
            }

            // Intercept Markdown "- " at start/indent and convert into "• " synchronously.
            if replacement == " " {
                let text = textView.string as NSString
                if affectedCharRange.location > 0 {
                    let prevCharIndex = affectedCharRange.location - 1
                    let prevChar = text.substring(with: NSRange(location: prevCharIndex, length: 1))

                    if prevChar == "-" {
                        let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
                        let prefixRange = NSRange(location: lineRange.location, length: max(0, prevCharIndex - lineRange.location))
                        let prefix = text.substring(with: prefixRange)
                        let isIndentedStart = prefix.allSatisfy { $0 == " " || $0 == "\t" }
                        if lineRange.location == prevCharIndex || isIndentedStart {
                            textView.undoManager?.beginUndoGrouping()
                            textView.insertText("• ", replacementRange: NSRange(location: prevCharIndex, length: 1))
                            textView.undoManager?.endUndoGrouping()
                            saveState()
                            return false
                        }
                    }
                }
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { return handleEnter(textView) }
            else if commandSelector == #selector(NSResponder.insertTab(_:)) { return handleTab(textView) }
            else if commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) { return handleTab(textView) }
            else if commandSelector == #selector(NSResponder.insertBacktab(_:)) { return handleShiftTab(textView) }
            else if commandSelector == #selector(NSResponder.deleteBackward(_:)) { return handleBackspace(textView) }
            return false
        }

        private func handleEnter(_ textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            if text.length == 0 { return false }
            
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            
            // Extract any leading whitespace (tabs or spaces) for sub-bullets
            var leadingWhitespace = ""
            for char in lineString {
                if char == " " || char == "\t" {
                    leadingWhitespace.append(char)
                } else {
                    break
                }
            }
            
            let trimmedLine = lineString.trimmingCharacters(in: .whitespaces)
            
            var prefixToContinue = ""
            if trimmedLine.hasPrefix("• ") { prefixToContinue = "• " }
            else if trimmedLine.hasPrefix("○ ") || trimmedLine.hasPrefix("◉ ") { prefixToContinue = "○ " }
            
            if !prefixToContinue.isEmpty {
                let textAfterPrefix = trimmedLine.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if textAfterPrefix.isEmpty {
                    // Empty list item -> Remove the list and outdent or exit
                    textView.undoManager?.beginUndoGrouping()
                    
                    if !leadingWhitespace.isEmpty {
                        // If it's a sub-bullet, just outdent it by removing the last tab/space
                        let newWhitespace = String(leadingWhitespace.dropLast())
                        textView.insertText("", replacementRange: lineRange)
                        textView.insertText(newWhitespace + prefixToContinue, replacementRange: NSRange(location: lineRange.location, length: 0))
                    } else {
                        // If it's a root bullet, remove it entirely and go to new line
                        let fullLineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
                        textView.insertText("", replacementRange: fullLineRange)
                        textView.insertText("\n", replacementRange: textView.selectedRange())
                    }
                    
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                } else {
                    // Continue the list automatically on the next line, preserving indent
                    textView.undoManager?.beginUndoGrouping()
                    textView.insertText("\n" + leadingWhitespace + prefixToContinue, replacementRange: textView.selectedRange())
                    
                    // If it's a green checked dot we need to make sure the newly inserted one is white
                    let newCursor = textView.selectedRange()
                    if prefixToContinue == "○ " {
                        textView.textStorage?.addAttribute(.foregroundColor, value: Theme.editorTextNSColor, range: NSRange(location: newCursor.location - 2, length: 1))
                    }
                    
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                }
            }
            
            return false
        }

        private func handleTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let probeLocation = max(0, min(selectedRange.location, text.length) - 1)
            let lineRange = text.lineRange(for: NSRange(location: probeLocation, length: 0))
            let lineString = text.substring(with: lineRange)
            let leadingStripped = String(lineString.drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .newlines)
            
            if leadingStripped.hasPrefix("•") || leadingStripped.hasPrefix("○") || leadingStripped.hasPrefix("◉") || leadingStripped.hasPrefix("-") {
                textView.insertText("\t", replacementRange: NSRange(location: lineRange.location, length: 0))
                saveState()
                return true
            }
            return false
        }

        private func handleShiftTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            
            if lineString.hasPrefix("\t") || lineString.hasPrefix("    ") {
                let outdentLength = lineString.hasPrefix("\t") ? 1 : 4
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: outdentLength))
                saveState()
                return true
            }
            return false
        }

        private func handleBackspace(_ textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return false }

            let text = textView.string as NSString
            guard text.length > 0 else { return false }

            let cursor = selectedRange.location
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineString = text.substring(with: lineRange)
            let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("• ") || trimmed.hasPrefix("○ ") || trimmed.hasPrefix("◉ ") else { return false }

            let markerStart = lineRange.location + leadingWhitespace.utf16.count
            let contentStart = markerStart + 2

            if cursor == contentStart && !leadingWhitespace.isEmpty {
                let outdentLength: Int
                if leadingWhitespace.hasSuffix("\t") {
                    outdentLength = 1
                } else if leadingWhitespace.hasSuffix("    ") {
                    outdentLength = 4
                } else {
                    outdentLength = 1
                }
                textView.insertText("", replacementRange: NSRange(location: markerStart - outdentLength, length: outdentLength))
                saveState()
                return true
            }

            return false
        }
    }
}
