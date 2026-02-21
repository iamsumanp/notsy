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

    private static func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }

    private func normalizedTypingAttributes(base: [NSAttributedString.Key: Any]? = nil) -> [NSAttributedString.Key: Any] {
        var attrs = base ?? typingAttributes
        attrs[.foregroundColor] = NSColor.white
        if attrs[.font] == nil {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular)
        }
        if attrs[.paragraphStyle] == nil {
            attrs[.paragraphStyle] = Self.defaultParagraphStyle()
        }
        return attrs
    }

    private func applyPaste(text: String) {
        let attrs = normalizedTypingAttributes()
        let insertion = NSAttributedString(string: text, attributes: attrs)
        textStorage?.replaceCharacters(in: selectedRange(), with: insertion)
        let cursor = selectedRange().location + insertion.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = attrs
        didChangeText()
    }

    override func paste(_ sender: Any?) {
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
                            textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: circleLocation + 1, length: 1))
                        }
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    self.typingAttributes[.foregroundColor] = NSColor.white
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator { delegate.saveState() }
                    return
                } else if trimmed.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "○", attributes: [
                        .font: NSFont.systemFont(ofSize: Self.editorFontSize),
                        .foregroundColor: NSColor.white
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: whiteCircle)
                        if circleLocation + 1 < textStorage.length {
                            textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: circleLocation + 1, length: 1))
                        }
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    self.typingAttributes[.foregroundColor] = NSColor.white
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator { delegate.saveState() }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        normalizeImageAttachmentsIfNeeded()
        refreshDetectedLinks()
        super.didChangeText()
    }

    func refreshDetectedLinks() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.link, range: fullRange)

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let text = textStorage.string
        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            textStorage.addAttribute(.link, value: url, range: match.range)
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
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.usesFontPanel = true
        textView.usesRuler = true

        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 4
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize, weight: .regular),
            .foregroundColor: NSColor.white,
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
        textView.refreshDetectedLinks()
        textView.normalizeImageAttachmentsIfNeeded()
        context.coordinator.currentNoteID = note.id

        return scrollView
    }

    func updateNSView(_ nsView: EditorScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // ALWAYS update the parent reference so text changes apply to the active Note!
        context.coordinator.parent = self

        if context.coordinator.currentNoteID != note.id {
            context.coordinator.isUpdating = true
            context.coordinator.currentNoteID = note.id

            textView.textStorage?.setAttributedString(note.stringRepresentation)
            if let customTextView = textView as? CustomTextView {
                customTextView.refreshDetectedLinks()
                customTextView.normalizeImageAttachmentsIfNeeded()
            }

            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: length, length: 0))

            context.coordinator.updateFormattingState(for: textView)
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorView
        var currentNoteID: UUID?
        var isUpdating = false
        weak var textView: NSTextView?

        init(_ parent: RichTextEditorView) { 
            self.parent = parent 
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleToolbarAction(_:)), name: NSNotification.Name("NotsyToolbarAction"), object: nil)
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

        private func applyTextColor(_ color: NSColor) {
            guard let textView = self.textView else { return }
            let selected = textView.selectedRange()
            if selected.length > 0 {
                textView.textStorage?.addAttribute(.foregroundColor, value: color, range: selected)
            }
            textView.typingAttributes[.foregroundColor] = color
            saveState()
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
                textView.typingAttributes[.foregroundColor] = NSColor.white
            }
            
            textView.undoManager?.endUndoGrouping()
            saveState()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            // Prevent checked-checkbox green from leaking into newly typed text.
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = NSColor.white
            }
            parent.note.update(with: textView.attributedString())
            var didAutoUpdateTitle = false
            if parent.note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let firstLine = parent.note.plainTextCache
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? ""
                if !firstLine.isEmpty {
                    parent.store.updateTitle(noteID: parent.note.id, title: String(firstLine.prefix(120)))
                    didAutoUpdateTitle = true
                }
            }
            if !didAutoUpdateTitle {
                parent.store.saveNoteChanges(noteID: parent.note.id)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateFormattingState(for: textView)
        }
        
        func updateFormattingState(for textView: NSTextView) {
            // Aggressively prevent green text inheritance when moving cursor
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = NSColor.white
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
                        textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: newCursor.location - 2, length: 1))
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
