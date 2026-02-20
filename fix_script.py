import sys

path = "Sources/notebar/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# Fix 1: Add Context Menu to NoteRowView usage, and restore .id(note.id)
old_pinned_loop = """                                        ForEach(pinnedNotes) { note in
                                            NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                                .onTapGesture {
                                                    selectedNoteID = note.id
                                                    focus = .editor
                                                }
                                        }"""
new_pinned_loop = """                                        ForEach(pinnedNotes) { note in
                                            NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                                .id(note.id)
                                                .onTapGesture {
                                                    selectedNoteID = note.id
                                                    focus = .editor
                                                }
                                                .contextMenu {
                                                    Button(action: {
                                                        withAnimation(.spring()) {
                                                            store.togglePin(for: note)
                                                        }
                                                    }) {
                                                        Text(note.pinned ? "Unpin" : "Pin")
                                                        Image(systemName: note.pinned ? "pin.slash" : "pin")
                                                    }
                                                    Button(action: {
                                                        let pasteboard = NSPasteboard.general
                                                        pasteboard.clearContents()
                                                        pasteboard.setString(note.plainTextCache, forType: .string)
                                                    }) {
                                                        Text("Copy Content")
                                                        Image(systemName: "doc.on.doc")
                                                    }
                                                    Divider()
                                                    Button(role: .destructive, action: {
                                                        withAnimation {
                                                            store.delete(note)
                                                            if selectedNoteID == note.id {
                                                                selectedNoteID = store.notes.first?.id
                                                            }
                                                        }
                                                    }) {
                                                        Text("Delete")
                                                        Image(systemName: "trash")
                                                    }
                                                }
                                        }"""
content = content.replace(old_pinned_loop, new_pinned_loop)

old_recent_loop = """                                    ForEach(recentNotes) { note in
                                        NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                            .onTapGesture {
                                                selectedNoteID = note.id
                                                focus = .editor
                                            }
                                    }"""
new_recent_loop = """                                    ForEach(recentNotes) { note in
                                        NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                            .id(note.id)
                                            .onTapGesture {
                                                selectedNoteID = note.id
                                                focus = .editor
                                            }
                                            .contextMenu {
                                                Button(action: {
                                                    withAnimation(.spring()) {
                                                        store.togglePin(for: note)
                                                    }
                                                }) {
                                                    Text(note.pinned ? "Unpin" : "Pin")
                                                    Image(systemName: note.pinned ? "pin.slash" : "pin")
                                                }
                                                Button(action: {
                                                    let pasteboard = NSPasteboard.general
                                                    pasteboard.clearContents()
                                                    pasteboard.setString(note.plainTextCache, forType: .string)
                                                }) {
                                                    Text("Copy Content")
                                                    Image(systemName: "doc.on.doc")
                                                }
                                                Divider()
                                                Button(role: .destructive, action: {
                                                    withAnimation {
                                                        store.delete(note)
                                                        if selectedNoteID == note.id {
                                                            selectedNoteID = store.notes.first?.id
                                                        }
                                                    }
                                                }) {
                                                    Text("Delete")
                                                    Image(systemName: "trash")
                                                }
                                            }
                                    }"""
content = content.replace(old_recent_loop, new_recent_loop)

# Fix 2: Make createNewNote consistently focus the editor
old_create = """    private func createNewNote(fromQuery: Bool) {
        let hasQuery = fromQuery && !queryBuffer.isEmpty
        let content = hasQuery ? queryBuffer : ""
        let newNote = Note(title: content, plainTextCache: "", createdAt: Date(), updatedAt: Date())

        let attrStr = NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        newNote.update(with: attrStr)
        store.insert(newNote)
        queryBuffer = ""
        selectedNoteID = newNote.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if hasQuery {
                focus = .editor
            } else {
                focus = .title
            }
        }
    }"""
new_create = """    private func createNewNote(fromQuery: Bool) {
        let hasQuery = fromQuery && !queryBuffer.isEmpty
        let content = hasQuery ? queryBuffer : ""
        let newNote = Note(title: content, plainTextCache: "", createdAt: Date(), updatedAt: Date())

        let attrStr = NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white])
        newNote.update(with: attrStr)
        store.insert(newNote)
        queryBuffer = ""
        selectedNoteID = newNote.id

        // Increase delay slightly to ensure NSViewRepresentable is fully mounted before focusing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focus = .editor
        }
    }"""
content = content.replace(old_create, new_create)

old_onchange = """                                .onChange(of: queryBuffer) { oldVal, newVal in
                                    if let first = filteredNotes.first {
                                        selectedNoteID = first.id
                                    }
                                }"""
new_onchange = """                                .onChange(of: queryBuffer) { oldVal, newVal in
                                    if !newVal.isEmpty, let first = filteredNotes.first {
                                        if selectedNoteID != first.id {
                                            selectedNoteID = first.id
                                        }
                                    }
                                }"""
content = content.replace(old_onchange, new_onchange)

with open(path, "w") as f:
    f.write(content)

print("Done")
