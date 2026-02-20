import sys

path = "Sources/notebar/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# Add EditorState and RichTextEditorWrapper back in
# They got lost during the full file overwrite

editor_state = """
struct EditorState: Equatable {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isBullet: Bool = false
    var isCheckbox: Bool = false
}

struct RichTextEditorWrapper: View {
    let note: Note
    let store: NoteStore
    @Binding var editorState: EditorState
    @FocusState var isFocused: MainPanel.FocusField?

    var body: some View {
        RichTextEditorView(note: note, store: store, editorState: $editorState).focused($isFocused, equals: .editor)
    }
}
"""

content = content + editor_state

# Also fix the missing @State var editorState inside MainPanel
content = content.replace("@State private var selectedNoteID: UUID?", "@State private var selectedNoteID: UUID?\n    @State private var editorState = EditorState()")

with open(path, "w") as f:
    f.write(content)
