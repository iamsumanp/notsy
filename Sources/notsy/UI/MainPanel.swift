import AppKit
import SwiftUI

enum EditorFontStyle: Equatable {
    case sans
    case serif
    case mono
}

struct EditorState: Equatable {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var isBullet: Bool = false
    var isCheckbox: Bool = false
    var fontStyle: EditorFontStyle = .mono
}

struct MainPanel: View {
    var onClose: () -> Void
    @Environment(NoteStore.self) private var store
    @State private var queryBuffer: String = ""
    @State private var selectedNoteID: UUID?
    @State private var editorState = EditorState()
    @State private var showColorPalette = false
    @State private var activeEditorColor = NSColor.white
    @State private var previewImage: NSImage?

    enum FocusField: Hashable {
        case search
        case list
        case editor
        case title
    }
    @FocusState private var focus: FocusField?

    let newNotePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyNewNote"))
    let focusSearchPub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyFocusSearch"))
    let previewImagePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyPreviewImage"))

    var filteredNotes: [Note] {
        if queryBuffer.isEmpty { return store.notes }
        return store.notes.filter { note in
            note.title.localizedCaseInsensitiveContains(queryBuffer) || 
            note.plainTextCache.localizedCaseInsensitiveContains(queryBuffer)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP BIG SEARCH BAR
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textMuted)
                
                TextField("Search or command...", text: $queryBuffer)
                    .font(.system(size: 18))
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
                
                Spacer()
                
                Text("ESC")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.elementBg)
                    .foregroundColor(Theme.textMuted)
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Theme.sidebarBg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focus == .search ? Theme.selection : Theme.border, lineWidth: 1)
            )
            .padding(16)
            .background(Theme.sidebarBg)

            Divider().background(Theme.border)
            
            // MAIN CONTENT
            HStack(spacing: 0) {
                // LEFT PANEL (SIDEBAR)
                SidebarView(
                    queryBuffer: $queryBuffer,
                    selectedNoteID: $selectedNoteID,
                    filteredNotes: filteredNotes,
                    focus: _focus,
                    createNewNote: { createNewNote(fromQuery: true) }
                )
                .frame(width: 300)
                .background(Theme.sidebarBg)

                Divider().background(Theme.border)

                // RIGHT PANEL (EDITOR)
                VStack(spacing: 0) {
                    if let selectedNoteID = selectedNoteID,
                       let noteIndex = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                        
                        let note = store.notes[noteIndex]
                        
                        // Title/meta + formatting controls (top section)
                        VStack(alignment: .leading, spacing: 10) {
                            titleEditor(for: note, selectedNoteID: selectedNoteID)

                            HStack(spacing: 12) {
                                Text("Created \(metaTimeString(from: note.createdAt))")
                                Text("•")
                                Text("\(note.plainTextCache.split(separator: " ").count) words")
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textMuted)

                            formattingToolbar()
                        }
                        .zIndex(showColorPalette ? 50 : 1)
                        .overlay(alignment: .topTrailing) {
                            Button(action: {
                                withAnimation(.spring()) {
                                    if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                                        store.togglePin(for: store.notes[idx])
                                    }
                                }
                            }) {
                                Image(systemName: note.pinned ? "pin.fill" : "pin")
                                    .font(.system(size: 13))
                                    .foregroundColor(note.pinned ? Theme.pinGold : Theme.textMuted)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 18, y: 0)
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                        .padding(.bottom, 14)
                        
                        RichTextEditorWrapper(note: note, store: store, editorState: $editorState, isFocused: _focus)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                            .zIndex(0)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text").font(.system(size: 40)).foregroundColor(Theme.border)
                            Text("No note selected").foregroundColor(Theme.textMuted)
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
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Notsy")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                    Text("Application Support/Notsy")
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                .foregroundColor(Theme.textMuted)
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, 8)
                
                Button(action: {
                    withAnimation {
                        let toDelete = store.notes.filter { !$0.pinned }
                        for note in toDelete {
                            store.delete(note)
                        }
                        if let selected = selectedNoteID, !store.notes.contains(where: { $0.id == selected }) {
                            selectedNoteID = store.notes.first?.id
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Clear Unpinned")
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.elementBg)
                    .foregroundColor(Theme.textMuted)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                
                Spacer()
                
                Text("\(filteredNotes.count) results found")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.sidebarBg)
        }
        .frame(width: 950, height: 650)
        .background(Theme.sidebarBg)
        .edgesIgnoringSafeArea(.all)
        .preferredColorScheme(.dark)
        .overlay {
            if let previewImage {
                ZStack {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()
                        .onTapGesture { self.previewImage = nil }

                    VStack(spacing: 12) {
                        HStack {
                            Spacer()
                            Button(action: { self.previewImage = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }

                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 820, maxHeight: 520)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(20)
                }
                .zIndex(200)
            }
        }
        .onReceive(newNotePub) { _ in createNewNote(fromQuery: false) }
        .onReceive(previewImagePub) { notification in
            if let image = notification.userInfo?["image"] as? NSImage {
                previewImage = image
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NotsyOpened"))) { _ in
            store.sortNotes()
            queryBuffer = ""
            if let first = store.notes.first {
                selectedNoteID = first.id
                // Delay slightly to let the view render before stealing focus into the NSViewRepresentable
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focus = .editor
                }
            } else {
                focus = .search
            }
        }
        .onReceive(focusSearchPub) { _ in focus = .search }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKeyDown(event) }
            if selectedNoteID == nil, let first = store.notes.first { 
                selectedNoteID = first.id 
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focus = .editor
                }
            } else {
                focus = .search
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53, previewImage != nil {
            previewImage = nil
            return nil
        }
        // Cmd + , (Preferences)
        if event.modifierFlags.contains(.command) && event.keyCode == 43 {
            NotificationCenter.default.post(name: NSNotification.Name("NotsyShowPreferences"), object: nil)
            return nil
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {
            createNewNote(fromQuery: false)
            return nil
        }
        if event.modifierFlags.contains(.command) && (event.keyCode == 3 || event.keyCode == 37) {
            focus = .search
            return nil
        }
        if event.keyCode == 53 {
            if focus == .editor || focus == .title { focus = .search; return nil }
            else if !queryBuffer.isEmpty { queryBuffer = ""; focus = .search; return nil }
            else { onClose(); return nil }
        }
        if event.keyCode == 36 {
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
        let initialTitle = hasQuery ? capitalizeFirstCharacter(queryBuffer) : ""
        let newNote = Note(title: initialTitle, plainTextCache: "", createdAt: Date(), updatedAt: Date())

        let attrStr = NSAttributedString(string: "", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.white])
        newNote.update(with: attrStr)
        store.insert(newNote)
        queryBuffer = ""
        selectedNoteID = newNote.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // For a truly new note (no inferred title), put cursor in title first.
            focus = hasQuery ? .editor : .title
        }
    }

    private func metaTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func postColorAction(_ action: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("NotsyToolbarAction"),
            object: nil,
            userInfo: ["action": action]
        )
    }

    private func postCustomColor(_ color: NSColor) {
        activeEditorColor = color
        NotificationCenter.default.post(
            name: NSNotification.Name("NotsyToolbarAction"),
            object: nil,
            userInfo: ["action": "color-custom", "nsColor": color]
        )
    }

    private func capitalizeFirstCharacter(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    @ViewBuilder
    private func formattingToolbar() -> some View {
        HStack(spacing: 4) {
            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-sans"]) }) {
                Text("Aa").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 20).background(editorState.fontStyle == .sans ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-serif"]) }) {
                Text("Ag").font(.system(size: 10, weight: .semibold, design: .serif)).frame(width: 24, height: 20).background(editorState.fontStyle == .serif ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-mono"]) }) {
                Text("M").font(.system(size: 10, weight: .semibold, design: .monospaced)).frame(width: 20, height: 20).background(editorState.fontStyle == .mono ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "bold"]) }) {
                Text("B").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20).background(editorState.isBold ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "italic"]) }) {
                Text("I").font(.system(size: 12, weight: .semibold).italic()).frame(width: 20, height: 20).background(editorState.isItalic ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "underline"]) }) {
                Text("U").font(.system(size: 12, weight: .semibold)).underline().frame(width: 20, height: 20).background(editorState.isUnderline ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "strikethrough"]) }) {
                Text("S").font(.system(size: 12, weight: .semibold)).strikethrough().frame(width: 20, height: 20).background(editorState.isStrikethrough ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "list"]) }) {
                Image(systemName: "list.bullet").font(.system(size: 10)).frame(width: 20, height: 20).background(editorState.isBullet ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "checkbox"]) }) {
                Image(systemName: "checkmark.square").font(.system(size: 10)).frame(width: 20, height: 20).background(editorState.isCheckbox ? Theme.selection.opacity(0.3) : Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Divider().frame(height: 12).background(Theme.border).padding(.horizontal, 4)

            ColorDot(color: activeEditorColor) { postCustomColor(activeEditorColor) }
            Button(action: { showColorPalette.toggle() }) {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PointerPlainButtonStyle())
            .popover(isPresented: $showColorPalette, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                ColorPalettePopover { color in
                    postCustomColor(color)
                    showColorPalette = false
                }
            }
        }
        .foregroundColor(Theme.textMuted)
    }

    @ViewBuilder
    private func titleEditor(for note: Note, selectedNoteID: UUID) -> some View {
        HStack {
            if note.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.pinGold)
            }
            TextField("Untitled", text: Binding(
                get: {
                    if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                        return store.notes[idx].title
                    }
                    return note.title
                },
                set: { newValue in
                    let previousTitle = store.notes.first(where: { $0.id == selectedNoteID })?.title ?? ""
                    let nextTitle = previousTitle.isEmpty ? capitalizeFirstCharacter(newValue) : newValue
                    store.updateTitle(noteID: selectedNoteID, title: nextTitle)
                }
            ))
            .font(.system(size: 34, weight: .bold))
            .lineLimit(1)
        }
        .textFieldStyle(.plain)
        .foregroundColor(Theme.text)
        .focused($focus, equals: .title)
        .onSubmit { focus = .editor }
    }
}

struct SidebarView: View {
    @Binding var queryBuffer: String
    @Binding var selectedNoteID: UUID?
    var filteredNotes: [Note]
    @FocusState var focus: MainPanel.FocusField?
    var createNewNote: () -> Void
    @Environment(NoteStore.self) private var store
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        
                        let pinned = filteredNotes.filter { $0.pinned }
                        let recent = filteredNotes.filter { !$0.pinned }
                        
                        let topHitID = (!queryBuffer.isEmpty && !filteredNotes.isEmpty) ? filteredNotes.first?.id : nil
                        
                        if !queryBuffer.isEmpty && !filteredNotes.isEmpty {
                            Text("TOP HIT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            
                            if let firstNote = filteredNotes.first {
                                NoteRowView(note: firstNote, isSelected: selectedNoteID == firstNote.id)
                                    .id("top-\(firstNote.id.uuidString)-\(firstNote.title)")
                                    .onTapGesture {
                                        selectedNoteID = firstNote.id
                                        focus = .editor
                                    }
                            }
                        }

                        let displayPinned = pinned.filter { $0.id != topHitID }
                        let displayRecent = recent.filter { $0.id != topHitID }

                        if !displayPinned.isEmpty {
                            Text("PINNED")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            
                            ForEach(displayPinned) { note in
                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id("pinned-\(note.id.uuidString)-\(note.title)")
                                    .onTapGesture {
                                        selectedNoteID = note.id
                                        focus = .editor
                                    }
                                    .contextMenu {
                                        Button(action: { withAnimation(.spring()) { store.togglePin(for: note) } }) {
                                            Text("Unpin")
                                            Image(systemName: "pin.slash")
                                        }
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(note.plainTextCache, forType: .string)
                                        }) { Text("Copy Content"); Image(systemName: "doc.on.doc") }
                                        Divider()
                                        Button(role: .destructive, action: { withAnimation { store.delete(note) } }) { Text("Delete"); Image(systemName: "trash") }
                                    }
                            }
                        }

                        if !displayRecent.isEmpty {
                            Text("NOTES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            
                            ForEach(displayRecent) { note in
                                NoteRowView(note: note, isSelected: selectedNoteID == note.id)
                                    .id("recent-\(note.id.uuidString)-\(note.title)")
                                    .onTapGesture {
                                        selectedNoteID = note.id
                                        focus = .editor
                                    }
                                    .contextMenu {
                                        Button(action: { withAnimation(.spring()) { store.togglePin(for: note) } }) {
                                            Text("Pin")
                                            Image(systemName: "pin")
                                        }
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(note.plainTextCache, forType: .string)
                                        }) { Text("Copy Content"); Image(systemName: "doc.on.doc") }
                                        Divider()
                                        Button(role: .destructive, action: { withAnimation { store.delete(note) } }) { Text("Delete"); Image(systemName: "trash") }
                                    }
                            }
                        }

                        Text("ACTIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 4)
                        
                        Button(action: createNewNote) {
                            HStack(spacing: 12) {
                                ZRectangleIcon(icon: "plus", isSelected: false)
                                Text(queryBuffer.isEmpty ? "Create New Note" : "Create \"\(queryBuffer)\"")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Spacer()
                                Text("Cmd+N")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textMuted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        

                    }
                    .padding(.bottom, 16)
                }
                .focused($focus, equals: .list)
            }
        }
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

struct ShortcutBadge: View {
    let key: String
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.elementBg)
                .cornerRadius(4)
                .foregroundColor(Theme.textMuted)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
        }
    }
}

struct ColorDot: View {
    let color: NSColor
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(PointerPlainButtonStyle())
    }
}

struct PointerPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct ColorPalettePopover: View {
    let onSelect: (NSColor) -> Void

    private let palette: [NSColor] = [
        .white, .systemGray, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink,
        NSColor(red: 0.92, green: 0.58, blue: 0.58, alpha: 1), NSColor(red: 0.86, green: 0.72, blue: 0.52, alpha: 1), NSColor(red: 0.61, green: 0.80, blue: 0.45, alpha: 1), NSColor(red: 0.45, green: 0.77, blue: 0.73, alpha: 1),
        NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1), NSColor(red: 0.65, green: 0.52, blue: 0.95, alpha: 1), NSColor(red: 0.88, green: 0.50, blue: 0.83, alpha: 1), NSColor(red: 0.74, green: 0.74, blue: 0.74, alpha: 1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textMuted)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button(action: { onSelect(color) }) {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(width: 180)
        .background(Theme.sidebarBg)
    }
}

struct ZRectangleIcon: View {
    let icon: String
    let isSelected: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.text.opacity(0.2) : Theme.elementBg)
                .frame(width: 24, height: 24)
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isSelected ? Theme.text : Theme.textMuted)
        }
    }
}

struct NoteRowView: View {
    let note: Note
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZRectangleIcon(icon: "doc.text.fill", isSelected: isSelected)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSelected ? .white : Theme.text)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(timeString(from: note.updatedAt))
                    Text("•")
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(Theme.pinGold)
                        Text("•")
                    }
                    Text(preview(for: note.plainTextCache))
                        .lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white.opacity(0.8) : Theme.textMuted)
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Theme.selection : Color.clear)
        .cornerRadius(8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
    
    private func preview(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No additional text" }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
