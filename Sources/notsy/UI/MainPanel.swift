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
    @State private var activeEditorColor = Theme.editorTextNSColor
    @State private var previewImage: NSImage?
    @State private var showEditorFind = false
    @State private var editorFindQuery = ""
    @AppStorage(Theme.themeDefaultsKey) private var themeVariantRaw: String = NotsyThemeVariant.bluish.rawValue
    @AppStorage("notsy.sidebar.width") private var sidebarWidth: Double = 300
    @AppStorage("notsy.sidebar.collapsed") private var sidebarCollapsed: Bool = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarRuntimeWidth: CGFloat = 300
    @State private var sidebarResizeHovering = false
    @State private var sidebarContentPreviewCache: [UUID: String] = [:]
    @State private var autoExpandedSidebarForSearch = false

    enum FocusField: Hashable {
        case search
        case list
        case editor
        case title
        case find
    }
    @FocusState private var focus: FocusField?

    let newNotePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyNewNote"))
    let focusSearchPub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyFocusSearch"))
    let previewImagePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyPreviewImage"))
    private let editorFindActionNotification = NSNotification.Name("NotsyEditorFindAction")

    var filteredNotes: [Note] {
        if queryBuffer.isEmpty { return store.notes }
        return store.notes.filter { note in
            note.title.localizedCaseInsensitiveContains(queryBuffer) || 
            note.plainTextCache.localizedCaseInsensitiveContains(queryBuffer)
        }
    }

    private var navigableNotes: [Note] {
        let pinned = filteredNotes.filter { $0.pinned }
        let recent = filteredNotes.filter { !$0.pinned }

        if queryBuffer.isEmpty {
            return pinned + recent
        }

        guard let topHit = filteredNotes.first else { return [] }
        let pinnedWithoutTop = pinned.filter { $0.id != topHit.id }
        let recentWithoutTop = recent.filter { $0.id != topHit.id }
        return [topHit] + pinnedWithoutTop + recentWithoutTop
    }

    private var isSearchCompact: Bool {
        focus == .editor || focus == .title || focus == .find
    }

    private var selectedThemeVariant: NotsyThemeVariant {
        NotsyThemeVariant(rawValue: themeVariantRaw) ?? .bluish
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP BIG SEARCH BAR
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: isSearchCompact ? 14 : 18))
                    .foregroundColor(Theme.textMuted)
                
                TextField("Search or command...", text: $queryBuffer)
                    .font(.system(size: isSearchCompact ? 14 : 18))
                    .textFieldStyle(.plain)
                    .foregroundColor(Theme.text)
                    .focused($focus, equals: .search)
                    .onChange(of: queryBuffer) { oldVal, newVal in
                        if focus == .search {
                            if !newVal.isEmpty && sidebarCollapsed {
                                autoExpandedSidebarForSearch = true
                                withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed = false }
                            } else if newVal.isEmpty && autoExpandedSidebarForSearch {
                                withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed = true }
                                autoExpandedSidebarForSearch = false
                            }
                        }
                        if !newVal.isEmpty, let first = navigableNotes.first {
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
            .padding(.horizontal, isSearchCompact ? 12 : 16)
            .padding(.vertical, isSearchCompact ? 10 : 16)
            .background(Theme.sidebarBg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focus == .search ? Theme.selection : Theme.border, lineWidth: 1)
            )
            .padding(16)
            .background(Theme.sidebarBg)
            .animation(.easeInOut(duration: 0.15), value: isSearchCompact)

            Divider().background(Theme.border)
            
            // MAIN CONTENT
            HStack(spacing: 0) {
                // LEFT PANEL (SIDEBAR)
                if !sidebarCollapsed {
                    ZStack(alignment: .topTrailing) {
                        SidebarView(
                            queryBuffer: $queryBuffer,
                            selectedNoteID: $selectedNoteID,
                            filteredNotes: filteredNotes,
                            contentPreviewCache: sidebarContentPreviewCache,
                            focus: _focus,
                            createNewNote: { createNewNote(fromQuery: true) }
                        )
                        .frame(width: clampedSidebarWidth)
                        .background(Theme.sidebarBg)

                        HStack(spacing: 6) {
                            Text("Cmd+/")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.textMuted.opacity(0.8))
                            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed = true } }) {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textMuted)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(PointerPlainButtonStyle())
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                    .frame(width: clampedSidebarWidth)

                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                        .overlay {
                            Color.clear
                                .frame(width: 12)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if sidebarDragStartWidth == nil {
                                                sidebarDragStartWidth = clampedSidebarWidth
                                            }
                                            let base = sidebarDragStartWidth ?? clampedSidebarWidth
                                            let proposed = base + value.translation.width
                                            sidebarRuntimeWidth = max(200, min(460, proposed))
                                        }
                                        .onEnded { _ in
                                            sidebarWidth = Double(clampedSidebarWidth)
                                            sidebarDragStartWidth = nil
                                        }
                                )
                                .onHover { isHovering in
                                    if isHovering {
                                        NSCursor.resizeLeftRight.push()
                                        sidebarResizeHovering = true
                                    } else if sidebarResizeHovering {
                                        NSCursor.pop()
                                        sidebarResizeHovering = false
                                    }
                                }
                        }
                }

                // RIGHT PANEL (EDITOR)
                VStack(spacing: 0) {
                    if let selectedNoteID = selectedNoteID,
                       let noteIndex = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                        
                        let note = store.notes[noteIndex]
                        
                        // Title/meta + formatting controls (top section)
                        VStack(alignment: .leading, spacing: 8) {
                            titleEditor(for: note, selectedNoteID: selectedNoteID)

                            formattingToolbar()
                        }
                        .zIndex(showColorPalette ? 50 : 1)
                        .overlay(alignment: .topTrailing) {
                            VStack(alignment: .trailing, spacing: 8) {
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

                                if showEditorFind {
                                    HStack(spacing: 6) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textMuted)
                                        TextField("Find in note", text: $editorFindQuery)
                                            .font(.system(size: 12))
                                            .textFieldStyle(.plain)
                                            .foregroundColor(Theme.text)
                                            .focused($focus, equals: .find)
                                            .onChange(of: editorFindQuery) { _, newValue in
                                                postEditorFindAction("update", query: newValue)
                                            }
                                        Button(action: { postEditorFindAction("prev") }) {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .buttonStyle(PointerPlainButtonStyle())
                                        Button(action: { postEditorFindAction("next") }) {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .buttonStyle(PointerPlainButtonStyle())
                                        Button(action: {
                                            showEditorFind = false
                                            editorFindQuery = ""
                                            postEditorFindAction("close")
                                            focus = .editor
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .buttonStyle(PointerPlainButtonStyle())
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(width: 260)
                                    .background(Theme.sidebarBg)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                                    .cornerRadius(8)
                                }
                            }
                            .offset(x: 18, y: 0)
                        }
                        .padding(.leading, sidebarCollapsed ? 48 : 22)
                        .padding(.trailing, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 12)
                        
                        RichTextEditorWrapper(note: note, store: store, editorState: $editorState, isFocused: _focus)
                            .padding(.leading, sidebarCollapsed ? 40 : 18)
                            .padding(.trailing, 18)
                            .padding(.bottom, 14)
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
                .overlay(alignment: .topLeading) {
                    if sidebarCollapsed {
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed = false } }) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 28, height: 32)
                        }
                        .buttonStyle(PointerPlainButtonStyle())
                        .padding(.top, 20)
                        .padding(.leading, 10)
                    }
                }
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

                if let selectedNoteID,
                   let note = store.notes.first(where: { $0.id == selectedNoteID }) {
                    Divider()
                        .frame(height: 12)
                        .background(Theme.border)
                        .padding(.horizontal, 10)
                    Text("Created \(metaTimeString(from: note.createdAt)) • \(note.plainTextCache.split(separator: " ").count) words")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.sidebarBg)
        }
        .frame(width: 950, height: 650)
        .background(Theme.sidebarBg)
        .edgesIgnoringSafeArea(.all)
        .preferredColorScheme(Theme.palette(for: selectedThemeVariant).preferredColorScheme)
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
            refreshSidebarPreviewCache()
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
        .onChange(of: themeVariantRaw) { _, _ in
            activeEditorColor = Theme.editorTextNSColor
        }
        .onChange(of: focus) { _, newFocus in
            // Global search should be transient: when search loses focus, restore full list.
            if newFocus != .search && !queryBuffer.isEmpty {
                queryBuffer = ""
            }
            if newFocus != .search {
                autoExpandedSidebarForSearch = false
            }
        }
        .onChange(of: selectedNoteID) { _, _ in
            refreshSidebarPreviewCache()
            if showEditorFind {
                showEditorFind = false
                editorFindQuery = ""
                postEditorFindAction("close")
            }
        }
        .onAppear {
            sidebarRuntimeWidth = CGFloat(sidebarWidth)
            refreshSidebarPreviewCache()
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
        // Up/Down in global search should navigate matched notes.
        if (focus == .search || focus == .list),
           !filteredNotes.isEmpty,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           (event.keyCode == 125 || event.keyCode == 126) {
            moveSearchSelection(delta: event.keyCode == 125 ? 1 : -1)
            return nil
        }
        if event.keyCode == 53, previewImage != nil {
            previewImage = nil
            return nil
        }
        if event.keyCode == 53, showEditorFind {
            showEditorFind = false
            editorFindQuery = ""
            postEditorFindAction("close")
            focus = .editor
            return nil
        }
        // Cmd + Shift + F -> Global search
        if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 3 {
            focus = .search
            return nil
        }
        // Cmd + / -> toggle sidebar
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "/" {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed.toggle() }
            return nil
        }
        // Cmd + F -> Find inside editor
        if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) && event.keyCode == 3 {
            showEditorFind = true
            DispatchQueue.main.async {
                focus = .find
                postEditorFindAction("update", query: editorFindQuery)
            }
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
        if event.modifierFlags.contains(.command) && event.keyCode == 37 {
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
        if focus != .editor && focus != .title && focus != .search && focus != .find {
            if let chars = event.characters, chars.rangeOfCharacter(from: .alphanumerics) != nil {
                focus = .search
            }
        }
        if event.keyCode == 51 && focus == .list {
            if let id = selectedNoteID, let note = store.notes.first(where: { $0.id == id }) {
                store.delete(note)
                self.selectedNoteID = filteredNotes.first(where: { $0.id != id })?.id
                return nil
            }
        }
        return event
    }

    private func moveSearchSelection(delta: Int) {
        guard !navigableNotes.isEmpty else { return }

        if let selectedNoteID,
           let currentIndex = navigableNotes.firstIndex(where: { $0.id == selectedNoteID }) {
            let nextIndex = max(0, min(navigableNotes.count - 1, currentIndex + delta))
            self.selectedNoteID = navigableNotes[nextIndex].id
            return
        }

        self.selectedNoteID = navigableNotes[delta >= 0 ? 0 : navigableNotes.count - 1].id
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

        let attrStr = NSAttributedString(string: "", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: Theme.editorTextNSColor])
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

    private var clampedSidebarWidth: CGFloat {
        max(200, min(460, sidebarRuntimeWidth))
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

    private func postEditorFindAction(_ action: String, query: String? = nil) {
        var payload: [String: Any] = ["action": action]
        if let query { payload["query"] = query }
        NotificationCenter.default.post(
            name: editorFindActionNotification,
            object: nil,
            userInfo: payload
        )
    }

    private func capitalizeFirstCharacter(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private func refreshSidebarPreviewCache() {
        var snapshot: [UUID: String] = [:]
        for note in store.notes {
            snapshot[note.id] = note.plainTextCache
        }
        sidebarContentPreviewCache = snapshot
    }

    @ViewBuilder
    private func formattingToolbar() -> some View {
        HStack(spacing: 4) {
            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-sans"]) }) {
                Text("Aa").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 20).background(Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-serif"]) }) {
                Text("Ag").font(.system(size: 10, weight: .semibold, design: .serif)).frame(width: 24, height: 20).background(Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-mono"]) }) {
                Text("M").font(.system(size: 10, weight: .semibold, design: .monospaced)).frame(width: 20, height: 20).background(Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-size-down"]) }) {
                Text("A-").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 20).background(Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-size-default"]) }) {
                Text("A").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 20).background(Color.clear).cornerRadius(4)
            }.buttonStyle(PointerPlainButtonStyle())

            Button(action: { NotificationCenter.default.post(name: NSNotification.Name("NotsyToolbarAction"), object: nil, userInfo: ["action": "font-size-up"]) }) {
                Text("A+").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 20).background(Color.clear).cornerRadius(4)
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
            .font(.system(size: 30, weight: .bold))
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
    var contentPreviewCache: [UUID: String]
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
                                NoteRowView(note: firstNote, isSelected: selectedNoteID == firstNote.id, contentPreviewText: contentPreviewCache[firstNote.id] ?? firstNote.plainTextCache)
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
                                NoteRowView(note: note, isSelected: selectedNoteID == note.id, contentPreviewText: contentPreviewCache[note.id] ?? note.plainTextCache)
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
                                NoteRowView(note: note, isSelected: selectedNoteID == note.id, contentPreviewText: contentPreviewCache[note.id] ?? note.plainTextCache)
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
                            HStack(spacing: 10) {
                                ZRectangleIcon(icon: "plus", isSelected: false)
                                Text(queryBuffer.isEmpty ? "Create New Note" : "Create \"\(queryBuffer)\"")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text("Cmd+N")
                                    .font(.system(size: 8))
                                    .foregroundColor(Theme.textMuted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
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
    @AppStorage(Theme.themeDefaultsKey) private var themeVariantRaw: String = NotsyThemeVariant.bluish.rawValue

    var body: some View {
        RichTextEditorView(
            note: note,
            store: store,
            editorState: $editorState,
            themeVariantRaw: themeVariantRaw
        )
        .focused($isFocused, equals: .editor)
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
    let contentPreviewText: String
    @AppStorage("notsy.selection.color") private var selectionColorChoice: String = "blue"

    var body: some View {
        HStack(spacing: 12) {
            ZRectangleIcon(icon: "doc.text.fill", isSelected: isSelected)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSelected ? .white : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                HStack(spacing: 4) {
                    Text(timeString(from: note.updatedAt))
                        .lineLimit(1)

                    if note.pinned {
                        Text("•")
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.pinGold)
                    }

                    Text("•")
                    Text(preview(for: contentPreviewText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white.opacity(0.8) : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer()
            
            if isSelected {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? rowSelectionColor : Color.clear)
        .cornerRadius(8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var rowSelectionColor: Color {
        selectionColorChoice == "gray"
            ? Color(red: 0.38, green: 0.40, blue: 0.45)
            : Theme.selection
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
