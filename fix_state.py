import sys

path = "Sources/notebar/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

old_handle = """        @objc func handleToolbarAction(_ notification: Notification) {
            guard let action = notification.userInfo?["action"] as? String,
                  let textView = self.textView,
                  textView.window?.isKeyWindow == true else { return }
            
            textView.window?.makeFirstResponder(textView)
            
            if action == "bold" {
                let sender = NSMenuItem()
                sender.tag = Int(NSFontTraitMask.unboldFontMask.rawValue)
                if self.parent.editorState.isBold {
                    NSFontManager.shared.removeFontTrait(sender)
                } else {
                    sender.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                }
                saveState()
            } else if action == "italic" {
                let sender = NSMenuItem()
                sender.tag = Int(NSFontTraitMask.unitalicFontMask.rawValue)
                if self.parent.editorState.isItalic {
                    NSFontManager.shared.removeFontTrait(sender)
                } else {
                    sender.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
                    NSFontManager.shared.addFontTrait(sender)
                }
                saveState()
            } else if action == "underline" {
                textView.underline(nil)
                saveState()
            } else if action == "list" {
                toggleList(format: .disc)
            } else if action == "checkbox" {
                toggleList(format: .box)
            }
        }"""

new_handle = """        @objc func handleToolbarAction(_ notification: Notification) {
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
                toggleList(format: .disc)
            } else if action == "checkbox" {
                toggleList(format: .box)
            }
        }"""
content = content.replace(old_handle, new_handle)

with open(path, "w") as f:
    f.write(content)
