import AppKit
import SwiftUI
import UniformTypeIdentifiers

class EditorScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let docView = documentView { return window?.makeFirstResponder(docView) ?? true }
        return super.becomeFirstResponder()
    }
}

class CustomTextView: NSTextView {
    fileprivate static let uncheckedCheckboxMarker = "☐ "
    fileprivate static let checkedCheckboxMarker = "☑ "
    fileprivate static let legacyCheckedCheckboxMarker = "✓ "

    static let editorFontSize: CGFloat = 15
    static let editorTextInset = NSSize(width: 8, height: 16)
    static let editorLineFragmentPadding: CGFloat = 5
    private static let defaultImageDisplayWidth: CGFloat = 260
    private static let minResizableImageWidth: CGFloat = 24
    private static let minResizableImageHeight: CGFloat = 12
    private static let resizeHandleVisualSize: CGFloat = 12
    private static let resizeHandleHitPadding: CGFloat = 4
    private static let resizeDragThreshold: CGFloat = 5
    private static let tableAddButtonSize: CGFloat = 20
    private static let tableRowResizeHitHeight: CGFloat = 4
    private static let minTableRowHeight: CGFloat = 18
    private static let diagonalResizeCursor: NSCursor = {
        if let symbol = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right.circle.fill",
            accessibilityDescription: nil
        ) {
            symbol.size = NSSize(width: 18, height: 18)
            return NSCursor(
                image: symbol,
                hotSpot: NSPoint(x: symbol.size.width / 2, y: symbol.size.height / 2)
            )
        }
        return .crosshair
    }()
    private static let fallbackTabInterval: CGFloat = 28
    static let bulletMarkers: [String] = ["• ", "◦ ", "∙ "]
    private static let codeDefaultForegroundColor = NSColor(
        calibratedRed: 212.0 / 255.0,
        green: 212.0 / 255.0,
        blue: 212.0 / 255.0,
        alpha: 1.0
    )
    private static let codeKeywordForegroundColor = NSColor(
        calibratedRed: 86.0 / 255.0,
        green: 156.0 / 255.0,
        blue: 214.0 / 255.0,
        alpha: 1.0
    )
    private static let codeStringForegroundColor = NSColor(
        calibratedRed: 206.0 / 255.0,
        green: 145.0 / 255.0,
        blue: 120.0 / 255.0,
        alpha: 1.0
    )
    private static let codeNumberForegroundColor = NSColor(
        calibratedRed: 181.0 / 255.0,
        green: 206.0 / 255.0,
        blue: 168.0 / 255.0,
        alpha: 1.0
    )
    private static let codeCommentForegroundColor = NSColor(
        calibratedRed: 106.0 / 255.0,
        green: 153.0 / 255.0,
        blue: 85.0 / 255.0,
        alpha: 1.0
    )
    private static let codeLanguageAttribute = NSAttributedString.Key("notsy.code.language")
    private static let codeTokenAttribute = NSAttributedString.Key("notsy.code.token")
    static let autoDetectedLinkAttribute = NSAttributedString.Key("notsy.link.auto")
    static let explicitLinkAttribute = NSAttributedString.Key("notsy.link.explicit")

    private var isNormalizingAttachments = false
    private var isNormalizingListParagraphStyles = false
    private var isNormalizingTableStructure = false
    private var pendingEditedRange: NSRange?
    private var imageTrackingArea: NSTrackingArea?
    private var hoveredAttachmentIndex: Int?
    private var resizeAttachmentIndex: Int?
    private var resizeStartPoint: NSPoint = .zero
    private var resizeStartSize: NSSize = .zero
    private var resizeStartAttachmentRect: NSRect = .zero
    private var resizeAspectRatio: CGFloat = 1
    private var didBeginResizeDrag = false
    private var hoveredTableAddButtonRect: NSRect?
    private var hoveredTableForAddButton: NSTextTable?
    private var hoveredTableRowResizeTarget: TableRowResizeTarget?
    private var tableRowResizeSession: TableRowResizeSession?

    private enum DetectedCodeLanguage: String {
        case swift
        case python
        case javascript
        case json
        case endpoint
    }

    private static func defaultParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }

    private func cleanDefaultTypingAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: Self.defaultParagraphStyle(),
            .underlineStyle: 0,
            .strikethroughStyle: 0
        ]
    }


    private func normalizedTypingAttributes(
        base: [NSAttributedString.Key: Any]? = nil,
        forceDefaultColor: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var attrs = base ?? typingAttributes
        // Never keep a link attribute in typing attrs; otherwise new typed text can inherit link style.
        attrs.removeValue(forKey: .link)
        attrs.removeValue(forKey: Self.autoDetectedLinkAttribute)
        attrs.removeValue(forKey: Self.explicitLinkAttribute)
        if forceDefaultColor {
            attrs[.foregroundColor] = Theme.editorTextNSColor
        } else if let color = attrs[.foregroundColor] as? NSColor {
            attrs[.foregroundColor] = areColorsEquivalent(color, .systemGreen)
                ? Theme.editorTextNSColor
                : color
        } else {
            attrs[.foregroundColor] = Theme.editorTextNSColor
        }
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
        let adjustedText = sanitizedListPasteIfNeeded(text, selection: selection)
        let insertion = NSAttributedString(string: adjustedText, attributes: attrs)
        textStorage?.replaceCharacters(in: selection, with: insertion)
        applyCodeHighlightingForEditedRange(
            NSRange(location: selection.location, length: insertion.length),
            preferredLanguage: detectCodeLanguage(in: adjustedText)
        )
        let cursor = selection.location + insertion.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = attrs
        didChangeText()
    }

    private func applyPaste(attributed attributedText: NSAttributedString) {
        let selection = selectedRange()
        let normalized = normalizePastedAttributedText(attributedText)
        let adjusted = sanitizedListPasteIfNeeded(normalized, selection: selection)
        textStorage?.replaceCharacters(in: selection, with: adjusted)
        applyCodeHighlightingForEditedRange(
            NSRange(location: selection.location, length: adjusted.length),
            preferredLanguage: detectCodeLanguage(in: adjusted.string)
        )
        let cursor = selection.location + adjusted.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = normalizedTypingAttributes()
        didChangeText()
    }

    private func sanitizedListPasteIfNeeded(_ text: String, selection: NSRange) -> String {
        guard shouldStripLeadingPastedListMarker(at: selection) else { return text }
        guard let removablePrefixLength = leadingPastedListMarkerPrefixLength(in: text) else { return text }
        let nsText = text as NSString
        guard removablePrefixLength > 0, removablePrefixLength <= nsText.length else { return text }
        return nsText.replacingCharacters(in: NSRange(location: 0, length: removablePrefixLength), with: "")
    }

    private func sanitizedListPasteIfNeeded(_ attributedText: NSAttributedString, selection: NSRange) -> NSAttributedString {
        guard shouldStripLeadingPastedListMarker(at: selection) else { return attributedText }
        guard let removablePrefixLength = leadingPastedListMarkerPrefixLength(in: attributedText.string) else {
            return attributedText
        }
        guard removablePrefixLength > 0, removablePrefixLength <= attributedText.length else { return attributedText }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        mutable.deleteCharacters(in: NSRange(location: 0, length: removablePrefixLength))
        return mutable
    }

    private func leadingPastedListMarkerPrefixLength(in text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let firstLine: String
        if let newlineRange = text.rangeOfCharacter(from: .newlines) {
            firstLine = String(text[..<newlineRange.lowerBound])
        } else {
            firstLine = text
        }

        let leadingWhitespace = String(firstLine.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedLeading = String(firstLine.dropFirst(leadingWhitespace.count))
        guard let marker = listMarkerPrefix(in: trimmedLeading) else { return nil }
        return leadingWhitespace.utf16.count + marker.utf16.count
    }

    private func shouldStripLeadingPastedListMarker(at selection: NSRange) -> Bool {
        guard let textStorage else { return false }
        let text = textStorage.string as NSString
        guard text.length > 0 else { return false }

        let insertionLocation = max(0, min(selection.location, text.length))
        if insertionLocation == text.length, text.length > 0 {
            let previous = text.character(at: text.length - 1)
            if previous == 10 || previous == 13 { return false }
        }

        let probeLocation = insertionLocation == text.length ? max(0, text.length - 1) : insertionLocation
        let lineRange = text.lineRange(for: NSRange(location: probeLocation, length: 0))
        let lineString = text.substring(with: lineRange)
        let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedLeading = String(lineString.dropFirst(leadingWhitespace.count))
        guard let marker = listMarkerPrefix(in: trimmedLeading) else { return false }

        let markerBoundary = lineRange.location + leadingWhitespace.utf16.count + marker.utf16.count
        return insertionLocation >= markerBoundary
    }

    private func applyPaste(image: NSImage) {
        let selection = selectedRange()
        let attachment = NSTextAttachment()
        attachment.image = image
        if let pngData = pngData(from: image) {
            let wrapper = FileWrapper(regularFileWithContents: pngData)
            wrapper.preferredFilename = "image.png"
            attachment.fileWrapper = wrapper
        }

        let attributed = NSAttributedString(attachment: attachment)
        textStorage?.replaceCharacters(in: selection, with: attributed)
        let attachmentRange = NSRange(location: selection.location, length: attributed.length)
        applyImageSize(
            to: attachment,
            range: attachmentRange,
            targetWidth: Self.defaultImageDisplayWidth
        )
        let cursor = selection.location + attributed.length
        setSelectedRange(NSRange(location: cursor, length: 0))
        typingAttributes = normalizedTypingAttributes()
        didChangeText()
    }

    func registerPendingEdit(affectedRange: NSRange, replacementString: String?) {
        let replacementLength = replacementString?.utf16.count ?? 0
        pendingEditedRange = NSRange(
            location: affectedRange.location,
            length: max(affectedRange.length, replacementLength, 1)
        )
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
                normalized[.font] = editorDefaultFontPreservingTraits(from: sourceFont)
                if let sourceColor = attrs[.foregroundColor] as? NSColor {
                    normalized[.foregroundColor] = areColorsEquivalent(sourceColor, .systemGreen)
                        ? Theme.editorTextNSColor
                        : sourceColor
                } else {
                    normalized[.foregroundColor] = Theme.editorTextNSColor
                }
            }

            let paragraph = ((attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            normalized[.paragraphStyle] = paragraph
            if normalized[.link] != nil {
                normalized[Self.explicitLinkAttribute] = true
                normalized.removeValue(forKey: Self.autoDetectedLinkAttribute)
            }

            mutable.setAttributes(normalized, range: range)
        }

        return mutable
    }

    private func editorDefaultFontPreservingTraits(from font: NSFont) -> NSFont {
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
            typingAttributes = cleanDefaultTypingAttributes(color: Theme.editorTextNSColor)
            return
        }

        guard textStorage.length > 0 else {
            typingAttributes = cleanDefaultTypingAttributes(color: Theme.editorTextNSColor)
            return
        }

        let selection = selectedRange()
        let useCurrentLocation = selection.length == 0
            && selection.location < textStorage.length
            && tableCursorLocation(at: selection.location) != nil
        let probeLocation = useCurrentLocation
            ? selection.location
            : (selection.location > 0 ? selection.location - 1 : selection.location)
        let cursor = max(0, min(probeLocation, textStorage.length - 1))
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
        if let typingColor = typingAttributes[.foregroundColor] as? NSColor {
            if shouldAutoThemeRecolor(current: typingColor, oldThemeColor: oldColor) {
                typingAttributes[.foregroundColor] = newColor
            }
        } else {
            typingAttributes[.foregroundColor] = newColor
        }
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

    private func pastedImageFromPasteboard(_ pasteboard: NSPasteboard) -> NSImage? {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return image
        }

        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) {
            return image
        }
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) {
            return image
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where url.isFileURL && isImageFileURL(url) {
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        return nil
    }

    private func isImageFileURL(_ url: URL) -> Bool {
        let extensionLowercased = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: extensionLowercased) {
            return type.conforms(to: .image)
        }
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp"].contains(
            extensionLowercased
        )
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    override func paste(_ sender: Any?) {
        if let pastedImage = pastedImageFromPasteboard(NSPasteboard.general) {
            applyPaste(image: pastedImage)
            return
        }
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
        if event.keyCode == 48, handleTableTabNavigation(outdent: event.modifierFlags.contains(.shift)) {
            return
        }
        if event.keyCode == 36, handleTableEnterInCell() {
            return
        }
        if event.keyCode == 51, handleTableBoundaryDelete(backward: true) {
            return
        }
        if event.keyCode == 117, handleTableBoundaryDelete(backward: false) {
            return
        }
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

    private func handleTableEnterInCell() -> Bool {
        guard let textStorage, textStorage.length > 0 else { return false }
        let selected = selectedRange()
        let probeLocation = min(max(0, selected.location), textStorage.length - 1)
        guard tableCursorLocation(at: probeLocation) != nil else { return false }

        // Keep Enter inside the same table cell.
        insertText("\u{2028}", replacementRange: selected)
        return true
    }

    private struct TableCursorLocation {
        let table: NSTextTable
        let tableBlock: NSTextTableBlock
        let row: Int
        let column: Int
        let paragraphRange: NSRange
    }

    private struct TableRowResizeTarget {
        let table: NSTextTable
        let row: Int
        let hitRect: NSRect
    }

    private struct TableRowResizeSession {
        let table: NSTextTable
        let row: Int
        let startPoint: NSPoint
        let initialMinimumLineHeight: CGFloat
    }

    private struct TableNormalizationParagraph {
        let table: NSTextTable
        let tableBlock: NSTextTableBlock
        let row: Int
        let column: Int
        let paragraphRange: NSRange
        let value: String
        let minimumLineHeight: CGFloat?
    }

    private struct TableNormalizationGroup {
        let table: NSTextTable
        var paragraphs: [TableNormalizationParagraph]
        var tableRange: NSRange
    }

    private struct TableNormalizationReplacement {
        let range: NSRange
        let attributed: NSAttributedString
        let preferredCaretLocation: Int?
    }

    private func handleTableTabNavigation(outdent: Bool) -> Bool {
        let selected = selectedRange()
        guard selected.length == 0 else { return false }
        guard let textStorage, textStorage.length > 0 else { return false }

        let probeLocation: Int
        if selected.location >= textStorage.length {
            probeLocation = max(0, textStorage.length - 1)
        } else {
            probeLocation = max(0, selected.location)
        }

        guard let current = tableCursorLocation(at: probeLocation) else { return false }
        let cells = tableCursorLocations(for: current.table)
        guard !cells.isEmpty else { return true }

        let currentIndex = cells.firstIndex(where: {
            $0.row == current.row
                && $0.column == current.column
                && $0.paragraphRange.location == current.paragraphRange.location
        }) ?? cells.firstIndex(where: { NSLocationInRange(probeLocation, $0.paragraphRange) })

        guard let index = currentIndex else { return true }
        if !outdent, index == cells.count - 1 {
            NotificationCenter.default.post(
                name: NSNotification.Name("NotsyToolbarAction"),
                object: nil,
                userInfo: ["action": "table-row-add"]
            )
            return true
        }
        let targetIndex: Int
        if outdent {
            targetIndex = index == 0 ? cells.count - 1 : index - 1
        } else {
            targetIndex = (index + 1) % cells.count
        }

        let target = cells[targetIndex]
        setSelectedRange(NSRange(location: target.paragraphRange.location, length: 0))
        scrollRangeToVisible(target.paragraphRange)
        return true
    }

    private func handleTableBoundaryDelete(backward: Bool) -> Bool {
        let selected = selectedRange()
        guard selected.length == 0 else { return false }
        guard let textStorage, textStorage.length > 0 else { return false }

        let caret = max(0, min(selected.location, textStorage.length))
        if backward, caret == 0 { return false }
        if !backward, caret >= textStorage.length { return false }

        let probeLocation = min(max(0, caret), textStorage.length - 1)
        guard let current = tableCursorLocation(at: probeLocation) else { return false }

        let cellStart = current.paragraphRange.location
        let cellEnd = max(cellStart, NSMaxRange(current.paragraphRange) - 1)
        let isBoundaryDelete = backward ? (caret == cellStart) : (caret >= cellEnd)
        guard isBoundaryDelete else { return false }

        let cells = tableCursorLocations(for: current.table)
        guard !cells.isEmpty else { return true }
        let currentIndex = cells.firstIndex(where: {
            $0.row == current.row
                && $0.column == current.column
                && $0.paragraphRange.location == current.paragraphRange.location
        }) ?? cells.firstIndex(where: { NSLocationInRange(probeLocation, $0.paragraphRange) })

        guard let index = currentIndex else { return true }
        let targetIndex: Int?
        if backward {
            targetIndex = index > 0 ? index - 1 : nil
        } else {
            targetIndex = index < cells.count - 1 ? index + 1 : nil
        }

        if let targetIndex {
            let target = cells[targetIndex]
            setSelectedRange(NSRange(location: target.paragraphRange.location, length: 0))
            scrollRangeToVisible(target.paragraphRange)
        }
        return true
    }

    private func tableCursorLocation(at location: Int) -> TableCursorLocation? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let text = textStorage.string as NSString
        let safeLocation = max(0, min(location, textStorage.length - 1))
        let paragraphRange = text.paragraphRange(for: NSRange(location: safeLocation, length: 0))
        let styleLocation = min(paragraphRange.location, textStorage.length - 1)
        guard let paragraph = textStorage.attribute(
            .paragraphStyle,
            at: styleLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle,
            let tableBlock = paragraph.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
        else {
            return nil
        }
        return TableCursorLocation(
            table: tableBlock.table,
            tableBlock: tableBlock,
            row: tableBlock.startingRow,
            column: tableBlock.startingColumn,
            paragraphRange: paragraphRange
        )
    }

    private func tableCursorLocations(for table: NSTextTable) -> [TableCursorLocation] {
        guard let textStorage, textStorage.length > 0 else { return [] }
        let text = textStorage.string as NSString
        var locations: [TableCursorLocation] = []
        var paragraphLocation = 0

        while paragraphLocation < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: paragraphLocation, length: 0))
            let styleLocation = min(paragraphRange.location, max(0, textStorage.length - 1))
            if let paragraph = textStorage.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil)
                as? NSParagraphStyle,
                let tableBlock = paragraph.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock,
                tableBlock.table === table {
                locations.append(
                    TableCursorLocation(
                        table: table,
                        tableBlock: tableBlock,
                        row: tableBlock.startingRow,
                        column: tableBlock.startingColumn,
                        paragraphRange: paragraphRange
                    )
                )
            }
            paragraphLocation = NSMaxRange(paragraphRange)
        }

        return locations.sorted {
            if $0.row != $1.row { return $0.row < $1.row }
            if $0.column != $1.column { return $0.column < $1.column }
            return $0.paragraphRange.location < $1.paragraphRange.location
        }
    }

    private func tableCellRect(for cell: TableCursorLocation) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: cell.paragraphRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.isEmpty {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: cell.paragraphRange.location)
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
        }
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    private func tableRect(for table: NSTextTable) -> NSRect? {
        let cells = tableCursorLocations(for: table)
        guard !cells.isEmpty else { return nil }
        var frame: NSRect?
        for cell in cells {
            guard let rect = tableCellRect(for: cell) else { continue }
            frame = frame == nil ? rect : frame!.union(rect)
        }
        return frame
    }

    private func tableCell(at point: NSPoint) -> TableCursorLocation? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        var tables: [NSTextTable] = []
        var seen = Set<ObjectIdentifier>()
        var paragraphLocation = 0
        let text = textStorage.string as NSString

        while paragraphLocation < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: paragraphLocation, length: 0))
            let styleLocation = min(paragraphRange.location, max(0, textStorage.length - 1))
            if let paragraph = textStorage.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil) as? NSParagraphStyle,
               let tableBlock = paragraph.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock {
                let id = ObjectIdentifier(tableBlock.table)
                if !seen.contains(id) {
                    seen.insert(id)
                    tables.append(tableBlock.table)
                }
            }
            paragraphLocation = NSMaxRange(paragraphRange)
        }

        for table in tables {
            for cell in tableCursorLocations(for: table) {
                guard let rect = tableCellRect(for: cell) else { continue }
                if rect.contains(point) {
                    return cell
                }
            }
        }
        return nil
    }

    private func insertionLocation(in cell: TableCursorLocation, at point: NSPoint) -> Int {
        guard let layoutManager, let textContainer, let textStorage else {
            return cell.paragraphRange.location
        }
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        var fraction: CGFloat = 0
        let rawIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )

        let start = cell.paragraphRange.location
        let end = max(start, NSMaxRange(cell.paragraphRange) - 1)
        let clamped = min(max(start, rawIndex), end)
        return min(clamped, max(0, textStorage.length))
    }

    private func tableAddButtonRect(for table: NSTextTable) -> NSRect? {
        guard let frame = tableRect(for: table) else { return nil }
        let size = Self.tableAddButtonSize
        let x = frame.minX - size - 6
        let y = isFlipped ? frame.maxY + 4 : frame.minY - size - 4
        return NSRect(x: x, y: y, width: size, height: size)
    }

    private func tableRowResizeTarget(at point: NSPoint, table: NSTextTable) -> TableRowResizeTarget? {
        let cells = tableCursorLocations(for: table)
        guard !cells.isEmpty else { return nil }

        let maxRow = cells.map { $0.row }.max() ?? 0
        for row in 0...maxRow {
            let rowCells = cells.filter { $0.row == row }
            guard !rowCells.isEmpty else { continue }

            var rowRect: NSRect?
            for cell in rowCells {
                guard let rect = tableCellRect(for: cell) else { continue }
                rowRect = rowRect == nil ? rect : rowRect!.union(rect)
            }
            guard let resolvedRowRect = rowRect else { continue }

            let boundaryY = isFlipped ? resolvedRowRect.maxY : resolvedRowRect.minY
            let hitRect = NSRect(
                x: resolvedRowRect.minX,
                y: boundaryY - Self.tableRowResizeHitHeight / 2,
                width: resolvedRowRect.width,
                height: Self.tableRowResizeHitHeight
            )
            if hitRect.contains(point) {
                return TableRowResizeTarget(table: table, row: row, hitRect: hitRect)
            }
        }
        return nil
    }

    private func currentMinimumLineHeight(for row: Int, in table: NSTextTable) -> CGFloat {
        let cells = tableCursorLocations(for: table).filter { $0.row == row }
        guard let first = cells.first else { return Self.minTableRowHeight }
        guard let textStorage, textStorage.length > 0 else { return Self.minTableRowHeight }
        let styleLocation = min(first.paragraphRange.location, textStorage.length - 1)
        let style = textStorage.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil) as? NSParagraphStyle
        if let minimum = style?.minimumLineHeight, minimum > 0 {
            return minimum
        }
        let font = (textStorage.attribute(.font, at: styleLocation, effectiveRange: nil) as? NSFont)
            ?? NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular)
        let natural = ceil(font.ascender - font.descender + font.leading) + 2
        return max(Self.minTableRowHeight, natural)
    }

    private func applyMinimumLineHeight(_ minimumHeight: CGFloat, for row: Int, in table: NSTextTable) {
        guard let textStorage else { return }
        let cells = tableCursorLocations(for: table).filter { $0.row == row }
        guard !cells.isEmpty else { return }

        for cell in cells {
            let styleLocation = min(cell.paragraphRange.location, max(0, textStorage.length - 1))
            let existing = textStorage.attribute(.paragraphStyle, at: styleLocation, effectiveRange: nil) as? NSParagraphStyle
            let base = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            base.minimumLineHeight = minimumHeight
            if base.maximumLineHeight > 0, base.maximumLineHeight < minimumHeight {
                base.maximumLineHeight = 0
            }
            textStorage.addAttribute(.paragraphStyle, value: base, range: cell.paragraphRange)
        }
    }

    private func clearHoveredTableControls() {
        let hadState = hoveredTableForAddButton != nil || hoveredTableAddButtonRect != nil || hoveredTableRowResizeTarget != nil
        hoveredTableForAddButton = nil
        hoveredTableAddButtonRect = nil
        hoveredTableRowResizeTarget = nil
        if hadState {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private func updateHoveredTableControls(at point: NSPoint) {
        if tableRowResizeSession != nil { return }

        if let hoveredRect = hoveredTableAddButtonRect, hoveredRect.insetBy(dx: -8, dy: -8).contains(point) {
            hoveredTableRowResizeTarget = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }

        let index = characterIndexForInsertion(at: point)
        guard let textStorage, index >= 0, index < textStorage.length,
              let table = tableCursorLocation(at: index)?.table else {
            if let hoveredRect = hoveredTableAddButtonRect, hoveredRect.insetBy(dx: -8, dy: -8).contains(point) {
                return
            }
            clearHoveredTableControls()
            return
        }

        let addRect = tableAddButtonRect(for: table)
        let resizeTarget: TableRowResizeTarget? = nil
        let changed = hoveredTableForAddButton !== table
            || hoveredTableAddButtonRect != addRect
            || hoveredTableRowResizeTarget != nil

        hoveredTableForAddButton = table
        hoveredTableAddButtonRect = addRect
        hoveredTableRowResizeTarget = resizeTarget
        if changed {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        updateHoveredTableControls(at: point)

        if let addRect = hoveredTableAddButtonRect, addRect.insetBy(dx: -4, dy: -4).contains(point) {
            if let table = hoveredTableForAddButton,
               let anchor = tableCursorLocations(for: table).last {
                setSelectedRange(NSRange(location: anchor.paragraphRange.location, length: 0))
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("NotsyToolbarAction"),
                object: nil,
                userInfo: ["action": "table-row-add"]
            )
            return
        }

        if beginImageResizeIfNeeded(at: point) {
            return
        }

        // Make cell switching deterministic even in tall/mostly-empty table rows.
        if event.type == .leftMouseDown, event.clickCount == 1,
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           let cell = tableCell(at: point) {
            let targetLocation = insertionLocation(in: cell, at: point)
            setSelectedRange(NSRange(location: targetLocation, length: 0))
            if let delegate = self.delegate as? RichTextEditorView.Coordinator {
                delegate.updateSelectionText(for: self)
            }
            resetTypingAttributesForCurrentSelection()
            return
        }

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
            
            // Check if click happened directly on the checkbox marker
            let circleLocation = lineRange.location + leadingWhitespace.utf16.count
            if characterIndex == circleLocation || characterIndex == circleLocation + 1 {
                let markerFont: NSFont = {
                    guard let textStorage = self.textStorage, textStorage.length > 0 else {
                        return NSFont.monospacedSystemFont(ofSize: Self.editorFontSize + 2, weight: .regular)
                    }
                    let probeLocation = min(textStorage.length - 1, circleLocation + 2)
                    let base = (textStorage.attribute(.font, at: probeLocation, effectiveRange: nil) as? NSFont)
                        ?? NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular)
                    let targetSize = max(base.pointSize + 2, Self.editorFontSize + 1)
                    return NSFont(descriptor: base.fontDescriptor, size: targetSize) ?? base
                }()
                if trimmed.hasPrefix(Self.uncheckedCheckboxMarker) {
                    self.undoManager?.beginUndoGrouping()
                    let checkedBox = NSAttributedString(string: "☑", attributes: [
                        .font: markerFont,
                        .foregroundColor: NSColor.systemGreen
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: checkedBox)
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
                } else if trimmed.hasPrefix(Self.checkedCheckboxMarker) || trimmed.hasPrefix(Self.legacyCheckedCheckboxMarker) {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "☐", attributes: [
                        .font: markerFont,
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

    override func mouseDragged(with event: NSEvent) {
        if let rowResize = tableRowResizeSession {
            let point = convert(event.locationInWindow, from: nil)
            let delta = isFlipped ? (point.y - rowResize.startPoint.y) : (rowResize.startPoint.y - point.y)
            let targetHeight = max(Self.minTableRowHeight, rowResize.initialMinimumLineHeight + delta)
            applyMinimumLineHeight(targetHeight, for: rowResize.row, in: rowResize.table)
            needsDisplay = true
            return
        }

        guard let resizeAttachmentIndex else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - resizeStartPoint.x
        let dy = (isFlipped ? 1 : -1) * (point.y - resizeStartPoint.y)
        let distance = hypot(dx, dy)

        if !didBeginResizeDrag {
            if distance < Self.resizeDragThreshold {
                return
            }
            didBeginResizeDrag = true
        }

        applyResizeDrag(
            for: resizeAttachmentIndex,
            point: point,
            freeResize: event.modifierFlags.contains(.shift)
        )
    }

    override func mouseUp(with event: NSEvent) {
        if tableRowResizeSession != nil {
            tableRowResizeSession = nil
            let point = convert(event.locationInWindow, from: nil)
            updateHoveredTableControls(at: point)
            if let delegate = delegate as? RichTextEditorView.Coordinator {
                delegate.saveState()
            }
            return
        }

        if resizeAttachmentIndex != nil {
            let didResize = didBeginResizeDrag
            let point = convert(event.locationInWindow, from: nil)
            clearImageResizeState(updateHoverAt: point)
            if didResize, let delegate = delegate as? RichTextEditorView.Coordinator {
                delegate.saveState()
            }
            return
        }
        super.mouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let imageTrackingArea {
            removeTrackingArea(imageTrackingArea)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
            .cursorUpdate,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag
        ]
        let tracking = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(tracking)
        imageTrackingArea = tracking
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredTableControls(at: point)
        updateHoveredAttachment(at: point)
        if let addRect = hoveredTableAddButtonRect, addRect.contains(point) {
            NSCursor.pointingHand.set()
        } else if hoveredTableRowResizeTarget?.hitRect.contains(point) == true {
            NSCursor.resizeUpDown.set()
        } else if isPointOverResizeHandle(point) {
            Self.diagonalResizeCursor.set()
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let addRect = hoveredTableAddButtonRect, addRect.contains(point) {
            NSCursor.pointingHand.set()
        } else if hoveredTableRowResizeTarget?.hitRect.contains(point) == true {
            NSCursor.resizeUpDown.set()
        } else if isPointOverResizeHandle(point) {
            Self.diagonalResizeCursor.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredAttachmentIndex(nil)
        clearHoveredTableControls()
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let attachmentIndex = hoveredAttachmentIndex,
           let attachmentRect = attachmentRect(for: attachmentIndex) {
            addCursorRect(
                imageResizeHandleHitRect(for: attachmentRect),
                cursor: Self.diagonalResizeCursor
            )
        }
        if let addRect = hoveredTableAddButtonRect {
            addCursorRect(addRect, cursor: .pointingHand)
        }
        if let rowTarget = hoveredTableRowResizeTarget {
            addCursorRect(rowTarget.hitRect, cursor: .resizeUpDown)
        }
    }

    override func didChangeText() {
        normalizeListParagraphStylesIfNeeded()
        normalizeTableStructuresIfNeeded()
        normalizeImageAttachmentsIfNeeded()
        refreshDetectedLinks()
        if let pendingEditedRange {
            applyCodeHighlightingForEditedRange(pendingEditedRange, preferredLanguage: nil)
            self.pendingEditedRange = nil
        }
        super.didChangeText()
        refreshImageChrome()
    }

    private func normalizeTableStructuresIfNeeded() {
        guard !isNormalizingTableStructure else { return }
        guard let textStorage, textStorage.length > 0 else { return }

        let text = textStorage.string as NSString
        var groupsByID: [ObjectIdentifier: TableNormalizationGroup] = [:]
        var orderedGroupIDs: [ObjectIdentifier] = []
        var paragraphLocation = 0

        while paragraphLocation < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: paragraphLocation, length: 0))
            let styleLocation = min(paragraphRange.location, max(0, textStorage.length - 1))
            guard let paragraph = textStorage.attribute(
                .paragraphStyle,
                at: styleLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle,
            let tableBlock = paragraph.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
            else {
                paragraphLocation = NSMaxRange(paragraphRange)
                continue
            }

            let rawValue = text.substring(with: paragraphRange)
            let singleLine = rawValue
                .trimmingCharacters(in: .newlines)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let paragraphInfo = TableNormalizationParagraph(
                table: tableBlock.table,
                tableBlock: tableBlock,
                row: tableBlock.startingRow,
                column: tableBlock.startingColumn,
                paragraphRange: paragraphRange,
                value: singleLine,
                minimumLineHeight: paragraph.minimumLineHeight > 0 ? paragraph.minimumLineHeight : nil
            )

            let groupID = ObjectIdentifier(tableBlock.table)
            if groupsByID[groupID] == nil {
                orderedGroupIDs.append(groupID)
                groupsByID[groupID] = TableNormalizationGroup(
                    table: tableBlock.table,
                    paragraphs: [paragraphInfo],
                    tableRange: paragraphRange
                )
            } else {
                groupsByID[groupID]?.paragraphs.append(paragraphInfo)
                if let currentRange = groupsByID[groupID]?.tableRange {
                    groupsByID[groupID]?.tableRange = NSUnionRange(currentRange, paragraphRange)
                }
            }

            paragraphLocation = NSMaxRange(paragraphRange)
        }

        guard !orderedGroupIDs.isEmpty else { return }

        let selected = selectedRange()
        let selectionProbe = min(max(0, selected.location), max(0, textStorage.length - 1))
        let anchorCell = tableCursorLocation(at: selectionProbe)

        var replacements: [TableNormalizationReplacement] = []

        for groupID in orderedGroupIDs {
            guard let group = groupsByID[groupID], !group.paragraphs.isEmpty else { continue }

            let rowCount = (group.paragraphs.map(\.row).max() ?? -1) + 1
            let detectedColumnCount = (group.paragraphs.map(\.column).max() ?? -1) + 1
            let columnCount = max(group.table.numberOfColumns, detectedColumnCount)
            guard rowCount > 0, columnCount > 0 else { continue }

            var valueByKey: [String: String] = [:]
            var countByKey: [String: Int] = [:]
            var minimumLineHeightByRow: [Int: CGFloat] = [:]
            var hasIrregularBlock = false

            for paragraph in group.paragraphs.sorted(by: { $0.paragraphRange.location < $1.paragraphRange.location }) {
                let key = "\(paragraph.row):\(paragraph.column)"
                countByKey[key, default: 0] += 1

                if let minimumLineHeight = paragraph.minimumLineHeight, minimumLineHeight > 0 {
                    minimumLineHeightByRow[paragraph.row] = max(
                        minimumLineHeightByRow[paragraph.row] ?? 0,
                        minimumLineHeight
                    )
                }

                if paragraph.tableBlock.rowSpan != 1 || paragraph.tableBlock.columnSpan != 1 {
                    hasIrregularBlock = true
                }

                let cleanedValue = paragraph.value
                if cleanedValue.isEmpty { continue }
                if let existing = valueByKey[key], !existing.isEmpty {
                    valueByKey[key] = "\(existing) \(cleanedValue)"
                } else {
                    valueByKey[key] = cleanedValue
                }
            }

            let expectedCellCount = rowCount * columnCount
            let hasDuplicates = countByKey.values.contains(where: { $0 > 1 })
            let hasMissingCells = countByKey.keys.count != expectedCellCount
            let hasColumnMismatch = group.table.numberOfColumns != columnCount
            let shouldNormalize = hasDuplicates || hasMissingCells || hasIrregularBlock || hasColumnMismatch
            guard shouldNormalize else { continue }

            let baseLocation = min(max(0, group.tableRange.location), textStorage.length - 1)
            let sourceAttributes = textStorage.attributes(at: baseLocation, effectiveRange: nil)
            var baseAttributes = normalizedTypingAttributes(base: sourceAttributes)
            baseAttributes.removeValue(forKey: .paragraphStyle)

            let borderColor = (group.paragraphs.first?.tableBlock.borderColor(for: .minX) as? NSColor)
                ?? NSColor(calibratedWhite: 0.56, alpha: 0.82)

            let targetRow = anchorCell?.table === group.table
                ? min(max(0, anchorCell?.row ?? 0), rowCount - 1)
                : nil
            let targetColumn = anchorCell?.table === group.table
                ? min(max(0, anchorCell?.column ?? 0), columnCount - 1)
                : nil

            let rebuilt = makeCanonicalTableAttributedText(
                rows: rowCount,
                columns: columnCount,
                valueByKey: valueByKey,
                baseAttributes: baseAttributes,
                minimumLineHeightByRow: minimumLineHeightByRow,
                borderColor: borderColor,
                initialRow: targetRow,
                initialColumn: targetColumn
            )

            let preferredCaretLocation = rebuilt.caretOffset.map { group.tableRange.location + $0 }
            replacements.append(
                TableNormalizationReplacement(
                    range: group.tableRange,
                    attributed: rebuilt.attributed,
                    preferredCaretLocation: preferredCaretLocation
                )
            )
        }

        guard !replacements.isEmpty else { return }

        isNormalizingTableStructure = true
        defer { isNormalizingTableStructure = false }

        var updatedSelection = selected
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            let isCollapsedInsideRange = updatedSelection.length == 0
                && updatedSelection.location >= replacement.range.location
                && updatedSelection.location <= NSMaxRange(replacement.range)
            let overlapsRange = NSIntersectionRange(updatedSelection, replacement.range).length > 0
            let shouldApplyPreferredCaret = (isCollapsedInsideRange || overlapsRange)
                && replacement.preferredCaretLocation != nil

            textStorage.replaceCharacters(in: replacement.range, with: replacement.attributed)

            if shouldApplyPreferredCaret, let preferredCaretLocation = replacement.preferredCaretLocation {
                updatedSelection = NSRange(location: preferredCaretLocation, length: 0)
            } else {
                updatedSelection = adjustedSelectionAfterReplacement(
                    updatedSelection,
                    replacing: replacement.range,
                    replacementLength: replacement.attributed.length
                )
            }
        }

        let clampedLocation = min(max(0, updatedSelection.location), textStorage.length)
        let clampedLength = min(
            max(0, updatedSelection.length),
            max(0, textStorage.length - clampedLocation)
        )
        setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        resetTypingAttributesForCurrentSelection()
        clearHoveredTableControls()
    }

    private func makeCanonicalTableAttributedText(
        rows: Int,
        columns: Int,
        valueByKey: [String: String],
        baseAttributes: [NSAttributedString.Key: Any],
        minimumLineHeightByRow: [Int: CGFloat],
        borderColor: NSColor,
        initialRow: Int?,
        initialColumn: Int?
    ) -> (attributed: NSAttributedString, caretOffset: Int?) {
        let table = NSTextTable()
        table.numberOfColumns = columns

        let mutable = NSMutableAttributedString()
        var runningOffset = 0
        var caretOffset: Int?

        for row in 0..<rows {
            for column in 0..<columns {
                let key = "\(row):\(column)"
                let rawValue = valueByKey[key, default: ""]
                let sanitizedValue = rawValue
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                let cellValue = sanitizedValue.isEmpty ? " " : sanitizedValue
                let paragraphText = cellValue + "\n"

                if row == initialRow, column == initialColumn {
                    caretOffset = runningOffset
                }

                let block = NSTextTableBlock(
                    table: table,
                    startingRow: row,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setBorderColor(borderColor, for: .minX)
                block.setBorderColor(borderColor, for: .maxX)
                block.setBorderColor(borderColor, for: .minY)
                block.setBorderColor(borderColor, for: .maxY)
                block.setWidth(1.0, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [block]
                paragraphStyle.lineSpacing = 4
                if let minimumLineHeight = minimumLineHeightByRow[row], minimumLineHeight > 0 {
                    paragraphStyle.minimumLineHeight = minimumLineHeight
                }

                var attrs = baseAttributes
                attrs[.paragraphStyle] = paragraphStyle
                let attributed = NSAttributedString(string: paragraphText, attributes: attrs)
                mutable.append(attributed)
                runningOffset += attributed.length
            }
        }

        return (attributed: mutable, caretOffset: caretOffset)
    }

    private func adjustedSelectionAfterReplacement(
        _ selection: NSRange,
        replacing range: NSRange,
        replacementLength: Int
    ) -> NSRange {
        let delta = replacementLength - range.length

        func adjustedPoint(_ point: Int) -> Int {
            if point <= range.location {
                return point
            }
            if point >= NSMaxRange(range) {
                return point + delta
            }
            return range.location + min(max(0, point - range.location), replacementLength)
        }

        let start = adjustedPoint(selection.location)
        let end = adjustedPoint(selection.location + selection.length)
        let location = min(start, end)
        return NSRange(location: location, length: max(0, end - location))
    }

    private struct TableMutationContext {
        let table: NSTextTable
        let rowCount: Int
        let columnCount: Int
        let replacementRange: NSRange
        let valuesByKey: [String: String]
        let minimumLineHeightByRow: [Int: CGFloat]
        let borderColor: NSColor
        let currentRow: Int
        let currentColumn: Int
    }

    func insertNewTable(
        rows: Int,
        columns: Int,
        seedValues: [String: String] = [:],
        focusRow: Int = 0,
        focusColumn: Int = 0
    ) -> Bool {
        guard rows > 0, columns > 0, let textStorage else { return false }
        let selection = selectedRange()
        let baseIndex = min(max(0, selection.location), max(0, textStorage.length - 1))
        let sourceAttributes = textStorage.length > 0 ? textStorage.attributes(at: baseIndex, effectiveRange: nil) : typingAttributes
        var baseAttributes = normalizedTypingAttributes(base: sourceAttributes)
        baseAttributes.removeValue(forKey: .paragraphStyle)

        let targetRow = min(max(0, focusRow), rows - 1)
        let targetColumn = min(max(0, focusColumn), columns - 1)
        let table = makeCanonicalTableAttributedText(
            rows: rows,
            columns: columns,
            valueByKey: seedValues,
            baseAttributes: baseAttributes,
            minimumLineHeightByRow: [:],
            borderColor: NSColor(calibratedWhite: 0.56, alpha: 0.82),
            initialRow: targetRow,
            initialColumn: targetColumn
        )
        let caretLocation = selection.location + (table.caretOffset ?? 0)
        return applyTableEdit(
            replacing: selection,
            with: table.attributed,
            caretLocation: caretLocation
        )
    }

    func insertDiffTemplateTable() -> Bool {
        let seeds: [String: String] = [
            "0:0": "Note A",
            "0:1": "Note B"
        ]
        return insertNewTable(
            rows: 2,
            columns: 2,
            seedValues: seeds,
            focusRow: 1,
            focusColumn: 0
        )
    }

    func addRowToCurrentTable() -> Bool {
        normalizeTableStructuresIfNeeded()
        guard let context = currentTableMutationContext() else { return false }

        let insertionRow = min(context.rowCount, context.currentRow + 1)
        let newRowCount = context.rowCount + 1
        var mappedValues: [String: String] = [:]
        var mappedMinimumLineHeightByRow: [Int: CGFloat] = [:]

        for row in 0..<context.rowCount {
            let mappedRow = row >= insertionRow ? row + 1 : row
            for column in 0..<context.columnCount {
                let key = "\(row):\(column)"
                if let value = context.valuesByKey[key], !value.isEmpty {
                    mappedValues["\(mappedRow):\(column)"] = value
                }
            }
            if let minimumLineHeight = context.minimumLineHeightByRow[row], minimumLineHeight > 0 {
                mappedMinimumLineHeightByRow[mappedRow] = minimumLineHeight
            }
        }

        return applyTableMutation(
            context: context,
            rows: newRowCount,
            columns: context.columnCount,
            valuesByKey: mappedValues,
            minimumLineHeightByRow: mappedMinimumLineHeightByRow,
            focusRow: insertionRow,
            focusColumn: 0
        )
    }

    func removeRowFromCurrentTable() -> Bool {
        normalizeTableStructuresIfNeeded()
        guard let context = currentTableMutationContext(), context.rowCount > 1 else { return false }

        // Keep the first row as a header-like row, mirroring existing behavior.
        let removableRow = context.currentRow == 0 ? 1 : context.currentRow
        let targetRow = min(max(1, removableRow), context.rowCount - 1)
        let newRowCount = context.rowCount - 1
        var mappedValues: [String: String] = [:]
        var mappedMinimumLineHeightByRow: [Int: CGFloat] = [:]

        for row in 0..<context.rowCount {
            if row == targetRow { continue }
            let mappedRow = row > targetRow ? row - 1 : row
            for column in 0..<context.columnCount {
                let key = "\(row):\(column)"
                if let value = context.valuesByKey[key], !value.isEmpty {
                    mappedValues["\(mappedRow):\(column)"] = value
                }
            }
            if let minimumLineHeight = context.minimumLineHeightByRow[row], minimumLineHeight > 0 {
                mappedMinimumLineHeightByRow[mappedRow] = minimumLineHeight
            }
        }

        let focusRow = min(context.currentRow, max(0, newRowCount - 1))
        let focusColumn = min(context.currentColumn, max(0, context.columnCount - 1))
        return applyTableMutation(
            context: context,
            rows: newRowCount,
            columns: context.columnCount,
            valuesByKey: mappedValues,
            minimumLineHeightByRow: mappedMinimumLineHeightByRow,
            focusRow: focusRow,
            focusColumn: focusColumn
        )
    }

    private func currentTableMutationContext() -> TableMutationContext? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let selection = selectedRange()
        let probeLocation = min(max(0, selection.location), textStorage.length - 1)
        guard let current = tableCursorLocation(at: probeLocation) else { return nil }

        let cells = tableCursorLocations(for: current.table)
        guard !cells.isEmpty else { return nil }

        let rowCount = (cells.map(\.row).max() ?? -1) + 1
        let columnCount = max(current.table.numberOfColumns, (cells.map(\.column).max() ?? -1) + 1)
        guard rowCount > 0, columnCount > 0 else { return nil }

        let minLocation = cells.map { $0.paragraphRange.location }.min() ?? current.paragraphRange.location
        let maxLocation = cells.map { NSMaxRange($0.paragraphRange) }.max() ?? NSMaxRange(current.paragraphRange)
        let replacementRange = NSRange(location: minLocation, length: max(0, maxLocation - minLocation))

        var valuesByKey: [String: String] = [:]
        var minimumLineHeightByRow: [Int: CGFloat] = [:]
        for cell in cells {
            let key = "\(cell.row):\(cell.column)"
            let value = tableCellValue(for: cell.paragraphRange)
            if !value.isEmpty {
                valuesByKey[key] = value
            }
            if let minimumLineHeight = minimumLineHeight(at: cell.paragraphRange.location), minimumLineHeight > 0 {
                minimumLineHeightByRow[cell.row] = max(minimumLineHeightByRow[cell.row] ?? 0, minimumLineHeight)
            }
        }

        let borderColor = (cells.first?.tableBlock.borderColor(for: .minX) as? NSColor)
            ?? NSColor(calibratedWhite: 0.56, alpha: 0.82)

        return TableMutationContext(
            table: current.table,
            rowCount: rowCount,
            columnCount: columnCount,
            replacementRange: replacementRange,
            valuesByKey: valuesByKey,
            minimumLineHeightByRow: minimumLineHeightByRow,
            borderColor: borderColor,
            currentRow: current.row,
            currentColumn: current.column
        )
    }

    private func tableCellValue(for paragraphRange: NSRange) -> String {
        guard let textStorage else { return "" }
        let text = textStorage.string as NSString
        let raw = text.substring(with: paragraphRange)
        return raw
            .trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func minimumLineHeight(at location: Int) -> CGFloat? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let safeLocation = min(max(0, location), textStorage.length - 1)
        let paragraph = textStorage.attribute(.paragraphStyle, at: safeLocation, effectiveRange: nil) as? NSParagraphStyle
        let minimum = paragraph?.minimumLineHeight ?? 0
        return minimum > 0 ? minimum : nil
    }

    private func applyTableMutation(
        context: TableMutationContext,
        rows: Int,
        columns: Int,
        valuesByKey: [String: String],
        minimumLineHeightByRow: [Int: CGFloat],
        focusRow: Int,
        focusColumn: Int
    ) -> Bool {
        guard let textStorage else { return false }
        let baseIndex = min(max(0, context.replacementRange.location), textStorage.length - 1)
        let sourceAttributes = textStorage.attributes(at: baseIndex, effectiveRange: nil)
        var baseAttributes = normalizedTypingAttributes(base: sourceAttributes)
        baseAttributes.removeValue(forKey: .paragraphStyle)

        let clampedRow = min(max(0, focusRow), max(0, rows - 1))
        let clampedColumn = min(max(0, focusColumn), max(0, columns - 1))
        let table = makeCanonicalTableAttributedText(
            rows: rows,
            columns: columns,
            valueByKey: valuesByKey,
            baseAttributes: baseAttributes,
            minimumLineHeightByRow: minimumLineHeightByRow,
            borderColor: context.borderColor,
            initialRow: clampedRow,
            initialColumn: clampedColumn
        )
        let caretLocation = context.replacementRange.location + (table.caretOffset ?? 0)
        return applyTableEdit(
            replacing: context.replacementRange,
            with: table.attributed,
            caretLocation: caretLocation
        )
    }

    private func applyTableEdit(
        replacing range: NSRange,
        with replacement: NSAttributedString,
        caretLocation: Int
    ) -> Bool {
        guard let textStorage else { return false }
        registerPendingEdit(affectedRange: range, replacementString: replacement.string)
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }

        textStorage.replaceCharacters(in: range, with: replacement)
        let targetLocation = min(max(0, caretLocation), textStorage.length)
        setSelectedRange(NSRange(location: targetLocation, length: 0))
        didChangeText()
        resetTypingAttributesForCurrentSelection()
        scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
        return true
    }

    private func applyCodeHighlightingForEditedRange(_ editedRange: NSRange, preferredLanguage: DetectedCodeLanguage?) {
        guard let textStorage else { return }
        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        let clampedLocation = max(0, min(editedRange.location, max(0, text.length - 1)))
        let clampedLength = max(1, min(editedRange.length, max(1, text.length - clampedLocation)))
        let paragraphRange = text.paragraphRange(for: NSRange(location: clampedLocation, length: clampedLength))

        var lineLocation = paragraphRange.location
        while lineLocation < NSMaxRange(paragraphRange) {
            let lineRange = text.lineRange(for: NSRange(location: lineLocation, length: 0))
            let contentRange = lineContentRange(from: lineRange, in: text)
            if contentRange.length == 0 {
                clearCodeStyling(in: lineRange)
                lineLocation = NSMaxRange(lineRange)
                continue
            }

            let lineText = text.substring(with: contentRange)
            let detectedLanguage = detectCodeLanguage(in: lineText) ?? preferredLanguage
            if let language = detectedLanguage {
                applyCodeStyling(in: contentRange, lineText: lineText, language: language)
            } else {
                clearCodeStyling(in: lineRange)
            }

            lineLocation = NSMaxRange(lineRange)
        }
    }

    private func lineContentRange(from lineRange: NSRange, in text: NSString) -> NSRange {
        var length = lineRange.length
        while length > 0 {
            let char = text.character(at: lineRange.location + length - 1)
            if char == 10 || char == 13 {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private func clearCodeStyling(in range: NSRange) {
        guard let textStorage, range.length > 0 else { return }

        let existingCodeLanguage = textStorage.attribute(Self.codeLanguageAttribute, at: range.location, effectiveRange: nil) != nil
        guard existingCodeLanguage else { return }

        textStorage.removeAttribute(Self.codeTokenAttribute, range: range)
        textStorage.removeAttribute(Self.codeLanguageAttribute, range: range)
        textStorage.addAttribute(.foregroundColor, value: Theme.editorTextNSColor, range: range)
    }

    private func applyCodeStyling(in range: NSRange, lineText: String, language: DetectedCodeLanguage) {
        guard let textStorage, range.length > 0 else { return }

        textStorage.addAttributes(
            [
                .foregroundColor: Self.codeDefaultForegroundColor,
                Self.codeLanguageAttribute: language.rawValue,
                Self.codeTokenAttribute: "base"
            ],
            range: range
        )
        applySyntaxTokens(in: range, text: lineText, language: language)
    }

    private func applySyntaxTokens(in range: NSRange, text: String, language: DetectedCodeLanguage) {
        guard let textStorage else { return }
        let nsText = text as NSString

        func applyRegex(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let full = NSRange(location: 0, length: nsText.length)
            regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let target = NSRange(location: range.location + match.range.location, length: match.range.length)
                textStorage.addAttributes(
                    [
                        .foregroundColor: color,
                        Self.codeTokenAttribute: "token"
                    ],
                    range: target
                )
            }
        }

        applyRegex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: Self.codeStringForegroundColor)
        applyRegex(#"\b\d+(?:\.\d+)?\b"#, color: Self.codeNumberForegroundColor)

        switch language {
        case .swift:
            applyRegex(#"\b(import|let|var|func|class|struct|enum|protocol|extension|if|else|guard|return|for|while|switch|case|default|try|catch|throw|async|await|nil|true|false)\b"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"//.*$"#, color: Self.codeCommentForegroundColor)
        case .python:
            applyRegex(#"\b(def|class|import|from|as|if|elif|else|for|while|return|try|except|finally|with|lambda|yield|pass|break|continue|None|True|False)\b"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"#.*$"#, color: Self.codeCommentForegroundColor)
        case .javascript:
            applyRegex(#"\b(const|let|var|function|class|if|else|return|import|from|export|default|async|await|try|catch|finally|new|null|true|false|undefined)\b"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"//.*$"#, color: Self.codeCommentForegroundColor)
        case .json:
            applyRegex(#""[^"]*"\s*:"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"\b(true|false|null)\b"#, color: Self.codeKeywordForegroundColor)
        case .endpoint:
            applyRegex(#"(https?://[^\s]+|/[A-Za-z0-9._~!$&'()*+,;=:@%/\-{}]+)"#, color: Self.codeStringForegroundColor)
            applyRegex(#"\{[A-Za-z_][A-Za-z0-9_-]*\}"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#":[A-Za-z_][A-Za-z0-9_-]*"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"\?[A-Za-z0-9_.-]+(?==)"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"&[A-Za-z0-9_.-]+(?==)"#, color: Self.codeKeywordForegroundColor)
            applyRegex(#"https?://"#, color: Self.codeCommentForegroundColor)
        }
    }

    private func detectCodeLanguage(in text: String) -> DetectedCodeLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let swiftScore = scoreForSwift(trimmed)
        let pythonScore = scoreForPython(trimmed)
        let javascriptScore = scoreForJavaScript(trimmed)
        let jsonScore = scoreForJSON(trimmed)
        let endpointScore = scoreForEndpoint(trimmed)
        let scores: [(DetectedCodeLanguage, Int)] = [
            (.swift, swiftScore),
            (.python, pythonScore),
            (.javascript, javascriptScore),
            (.json, jsonScore),
            (.endpoint, endpointScore)
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        guard best.1 >= minimumScore(for: best.0) else { return nil }
        if isLikelyProseLine(trimmed), best.1 < strongCodeScore(for: best.0) {
            return nil
        }
        return best.0
    }

    private func minimumScore(for language: DetectedCodeLanguage) -> Int {
        switch language {
        case .swift: return 3
        case .python: return 4
        case .javascript: return 4
        case .json: return 4
        case .endpoint: return 5
        }
    }

    private func strongCodeScore(for language: DetectedCodeLanguage) -> Int {
        switch language {
        case .swift: return 5
        case .python: return 6
        case .javascript: return 6
        case .json: return 5
        case .endpoint: return 6
        }
    }

    private func isLikelyProseLine(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        let punctuationSet = CharacterSet(charactersIn: "{}[]();:=<>`\"\\")
        let punctuationCount = text.unicodeScalars.filter { punctuationSet.contains($0) }.count
        let hasCodeShape = text.contains("{") || text.contains("}") || text.contains("=>") || text.contains("://")
        return words.count >= 6 && punctuationCount <= 1 && !hasCodeShape
    }

    private func scoreForSwift(_ text: String) -> Int {
        var score = 0
        if text.contains("import ") { score += 3 }
        if text.range(of: #"\b(let|var|func|struct|class|enum|protocol|extension|guard)\b"#, options: .regularExpression) != nil { score += 3 }
        if text.contains("->") { score += 2 }
        if text.contains(" if let ") || text.hasPrefix("if let ") { score += 2 }
        if text.contains(":") && text.contains("{") { score += 1 }
        return score
    }

    private func scoreForPython(_ text: String) -> Int {
        var score = 0
        if text.range(of: #"^\s*(def|class)\s+\w+\s*[\(:]"#, options: .regularExpression) != nil { score += 4 }
        if text.range(of: #"\b(import|def|class|elif|except|lambda|None|True|False)\b"#, options: .regularExpression) != nil { score += 3 }
        if text.range(of: #"\b(from\s+\w+\s+import|with\s+\w+.*:)\b"#, options: .regularExpression) != nil { score += 2 }
        if text.hasSuffix(":") { score += 1 }
        if text.contains("__name__") { score += 2 }
        return score
    }

    private func scoreForJavaScript(_ text: String) -> Int {
        var score = 0
        if text.range(of: #"\b(const|let|var|function|console\.log|document\.|window\.)\b"#, options: .regularExpression) != nil { score += 4 }
        if text.contains("=>") { score += 2 }
        if text.contains("===") || text.contains("!==") { score += 1 }
        if text.hasSuffix(";") { score += 1 }
        return score
    }

    private func scoreForJSON(_ text: String) -> Int {
        var score = 0
        if text.range(of: #"^\s*[\{\[]\s*$"#, options: .regularExpression) != nil { score += 2 }
        if text.range(of: #""[^"]+"\s*:"#, options: .regularExpression) != nil { score += 4 }
        if text.range(of: #"\b(true|false|null)\b"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"^\s*[\}\]]\s*,?\s*$"#, options: .regularExpression) != nil { score += 2 }
        return score
    }

    private func scoreForEndpoint(_ text: String) -> Int {
        var score = 0
        if text.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil { score += 7 }
        if text.range(of: #"^/[A-Za-z0-9._~!$&'()*+,;=:@%/\-{}]+$"#, options: .regularExpression) != nil { score += 6 }
        if text.range(of: #"\b(url|endpoint|path)\b\s*:\s*/[A-Za-z0-9._~!$&'()*+,;=:@%/\-{}]+"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 6 }
        if text.range(of: #"\{[A-Za-z_][A-Za-z0-9_-]*\}"#, options: .regularExpression) != nil { score += 2 }
        if text.range(of: #":[A-Za-z_][A-Za-z0-9_-]*"#, options: .regularExpression) != nil { score += 2 }
        if text.contains("?") && text.contains("=") { score += 2 }
        if text.range(of: #"\b(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD)\b"#, options: .regularExpression) != nil { score += 2 }
        return score
    }

    func normalizeListParagraphStylesIfNeeded() {
        guard !isNormalizingListParagraphStyles else { return }
        guard let textStorage, textStorage.length > 0 else { return }

        isNormalizingListParagraphStyles = true
        defer { isNormalizingListParagraphStyles = false }

        let fullString = textStorage.string as NSString
        var paragraphLocation = 0

        while paragraphLocation < fullString.length {
            let paragraphRange = fullString.paragraphRange(for: NSRange(location: paragraphLocation, length: 0))
            let paragraphText = fullString.substring(with: paragraphRange)
            let leadingWhitespace = String(paragraphText.prefix(while: { $0 == " " || $0 == "\t" }))
            let trimmedLeading = String(paragraphText.drop(while: { $0 == " " || $0 == "\t" }))

            let styleSourceIndex = min(paragraphRange.location, max(0, textStorage.length - 1))
            let styleSource = textStorage.attribute(.paragraphStyle, at: styleSourceIndex, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = (styleSource?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            var didChange = false

            let hasTableBlock = paragraph.textBlocks.contains { $0 is NSTextTableBlock }
            if hasTableBlock {
                if paragraph.lineSpacing != 4 {
                    paragraph.lineSpacing = 4
                    didChange = true
                }
                if didChange {
                    textStorage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
                }
                paragraphLocation = NSMaxRange(paragraphRange)
                continue
            }

            if !paragraph.textLists.isEmpty {
                paragraph.textLists = []
                didChange = true
            }

            if paragraph.lineSpacing != 4 {
                paragraph.lineSpacing = 4
                didChange = true
            }

            let font = (textStorage.attribute(.font, at: styleSourceIndex, effectiveRange: nil) as? NSFont)
                ?? (typingAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: Self.editorFontSize, weight: .regular)

            if let marker = listMarkerPrefix(in: trimmedLeading) {
                let leadingIndent = widthOfLeadingWhitespace(leadingWhitespace, font: font, paragraphStyle: paragraph)
                let hangingIndent = leadingIndent + textWidth(marker, font: font)

                // Keep first line natural (actual tabs/spaces + marker chars), and only indent wrapped lines
                // to the text start after the marker.
                if abs(paragraph.firstLineHeadIndent) > 0.25 {
                    paragraph.firstLineHeadIndent = 0
                    didChange = true
                }
                if abs(paragraph.headIndent - hangingIndent) > 0.25 {
                    paragraph.headIndent = hangingIndent
                    didChange = true
                }
            } else {
                if abs(paragraph.firstLineHeadIndent) > 0.25 {
                    paragraph.firstLineHeadIndent = 0
                    didChange = true
                }
                if abs(paragraph.headIndent) > 0.25 {
                    paragraph.headIndent = 0
                    didChange = true
                }
            }

            if didChange {
                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            }

            paragraphLocation = NSMaxRange(paragraphRange)
        }
    }

    static func bulletMarker(forLeadingWhitespace whitespace: String) -> String {
        let level = listIndentLevel(fromLeadingWhitespace: whitespace)
        return bulletMarkers[level % bulletMarkers.count]
    }

    static func listIndentLevel(fromLeadingWhitespace whitespace: String) -> Int {
        var level = 0
        var spaces = 0
        for char in whitespace {
            if char == "\t" {
                level += 1
            } else if char == " " {
                spaces += 1
                if spaces == 4 {
                    level += 1
                    spaces = 0
                }
            }
        }
        return level
    }

    static func bulletMarkerPrefix(in text: String) -> String? {
        for marker in bulletMarkers where text.hasPrefix(marker) {
            return marker
        }
        // Legacy marker from previous build; keep behavior stable for existing notes.
        if text.hasPrefix("▪ ") { return "▪ " }
        return nil
    }

    private func listMarkerPrefix(in text: String) -> String? {
        if let marker = Self.bulletMarkerPrefix(in: text) { return marker }
        if text.hasPrefix(Self.uncheckedCheckboxMarker) { return Self.uncheckedCheckboxMarker }
        if text.hasPrefix(Self.checkedCheckboxMarker) { return Self.checkedCheckboxMarker }
        if text.hasPrefix(Self.legacyCheckedCheckboxMarker) { return Self.legacyCheckedCheckboxMarker }
        if text.hasPrefix("- ") { return "- " }
        return nil
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func widthOfLeadingWhitespace(_ whitespace: String, font: NSFont, paragraphStyle: NSParagraphStyle) -> CGFloat {
        let spaceWidth = textWidth(" ", font: font)
        let tabInterval = paragraphStyle.defaultTabInterval > 0 ? paragraphStyle.defaultTabInterval : Self.fallbackTabInterval
        var width: CGFloat = 0

        for char in whitespace {
            if char == " " {
                width += spaceWidth
            } else if char == "\t" {
                let remainder = width.truncatingRemainder(dividingBy: tabInterval)
                width += remainder == 0 ? tabInterval : (tabInterval - remainder)
            }
        }

        return width
    }

    func refreshDetectedLinks() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.enumerateAttribute(Self.autoDetectedLinkAttribute, in: fullRange, options: []) { value, range, _ in
            guard let isAuto = value as? Bool, isAuto else { return }
            textStorage.removeAttribute(.link, range: range)
            textStorage.removeAttribute(Self.autoDetectedLinkAttribute, range: range)
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let text = textStorage.string
        detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            guard match.range.location < textStorage.length else { return }

            // Preserve manually created links and only manage auto-detected ones.
            let isExplicit = (textStorage.attribute(
                Self.explicitLinkAttribute,
                at: match.range.location,
                effectiveRange: nil
            ) as? Bool) == true
            let hasLink = textStorage.attribute(.link, at: match.range.location, effectiveRange: nil) != nil
            if isExplicit || hasLink { return }

            textStorage.addAttributes(
                [
                    .link: url,
                    Self.autoDetectedLinkAttribute: true
                ],
                range: match.range
            )
        }
    }

    func normalizeImageAttachmentsIfNeeded() {
        guard !isNormalizingAttachments else { return }
        guard let textStorage else { return }
        isNormalizingAttachments = true
        defer { isNormalizingAttachments = false }

        let wholeRange = NSRange(location: 0, length: textStorage.length)
        var attachmentRanges: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: wholeRange, options: []) { value, range, _ in
            guard value is NSTextAttachment else { return }
            attachmentRanges.append(range)
        }

        for range in attachmentRanges {
            guard range.location < textStorage.length,
                  let attachment = textStorage.attribute(.attachment, at: range.location, effectiveRange: nil)
                    as? NSTextAttachment else { continue }
            let currentWidth = attachment.bounds.width
            let targetWidth = currentWidth > 1
                ? min(currentWidth, self.availableImageWidth())
                : Self.defaultImageDisplayWidth
            self.applyImageSize(
                to: attachment,
                range: range,
                targetWidth: targetWidth
            )
            self.alignAttachmentVerticallyIfNeeded(attachment: attachment, attachmentRange: range)
            self.centerAttachmentParagraphIfNeeded(attachmentRange: range)
        }
        refreshImageChrome()
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

    private func beginImageResizeIfNeeded(at point: NSPoint) -> Bool {
        guard let attachmentIndex = attachmentCharacterIndex(at: point),
              let attachmentRect = attachmentRect(for: attachmentIndex),
              imageResizeHandleHitRect(for: attachmentRect).contains(point),
              let textStorage,
              textStorage.length > 0,
              let attachment = textStorage.attribute(.attachment, at: attachmentIndex, effectiveRange: nil)
                as? NSTextAttachment else {
            return false
        }

        var range = NSRange(location: attachmentIndex, length: 1)
        _ = textStorage.attribute(.attachment, at: attachmentIndex, effectiveRange: &range)
        let currentSize = resolvedAttachmentSize(for: attachment)

        resizeAttachmentIndex = attachmentIndex
        resizeStartPoint = point
        resizeStartSize = currentSize
        resizeStartAttachmentRect = attachmentRect
        resizeAspectRatio = max(0.1, currentSize.width / max(currentSize.height, 1))
        didBeginResizeDrag = false
        setHoveredAttachmentIndex(attachmentIndex)
        window?.makeFirstResponder(self)
        return true
    }

    private func applyResizeDrag(
        for attachmentIndex: Int,
        point: NSPoint,
        freeResize: Bool
    ) {
        guard let textStorage,
              attachmentIndex >= 0,
              attachmentIndex < textStorage.length else { return }
        var effectiveRange = NSRange(location: attachmentIndex, length: 1)
        guard let attachment = textStorage.attribute(.attachment, at: attachmentIndex, effectiveRange: &effectiveRange)
                as? NSTextAttachment else { return }

        let maxWidth = availableImageWidth()
        let minWidth = min(Self.minResizableImageWidth, maxWidth)
        let widthFromX = point.x - resizeStartAttachmentRect.minX
        let newWidth = min(max(widthFromX, minWidth), maxWidth)
        var newHeight = resizeStartSize.height

        if freeResize {
            let proposedHeight: CGFloat
            if isFlipped {
                proposedHeight = point.y - resizeStartAttachmentRect.minY
            } else {
                proposedHeight = resizeStartAttachmentRect.maxY - point.y
            }
            newHeight = max(Self.minResizableImageHeight, proposedHeight)
        } else {
            newHeight = max(Self.minResizableImageHeight, newWidth / max(resizeAspectRatio, 0.1))
        }

        attachment.bounds = NSRect(
            origin: .zero,
            size: NSSize(width: floor(newWidth), height: floor(newHeight))
        )
        alignAttachmentVerticallyIfNeeded(attachment: attachment, attachmentRange: effectiveRange)
        centerAttachmentParagraphIfNeeded(attachmentRange: effectiveRange)
        textStorage.edited([.editedAttributes], range: effectiveRange, changeInLength: 0)
        needsDisplay = true
    }

    private func clearImageResizeState(updateHoverAt point: NSPoint?) {
        resizeAttachmentIndex = nil
        didBeginResizeDrag = false
        resizeStartPoint = .zero
        resizeStartSize = .zero
        resizeStartAttachmentRect = .zero
        resizeAspectRatio = 1
        if let point {
            updateHoveredAttachment(at: point)
        } else {
            setHoveredAttachmentIndex(nil)
        }
        needsDisplay = true
    }

    private func isPointOverResizeHandle(_ point: NSPoint) -> Bool {
        guard let attachmentIndex = attachmentCharacterIndex(at: point),
              let attachmentRect = attachmentRect(for: attachmentIndex) else { return false }
        return imageResizeHandleHitRect(for: attachmentRect).contains(point)
    }

    private func updateHoveredAttachment(at point: NSPoint) {
        guard resizeAttachmentIndex == nil else { return }
        setHoveredAttachmentIndex(attachmentCharacterIndex(at: point))
    }

    private func setHoveredAttachmentIndex(_ index: Int?) {
        if hoveredAttachmentIndex == index { return }
        hoveredAttachmentIndex = index
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func selectedAttachmentIndex() -> Int? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let selected = selectedRange()

        if selected.length > 0 {
            var foundIndex: Int?
            textStorage.enumerateAttribute(.attachment, in: selected, options: []) { value, range, stop in
                if value is NSTextAttachment {
                    foundIndex = range.location
                    stop.pointee = true
                }
            }
            return foundIndex
        }

        let candidates = [selected.location, selected.location - 1]
            .filter { $0 >= 0 && $0 < textStorage.length }
        for candidate in candidates {
            if textStorage.attribute(.attachment, at: candidate, effectiveRange: nil) is NSTextAttachment {
                return candidate
            }
        }
        return nil
    }

    private var chromeAttachmentIndex: Int? {
        if let resizeAttachmentIndex { return resizeAttachmentIndex }
        if let hoveredAttachmentIndex { return hoveredAttachmentIndex }
        return selectedAttachmentIndex()
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

    private func resolvedAttachmentSize(for attachment: NSTextAttachment) -> NSSize {
        if attachment.image == nil, let decoded = decodedImage(from: attachment) {
            attachment.image = decoded
        }

        let imageSize = attachment.image?.size ?? attachment.attachmentCell?.cellSize() ?? .zero
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: Self.defaultImageDisplayWidth, height: Self.defaultImageDisplayWidth * 0.6)
        }

        if attachment.bounds.width > 1, attachment.bounds.height > 1 {
            return attachment.bounds.size
        }

        let maxWidth = availableImageWidth()
        let defaultWidth = min(Self.defaultImageDisplayWidth, maxWidth)
        let scale = defaultWidth / imageSize.width
        return NSSize(
            width: floor(defaultWidth),
            height: floor(imageSize.height * scale)
        )
    }

    private func applyImageSize(to attachment: NSTextAttachment, range: NSRange, targetWidth: CGFloat) {
        let maxWidth = availableImageWidth()
        guard maxWidth > 0 else { return }

        let imageSize = resolvedAttachmentSize(for: attachment)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let clampedWidth = min(max(targetWidth, 1), maxWidth)
        let ratio = imageSize.height / max(imageSize.width, 1)
        let newSize = NSSize(
            width: floor(clampedWidth),
            height: floor(clampedWidth * ratio)
        )
        attachment.bounds = NSRect(origin: .zero, size: newSize)

        // Refresh layout for the single attachment run.
        textStorage?.edited([.editedAttributes], range: range, changeInLength: 0)
    }

    private func centerAttachmentParagraphIfNeeded(attachmentRange: NSRange) {
        guard let textStorage, textStorage.length > 0 else { return }
        let text = textStorage.string as NSString
        let paragraphRange = text.paragraphRange(for: attachmentRange)
        let trimmed = text.substring(with: paragraphRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count == 1 else { return }

        var contentLength = paragraphRange.length
        while contentLength > 0 {
            let char = text.character(at: paragraphRange.location + contentLength - 1)
            if char == 10 || char == 13 {
                contentLength -= 1
            } else {
                break
            }
        }
        guard contentLength > 0 else { return }

        let contentRange = NSRange(location: paragraphRange.location, length: contentLength)
        var attachmentCharacterRange: NSRange?
        textStorage.enumerateAttribute(.attachment, in: contentRange, options: []) { value, range, stop in
            guard value is NSTextAttachment else { return }
            attachmentCharacterRange = range
            stop.pointee = true
        }
        guard let attachmentCharacterRange else { return }

        let attachmentAttributed = textStorage.attributedSubstring(from: attachmentCharacterRange)
        textStorage.replaceCharacters(in: contentRange, with: attachmentAttributed)

        let normalizedParagraphRange = (textStorage.string as NSString).paragraphRange(
            for: NSRange(location: attachmentCharacterRange.location, length: 0)
        )
        guard normalizedParagraphRange.length > 0 else { return }

        let sourceIndex = min(normalizedParagraphRange.location, max(0, textStorage.length - 1))
        let paragraph = ((textStorage.attribute(.paragraphStyle, at: sourceIndex, effectiveRange: nil)
            as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

        var changed = false
        if paragraph.alignment != .center {
            paragraph.alignment = .center
            changed = true
        }
        if paragraph.lineSpacing != 4 {
            paragraph.lineSpacing = 4
            changed = true
        }

        if changed {
            textStorage.addAttribute(.paragraphStyle, value: paragraph, range: normalizedParagraphRange)
        }
    }

    private func alignAttachmentVerticallyIfNeeded(
        attachment: NSTextAttachment,
        attachmentRange: NSRange
    ) {
        guard let textStorage, textStorage.length > 0 else { return }
        let text = textStorage.string as NSString
        let paragraphRange = text.paragraphRange(for: attachmentRange)

        // If paragraph has only the attachment (plus whitespace/newline), keep block behavior.
        let trimmed = text.substring(with: paragraphRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let isAttachmentOnlyParagraph = trimmed.utf16.count == 1

        let targetYOffset: CGFloat
        if isAttachmentOnlyParagraph {
            targetYOffset = 0
        } else {
            let probeIndex = min(paragraphRange.location, max(0, textStorage.length - 1))
            let font = (textStorage.attribute(.font, at: probeIndex, effectiveRange: nil) as? NSFont)
                ?? (typingAttributes[.font] as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: Self.editorFontSize, weight: .regular)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            targetYOffset = -max(0, (attachment.bounds.height - lineHeight) / 2)
        }

        if abs(attachment.bounds.origin.y - targetYOffset) > 0.25 {
            attachment.bounds.origin.y = targetYOffset
            textStorage.edited([.editedAttributes], range: attachmentRange, changeInLength: 0)
        }
    }

    private func availableImageWidth() -> CGFloat {
        let inset = textContainerInset.width * 2
        return max(Self.minResizableImageWidth, bounds.width - inset - 24)
    }

    private func decodedImage(from attachment: NSTextAttachment) -> NSImage? {
        if let data = attachment.fileWrapper?.regularFileContents {
            return NSImage(data: data)
        }
        return nil
    }

    private func imageResizeHandleRect(for attachmentRect: NSRect) -> NSRect {
        let size = Self.resizeHandleVisualSize
        let x = attachmentRect.maxX - size
        let y = isFlipped ? attachmentRect.maxY - size : attachmentRect.minY
        return NSRect(x: x, y: y, width: size, height: size)
    }

    private func imageResizeHandleHitRect(for attachmentRect: NSRect) -> NSRect {
        imageResizeHandleRect(for: attachmentRect)
            .insetBy(dx: -Self.resizeHandleHitPadding, dy: -Self.resizeHandleHitPadding)
    }

    func refreshImageChrome() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        let isBullet = CustomTextView.bulletMarkerPrefix(in: leadingStripped) != nil
        guard isBullet || leadingStripped.hasPrefix("☐") || leadingStripped.hasPrefix("☑") || leadingStripped.hasPrefix("✓") || leadingStripped.hasPrefix("-") else { return false }

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
        normalizeBulletMarkerForCurrentLine()

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
        let isBullet = CustomTextView.bulletMarkerPrefix(in: leadingStripped) != nil
        guard isBullet || leadingStripped.hasPrefix("☐") || leadingStripped.hasPrefix("☑") || leadingStripped.hasPrefix("✓") || leadingStripped.hasPrefix("-") else { return false }

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
        normalizeBulletMarkerForCurrentLine()
        if let delegate = self.delegate as? RichTextEditorView.Coordinator {
            delegate.saveState()
        }
        return true
    }

    private func normalizeBulletMarkerForCurrentLine() {
        let selected = selectedRange()
        let ns = string as NSString
        guard ns.length > 0 else { return }

        let probeLocation = max(0, min(selected.location, ns.length) - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probeLocation, length: 0))
        let lineString = ns.substring(with: lineRange)
        let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = String(lineString.drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .newlines)

        let currentBullet: String
        if let dotBullet = Self.bulletMarkerPrefix(in: trimmed) {
            currentBullet = dotBullet
        } else if trimmed.hasPrefix("- ") {
            currentBullet = "- "
        } else {
            return
        }
        let expectedBullet = leadingWhitespace.isEmpty ? "- " : Self.bulletMarker(forLeadingWhitespace: leadingWhitespace)
        guard currentBullet != expectedBullet else { return }

        let markerLocation = lineRange.location + leadingWhitespace.utf16.count
        insertText(expectedBullet, replacementRange: NSRange(location: markerLocation, length: currentBullet.utf16.count))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let attachmentIndex = chromeAttachmentIndex,
           let attachmentRect = attachmentRect(for: attachmentIndex),
           attachmentRect.intersects(dirtyRect) {
            let outlineRect = attachmentRect.insetBy(dx: -1, dy: -1)
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let outline = NSBezierPath(roundedRect: outlineRect, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()

            let handleRect = imageResizeHandleRect(for: attachmentRect)
            let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.95).setFill()
            handlePath.fill()
            NSColor.black.withAlphaComponent(0.22).setStroke()
            handlePath.lineWidth = 0.8
            handlePath.stroke()

            let grip = NSBezierPath()
            grip.lineWidth = 1
            let endX = handleRect.maxX - 2
            let endY = handleRect.maxY - 2
            for inset in [6.0, 4.0, 2.0] {
                grip.move(to: NSPoint(x: endX - inset, y: endY))
                grip.line(to: NSPoint(x: endX, y: endY - inset))
            }
            NSColor.black.withAlphaComponent(0.45).setStroke()
            grip.stroke()
        }

        if let rowTarget = hoveredTableRowResizeTarget, rowTarget.hitRect.intersects(dirtyRect) {
            let y = rowTarget.hitRect.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rowTarget.hitRect.minX, y: y))
            path.line(to: NSPoint(x: rowTarget.hitRect.maxX, y: y))
            path.lineWidth = 1
            NSColor.white.withAlphaComponent(0.35).setStroke()
            path.stroke()
        }

        if let addRect = hoveredTableAddButtonRect, addRect.intersects(dirtyRect) {
            let circle = NSBezierPath(ovalIn: addRect)
            NSColor(calibratedWhite: 0.18, alpha: 0.95).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            circle.lineWidth = 1
            circle.stroke()

            let plus = NSBezierPath()
            plus.lineWidth = 1.6
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: addRect.midX - 4, y: addRect.midY))
            plus.line(to: NSPoint(x: addRect.midX + 4, y: addRect.midY))
            plus.move(to: NSPoint(x: addRect.midX, y: addRect.midY - 4))
            plus.line(to: NSPoint(x: addRect.midX, y: addRect.midY + 4))
            NSColor.white.withAlphaComponent(0.95).setStroke()
            plus.stroke()
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caretRect = rect
        caretRect.size.width = 1

        let font = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: Self.editorFontSize)
        let normalHeight = ceil(font.ascender - font.descender + font.leading)

        // When cursor sits on an attachment line, AppKit can report a very tall caret rect.
        // Clamp it to a normal text line height so typing next to images feels natural.
        if caretRect.height > normalHeight * 1.8 {
            if isFlipped {
                caretRect.origin.y = caretRect.minY + 2
            } else {
                caretRect.origin.y = caretRect.maxY - normalHeight - 2
            }
            caretRect.size.height = normalHeight
        }

        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
    }
}

enum EditorAIActionKind: Equatable {
    case replaceSelection
    case insertBelowSelection
}

struct EditorAIAttachmentPlaceholder: Equatable {
    let token: String
    let attributedData: Data
    let aiImageData: Data?
    let aiImageMimeType: String?

    init(
        token: String,
        attributedData: Data,
        aiImageData: Data? = nil,
        aiImageMimeType: String? = nil
    ) {
        self.token = token
        self.attributedData = attributedData
        self.aiImageData = aiImageData
        self.aiImageMimeType = aiImageMimeType
    }
}

struct EditorAIActionRequest: Equatable {
    let id: UUID
    let kind: EditorAIActionKind
    let text: String
    let targetRange: NSRange?
    let attachmentPlaceholders: [EditorAIAttachmentPlaceholder]

    init(
        id: UUID = UUID(),
        kind: EditorAIActionKind,
        text: String,
        targetRange: NSRange? = nil,
        attachmentPlaceholders: [EditorAIAttachmentPlaceholder] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.targetRange = targetRange
        self.attachmentPlaceholders = attachmentPlaceholders
    }
}

struct RichTextEditorView: NSViewRepresentable {
    var note: Note
    var store: NoteStore
    @Binding var editorState: EditorState
    @Binding var activeEditorColor: NSColor
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    @Binding var pendingAIAction: EditorAIActionRequest?
    var themeVariantRaw: String
    var spellCheckEnabled: Bool

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
        textView.textContainerInset = CustomTextView.editorTextInset
        textView.textContainer?.lineFragmentPadding = CustomTextView.editorLineFragmentPadding

        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.isContinuousSpellCheckingEnabled = spellCheckEnabled
        textView.insertionPointColor = themeEditorTextColor
        textView.drawsBackground = false
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45)
        ]

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
        context.coordinator.scrollView = scrollView
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(note.stringRepresentation)
        textView.normalizeListParagraphStylesIfNeeded()
        textView.refreshDetectedLinks()
        textView.normalizeImageAttachmentsIfNeeded()
        textView.resetTypingAttributesForCurrentSelection()
        context.coordinator.lastAppliedEditorTextColor = themeEditorTextColor
        context.coordinator.currentNoteID = note.id
        context.coordinator.updateSelectionText(for: textView)

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
        if textView.isContinuousSpellCheckingEnabled != spellCheckEnabled {
            textView.isContinuousSpellCheckingEnabled = spellCheckEnabled
        }

        if context.coordinator.currentNoteID != note.id {
            context.coordinator.isUpdating = true
            if let previousNoteID = context.coordinator.currentNoteID {
                context.coordinator.captureViewportState(for: previousNoteID, in: textView)
            }
            context.coordinator.currentNoteID = note.id

            textView.textStorage?.setAttributedString(note.stringRepresentation)
            if let customTextView = textView as? CustomTextView {
                customTextView.normalizeListParagraphStylesIfNeeded()
                customTextView.refreshDetectedLinks()
                customTextView.normalizeImageAttachmentsIfNeeded()
            }

            context.coordinator.restoreViewportState(for: note.id, in: textView)
            if let customTextView = textView as? CustomTextView {
                customTextView.resetTypingAttributesForCurrentSelection()
            }

            context.coordinator.updateFormattingState(for: textView)
            context.coordinator.updateSelectionText(for: textView)
            context.coordinator.isUpdating = false
        }

        if let pendingAIAction, context.coordinator.lastHandledAIActionID != pendingAIAction.id {
            context.coordinator.lastHandledAIActionID = pendingAIAction.id
            context.coordinator.applyAIAction(pendingAIAction, to: textView)
            DispatchQueue.main.async {
                self.pendingAIAction = nil
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorView
        var currentNoteID: UUID?
        var isUpdating = false
        var lastHandledAIActionID: UUID?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastAppliedEditorTextColor: NSColor = Theme.editorTextNSColor
        private var findQuery: String = ""
        private var findMatches: [NSRange] = []
        private var currentFindIndex: Int = -1
        private var isNormalizingSelectionRange = false
        private struct EditorViewportState {
            let selectedRange: NSRange
            let verticalOffset: CGFloat
        }
        private var noteViewportState: [UUID: EditorViewportState] = [:]

        init(_ parent: RichTextEditorView) { 
            self.parent = parent 
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(handleToolbarAction(_:)), name: NSNotification.Name("NotsyToolbarAction"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleEditorFindAction(_:)), name: NSNotification.Name("NotsyEditorFindAction"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleApplyLinkEditor(_:)), name: NSNotification.Name("NotsyApplyLinkEditor"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleAppOpened(_:)), name: NSNotification.Name("NotsyOpened"), object: nil)
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
                toggleBold()
            } else if action == "italic" {
                toggleItalic()
            } else if action == "underline" {
                toggleUnderline()
            } else if action == "strikethrough" {
                toggleStrikethrough()
            } else if action == "list" {
                toggleList(isCheckbox: false)
            } else if action == "checkbox" {
                toggleList(isCheckbox: true)
            } else if action == "table-insert" {
                insertTable(rows: 3, columns: 3)
            } else if action == "table-diff" {
                insertDiffTableTemplate()
            } else if action == "table-row-add" {
                addRowInCurrentTable()
            } else if action == "table-row-remove" {
                removeRowInCurrentTable()
            } else if action == "font-system" || action == "font-sans" {
                applyFontStyle(.system)
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

        @objc func handleAppOpened(_ notification: Notification) {
            guard let textView = self.textView else { return }
            DispatchQueue.main.async {
                let range = textView.selectedRange()
                guard range.length > 0 else { return }
                let length = (textView.string as NSString).length
                let location = min(length, range.location + range.length)
                textView.setSelectedRange(NSRange(location: location, length: 0))
                if let customTextView = textView as? CustomTextView {
                    customTextView.resetTypingAttributesForCurrentSelection()
                }
                self.updateFormattingState(for: textView)
            }
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
            performUndoableFormattingEdit(on: textView, actionName: "Text Color") {
                let ranges = selectedTextRanges(in: textView)
                if !ranges.isEmpty {
                    for range in ranges {
                        textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
                        textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
                    }
                }
                textView.typingAttributes[.foregroundColor] = color
            }
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
                        .font: (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize),
                        .foregroundColor: (textView.typingAttributes[.foregroundColor] as? NSColor) ?? Theme.editorTextNSColor,
                        .link: normalizedURL,
                        CustomTextView.explicitLinkAttribute: true
                    ]
                    let attributed = NSAttributedString(string: trimmedText, attributes: attrs)
                    textView.textStorage?.replaceCharacters(in: selected, with: attributed)
                    textView.setSelectedRange(NSRange(location: selected.location + trimmedText.utf16.count, length: 0))
                } else {
                    textView.textStorage?.addAttributes(
                        [
                            .link: normalizedURL,
                            CustomTextView.explicitLinkAttribute: true
                        ],
                        range: selected
                    )
                    textView.textStorage?.removeAttribute(
                        CustomTextView.autoDetectedLinkAttribute,
                        range: selected
                    )
                }
            } else {
                let anchor = trimmedText.isEmpty ? anchorText(from: normalizedURL) : trimmedText
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize),
                    .foregroundColor: (textView.typingAttributes[.foregroundColor] as? NSColor) ?? Theme.editorTextNSColor,
                    .link: normalizedURL,
                    CustomTextView.explicitLinkAttribute: true
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
            performUndoableFormattingEdit(on: textView, actionName: "Strikethrough") {
                let ranges = selectedTextRanges(in: textView)
                let newValue = parent.editorState.isStrikethrough
                    ? 0
                    : NSUnderlineStyle.single.rawValue

                if !ranges.isEmpty {
                    for range in ranges {
                        textView.textStorage?.addAttribute(.strikethroughStyle, value: newValue, range: range)
                    }
                }
                textView.typingAttributes[.strikethroughStyle] = newValue
            }
        }

        private func applyFontStyle(_ style: EditorFontStyle) {
            guard let textView = self.textView else { return }
            performUndoableFormattingEdit(on: textView, actionName: "Font Style") {
                let ranges = selectedTextRanges(in: textView)

                if !ranges.isEmpty, let textStorage = textView.textStorage {
                    for selected in ranges {
                        textStorage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                            let current = (value as? NSFont) ?? (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                            textStorage.addAttribute(.font, value: self.font(for: style, basedOn: current), range: range)
                        }
                    }
                } else {
                    let current = (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                    textView.typingAttributes[.font] = font(for: style, basedOn: current)
                }
            }
        }

        private func font(for style: EditorFontStyle, basedOn current: NSFont) -> NSFont {
            let size = current.pointSize
            let traits = current.fontDescriptor.symbolicTraits
            let base: NSFont
            switch style {
            case .system:
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
            performUndoableFormattingEdit(on: textView, actionName: "Font Size") {
                let ranges = selectedTextRanges(in: textView)

                func resized(_ font: NSFont) -> NSFont {
                    let currentSize = font.pointSize
                    let target = defaultSize ?? max(11, min(28, currentSize + (delta ?? 0)))
                    return NSFont(descriptor: font.fontDescriptor, size: target) ?? font
                }

                if !ranges.isEmpty, let textStorage = textView.textStorage {
                    for selected in ranges {
                        textStorage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                            let current = (value as? NSFont)
                                ?? (textView.typingAttributes[.font] as? NSFont)
                                ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                            textStorage.addAttribute(.font, value: resized(current), range: range)
                        }
                    }
                } else {
                    let current = (textView.typingAttributes[.font] as? NSFont)
                        ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                    textView.typingAttributes[.font] = resized(current)
                }
            }
        }

        private func toggleBold() {
            toggleFontTrait(.boldFontMask, enable: !parent.editorState.isBold)
        }

        private func toggleItalic() {
            toggleFontTrait(.italicFontMask, enable: !parent.editorState.isItalic)
        }

        private func toggleUnderline() {
            guard let textView = self.textView else { return }
            performUndoableFormattingEdit(on: textView, actionName: "Underline") {
                let ranges = selectedTextRanges(in: textView)
                let newValue = parent.editorState.isUnderline ? 0 : NSUnderlineStyle.single.rawValue

                if !ranges.isEmpty {
                    for range in ranges {
                        textView.textStorage?.addAttribute(.underlineStyle, value: newValue, range: range)
                    }
                }
                textView.typingAttributes[.underlineStyle] = newValue
            }
        }

        private func toggleFontTrait(_ trait: NSFontTraitMask, enable: Bool) {
            guard let textView = self.textView else { return }
            performUndoableFormattingEdit(on: textView, actionName: "Font Trait") {
                let ranges = selectedTextRanges(in: textView)
                let fontManager = NSFontManager.shared

                if !ranges.isEmpty, let textStorage = textView.textStorage {
                    for selected in ranges {
                        textStorage.enumerateAttribute(.font, in: selected, options: []) { value, range, _ in
                            let current = (value as? NSFont)
                                ?? (textView.typingAttributes[.font] as? NSFont)
                                ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                            let updated = enable
                                ? (fontManager.convert(current, toHaveTrait: trait) as NSFont? ?? current)
                                : (fontManager.convert(current, toNotHaveTrait: trait) as NSFont? ?? current)
                            textStorage.addAttribute(.font, value: updated, range: range)
                        }
                    }
                } else {
                    let current = (textView.typingAttributes[.font] as? NSFont)
                        ?? NSFont.systemFont(ofSize: CustomTextView.editorFontSize)
                    let updated = enable
                        ? (fontManager.convert(current, toHaveTrait: trait) as NSFont? ?? current)
                        : (fontManager.convert(current, toNotHaveTrait: trait) as NSFont? ?? current)
                    textView.typingAttributes[.font] = updated
                }
            }
        }

        private func performUndoableFormattingEdit(
            on textView: NSTextView,
            actionName: String,
            edit: () -> Void
        ) {
            guard let textStorage = textView.textStorage else { return }
            let ranges = selectedTextRanges(in: textView)
            let beforeSnapshots = ranges.map { textStorage.attributedSubstring(from: $0) }
            let beforeTypingAttributes = textView.typingAttributes

            textView.undoManager?.beginUndoGrouping()
            edit()
            let afterSnapshots = ranges.map { textStorage.attributedSubstring(from: $0) }
            let afterTypingAttributes = textView.typingAttributes

            if !ranges.isEmpty || !NSDictionary(dictionary: beforeTypingAttributes).isEqual(to: afterTypingAttributes) {
                textView.undoManager?.registerUndo(withTarget: self) { target in
                    target.applyFormattingSnapshot(
                        on: textView,
                        ranges: ranges,
                        snapshots: beforeSnapshots,
                        typingAttributes: beforeTypingAttributes,
                        redoSnapshots: afterSnapshots,
                        redoTypingAttributes: afterTypingAttributes
                    )
                }
                textView.undoManager?.setActionName(actionName)
            }
            textView.undoManager?.endUndoGrouping()
            saveState()
        }

        private func applyFormattingSnapshot(
            on textView: NSTextView,
            ranges: [NSRange],
            snapshots: [NSAttributedString],
            typingAttributes: [NSAttributedString.Key: Any],
            redoSnapshots: [NSAttributedString],
            redoTypingAttributes: [NSAttributedString.Key: Any]
        ) {
            guard let textStorage = textView.textStorage else { return }

            textView.undoManager?.beginUndoGrouping()
            for (index, range) in ranges.enumerated().reversed() where index < snapshots.count {
                textStorage.replaceCharacters(in: range, with: snapshots[index])
                textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
            }
            textView.typingAttributes = typingAttributes

            textView.undoManager?.registerUndo(withTarget: self) { target in
                target.applyFormattingSnapshot(
                    on: textView,
                    ranges: ranges,
                    snapshots: redoSnapshots,
                    typingAttributes: redoTypingAttributes,
                    redoSnapshots: snapshots,
                    redoTypingAttributes: typingAttributes
                )
            }
            textView.undoManager?.endUndoGrouping()
            saveState()
        }

        private func selectedTextRanges(in textView: NSTextView) -> [NSRange] {
            let nsText = textView.string as NSString
            let totalLength = nsText.length
            var ranges = textView.selectedRanges.map(\.rangeValue)
            ranges = ranges.filter { range in
                range.location != NSNotFound
                    && range.location <= totalLength
                    && range.location + range.length <= totalLength
                    && range.length > 0
            }

            if ranges.isEmpty {
                let selected = textView.selectedRange()
                if selected.location != NSNotFound,
                    selected.location <= totalLength,
                    selected.location + selected.length <= totalLength,
                    selected.length > 0
                {
                    ranges = [selected]
                }
            }

            return ranges.sorted { $0.location < $1.location }
        }

        func applyAIAction(_ action: EditorAIActionRequest, to textView: NSTextView) {
            textView.window?.makeFirstResponder(textView)
            switch action.kind {
            case .replaceSelection:
                replaceSelection(
                    in: textView,
                    with: action.text,
                    preferredRange: action.targetRange,
                    attachmentPlaceholders: action.attachmentPlaceholders
                )
            case .insertBelowSelection:
                insertBelowSelection(
                    in: textView,
                    value: action.text,
                    preferredRange: action.targetRange,
                    attachmentPlaceholders: action.attachmentPlaceholders
                )
            }
            saveState()
            updateSelectionText(for: textView)
        }

        func updateSelectionText(for textView: NSTextView) {
            let selected = textView.selectedRange()
            let nsText = textView.string as NSString
            let selectedString: String

            if selected.length > 0, selected.location + selected.length <= nsText.length {
                selectedString = nsText.substring(with: selected)
            } else {
                selectedString = ""
            }

            DispatchQueue.main.async {
                if self.parent.selectedText != selectedString {
                    self.parent.selectedText = selectedString
                }
                if self.parent.selectedRange != selected {
                    self.parent.selectedRange = selected
                }
            }
        }

        private func replaceSelection(
            in textView: NSTextView,
            with value: String,
            preferredRange: NSRange?,
            attachmentPlaceholders: [EditorAIAttachmentPlaceholder]
        ) {
            let fallback = textView.selectedRange()
            let selection: NSRange
            if let preferredRange,
               preferredRange.location != NSNotFound,
               preferredRange.length > 0,
               preferredRange.location + preferredRange.length <= (textView.string as NSString).length {
                selection = preferredRange
            } else {
                selection = fallback
            }
            guard selection.length > 0 else { return }
            let attributed = attributedText(
                from: value,
                textView: textView,
                attachmentPlaceholders: attachmentPlaceholders
            )
            if applyNonDestructiveColorUpdateIfPossible(
                in: textView,
                selection: selection,
                replacement: attributed
            ) {
                textView.setSelectedRange(NSRange(location: selection.location + selection.length, length: 0))
                if let customTextView = textView as? CustomTextView {
                    customTextView.resetTypingAttributesForCurrentSelection()
                }
                return
            }
            applyTextEdit(in: textView, range: selection, replacement: attributed)
            let cursor = selection.location + attributed.length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            if let customTextView = textView as? CustomTextView {
                customTextView.resetTypingAttributesForCurrentSelection()
            }
        }

        private func insertBelowSelection(
            in textView: NSTextView,
            value: String,
            preferredRange: NSRange?,
            attachmentPlaceholders: [EditorAIAttachmentPlaceholder]
        ) {
            let nsText = textView.string as NSString
            let fallback = textView.selectedRange()
            let selection: NSRange
            if let preferredRange,
               preferredRange.location != NSNotFound,
               preferredRange.location + preferredRange.length <= nsText.length {
                selection = preferredRange
            } else {
                selection = fallback
            }
            let baseLocation = selection.length > 0 ? selection.location + selection.length : selection.location
            let safeProbe = max(0, min(baseLocation, max(0, nsText.length - 1)))
            let lineRange = nsText.length == 0
                ? NSRange(location: 0, length: 0)
                : nsText.lineRange(for: NSRange(location: safeProbe, length: 0))
            let insertionLocation = nsText.length == 0 ? 0 : lineRange.location + lineRange.length

            var insertionText = value.trimmingCharacters(in: .newlines)
            if !insertionText.isEmpty, insertionLocation > 0 {
                let previous = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
                if previous != "\n" {
                    insertionText = "\n" + insertionText
                }
            }

            let attributed = attributedText(
                from: insertionText,
                textView: textView,
                attachmentPlaceholders: attachmentPlaceholders
            )
            applyTextEdit(
                in: textView,
                range: NSRange(location: insertionLocation, length: 0),
                replacement: attributed
            )
            textView.setSelectedRange(NSRange(location: insertionLocation + attributed.length, length: 0))
            if let customTextView = textView as? CustomTextView {
                customTextView.resetTypingAttributesForCurrentSelection()
            }
        }

        private func applyTextEdit(
            in textView: NSTextView,
            range: NSRange,
            replacement: NSAttributedString
        ) {
            guard let textStorage = textView.textStorage else { return }
            if let customTextView = textView as? CustomTextView {
                customTextView.registerPendingEdit(
                    affectedRange: range,
                    replacementString: replacement.string
                )
            }
            guard textView.shouldChangeText(in: range, replacementString: replacement.string) else {
                return
            }
            textStorage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }

        private func attributedText(
            from value: String,
            textView: NSTextView,
            attachmentPlaceholders: [EditorAIAttachmentPlaceholder]
        ) -> NSAttributedString {
            if let richText = attributedHTMLText(
                from: value,
                textView: textView,
                attachmentPlaceholders: attachmentPlaceholders
            ) {
                return richText
            }
            if !attachmentPlaceholders.isEmpty {
                let mutable = NSMutableAttributedString(
                    string: value,
                    attributes: defaultTypingAttributes(for: textView)
                )
                injectAttachmentPlaceholders(
                    into: mutable,
                    placeholders: attachmentPlaceholders
                )
                return mutable
            }
            let attrs = defaultTypingAttributes(for: textView)
            return NSAttributedString(string: value, attributes: attrs)
        }

        private func defaultTypingAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            if let _ = textView.typingAttributes[.font] as? NSFont {
                var attrs = textView.typingAttributes
                attrs.removeValue(forKey: .link)
                attrs.removeValue(forKey: CustomTextView.explicitLinkAttribute)
                return attrs
            }
            return [
                .font: NSFont.monospacedSystemFont(
                    ofSize: CustomTextView.editorFontSize,
                    weight: .regular
                ),
                .foregroundColor: Theme.editorTextNSColor
            ]
        }

        private func attributedHTMLText(
            from value: String,
            textView: NSTextView,
            attachmentPlaceholders: [EditorAIAttachmentPlaceholder]
        ) -> NSAttributedString? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard containsHTMLMarkup(trimmed) else { return nil }
            guard let data = trimmed.data(using: .utf8) else { return nil }

            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            guard let parsed = try? NSMutableAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            ),
            parsed.length > 0 else {
                return fallbackSimpleColorHTML(
                    from: trimmed,
                    textView: textView,
                    attachmentPlaceholders: attachmentPlaceholders
                )
            }

            normalizeAIAttributedText(parsed, textView: textView)
            injectAttachmentPlaceholders(into: parsed, placeholders: attachmentPlaceholders)
            return parsed
        }

        private func containsHTMLMarkup(_ value: String) -> Bool {
            guard value.contains("<"), value.contains(">") else { return false }
            return value.range(of: #"<\s*/?\s*[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
        }

        private func fallbackSimpleColorHTML(
            from html: String,
            textView: NSTextView,
            attachmentPlaceholders: [EditorAIAttachmentPlaceholder]
        ) -> NSAttributedString? {
            let plain = html.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
            guard !plain.isEmpty else { return nil }

            let mutable = NSMutableAttributedString(
                string: plain,
                attributes: defaultTypingAttributes(for: textView)
            )
            if let color = cssColor(from: html) {
                mutable.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: 0, length: mutable.length)
                )
            }
            injectAttachmentPlaceholders(into: mutable, placeholders: attachmentPlaceholders)
            return mutable
        }

        private func cssColor(from html: String) -> NSColor? {
            guard let match = html.range(
                of: #"(?i)color\s*:\s*([^;\"'>]+)"#,
                options: .regularExpression
            ) else { return nil }
            let fragment = String(html[match])
            guard let valueRange = fragment.range(
                of: #"(?i)color\s*:\s*"#,
                options: .regularExpression
            ) else { return nil }
            let raw = fragment[valueRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if raw == "red" { return .systemRed }
            if raw == "green" { return .systemGreen }
            if raw == "blue" { return .systemBlue }
            if raw == "yellow" { return .systemYellow }
            if raw == "white" { return .white }
            if raw == "black" { return .black }

            let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            guard hex.count == 6, let rgb = Int(hex, radix: 16) else { return nil }
            let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
            let blue = CGFloat(rgb & 0xFF) / 255.0
            return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        }

        private func normalizeAIAttributedText(_ attributed: NSMutableAttributedString, textView: NSTextView) {
            let fullRange = NSRange(location: 0, length: attributed.length)
            guard fullRange.length > 0 else { return }

            let baseAttributes = defaultTypingAttributes(for: textView)
            let baseColor = (baseAttributes[.foregroundColor] as? NSColor) ?? Theme.editorTextNSColor
            let baseFont = (baseAttributes[.font] as? NSFont) ?? NSFont.monospacedSystemFont(
                ofSize: CustomTextView.editorFontSize,
                weight: .regular
            )

            attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
                var normalized = attrs
                normalized.removeValue(forKey: .backgroundColor)
                if let sourceFont = normalized[.font] as? NSFont {
                    normalized[.font] = normalizedEditorFont(from: sourceFont, base: baseFont)
                } else {
                    normalized[.font] = baseFont
                }
                if normalized[.foregroundColor] == nil {
                    normalized[.foregroundColor] = baseColor
                }

                let paragraph = ((normalized[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                normalized[.paragraphStyle] = paragraph

                if normalized[.link] != nil {
                    normalized[CustomTextView.explicitLinkAttribute] = true
                }

                attributed.setAttributes(normalized, range: range)
            }
        }

        private func normalizedEditorFont(from source: NSFont, base: NSFont) -> NSFont {
            let fontManager = NSFontManager.shared
            var result = NSFont(descriptor: base.fontDescriptor, size: base.pointSize) ?? base
            let traits = source.fontDescriptor.symbolicTraits

            if traits.contains(.bold),
               let converted = fontManager.convert(result, toHaveTrait: .boldFontMask) as NSFont? {
                result = converted
            }
            if traits.contains(.italic),
               let converted = fontManager.convert(result, toHaveTrait: .italicFontMask) as NSFont? {
                result = converted
            }

            return result
        }

        private func injectAttachmentPlaceholders(
            into attributed: NSMutableAttributedString,
            placeholders: [EditorAIAttachmentPlaceholder]
        ) {
            guard !placeholders.isEmpty else { return }
            for placeholder in placeholders {
                while true {
                    let full = NSRange(location: 0, length: attributed.length)
                    let tokenRange = (attributed.string as NSString).range(of: placeholder.token, options: [], range: full)
                    if tokenRange.location == NSNotFound { break }

                    guard let replacement = attributedStringFromAttachmentData(placeholder.attributedData) else {
                        break
                    }
                    attributed.replaceCharacters(in: tokenRange, with: replacement)
                }
            }
        }

        private func attributedStringFromAttachmentData(_ data: Data) -> NSAttributedString? {
            let rtfdOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtfd
            ]
            if let attr = try? NSAttributedString(
                data: data,
                options: rtfdOptions,
                documentAttributes: nil
            ) {
                return attr
            }

            let rtfOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
            return try? NSAttributedString(
                data: data,
                options: rtfOptions,
                documentAttributes: nil
            )
        }

        private func applyNonDestructiveColorUpdateIfPossible(
            in textView: NSTextView,
            selection: NSRange,
            replacement: NSAttributedString
        ) -> Bool {
            guard let textStorage = textView.textStorage else { return false }
            guard selection.location + selection.length <= textStorage.length else { return false }

            let existing = textStorage.attributedSubstring(from: selection)
            guard normalizedComparableText(existing.string) == normalizedComparableText(replacement.string) else {
                return false
            }

            let baseExistingColor = (existing.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? NSColor) ?? Theme.editorTextNSColor
            var hasColorInstruction = false
            replacement.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: replacement.length),
                options: []
            ) { value, range, _ in
                guard let color = value as? NSColor else { return }
                if areColorsEquivalent(color, baseExistingColor) {
                    return
                }
                hasColorInstruction = true
                let target = NSRange(location: selection.location + range.location, length: range.length)
                textStorage.addAttribute(.foregroundColor, value: color, range: target)
            }

            guard hasColorInstruction else { return false }
            textView.didChangeText()
            return true
        }

        private func normalizedComparableText(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func areColorsEquivalent(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
            guard let l = lhs.usingColorSpace(.deviceRGB),
                  let r = rhs.usingColorSpace(.deviceRGB) else { return false }
            let tolerance: CGFloat = 0.02
            return abs(l.redComponent - r.redComponent) <= tolerance
                && abs(l.greenComponent - r.greenComponent) <= tolerance
                && abs(l.blueComponent - r.blueComponent) <= tolerance
                && abs(l.alphaComponent - r.alphaComponent) <= tolerance
        }
        
        func saveState() {
            guard let textView = self.textView else { return }
            updateFormattingState(for: textView)
            updateSelectionText(for: textView)
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges(noteID: parent.note.id)
            if let noteID = currentNoteID {
                captureViewportState(for: noteID, in: textView)
            }
        }

        func captureViewportState(for noteID: UUID, in textView: NSTextView) {
            let verticalOffset = scrollView?.contentView.bounds.origin.y ?? 0
            noteViewportState[noteID] = EditorViewportState(
                selectedRange: textView.selectedRange(),
                verticalOffset: verticalOffset
            )
        }

        func restoreViewportState(for noteID: UUID, in textView: NSTextView) {
            let length = textView.textStorage?.length ?? 0
            if let saved = noteViewportState[noteID], saved.selectedRange.location != NSNotFound {
                let clampedLocation = min(max(0, saved.selectedRange.location), length)
                let maxLength = max(0, length - clampedLocation)
                let clampedLength = min(saved.selectedRange.length, maxLength)
                let restoredRange = NSRange(location: clampedLocation, length: clampedLength)
                textView.setSelectedRange(restoredRange)

                if let scrollView {
                    let clip = scrollView.contentView
                    let maxY = max(0, textView.bounds.height - clip.bounds.height)
                    let targetY = min(max(0, saved.verticalOffset), maxY)
                    clip.scroll(to: NSPoint(x: 0, y: targetY))
                    scrollView.reflectScrolledClipView(clip)
                } else {
                    textView.scrollRangeToVisible(restoredRange)
                }

                return
            }

            textView.setSelectedRange(NSRange(location: length, length: 0))
        }

        private func insertDiffTableTemplate() {
            guard let textView = self.textView as? CustomTextView else { return }
            guard textView.insertDiffTemplateTable() else { return }
            saveState()
        }

        private func addRowInCurrentTable() {
            guard let textView = self.textView as? CustomTextView else { return }
            guard textView.addRowToCurrentTable() else { return }
            saveState()
        }

        private func removeRowInCurrentTable() {
            guard let textView = self.textView as? CustomTextView else { return }
            guard textView.removeRowFromCurrentTable() else { return }
            saveState()
        }

        private func insertTable(rows: Int, columns: Int) {
            guard let textView = self.textView as? CustomTextView else { return }
            guard textView.insertNewTable(rows: rows, columns: columns) else { return }
            saveState()
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
            
            let checkStr = CustomTextView.uncheckedCheckboxMarker
            let checkedStr = CustomTextView.checkedCheckboxMarker
            let legacyCheckedStr = CustomTextView.legacyCheckedCheckboxMarker
            
            for lineRange in lineRanges.reversed() {
                let lineString = text.substring(with: lineRange)
                let trimmed = lineString.trimmingCharacters(in: .whitespaces)
                let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\t" }))
                let bulletForLevel = CustomTextView.bulletMarker(forLeadingWhitespace: leadingWhitespace)
                let existingBullet = CustomTextView.bulletMarkerPrefix(in: trimmed)
                
                if isCheckbox {
                    if trimmed.hasPrefix(checkStr) {
                        let markerLocation = lineRange.location + leadingWhitespace.utf16.count
                        textView.insertText(
                            checkedStr,
                            replacementRange: NSRange(
                                location: markerLocation,
                                length: checkStr.utf16.count
                            )
                        )
                        styleCheckboxMarker(in: textView, markerLocation: markerLocation, checked: true)
                    } else if trimmed.hasPrefix(checkedStr) || trimmed.hasPrefix(legacyCheckedStr) {
                        let markerLocation = lineRange.location + leadingWhitespace.utf16.count
                        textView.insertText(
                            checkStr,
                            replacementRange: NSRange(
                                location: markerLocation,
                                length: trimmed.hasPrefix(checkedStr) ? checkedStr.utf16.count : legacyCheckedStr.utf16.count
                            )
                        )
                        styleCheckboxMarker(in: textView, markerLocation: markerLocation, checked: false)
                    } else if let bullet = existingBullet {
                        let markerLocation = lineRange.location + leadingWhitespace.utf16.count
                        textView.insertText(
                            checkStr,
                            replacementRange: NSRange(
                                location: markerLocation,
                                length: bullet.utf16.count
                            )
                        )
                        styleCheckboxMarker(in: textView, markerLocation: markerLocation, checked: false)
                    } else {
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 { continue }
                        let markerLocation = lineRange.location + leadingWhitespace.utf16.count
                        textView.insertText(
                            checkStr,
                            replacementRange: NSRange(location: markerLocation, length: 0)
                        )
                        styleCheckboxMarker(in: textView, markerLocation: markerLocation, checked: false)
                    }
                } else {
                    if let bullet = existingBullet {
                        textView.insertText("", replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: bullet.utf16.count))
                    } else if trimmed.hasPrefix("- ") {
                        textView.insertText(bulletForLevel, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: 2))
                    } else if trimmed.hasPrefix(checkStr) {
                        textView.insertText(bulletForLevel, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: checkStr.utf16.count))
                    } else if trimmed.hasPrefix(checkedStr) || trimmed.hasPrefix(legacyCheckedStr) {
                        let markerLength = trimmed.hasPrefix(checkedStr) ? checkedStr.utf16.count : legacyCheckedStr.utf16.count
                        textView.insertText(bulletForLevel, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: markerLength))
                    } else {
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 { continue }
                        textView.insertText(bulletForLevel, replacementRange: NSRange(location: lineRange.location + leadingWhitespace.utf16.count, length: 0))
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

        private func styleCheckboxMarker(
            in textView: NSTextView,
            markerLocation: Int,
            checked: Bool
        ) {
            guard let textStorage = textView.textStorage, textStorage.length > 0 else { return }
            guard markerLocation >= 0, markerLocation < textStorage.length else { return }

            let markerRange = NSRange(location: markerLocation, length: 1)
            let font = checkboxMarkerFont(in: textView, markerLocation: markerLocation)
            textStorage.addAttribute(.font, value: font, range: markerRange)
            textStorage.addAttribute(
                .foregroundColor,
                value: checked ? NSColor.systemGreen : Theme.editorTextNSColor,
                range: markerRange
            )
        }

        private func checkboxMarkerFont(in textView: NSTextView, markerLocation: Int) -> NSFont {
            guard let textStorage = textView.textStorage, textStorage.length > 0 else {
                return NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize + 2, weight: .regular)
            }

            let probeLocation = min(textStorage.length - 1, markerLocation + 2)
            if probeLocation >= 0,
               let lineFont = textStorage.attribute(.font, at: probeLocation, effectiveRange: nil) as? NSFont {
                let targetSize = max(lineFont.pointSize + 2, CustomTextView.editorFontSize + 1)
                return NSFont(descriptor: lineFont.fontDescriptor, size: targetSize) ?? lineFont
            }
            if let typingFont = textView.typingAttributes[.font] as? NSFont {
                let targetSize = max(typingFont.pointSize + 2, CustomTextView.editorFontSize + 1)
                return NSFont(descriptor: typingFont.fontDescriptor, size: targetSize) ?? typingFont
            }
            return NSFont.monospacedSystemFont(ofSize: CustomTextView.editorFontSize + 2, weight: .regular)
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            // Prevent checked-checkbox green from leaking into newly typed text.
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = Theme.editorTextNSColor
            }
            updateFormattingState(for: textView)
            parent.note.update(with: textView.attributedString())
            updateSelectionText(for: textView)
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
            if let noteID = currentNoteID {
                captureViewportState(for: noteID, in: textView)
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
                of: #"^\s*(?:[-*•]+|\d+[.)]|[☐☑✓]|#+)\s+"#,
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
            if !isNormalizingSelectionRange,
               let normalized = normalizedSelectionRangeRemovingTrailingWhitespace(in: textView),
               normalized != textView.selectedRange() {
                isNormalizingSelectionRange = true
                textView.setSelectedRange(normalized)
                isNormalizingSelectionRange = false
            }
            if let customTextView = textView as? CustomTextView {
                if textView.selectedRange().length == 0 {
                    customTextView.resetTypingAttributesForCurrentSelection()
                }
                customTextView.refreshImageChrome()
            }
            updateFormattingState(for: textView)
            updateSelectionText(for: textView)
            if let noteID = currentNoteID {
                captureViewportState(for: noteID, in: textView)
            }
        }

        private func normalizedSelectionRangeRemovingTrailingWhitespace(in textView: NSTextView) -> NSRange? {
            let selected = textView.selectedRange()
            guard selected.location != NSNotFound, selected.length > 0 else { return nil }
            let nsText = textView.string as NSString
            guard selected.location + selected.length <= nsText.length else { return nil }

            var start = selected.location
            var end = selected.location + selected.length
            while start < end {
                let scalar = UnicodeScalar(nsText.character(at: start))
                if let scalar, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    start += 1
                } else {
                    break
                }
            }
            while end > selected.location {
                let scalar = UnicodeScalar(nsText.character(at: end - 1))
                if let scalar, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    end -= 1
                } else {
                    break
                }
            }

            let trimmedLength = end - start
            guard trimmedLength > 0 else { return nil }
            if start == selected.location && trimmedLength == selected.length { return nil }
            return NSRange(location: start, length: trimmedLength)
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
            var fontStyle: EditorFontStyle = .system
            
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
                if traits.contains(.monoSpace) || font.fontName.lowercased().contains("mono") || font.fontName.lowercased().contains("menlo") {
                    fontStyle = .mono
                } else if font.familyName?.lowercased().contains("times") == true || font.fontName.lowercased().contains("serif") {
                    fontStyle = .serif
                } else {
                    fontStyle = .system
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
                if CustomTextView.bulletMarkerPrefix(in: trimmed) != nil { isBullet = true }
                else if trimmed.hasPrefix(CustomTextView.uncheckedCheckboxMarker)
                    || trimmed.hasPrefix(CustomTextView.checkedCheckboxMarker)
                    || trimmed.hasPrefix(CustomTextView.legacyCheckedCheckboxMarker) { isCheckbox = true }
            }

            let activeColor: NSColor = {
                if let color = attrs[.foregroundColor] as? NSColor, color != NSColor.systemGreen {
                    return color
                }
                return Theme.editorTextNSColor
            }()
            
            DispatchQueue.main.async {
                let hasSelection = textView.selectedRange().length > 0
                let newState = EditorState(
                    isBold: isBold,
                    isItalic: isItalic,
                    isUnderline: isUnderline,
                    isStrikethrough: isStrikethrough,
                    isBullet: isBullet,
                    isCheckbox: isCheckbox,
                    fontStyle: fontStyle,
                    hasSelection: hasSelection
                )
                if self.parent.editorState != newState {
                    self.parent.editorState = newState
                }
                self.parent.activeEditorColor = activeColor
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let customTextView = textView as? CustomTextView {
                customTextView.registerPendingEdit(affectedRange: affectedCharRange, replacementString: replacementString)
            }
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
                    let isListMarker = (marker == "•" || marker == "-" || marker == "☐" || marker == "☑" || marker == "✓") && markerSpacer == " "
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

            // Keep "- " at top-level, but convert nested "- " to dot bullets for that level.
            if replacement == " " {
                let text = textView.string as NSString
                let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
                let beforeCursorLength = max(0, affectedCharRange.location - lineRange.location)
                let beforeCursor = text.substring(with: NSRange(location: lineRange.location, length: beforeCursorLength))

                if let dashIndex = beforeCursor.lastIndex(of: "-") {
                    let prefixBeforeDash = String(beforeCursor[..<dashIndex])
                    let suffixAfterDash = String(beforeCursor[beforeCursor.index(after: dashIndex)...])
                    let isListDashPattern = suffixAfterDash.isEmpty && prefixBeforeDash.allSatisfy { $0 == " " || $0 == "\t" }

                    if isListDashPattern, !prefixBeforeDash.isEmpty {
                        let bulletForLevel = CustomTextView.bulletMarker(forLeadingWhitespace: prefixBeforeDash)
                        let dashLocation = lineRange.location + prefixBeforeDash.utf16.count
                        textView.undoManager?.beginUndoGrouping()
                        textView.insertText(bulletForLevel, replacementRange: NSRange(location: dashLocation, length: 1))
                        textView.undoManager?.endUndoGrouping()
                        saveState()
                        return false
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
            if let bullet = CustomTextView.bulletMarkerPrefix(in: trimmedLine) { prefixToContinue = bullet }
            else if trimmedLine.hasPrefix(CustomTextView.uncheckedCheckboxMarker)
                || trimmedLine.hasPrefix(CustomTextView.checkedCheckboxMarker)
                || trimmedLine.hasPrefix(CustomTextView.legacyCheckedCheckboxMarker) {
                prefixToContinue = CustomTextView.uncheckedCheckboxMarker
            }
            else if trimmedLine.hasPrefix("- ") {
                prefixToContinue = leadingWhitespace.isEmpty
                    ? "- "
                    : CustomTextView.bulletMarker(forLeadingWhitespace: leadingWhitespace)
            }
            
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
                    resetTypingAttributesForNewLine(in: textView)
                    
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                } else {
                    // Continue the list automatically on the next line, preserving indent
                    textView.undoManager?.beginUndoGrouping()
                    let insertedPrefix = "\n" + leadingWhitespace + prefixToContinue
                    let insertionStart = textView.selectedRange().location
                    textView.insertText(insertedPrefix, replacementRange: textView.selectedRange())
                    textView.textStorage?.addAttribute(
                        .foregroundColor,
                        value: Theme.editorTextNSColor,
                        range: NSRange(location: insertionStart, length: insertedPrefix.utf16.count)
                    )
                    
                    // If it's a green checked dot we need to make sure the newly inserted one is white
                    let newCursor = textView.selectedRange()
                    if prefixToContinue == CustomTextView.uncheckedCheckboxMarker {
                        textView.textStorage?.addAttribute(.foregroundColor, value: Theme.editorTextNSColor, range: NSRange(location: newCursor.location - 2, length: 1))
                    }
                    resetTypingAttributesForNewLine(in: textView)
                    
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                }
            }
            
            textView.undoManager?.beginUndoGrouping()
            textView.insertText("\n", replacementRange: textView.selectedRange())
            resetTypingAttributesForNewLine(in: textView)
            textView.undoManager?.endUndoGrouping()
            saveState()
            return true
        }

        private func resetTypingAttributesForNewLine(in textView: NSTextView) {
            var attrs = textView.typingAttributes
            attrs[.foregroundColor] = Theme.editorTextNSColor
            attrs[.strikethroughStyle] = 0
            textView.typingAttributes = attrs
        }

        private func handleTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let probeLocation = max(0, min(selectedRange.location, text.length) - 1)
            let lineRange = text.lineRange(for: NSRange(location: probeLocation, length: 0))
            let lineString = text.substring(with: lineRange)
            let leadingStripped = String(lineString.drop(while: { $0 == " " || $0 == "\t" })).trimmingCharacters(in: .newlines)
            
            let isBullet = CustomTextView.bulletMarkerPrefix(in: leadingStripped) != nil
            if isBullet || leadingStripped.hasPrefix("☐") || leadingStripped.hasPrefix("☑") || leadingStripped.hasPrefix("✓") || leadingStripped.hasPrefix("-") {
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
            let isBullet = CustomTextView.bulletMarkerPrefix(in: trimmed) != nil
            guard isBullet
                    || trimmed.hasPrefix("- ")
                    || trimmed.hasPrefix(CustomTextView.uncheckedCheckboxMarker)
                    || trimmed.hasPrefix(CustomTextView.checkedCheckboxMarker)
                    || trimmed.hasPrefix(CustomTextView.legacyCheckedCheckboxMarker) else { return false }

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
