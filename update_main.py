import sys

path = "Sources/notebar/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# 1. Fix double selection (For real this time)
# In SidebarView, NoteRowView `.id()` must be globally unique per RENDER instance so SwiftUI doesn't get confused 
# when moving between arrays.
old_id_pinned = """                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id(note.id)"""
new_id_pinned = """                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id("pinned-\(note.id)")"""
content = content.replace(old_id_pinned, new_id_pinned)

old_id_notes = """                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id(note.id)"""
new_id_notes = """                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id("recent-\(note.id)")"""
# The above replace will hit the 'remainingNotes' loop in the old block if it still exists. Let's be careful.

old_id_top = """                                NoteRowView(note: firstNote, isSelected: selectedNoteID == firstNote.id)
                                    .id(firstNote.id)"""
new_id_top = """                                NoteRowView(note: firstNote, isSelected: selectedNoteID == firstNote.id)
                                    .id("top-\(firstNote.id)")"""
content = content.replace(old_id_top, new_id_top)

# 2. Update Breadcrumbs to show local path
old_breadcrumb = """                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12))
                                Text("Notes")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                Text("Local")
                            }"""
new_breadcrumb = """                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 12))
                                Text("Notebar")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                Text("~/Library/Application Support/Notebar")
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                            }"""
content = content.replace(old_breadcrumb, new_breadcrumb)

# 3. Remove "Active" and "Open in Split" 
old_meta = """                        // Meta Row
                        HStack(spacing: 12) {
                            Text("Created \\(metaTimeString(from: note.createdAt))")
                            Text("•")
                            Text("\\(note.plainTextCache.split(separator: " ").count) words")
                            Text("•")
                            HStack(spacing: 4) {
                                Circle().fill(Theme.pinGold).frame(width: 8, height: 8)
                                Text("Active")
                            }
                        }"""
new_meta = """                        // Meta Row
                        HStack(spacing: 12) {
                            Text("Created \\(metaTimeString(from: note.createdAt))")
                            Text("•")
                            Text("\\(note.plainTextCache.split(separator: " ").count) words")
                        }"""
content = content.replace(old_meta, new_meta)

old_shortcuts = """            HStack {
                HStack(spacing: 16) {
                    ShortcutBadge(key: "↵", label: "Open")
                    ShortcutBadge(key: "⌘ ↵", label: "Open in Split")
                    ShortcutBadge(key: "Tab", label: "Actions")
                }"""
new_shortcuts = """            HStack {
                HStack(spacing: 16) {
                    ShortcutBadge(key: "↵", label: "Open")
                    ShortcutBadge(key: "Tab", label: "Actions")
                }"""
content = content.replace(old_shortcuts, new_shortcuts)

# 4. Integrate Toolbar directly into Editor Toolbar
# Add back the Rich Text Toolbar next to the title or inside the breadcrumbs area
old_tools = """                            HStack(spacing: 16) {
                                Button(action: { 
                                    withAnimation(.spring()) {
                                        if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                            store.togglePin(for: store.notes[idx])
                                        }
                                    }
                                }) {
                                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                                        .foregroundColor(note.pinned ? Theme.pinGold : Theme.textMuted)
                                }.buttonStyle(.plain)
                                
                                Button(action: { focus = .editor }) {
                                    Image(systemName: "pencil")
                                }.buttonStyle(.plain).foregroundColor(Theme.textMuted)
                            }"""

new_tools = """                            HStack(spacing: 4) {
                                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "bold"]) }) { 
                                    Text("B").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20).background(editorState.isBold ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "italic"]) }) { 
                                    Text("I").font(.system(size: 12, weight: .semibold).italic()).frame(width: 20, height: 20).background(editorState.isItalic ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "underline"]) }) { 
                                    Text("U").font(.system(size: 12, weight: .semibold)).underline().frame(width: 20, height: 20).background(editorState.isUnderline ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)
                                
                                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "list"]) }) { 
                                    Image(systemName: "list.bullet").font(.system(size: 10)).frame(width: 20, height: 20).background(editorState.isBullet ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "checkbox"]) }) { 
                                    Image(systemName: "checkmark.square").font(.system(size: 10)).frame(width: 20, height: 20).background(editorState.isCheckbox ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
                                }.buttonStyle(.plain)

                                Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)

                                Button(action: { 
                                    withAnimation(.spring()) {
                                        if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                            store.togglePin(for: store.notes[idx])
                                        }
                                    }
                                }) {
                                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                                        .font(.system(size: 12))
                                        .foregroundColor(note.pinned ? Theme.pinGold : Theme.textMuted)
                                        .frame(width: 20, height: 20)
                                }.buttonStyle(.plain)
                            }
                            .foregroundColor(Theme.textMuted)"""
content = content.replace(old_tools, new_tools)

# 5. Fix the space at the top. The window ignores safe area when configured properly.
old_body = """    var body: some View {
        VStack(spacing: 0) {"""
new_body = """    var body: some View {
        VStack(spacing: 0) {
            // Invisible drag area for fullSizeContentView
            Color.clear.frame(height: 24)"""
content = content.replace(old_body, new_body)

# We will actually remove the 24px invisible drag area from the visual tree and just use edgesIgnoringSafeArea.
content = content.replace("""        VStack(spacing: 0) {
            // Invisible drag area for fullSizeContentView
            Color.clear.frame(height: 24)""", """    var body: some View {
        VStack(spacing: 0) {""")

old_window_frame = """        .frame(width: 950, height: 650)
        .background(Theme.sidebarBg)"""
new_window_frame = """        .frame(width: 950, height: 650)
        .background(Theme.sidebarBg)
        .edgesIgnoringSafeArea(.all)"""
content = content.replace(old_window_frame, new_window_frame)


with open(path, "w") as f:
    f.write(content)

