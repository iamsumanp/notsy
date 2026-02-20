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
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let characterIndex = self.characterIndexForInsertion(at: point)
        
        let text = self.string as NSString
        if characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineString = text.substring(with: lineRange)
            
            // Check if the click happened near the beginning of the line (where the circle is)
            if characterIndex - lineRange.location <= 2 {
                if lineString.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    let greenDot = NSAttributedString(string: "◉", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.systemGreen
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: greenDot)
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator {
                        delegate.saveState()
                    }
                    return
                } else if lineString.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "○", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.white
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: whiteCircle)
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator {
                        delegate.saveState()
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
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
            .font: NSFont.systemFont(ofSize: 15), 
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
            } else if action == "list" {
                toggleList(isCheckbox: false)
            } else if action == "checkbox" {
                toggleList(isCheckbox: true)
            }
        }
        
        func saveState() {
            guard let textView = self.textView else { return }
            updateFormattingState(for: textView)
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }
        
        func toggleList(isCheckbox: Bool) {
            guard let textView = self.textView else { return }
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            
            // We need to find all paragraphs within the selected range
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
            
            // Process backwards so insertion/deletion doesn't invalidate subsequent NSRanges
            for lineRange in lineRanges.reversed() {
                let lineString = text.substring(with: lineRange)
                
                if isCheckbox {
                    if lineString.hasPrefix(checkStr) {
                        textView.insertText(checkedStr, replacementRange: NSRange(location: lineRange.location, length: checkStr.utf16.count))
                    } else if lineString.hasPrefix(checkedStr) {
                        textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: checkedStr.utf16.count))
                    } else if lineString.hasPrefix(bulletStr) {
                        textView.insertText(checkStr, replacementRange: NSRange(location: lineRange.location, length: bulletStr.utf16.count))
                    } else {
                        // Skip empty lines unless it's the only line selected
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 {
                            continue
                        }
                        textView.insertText(checkStr, replacementRange: NSRange(location: lineRange.location, length: 0))
                    }
                } else {
                    if lineString.hasPrefix(bulletStr) {
                        textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: bulletStr.utf16.count))
                    } else if lineString.hasPrefix(checkStr) {
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location, length: checkStr.utf16.count))
                    } else if lineString.hasPrefix(checkedStr) {
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location, length: checkedStr.utf16.count))
                    } else {
                        if lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lineRanges.count > 1 {
                            continue
                        }
                        textView.insertText(bulletStr, replacementRange: NSRange(location: lineRange.location, length: 0))
                    }
                }
            }
            
            textView.undoManager?.endUndoGrouping()
            
            // Restore selection around the newly modified text block
            if let first = lineRanges.first, let last = lineRanges.last {
                // Since length changed, we can just collapse cursor to the end or recalculate bounds
            }
            saveState()
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateFormattingState(for: textView)
        }
        
        func updateFormattingState(for textView: NSTextView) {
            var attrs: [NSAttributedString.Key: Any]
            
            if textView.selectedRange().length > 0 {
                attrs = textView.textStorage?.attributes(at: textView.selectedRange().location, effectiveRange: nil) ?? [:]
            } else {
                attrs = textView.typingAttributes
            }
            
            var isBold = false
            var isItalic = false
            var isUnderline = false
            var isBullet = false
            var isCheckbox = false
            
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                isBold = traits.contains(.bold)
                isItalic = traits.contains(.italic)
            }
            if let underlineStyle = attrs[.underlineStyle] as? Int, underlineStyle > 0 {
                isUnderline = true
            }
            
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let location = min(selectedRange.location, max(0, text.length))
            if text.length > 0 {
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                let lineString = text.substring(with: lineRange)
                if lineString.hasPrefix("• ") { isBullet = true }
                else if lineString.hasPrefix("○ ") || lineString.hasPrefix("◉ ") { isCheckbox = true }
            }
            
            DispatchQueue.main.async {
                let newState = EditorState(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, isBullet: isBullet, isCheckbox: isCheckbox)
                if self.parent.editorState != newState {
                    self.parent.editorState = newState
                }
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }

            // Intercept Markdown "- " and turn it into "• " natively
            if replacement == " " {
                let text = textView.string as NSString
                if affectedCharRange.location > 0 {
                    let prevCharIndex = affectedCharRange.location - 1
                    let prevChar = text.substring(with: NSRange(location: prevCharIndex, length: 1))

                    if prevChar == "-" {
                        let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
                        if lineRange.location == prevCharIndex {
                            DispatchQueue.main.async { 
                                textView.undoManager?.beginUndoGrouping()
                                textView.insertText("•", replacementRange: NSRange(location: prevCharIndex, length: 1))
                                textView.undoManager?.endUndoGrouping()
                                self.saveState()
                            }
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
            else if commandSelector == #selector(NSResponder.insertBacktab(_:)) { return handleShiftTab(textView) }
            return false
        }

        private func handleEnter(_ textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            if text.length == 0 { return false }
            
            let lineRange = text.lineRange(for: NSRange(location: max(0, selectedRange.location - 1), length: 0))
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
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            
            if lineString.hasPrefix("• ") || lineString.hasPrefix("[ ] ") || lineString.hasPrefix("[x] ") {
                textView.insertText("\t", replacementRange: NSRange(location: lineRange.location, length: 0))
                return true
            }
            return false
        }

        private func handleShiftTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            
            if lineString.hasPrefix("\t") {
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: 1))
                return true
            }
            return false
        }
    }
}
