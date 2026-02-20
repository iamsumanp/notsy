import AppKit
import SwiftUI

struct EditorState: Equatable {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isBullet: Bool = false
    var isCheckbox: Bool = false
}

struct MainPanel: View {
    var onClose: () -> Void
    @Environment(NoteStore.self) private var store
    @State private var queryBuffer: String = ""
    @State private var selectedNoteID: UUID?
    @State private var editorState = EditorState()
    @State private var isSidebarVisible: Bool = true

    enum FocusField: Hashable {
        case search
        case list
        case editor
        case title
    }
    @FocusState private var focus: FocusField?

    let newNotePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotebarNewNote"))
    let focusSearchPub = NotificationCenter.default.publisher(for: NSNotification.Name("NotebarFocusSearch"))

    var filteredNotes: [Note] {
        if queryBuffer.isEmpty { return store.notes }
        return store.notes.filter { note in
            note.title.localizedCaseInsensitiveContains(queryBuffer) || 
            note.plainTextCache.localizedCaseInsensitiveContains(queryBuffer)
        }
    }

    var pinnedNotes: [Note] { filteredNotes.filter { $0.pinned } }
    var recentNotes: [Note] { filteredNotes.filter { !$0.pinned } }

    var body: some View {
        VStack(spacing: 0) {
            // TOP BAR
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible.toggle()
                    }
                }) {
                    Image(systemName: isSidebarVisible ? "sidebar.left" : "sidebar.right").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textMuted)
                
                Spacer()
                Text("Notes").font(.system(size: 14, weight: .medium)).foregroundColor(Theme.textMuted)
                Spacer()
                
                Button(action: { createNewNote(fromQuery: false) }) {
                    Image(systemName: "plus.app.fill").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.bg)

            Divider().background(Theme.border)
            
            // MAIN CONTENT
            HStack(spacing: 0) {
                // LEFT PANEL (SIDEBAR)
                if isSidebarVisible {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
                            TextField("Search notes...", text: $queryBuffer)
                                .textFieldStyle(.plain)
                                .foregroundColor(Theme.text)
                                .focused($focus, equals: .search)
                                .onChange(of: queryBuffer) { oldVal, newVal in
                                    if !newVal.isEmpty, let first = filteredNotes.first {
                                        if selectedNoteID != first.id {
                                            selectedNoteID = first.id
                                        }
                                    }
                                }
                                .onSubmit { handleSearchSubmit() }
                        }
                        .padding(8)
                        .background(Theme.elementBg)
                        .cornerRadius(6)
                        .padding(16)

                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    if !pinnedNotes.isEmpty {
                                        HStack {
                                            Text("PINNED").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.textMuted)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.top, 4)
                                        .padding(.bottom, 4)
                                        
                                        ForEach(pinnedNotes) { note in
                                            NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                                
                                                .id("\(note.id)-\(note.pinned)-\(note.updatedAt.timeIntervalSince1970)")
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
                                        }
                                    }

                                    HStack {
                                        Text(pinnedNotes.isEmpty ? "NOTES" : "RECENT").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.textMuted)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                                    
                                    ForEach(recentNotes) { note in
                                        NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                            
                                            .id("\(note.id)-\(note.pinned)-\(note.updatedAt.timeIntervalSince1970)")
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
                                    }

                                    if filteredNotes.isEmpty {
                                        Button(action: { createNewNote(fromQuery: true) }) {
                                            HStack {
                                                Text(queryBuffer.isEmpty ? "Create new note" : "Create \"\(queryBuffer)\"")
                                                    .foregroundColor(Theme.selection)
                                                Spacer()
                                                Image(systemName: "plus.circle").foregroundColor(Theme.selection)
                                            }
                                            .padding(12)
                                            .background(Theme.elementBg.opacity(0.5))
                                            .cornerRadius(8)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                    }
                                }
                                .padding(.bottom, 16)
                            }
                            .focused($focus, equals: .list)
                        }
                    }
                    .frame(width: 280)
                    .background(Theme.sidebarBg)
                    .transition(.move(edge: .leading))

                    Divider().background(Theme.border)
                }

                // RIGHT PANEL (EDITOR)
                VStack(spacing: 0) {
                    if let selectedNoteID = selectedNoteID,
                       let noteIndex = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                        
                        let note = store.notes[noteIndex]
                        
                        // Editor Toolbar
                        HStack {
                            HStack(spacing: 4) {
                                Button(action: {
                                    NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "bold"])
                                }) { 
                                    Text("B").font(.system(size: 14, weight: .bold))
                                        .frame(width: 24, height: 24)
                                        .background(editorState.isBold ? Theme.selection.opacity(0.3) : Color.clear)
                                        .cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: {
                                    NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "italic"])
                                }) { 
                                    Text("I").font(.system(size: 14, weight: .semibold).italic())
                                        .frame(width: 24, height: 24)
                                        .background(editorState.isItalic ? Theme.selection.opacity(0.3) : Color.clear)
                                        .cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: {
                                    NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "underline"])
                                }) { 
                                    Text("U").font(.system(size: 14, weight: .semibold)).underline()
                                        .frame(width: 24, height: 24)
                                        .background(editorState.isUnderline ? Theme.selection.opacity(0.3) : Color.clear)
                                        .cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)
                                
                                Button(action: {
                                    NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "list"])
                                }) { 
                                    Image(systemName: "list.bullet")
                                        .frame(width: 24, height: 24)
                                        .background(editorState.isBullet ? Theme.selection.opacity(0.3) : Color.clear)
                                        .cornerRadius(4)
                                }.buttonStyle(.plain)
                                
                                Button(action: {
                                    NotificationCenter.default.post(name: NSNotification.Name("NotebarToolbarAction"), object: nil, userInfo: ["action": "checkbox"])
                                }) { 
                                    Image(systemName: "checkmark.square")
                                        .frame(width: 24, height: 24)
                                        .background(editorState.isCheckbox ? Theme.selection.opacity(0.3) : Color.clear)
                                        .cornerRadius(4)
                                }.buttonStyle(.plain)
                            }
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.elementBg)
                            .cornerRadius(6)
                            
                            Spacer()
                            
                            Text("\(note.plainTextCache.count) chars")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.border)
                                .padding(.trailing, 12)
                            
                            Button(action: { 
                                withAnimation(.spring()) {
                                    if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                        store.togglePin(for: store.notes[idx])
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "pin.fill")
                                    Text("Pinned")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(note.pinned ? Theme.pinBg : Theme.elementBg)
                                .foregroundColor(note.pinned ? Theme.pinGold : Theme.textMuted)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(note.pinned ? Theme.pinGold.opacity(0.3) : Theme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("p", modifiers: .command)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                        
                        // Title Editor
                        TextField("New Note", text: Binding(
                            get: { 
                                if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                    return store.notes[idx].title
                                }
                                return note.title 
                            },
                            set: { newValue in 
                                if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                    store.notes[idx].title = newValue
                                    store.notes[idx].updatedAt = Date()
                                    store.saveNoteChanges()
                                }
                            }
                        ))
                        .font(.system(size: 24, weight: .bold))
                        .textFieldStyle(.plain)
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .focused($focus, equals: .title)
                        .onSubmit { focus = .editor }

                        // Meta Row
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                Text(metaTimeString(from: note.updatedAt))
                                Text("·")
                                Text("Secure Note")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.elementBg)
                                    .cornerRadius(4)
                            }
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                            .opacity(note.plainTextCache.isEmpty && note.title.isEmpty ? 0 : 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        RichTextEditorWrapper(note: note, store: store, editorState: $editorState, isFocused: _focus)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "note.text").font(.system(size: 40)).foregroundColor(Theme.border)
                            
                            Button(action: { createNewNote(fromQuery: false) }) {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("Create a new note")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.text)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Theme.selection)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
            
            Divider().background(Theme.border)
            
            // BOTTOM BAR
            HStack {
                Button(action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                        Text("Preferences")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textMuted)
                
                Spacer()
                
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("⌘").font(.system(size: 12, weight: .bold)).padding(4).background(Theme.border).cornerRadius(4)
                        Text("C").font(.system(size: 12, weight: .bold)).padding(4).background(Theme.border).cornerRadius(4)
                        Text("Copy").foregroundColor(Theme.textMuted)
                    }

                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.sidebarBg)
        }
        .frame(width: 900, height: 600)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onReceive(newNotePub) { _ in createNewNote(fromQuery: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NotebarOpened"))) { _ in
            store.sortNotes()
            queryBuffer = ""
            if let first = store.notes.first {
                selectedNoteID = first.id
            }
            focus = .search
        }
        .onReceive(focusSearchPub) { _ in focus = .search }
        .onAppear {
            focus = .search
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKeyDown(event) }
            if selectedNoteID == nil, let first = store.notes.first { selectedNoteID = first.id }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {
            createNewNote(fromQuery: false)
            return nil
        }
        if event.modifierFlags.contains(.command) && (event.keyCode == 3 || event.keyCode == 37) {
            focus = .search
            return nil
        }
        if event.keyCode == 53 { // Esc
            if focus == .editor || focus == .title { focus = .search; return nil }
            else if !queryBuffer.isEmpty { queryBuffer = ""; focus = .search; return nil }
            else { onClose(); return nil }
        }
        if event.keyCode == 36 { // Enter
            if focus == .search || focus == .list {
                if filteredNotes.isEmpty { createNewNote(fromQuery: true) } else { focus = .editor }
                return nil
            }
        }
        if focus != .editor && focus != .title && focus != .search {
            if let chars = event.characters, chars.rangeOfCharacter(from: .alphanumerics) != nil {
                focus = .search
            }
        }
        if event.keyCode == 51 && (focus == .list || focus == .search) {
            if let id = selectedNoteID, let note = store.notes.first(where: { $0.id == id }) {
                store.delete(note)
                self.selectedNoteID = filteredNotes.first(where: { $0.id != id })?.id
                return nil
            }
        }
        return event
    }

    private func handleSearchSubmit() {
        if filteredNotes.isEmpty { createNewNote(fromQuery: true) } else {
            if let first = filteredNotes.first { selectedNoteID = first.id }
            focus = .editor
        }
    }

    private func createNewNote(fromQuery: Bool) {
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
    }

    private func metaTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        return formatter.string(from: date)
    }
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

struct NoteRowView: View {
    let note: Note
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.title.isEmpty ? "New Note" : note.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSelected ? .white : Theme.text)
                    .lineLimit(1)
                Spacer()
                if note.pinned { 
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white : Theme.pinGold) 
                }
            }
            Text(note.plainTextCache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No additional text" : note.plainTextCache.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white.opacity(0.8) : Theme.textMuted)
                .lineLimit(2)
            
            Text(timeString(from: note.updatedAt))
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .white.opacity(0.6) : Theme.textMuted.opacity(0.6))
        }
        .padding(12)
        .background(isSelected ? Theme.selection : Color.clear)
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
