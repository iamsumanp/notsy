import sys

path = "Sources/notebar/UI/RichTextEditorView.swift"
with open(path, "r") as f:
    content = f.read()

# Fix applyBulletList
old_typing_apply = """            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            textView.typingAttributes = typingAttributes"""
new_typing_apply = """            var typingAttributes = textView.typingAttributes
            typingAttributes[.paragraphStyle] = newStyle
            if typingAttributes[.foregroundColor] == nil || typingAttributes[.foregroundColor] as? NSColor == NSColor.black {
                typingAttributes[.foregroundColor] = NSColor.white
            }
            if typingAttributes[.font] == nil {
                typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
            }
            textView.typingAttributes = typingAttributes"""
content = content.replace(old_typing_apply, new_typing_apply)

with open(path, "w") as f:
    f.write(content)
