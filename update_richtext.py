import sys

path = "Sources/notsy/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

# Make the checked circle Green using NSAttributedString
old_check_insert = """                if lineString.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    self.insertText("◉", replacementRange: NSRange(location: lineRange.location, length: 1))
                    self.undoManager?.endUndoGrouping()"""

new_check_insert = """                if lineString.hasPrefix("○ ") {
                    self.undoManager?.beginUndoGrouping()
                    let greenDot = NSAttributedString(string: "◉", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.systemGreen
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: greenDot)
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()"""

content = content.replace(old_check_insert, new_check_insert)


old_uncheck_insert = """                } else if lineString.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    self.insertText("○", replacementRange: NSRange(location: lineRange.location, length: 1))
                    self.undoManager?.endUndoGrouping()"""

new_uncheck_insert = """                } else if lineString.hasPrefix("◉ ") {
                    self.undoManager?.beginUndoGrouping()
                    let whiteCircle = NSAttributedString(string: "○", attributes: [
                        .font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: NSColor.white
                    ])
                    if let textStorage = self.textStorage {
                        textStorage.replaceCharacters(in: NSRange(location: lineRange.location, length: 1), with: whiteCircle)
                        self.didChangeText()
                    }
                    self.undoManager?.endUndoGrouping()"""
content = content.replace(old_uncheck_insert, new_uncheck_insert)


# Fix handleEnter so it tracks sub-bullets (preserves tabs/spaces before the bullet)
old_handle_enter = """        private func handleEnter(_ textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            if text.length == 0 { return false }
            
            let lineRange = text.lineRange(for: NSRange(location: max(0, selectedRange.location - 1), length: 0))
            let lineString = text.substring(with: lineRange)
            
            let bulletStr = "• "
            let checkStr = "○ "
            let checkDoneStr = "◉ "
            
            var prefixToContinue = ""
            if lineString.hasPrefix(bulletStr) { prefixToContinue = bulletStr }
            else if lineString.hasPrefix(checkStr) || lineString.hasPrefix(checkDoneStr) { prefixToContinue = checkStr }
            
            if !prefixToContinue.isEmpty {
                let trimmed = lineString.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "•" || trimmed == "○" || trimmed == "◉" {
                    // Empty list item -> Remove the list and exit out to a normal newline
                    textView.undoManager?.beginUndoGrouping()
                    let fullLineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
                    textView.insertText("", replacementRange: fullLineRange)
                    textView.insertText("\\n", replacementRange: textView.selectedRange())
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                } else {
                    // Continue the list automatically on the next line
                    textView.undoManager?.beginUndoGrouping()
                    textView.insertText("\\n" + prefixToContinue, replacementRange: textView.selectedRange())
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                }
            }
            
            return false
        }"""

new_handle_enter = """        private func handleEnter(_ textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            if text.length == 0 { return false }
            
            let lineRange = text.lineRange(for: NSRange(location: max(0, selectedRange.location - 1), length: 0))
            let lineString = text.substring(with: lineRange)
            
            // Extract any leading whitespace (tabs or spaces) for sub-bullets
            var leadingWhitespace = ""
            for char in lineString {
                if char == " " || char == "\\t" {
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
                        textView.insertText("\\n", replacementRange: textView.selectedRange())
                    }
                    
                    textView.undoManager?.endUndoGrouping()
                    saveState()
                    return true
                } else {
                    // Continue the list automatically on the next line, preserving indent
                    textView.undoManager?.beginUndoGrouping()
                    textView.insertText("\\n" + leadingWhitespace + prefixToContinue, replacementRange: textView.selectedRange())
                    
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
        }"""
content = content.replace(old_handle_enter, new_handle_enter)

# Update Tab / Shift Tab to also respect indented bullets
old_tab = """        private func handleTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            
            if lineString.hasPrefix("• ") || lineString.hasPrefix("○ ") || lineString.hasPrefix("◉ ") {
                textView.insertText("\\t", replacementRange: NSRange(location: lineRange.location, length: 0))
                return true
            }
            return false
        }"""

new_tab = """        private func handleTab(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let selectedRange = textView.selectedRange()
            let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let lineString = text.substring(with: lineRange)
            let trimmed = lineString.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("• ") || trimmed.hasPrefix("○ ") || trimmed.hasPrefix("◉ ") {
                textView.insertText("\\t", replacementRange: NSRange(location: lineRange.location, length: 0))
                return true
            }
            return false
        }"""
content = content.replace(old_tab, new_tab)

with open(path, "w") as f:
    f.write(content)
