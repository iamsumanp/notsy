import sys

path = "Sources/notebar/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

# Update RichTextEditorView signature and Coordinator
if "@Binding var editorState: EditorState" not in content:
    content = content.replace("var note: Note\n    var store: NoteStore", "var note: Note\n    var store: NoteStore\n    @Binding var editorState: EditorState")

old_delegate = "class Coordinator: NSObject, NSTextViewDelegate {"
new_delegate = "class Coordinator: NSObject, NSTextViewDelegate {"

# Add textViewDidChangeSelection to track formatting
old_textDidChange = """        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }"""
        
new_textDidChange = """        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateFormattingState(for: textView)
        }
        
        private func updateFormattingState(for textView: NSTextView) {
            var attrs: [NSAttributedString.Key: Any]
            
            if textView.selectedRange().length > 0 {
                // Get attributes of the first character in selection
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
            
            if let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle, let list = paragraphStyle.textLists.first {
                if list.markerFormat == .disc {
                    isBullet = true
                } else if list.markerFormat == .box {
                    isCheckbox = true
                }
            }
            
            DispatchQueue.main.async {
                let newState = EditorState(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, isBullet: isBullet, isCheckbox: isCheckbox)
                if self.parent.editorState != newState {
                    self.parent.editorState = newState
                }
            }
        }"""
content = content.replace(old_textDidChange, new_textDidChange)

# Ensure toolbar changes immediately update the state
old_savestate = """        func saveState() {
            guard let textView = self.textView else { return }
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }"""
new_savestate = """        func saveState() {
            guard let textView = self.textView else { return }
            updateFormattingState(for: textView)
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }"""
content = content.replace(old_savestate, new_savestate)

# Fix bullet list creation error (dash + space disappearing instead of turning into bullet)
old_bullet_apply = """        private func applyBulletList(to textView: NSTextView, dashLocation: Int) {
            guard let textStorage = textView.textStorage else { return }

            textView.undoManager?.beginUndoGrouping()
            let dashRange = NSRange(location: dashLocation, length: 1)
            if dashRange.location < textStorage.length && textView.shouldChangeText(in: dashRange, replacementString: "") {
                textStorage.replaceCharacters(in: dashRange, with: "")
                textView.didChangeText()
            }

            let currentRange = textView.selectedRange()
            let pRange = (textStorage.string as NSString).paragraphRange(for: currentRange)
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
            
            // Explicitly set the typing attributes so the cursor adopts the bullet list style
            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            textView.typingAttributes = typingAttributes

            textView.undoManager?.endUndoGrouping()
            parent.note.update(with: textView.attributedString())
            parent.store.saveNoteChanges()
        }"""

new_bullet_apply = """        private func applyBulletList(to textView: NSTextView, dashLocation: Int) {
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
            textView.typingAttributes = typingAttributes

            textView.undoManager?.endUndoGrouping()
            saveState()
        }"""
content = content.replace(old_bullet_apply, new_bullet_apply)

with open(path, "w") as f:
    f.write(content)
