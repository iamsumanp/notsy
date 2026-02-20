import sys

path = "Sources/notsy/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

# The bug happens because we update `.foregroundColor` over a range in textStorage in `mouseDown`,
# but `textStorage.replaceCharacters` shifts things around and can infect the entire line if it's empty,
# OR typingAttributes are still picking up the green from the clicked index.

# Let's fix CustomTextView mouseDown
old_custom = """class CustomTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let characterIndex = self.characterIndexForInsertion(at: point)
        
        let text = self.string as NSString
        if characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineString = text.substring(with: lineRange)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)
            let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\\t" }))
            
            // Check if click happened directly on the circle
            let circleLocation = lineRange.location + leadingWhitespace.utf16.count
            if characterIndex == circleLocation || characterIndex == circleLocation + 1 {
                if trimmed.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    let greenDot = NSAttributedString(string: "◉", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.systemGreen
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: greenDot)
                        // Make sure the space after it is white
                        textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: circleLocation + 1, length: textStorage.length - (circleLocation + 1)))
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()
                    if let delegate = self.delegate as? RichTextEditorView.Coordinator {
                        delegate.saveState()
                    }
                    return
                } else if trimmed.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "○", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.white
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: circleLocation, length: 1), with: whiteCircle)
                        textStorage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: circleLocation + 1, length: textStorage.length - (circleLocation + 1)))
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
}"""

new_custom = """class CustomTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let characterIndex = self.characterIndexForInsertion(at: point)
        
        let text = self.string as NSString
        if characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let lineString = text.substring(with: lineRange)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)
            let leadingWhitespace = String(lineString.prefix(while: { $0 == " " || $0 == "\\t" }))
            
            // Check if click happened directly on the circle
            let circleLocation = lineRange.location + leadingWhitespace.utf16.count
            if characterIndex == circleLocation || characterIndex == circleLocation + 1 {
                if trimmed.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    let greenDot = NSAttributedString(string: "◉", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
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
                        .font: NSFont.systemFont(ofSize: 15),
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
}"""
content = content.replace(old_custom, new_custom)

# We also need to fix `func textViewDidChangeSelection` which might be resetting the color globally.
old_selection = """        func updateFormattingState(for textView: NSTextView) {
            var attrs: [NSAttributedString.Key: Any]
            
            if textView.selectedRange().length > 0 {
                attrs = textView.textStorage?.attributes(at: textView.selectedRange().location, effectiveRange: nil) ?? [:]
            } else {
                attrs = textView.typingAttributes
            }"""
            
new_selection = """        func updateFormattingState(for textView: NSTextView) {
            // Aggressively prevent green text inheritance when moving cursor
            if let fgColor = textView.typingAttributes[.foregroundColor] as? NSColor, fgColor == NSColor.systemGreen {
                textView.typingAttributes[.foregroundColor] = NSColor.white
            }
            
            var attrs: [NSAttributedString.Key: Any]
            if textView.selectedRange().length > 0 {
                attrs = textView.textStorage?.attributes(at: textView.selectedRange().location, effectiveRange: nil) ?? [:]
            } else {
                attrs = textView.typingAttributes
            }"""
content = content.replace(old_selection, new_selection)

with open(path, "w") as f:
    f.write(content)
