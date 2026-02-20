import sys

path = "Sources/notebar/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

old_apply = """        private func applyBulletList(to textView: NSTextView, dashLocation: Int) {
            guard let textStorage = textView.textStorage else { return }

            textView.undoManager?.beginUndoGrouping()
            
            let dashRange = NSRange(location: dashLocation, length: 1)
            if dashRange.location < textStorage.length && textView.shouldChangeText(in: dashRange, replacementString: "") {
                textStorage.replaceCharacters(in: dashRange, with: "")
                textView.didChangeText()
            }

            let currentRange = textView.selectedRange()
            
            var pRange = NSRange(location: 0, length: 0)
            if textStorage.length > 0 {
                let location = min(currentRange.location, textStorage.length - 1)
                pRange = (textStorage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            }

            let newStyle = NSMutableParagraphStyle()
            
            if textStorage.length > 0 && pRange.location < textStorage.length {
                if let currentStyle = textStorage.attribute(.paragraphStyle, at: pRange.location, effectiveRange: nil) as? NSParagraphStyle {
                    newStyle.setParagraphStyle(currentStyle)
                }
            }

            let textList = NSTextList(markerFormat: .disc, options: 0)
            newStyle.textLists = [textList]
            newStyle.firstLineHeadIndent = 24
            newStyle.headIndent = 24
            newStyle.paragraphSpacing = 6

            if textStorage.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: newStyle, range: pRange)
            }
            
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            if typingAttributes[.foregroundColor] == nil || typingAttributes[.foregroundColor] as? NSColor == NSColor.black {
                typingAttributes[.foregroundColor] = NSColor.white
            }
            if typingAttributes[.font] == nil {
                typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
            }
            textView.typingAttributes = typingAttributes

            textView.undoManager?.endUndoGrouping()
            saveState()
        }"""

new_apply = """        private func applyBulletList(to textView: NSTextView, dashLocation: Int) {
            textView.undoManager?.beginUndoGrouping()
            
            let dashRange = NSRange(location: dashLocation, length: 1)
            
            // By using insertText, NSTextView natively handles the deletion, updates selection,
            // and maintains layout manager state, preventing the "invisible" bug.
            textView.insertText("", replacementRange: dashRange)
            
            // Now just trigger the standard toggle list logic so it applies to the current paragraph
            toggleList(format: .disc)
            
            textView.undoManager?.endUndoGrouping()
        }"""
        
content = content.replace(old_apply, new_apply)

old_toggle = """        func toggleList(format: NSTextList.MarkerFormat) {
            guard let textView = self.textView, let textStorage = textView.textStorage else { return }
            
            textView.undoManager?.beginUndoGrouping()
            
            let currentRange = textView.selectedRange()
            let pRange = (textStorage.string as NSString).paragraphRange(for: currentRange)
            let newStyle = NSMutableParagraphStyle()
            var hasMatchingList = false
            
            if textStorage.length > 0 && pRange.location < textStorage.length {
                if let currentStyle = textStorage.attribute(.paragraphStyle, at: pRange.location, effectiveRange: nil) as? NSParagraphStyle {
                    newStyle.setParagraphStyle(currentStyle)
                    if let list = currentStyle.textLists.first, list.markerFormat == format {
                        hasMatchingList = true
                    }
                }
            }
            
            if hasMatchingList {
                newStyle.textLists = []
                newStyle.firstLineHeadIndent = 0
                newStyle.headIndent = 0
            } else {
                let textList = NSTextList(markerFormat: format, options: 0)
                newStyle.textLists = [textList]
                newStyle.firstLineHeadIndent = 24
                newStyle.headIndent = 24
                newStyle.paragraphSpacing = 6
            }
            
            if textStorage.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: newStyle, range: pRange)
            }
            
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            textView.typingAttributes = typingAttributes
            
            textView.undoManager?.endUndoGrouping()
            saveState()
        }"""
        
new_toggle = """        func toggleList(format: NSTextList.MarkerFormat) {
            guard let textView = self.textView, let textStorage = textView.textStorage else { return }
            
            textView.undoManager?.beginUndoGrouping()
            
            let currentRange = textView.selectedRange()
            var pRange = NSRange(location: 0, length: 0)
            if textStorage.length > 0 {
                let safeLocation = min(currentRange.location, textStorage.length - 1)
                pRange = (textStorage.string as NSString).paragraphRange(for: NSRange(location: safeLocation, length: 0))
            }
            
            let newStyle = NSMutableParagraphStyle()
            var hasMatchingList = false
            
            // Check existing style either from text or typing attributes if empty
            if textStorage.length > 0 && pRange.location < textStorage.length {
                if let currentStyle = textStorage.attribute(.paragraphStyle, at: pRange.location, effectiveRange: nil) as? NSParagraphStyle {
                    newStyle.setParagraphStyle(currentStyle)
                    if let list = currentStyle.textLists.first, list.markerFormat == format {
                        hasMatchingList = true
                    }
                }
            } else {
                if let currentStyle = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle {
                    newStyle.setParagraphStyle(currentStyle)
                    if let list = currentStyle.textLists.first, list.markerFormat == format {
                        hasMatchingList = true
                    }
                }
            }
            
            if hasMatchingList {
                newStyle.textLists = []
                newStyle.firstLineHeadIndent = 0
                newStyle.headIndent = 0
            } else {
                let textList = NSTextList(markerFormat: format, options: 0)
                newStyle.textLists = [textList]
                newStyle.firstLineHeadIndent = 24
                newStyle.headIndent = 24
                newStyle.paragraphSpacing = 6
            }
            
            if textStorage.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: newStyle, range: pRange)
            }
            
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            if typingAttributes[.foregroundColor] == nil || typingAttributes[.foregroundColor] as? NSColor == NSColor.black {
                typingAttributes[.foregroundColor] = NSColor.white
            }
            if typingAttributes[.font] == nil {
                typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
            }
            textView.typingAttributes = typingAttributes
            
            textView.undoManager?.endUndoGrouping()
            saveState()
        }"""
content = content.replace(old_toggle, new_toggle)

with open(path, "w") as f:
    f.write(content)

