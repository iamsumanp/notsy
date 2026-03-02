import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum EditorFontStyle: Equatable {
    case system
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
    var fontStyle: EditorFontStyle = .system
    var hasSelection: Bool = false
}

private enum AIQuickAction: String, CaseIterable, Identifiable {
    case improveWriting
    case proofread
    case makeShorter
    case simplifyLanguage
    case makeLonger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .improveWriting: return "Improve writing"
        case .proofread: return "Proofread"
        case .makeShorter: return "Make shorter"
        case .simplifyLanguage: return "Simplify language"
        case .makeLonger: return "Make longer"
        }
    }

    var instruction: String {
        switch self {
        case .improveWriting:
            return "Improve clarity, flow, and tone while preserving meaning."
        case .proofread:
            return "Proofread and fix grammar, spelling, and punctuation with minimal wording changes."
        case .makeShorter:
            return "Rewrite the text to be shorter and concise while preserving key meaning."
        case .simplifyLanguage:
            return "Rewrite using simpler language and shorter sentences."
        case .makeLonger:
            return "Expand the text with useful details while preserving intent and style."
        }
    }
}

private enum AIPopoverTrigger: String, Hashable {
    case improve
    case ask
    case edit
}

private enum AIPanelState {
    case input
    case loading
    case result
    case error
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
    @State private var showLinkEditor = false
    @State private var linkEditorText = ""
    @State private var linkEditorURL = ""
    @State private var showEditorFind = false
    @State private var editorFindQuery = ""
    @AppStorage(Theme.themeDefaultsKey) private var themeVariantRaw: String = NotsyThemeVariant
        .bluish.rawValue
    @AppStorage("notsy.sidebar.width") private var sidebarWidth: Double = 300
    @AppStorage("notsy.sidebar.collapsed") private var sidebarCollapsed: Bool = false
    @AppStorage("notsy.editor.spellcheck.enabled") private var spellCheckEnabled: Bool = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarRuntimeWidth: CGFloat = 300
    @State private var sidebarResizeHovering = false
    @State private var sidebarContentPreviewCache: [UUID: String] = [:]
    @State private var autoExpandedSidebarForSearch = false
    @State private var keyDownMonitor: Any?
    @State private var manualSaveStatusMessage: String?
    @State private var manualSaveStatusTask: Task<Void, Never>?
    @State private var zenModeEnabled = false
    @State private var showClearUnpinnedConfirmation = false
    @State private var selectedEditorText = ""
    @State private var selectedEditorRange: NSRange?
    @State private var aiGeneratedText = ""
    @State private var aiErrorMessage: String?
    @State private var aiLastInstruction = ""
    @State private var aiLastSelectionText = ""
    @State private var aiLastSelectionRange: NSRange?
    @State private var aiLastAttachmentPlaceholders: [EditorAIAttachmentPlaceholder] = []
    @State private var aiTask: Task<Void, Never>?
    @State private var aiIsRunning = false
    @State private var pendingEditorAIAction: EditorAIActionRequest?
    @State private var aiPopoverTrigger: AIPopoverTrigger?
    @State private var aiCustomPrompt = ""
    @AppStorage(AIWritingService.enabledDefaultsKey) private var aiEnabled: Bool = false
    @AppStorage("notsy.last.selected.note.id") private var persistedSelectedNoteIDRaw: String = ""

    enum FocusField: Hashable {
        case search
        case list
        case editor
        case title
        case find
    }
    @FocusState private var focus: FocusField?

    let newNotePub = NotificationCenter.default.publisher(for: NSNotification.Name("NotsyNewNote"))
    let focusSearchPub = NotificationCenter.default.publisher(
        for: NSNotification.Name("NotsyFocusSearch"))
    let previewImagePub = NotificationCenter.default.publisher(
        for: NSNotification.Name("NotsyPreviewImage"))
    let openLinkEditorPub = NotificationCenter.default.publisher(
        for: NSNotification.Name("NotsyOpenLinkEditor"))
    private let editorFindActionNotification = NSNotification.Name("NotsyEditorFindAction")

    private struct AISelectionPayload {
        let text: String
        let placeholders: [EditorAIAttachmentPlaceholder]
    }

    var filteredNotes: [Note] {
        if queryBuffer.isEmpty { return store.notes }
        return store.notes.filter { note in
            note.title.localizedCaseInsensitiveContains(queryBuffer)
                || note.plainTextCache.localizedCaseInsensitiveContains(queryBuffer)
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
        focus == .editor || focus == .title || focus == .find || aiPopoverTrigger != nil
    }

    private var sidebarIsVisible: Bool {
        !zenModeEnabled && !sidebarCollapsed
    }

    private var editorUsesCompactSidebarSpacing: Bool {
        sidebarCollapsed && !zenModeEnabled
    }

    private var selectedThemeVariant: NotsyThemeVariant {
        NotsyThemeVariant(rawValue: themeVariantRaw) ?? .bluish
    }

    private var mostRecentlyModifiedNoteID: UUID? {
        store.notes.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    private var persistedSelectedNoteID: UUID? {
        UUID(uuidString: persistedSelectedNoteIDRaw)
    }

    private var statusBannerMessage: String? {
        manualSaveStatusMessage ?? store.notionSyncStatusMessage
    }

    private var statusBannerIconName: String {
        if manualSaveStatusMessage != nil { return "checkmark.circle.fill" }
        if store.notionSyncInFlight { return "arrow.triangle.2.circlepath" }
        if store.notionSyncStatusIsError { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusBannerForegroundColor: Color {
        if manualSaveStatusMessage != nil { return Theme.textMuted.opacity(0.9) }
        return store.notionSyncStatusIsError ? .red.opacity(0.9) : Theme.textMuted.opacity(0.9)
    }

    var body: some View {
        VStack(spacing: 0) {
            // TOP BIG SEARCH BAR
            if !zenModeEnabled {
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
                            if !zenModeEnabled, focus == .search {
                                if !newVal.isEmpty && sidebarCollapsed {
                                    autoExpandedSidebarForSearch = true
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        sidebarCollapsed = false
                                    }
                                } else if newVal.isEmpty && autoExpandedSidebarForSearch {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        sidebarCollapsed = true
                                    }
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
                .padding(.horizontal, isSearchCompact ? 10 : 12)
                .padding(.vertical, isSearchCompact ? 8 : 12)
                .background(Theme.sidebarBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(focus == .search ? Theme.selection : Theme.border, lineWidth: 1)
                )
                .padding(12)
                .background(Theme.sidebarBg)
                .animation(.easeInOut(duration: 0.15), value: isSearchCompact)

                Divider().background(Theme.border)
            }

            // MAIN CONTENT
            HStack(spacing: 0) {
                // LEFT PANEL (SIDEBAR)
                if sidebarIsVisible {
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
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    sidebarCollapsed = true
                                }
                            }) {
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
                                            sidebarRuntimeWidth = max(
                                                sidebarMinWidth,
                                                min(sidebarMaxWidth, proposed)
                                            )
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
                        let noteIndex = store.notes.firstIndex(where: { $0.id == selectedNoteID })
                    {

                        let note = store.notes[noteIndex]

                        // Title/meta + formatting controls (top section)
                        VStack(alignment: .leading, spacing: 8) {
                            titleEditor(for: note, selectedNoteID: selectedNoteID)

                            formattingToolbar(note: note)
                        }
                        .zIndex(showColorPalette ? 50 : 1)
                        .overlay(alignment: .topTrailing) {
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
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(
                                        Theme.border, lineWidth: 1)
                                )
                                .cornerRadius(8)
                                .offset(x: 4, y: 0)
                            }
                        }
                        .padding(.leading, editorUsesCompactSidebarSpacing ? 48 : 22)
                        .padding(.trailing, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                        RichTextEditorWrapper(
                            note: note,
                            store: store,
                            editorState: $editorState,
                            activeEditorColor: $activeEditorColor,
                            selectedText: $selectedEditorText,
                            selectedRange: $selectedEditorRange,
                            pendingAIAction: $pendingEditorAIAction,
                            spellCheckEnabled: spellCheckEnabled,
                            isFocused: _focus
                        )
                        .padding(.leading, editorUsesCompactSidebarSpacing ? 40 : 18)
                        .padding(.trailing, 18)
                        .padding(.bottom, 14)
                        .zIndex(0)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text").font(.system(size: 40)).foregroundColor(
                                Theme.border)
                            Text("No note selected").foregroundColor(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .topLeading) {
                    if sidebarCollapsed && !zenModeEnabled {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed = false }
                        }) {
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
                .overlay(alignment: .bottomTrailing) {
                    if let statusBannerMessage {
                        HStack(spacing: 8) {
                            Image(systemName: statusBannerIconName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(statusBannerForegroundColor)
                            Text(statusBannerMessage)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .font(.system(size: 11))
                                .foregroundColor(statusBannerForegroundColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.sidebarBg.opacity(0.78))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(
                                Theme.border.opacity(0.7), lineWidth: 0.6)
                        )
                        .cornerRadius(6)
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                    }
                }
            }

            if !zenModeEnabled {
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
                        showClearUnpinnedConfirmation = true
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
                    .pointingHandCursor()
                    .padding(.leading, 8)

                    Spacer()

                    Text("\(filteredNotes.count) results found")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)

                    if let selectedNoteID,
                        let note = store.notes.first(where: { $0.id == selectedNoteID })
                    {
                        Divider()
                            .frame(height: 12)
                            .background(Theme.border)
                            .padding(.horizontal, 10)
                        Text(
                            "Created \(metaTimeString(from: note.createdAt)) • \(note.plainTextCache.split(separator: " ").count) words"
                        )
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.sidebarBg)
            }
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
                            .pointingHandCursor()
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
        .overlay {
            if showLinkEditor {
                ZStack {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()
                        .onTapGesture { showLinkEditor = false }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(linkEditorText.isEmpty ? "Add Link" : "Edit Link")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(Theme.text)
                            Spacer()
                            Button(action: { showLinkEditor = false }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(Theme.textMuted)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }

                        Text("Text")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                        TextField("youtube", text: $linkEditorText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.bg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).stroke(
                                    Theme.border, lineWidth: 1)
                            )
                            .cornerRadius(10)

                        Text("Link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                        TextField("https://www.youtube.com", text: $linkEditorURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.bg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).stroke(
                                    Theme.border, lineWidth: 1)
                            )
                            .cornerRadius(10)

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showLinkEditor = false
                            }
                            .buttonStyle(PointerPlainButtonStyle())
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.elementBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).stroke(
                                    Theme.border, lineWidth: 1)
                            )
                            .cornerRadius(10)
                            .foregroundColor(Theme.textMuted)

                            Button("Save") {
                                applyLinkEditor()
                            }
                            .buttonStyle(PointerPlainButtonStyle())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color(red: 0.14, green: 0.42, blue: 0.29))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                        }
                    }
                    .padding(24)
                    .frame(width: 720)
                    .background(Theme.sidebarBg)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
                    .cornerRadius(16)
                }
                .zIndex(220)
            }
        }
        .onReceive(newNotePub) { _ in createNewNote(fromQuery: false) }
        .onReceive(previewImagePub) { notification in
            if let image = notification.userInfo?["image"] as? NSImage {
                previewImage = image
            }
        }
        .onReceive(openLinkEditorPub) { notification in
            linkEditorText = (notification.userInfo?["text"] as? String) ?? ""
            linkEditorURL = (notification.userInfo?["url"] as? String) ?? ""
            showLinkEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NotsyOpened"))) {
            _ in
            store.sortNotes()
            queryBuffer = ""
            refreshSidebarPreviewCache()
            if let restoredID = resolvedSelectionForOpen() {
                if selectedNoteID != restoredID {
                    selectedNoteID = restoredID
                }
                focusEditorWhenAvailable()
            } else {
                focus = .search
            }
        }
        .onReceive(focusSearchPub) { _ in
            exitZenMode()
            focus = .search
        }
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
            persistSelectedSelection()
            refreshSidebarPreviewCache()
            resetAIOverlay(clearSelection: true)
            if showEditorFind {
                showEditorFind = false
                editorFindQuery = ""
                postEditorFindAction("close")
            }
        }
        .onChange(of: selectedEditorText) { oldValue, newValue in
            if oldValue != newValue {
                let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let newTrimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

                if !newTrimmed.isEmpty, newTrimmed != oldTrimmed, !aiIsRunning {
                    aiGeneratedText = ""
                    aiErrorMessage = nil
                } else if newTrimmed.isEmpty, !aiIsRunning, aiGeneratedText.isEmpty {
                    aiErrorMessage = nil
                }
            }
        }
        .onChange(of: aiEnabled) { _, isEnabled in
            if !isEnabled {
                resetAIOverlay(clearSelection: false)
            }
        }
        .onAppear {
            sidebarRuntimeWidth = CGFloat(sidebarWidth)
            refreshSidebarPreviewCache()
            if keyDownMonitor == nil {
                keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleKeyDown(event)
                }
            }
            if let restoredID = resolvedSelectionForOpen() {
                if selectedNoteID != restoredID {
                    selectedNoteID = restoredID
                }
                focusEditorWhenAvailable()
            } else {
                focus = .search
            }
        }
        .onDisappear {
            aiTask?.cancel()
            manualSaveStatusTask?.cancel()
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
                self.keyDownMonitor = nil
            }
        }
        .alert("Delete all unpinned notes?", isPresented: $showClearUnpinnedConfirmation) {
            Button("Delete", role: .destructive) {
                withAnimation {
                    let selectedWasUnpinned = selectedNoteID.flatMap { id in
                        store.notes.first(where: { $0.id == id })
                    }?.pinned == false
                    let toDelete = store.notes.filter { !$0.pinned }
                    for note in toDelete {
                        store.delete(note)
                    }
                    if selectedWasUnpinned {
                        selectedNoteID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = store.notes.filter { !$0.pinned }.count
            Text("This will permanently delete \(count) unpinned note\(count == 1 ? "" : "s").")
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Ignore global key handling unless the main Notsy panel is the active key window.
        guard AppDelegate.shared?.panel.isKeyWindow == true else { return event }
        // While the custom link modal is open, let its text fields handle all typing.
        if showLinkEditor { return event }
        // While AI popover input is open, let its text fields own keyboard handling.
        if aiPopoverTrigger != nil {
            if event.keyCode == 53 {
                aiPopoverTrigger = nil
                return nil
            }
            return event
        }

        // If global search is focused only due startup timing, direct normal typing to editor.
        if focus == .search,
            queryBuffer.isEmpty,
            selectedNoteID != nil,
            !isSearchInputActive(),
            !event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            let chars = event.characters,
            chars.rangeOfCharacter(from: .alphanumerics) != nil
        {
            focus = .editor
            return event
        }

        // Up/Down in global search should navigate matched notes.
        if focus == .search || focus == .list,
            !filteredNotes.isEmpty,
            !event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            event.keyCode == 125 || event.keyCode == 126
        {
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
        // Cmd + Shift + / -> toggle Zen mode
        if event.modifierFlags.contains([.command, .shift]),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            event.keyCode == 44
        {
            toggleZenMode()
            return nil
        }
        // Cmd + Shift + F -> Global search
        if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 3 {
            exitZenMode()
            focus = .search
            return nil
        }
        // Cmd + / -> toggle sidebar
        if event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            event.keyCode == 44
        {
            if zenModeEnabled {
                withAnimation(.easeInOut(duration: 0.15)) {
                    zenModeEnabled = false
                    sidebarCollapsed = false
                }
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { sidebarCollapsed.toggle() }
            }
            return nil
        }
        // Cmd + S -> explicit save feedback
        if event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            event.keyCode == 1
        {
            if let selectedNoteID {
                store.saveNoteChanges(noteID: selectedNoteID)
                showManualSaveStatus("Saved.")
            } else {
                showManualSaveStatus("Nothing selected to save.")
            }
            return nil
        }
        // Cmd + F -> Find inside editor
        if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift)
            && event.keyCode == 3
        {
            showEditorFind = true
            DispatchQueue.main.async {
                focus = .find
                postEditorFindAction("update", query: editorFindQuery)
            }
            return nil
        }
        // Cmd + , (Preferences)
        if event.modifierFlags.contains(.command) && event.keyCode == 43 {
            NotificationCenter.default.post(
                name: NSNotification.Name("NotsyShowPreferences"), object: nil)
            return nil
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {
            createNewNote(fromQuery: false)
            return nil
        }
        // Cmd + P -> toggle pin on selected note
        if event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.shift),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control),
            event.keyCode == 35
        {
            if let selectedNoteID,
                let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID })
            {
                withAnimation(.spring()) {
                    store.togglePin(for: store.notes[idx])
                }
            }
            return nil
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 37 {
            exitZenMode()
            focus = .search
            return nil
        }
        if event.keyCode == 53 {
            if focus == .editor || focus == .title {
                exitZenMode()
                focus = .search
                return nil
            } else if !queryBuffer.isEmpty {
                exitZenMode()
                queryBuffer = ""
                focus = .search
                return nil
            } else {
                onClose()
                return nil
            }
        }
        if event.keyCode == 36 {
            if focus == .search || focus == .list {
                if filteredNotes.isEmpty { createNewNote(fromQuery: true) } else { focus = .editor }
                return nil
            }
        }
        if focus != .editor && focus != .title && focus != .search && focus != .find {
            if let chars = event.characters, chars.rangeOfCharacter(from: .alphanumerics) != nil {
                focus = selectedNoteID == nil ? .search : .editor
            }
        }
        if event.keyCode == 51 && focus == .list {
            if let id = selectedNoteID, let note = store.notes.first(where: { $0.id == id }) {
                store.delete(note)
                if note.pinned {
                    self.selectedNoteID = filteredNotes.first(where: { $0.id != id })?.id
                } else {
                    self.selectedNoteID = filteredNotes.first(where: { $0.id != id && !$0.pinned })?.id
                }
                return nil
            }
        }
        return event
    }

    private func showManualSaveStatus(_ message: String) {
        manualSaveStatusTask?.cancel()
        manualSaveStatusMessage = message
        manualSaveStatusTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                manualSaveStatusMessage = nil
            }
        }
    }

    private func isSearchInputActive() -> Bool {
        guard let responder = AppDelegate.shared?.panel.firstResponder else { return false }
        guard let textView = responder as? NSTextView else { return false }
        return textView.isFieldEditor
    }

    private func toggleZenMode() {
        withAnimation(.easeInOut(duration: 0.15)) {
            zenModeEnabled.toggle()
        }
        if zenModeEnabled {
            autoExpandedSidebarForSearch = false
            if !queryBuffer.isEmpty {
                queryBuffer = ""
            }
            if showEditorFind {
                showEditorFind = false
                editorFindQuery = ""
                postEditorFindAction("close")
            }
            focus = .editor
        }
    }

    private func exitZenMode() {
        guard zenModeEnabled else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            zenModeEnabled = false
        }
    }

    private func moveSearchSelection(delta: Int) {
        guard !navigableNotes.isEmpty else { return }

        if let selectedNoteID,
            let currentIndex = navigableNotes.firstIndex(where: { $0.id == selectedNoteID })
        {
            let nextIndex = max(0, min(navigableNotes.count - 1, currentIndex + delta))
            self.selectedNoteID = navigableNotes[nextIndex].id
            return
        }

        self.selectedNoteID = navigableNotes[delta >= 0 ? 0 : navigableNotes.count - 1].id
    }

    private func handleSearchSubmit() {
        if filteredNotes.isEmpty {
            createNewNote(fromQuery: true)
        } else {
            if let first = filteredNotes.first { selectedNoteID = first.id }
            focus = .editor
        }
    }

    private func createNewNote(fromQuery: Bool) {
        let hasQuery = fromQuery && !queryBuffer.isEmpty
        let initialTitle = hasQuery ? capitalizeFirstCharacter(queryBuffer) : ""
        let newNote = Note(
            title: initialTitle, plainTextCache: "", createdAt: Date(), updatedAt: Date())

        let attrStr = NSAttributedString(
            string: "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: Theme.editorTextNSColor,
            ])
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
        max(sidebarMinWidth, min(sidebarMaxWidth, sidebarRuntimeWidth))
    }

    private var sidebarMinWidth: CGFloat { 140 }

    private var sidebarMaxWidth: CGFloat { 460 }

    private var hasCurrentSelection: Bool {
        let trimmed = selectedEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (selectedEditorRange?.length ?? 0) > 0
    }

    private func focusEditorWhenAvailable() {
        guard selectedNoteID != nil else {
            focus = .search
            return
        }
        DispatchQueue.main.async {
            focus = .editor
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            if focus == nil || focus == .search {
                focus = .editor
            }
        }
    }

    private func resolvedSelectionForOpen() -> UUID? {
        if let selectedNoteID, store.notes.contains(where: { $0.id == selectedNoteID }) {
            return selectedNoteID
        }
        if let persistedSelectedNoteID,
            store.notes.contains(where: { $0.id == persistedSelectedNoteID })
        {
            return persistedSelectedNoteID
        }
        return mostRecentlyModifiedNoteID
    }

    private func persistSelectedSelection() {
        persistedSelectedNoteIDRaw = selectedNoteID?.uuidString ?? ""
    }

    private var aiPanelState: AIPanelState {
        if aiIsRunning { return .loading }
        if !aiGeneratedText.isEmpty { return .result }
        if aiErrorMessage?.isEmpty == false { return .error }
        return .input
    }

    private var canRetryAIRequest: Bool {
        !aiLastInstruction.isEmpty && !aiLastSelectionText.isEmpty
    }

    private var aiPanelStatusText: String {
        switch aiPanelState {
        case .input: return "Input"
        case .loading: return "Generating"
        case .result: return "Result"
        case .error: return "Error"
        }
    }

    private func aiPopoverBinding(for trigger: AIPopoverTrigger) -> Binding<Bool> {
        Binding(
            get: { aiPopoverTrigger == trigger },
            set: { isPresented in
                if isPresented {
                    aiPopoverTrigger = trigger
                } else if aiPopoverTrigger == trigger {
                    aiPopoverTrigger = nil
                }
            }
        )
    }

    private func openAIPopover(_ trigger: AIPopoverTrigger) {
        // Keep layout stable and prevent search focus from visually expanding while AI is active.
        focus = .editor
        // Force a fresh presentation cycle in case AppKit didn't clear the previous binding state yet.
        if aiPopoverTrigger == trigger {
            aiPopoverTrigger = nil
            DispatchQueue.main.async {
                aiPopoverTrigger = trigger
            }
            return
        }
        if trigger == .improve && aiCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiCustomPrompt = AIQuickAction.improveWriting.instruction
        }
        if trigger == .edit {
            aiCustomPrompt = ""
        }
        aiPopoverTrigger = trigger
    }

    private func applyAIReplaceSelection() {
        pendingEditorAIAction = EditorAIActionRequest(
            kind: .replaceSelection,
            text: aiGeneratedText,
            targetRange: aiLastSelectionRange,
            attachmentPlaceholders: aiLastAttachmentPlaceholders
        )
        resetAIOverlay(clearSelection: false, clearPendingAction: false)
        aiPopoverTrigger = nil
    }

    private func applyAIInsertBelowSelection() {
        pendingEditorAIAction = EditorAIActionRequest(
            kind: .insertBelowSelection,
            text: aiGeneratedText,
            targetRange: aiLastSelectionRange,
            attachmentPlaceholders: aiLastAttachmentPlaceholders
        )
        resetAIOverlay(clearSelection: false, clearPendingAction: false)
        aiPopoverTrigger = nil
    }

    private func dismissAIError() {
        aiErrorMessage = nil
    }

    private func cancelAIRequest() {
        aiTask?.cancel()
        aiTask = nil
        aiIsRunning = false
    }

    private func aiActionChip(_ title: String, instruction: String) -> some View {
        Button(title) {
            aiCustomPrompt = instruction
        }
        .buttonStyle(PointerPlainButtonStyle())
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.textMuted)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.bg.opacity(0.45))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border.opacity(0.7), lineWidth: 0.8))
        .cornerRadius(5)
        .disabled(aiIsRunning)
    }

    @ViewBuilder
    private func aiAssistantChipGroup(note: Note) -> some View {
        if aiEnabled {
            Button(action: {
                openAIPopover(.improve)
            }) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                    .foregroundColor(Theme.textMuted)
                    .background(
                        aiPopoverTrigger == .improve ? Theme.selection.opacity(0.25) : Color.clear
                    )
                    .cornerRadius(4)
            }
            .buttonStyle(PointerPlainButtonStyle())
            .disabled(aiIsRunning)
            .popover(
                isPresented: aiPopoverBinding(for: .improve),
                attachmentAnchor: .point(.bottom),
                arrowEdge: .top
            ) {
                aiAssistantPopover(note: note)
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            .background(Theme.bg.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.border.opacity(0.9), lineWidth: 0.8)
            )
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func aiResultPreview() -> some View {
        let sourceText = aiLastSelectionText.isEmpty ? selectedEditorText : aiLastSelectionText

        VStack(alignment: .leading, spacing: 8) {
            Text("Compare")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)

            HStack(spacing: 10) {
                aiPreviewColumn(
                    title: "Current",
                    text: sourceText,
                    background: Color.red.opacity(0.10),
                    border: Color.red.opacity(0.25)
                )
                aiPreviewColumn(
                    title: "AI",
                    text: aiGeneratedText,
                    background: Color.green.opacity(0.10),
                    border: Color.green.opacity(0.25)
                )
            }

            Text("Select text in either pane and press Cmd+C to copy.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300, alignment: .topLeading)
        .background(Theme.sidebarBg.opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.85), lineWidth: 0.8))
        .cornerRadius(8)
    }

    private func aiPreviewColumn(
        title: String,
        text: String,
        background: Color,
        border: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textMuted)

            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 0.8))
            .cornerRadius(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func aiAssistantPopover(note: Note) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text(aiPanelStatusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                }

                TextField("Describe how to transform the selected text...", text: $aiCustomPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.bg.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.border.opacity(0.9), lineWidth: 0.8)
                    )
                    .cornerRadius(7)
                    .onSubmit {
                        if !aiIsRunning {
                            submitAskAI(note: note)
                        }
                    }
                    .disabled(aiIsRunning)

                HStack(spacing: 6) {
                    aiActionChip("Concise", instruction: AIQuickAction.makeShorter.instruction)
                    aiActionChip("Grammar", instruction: AIQuickAction.proofread.instruction)
                    aiActionChip("Pro", instruction: AIQuickAction.improveWriting.instruction)
                    aiActionChip(
                        "Summary",
                        instruction: "Summarize the selected text in 3 concise bullet points.")
                    aiActionChip(
                        "Bullets",
                        instruction: "Rewrite the selected text as concise bullet points.")
                    aiActionChip("Simple", instruction: AIQuickAction.simplifyLanguage.instruction)
                }
            }

            Group {
                switch aiPanelState {
                case .input:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter to run, Esc to close.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .topLeading)
                    .background(Theme.sidebarBg.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.85), lineWidth: 0.8))
                    .cornerRadius(8)
                case .loading:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating suggestion...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                        if let aiErrorMessage, aiErrorMessage.localizedCaseInsensitiveContains("network") {
                            Text("Reconnecting...")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136)
                    .background(Theme.sidebarBg.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.85), lineWidth: 0.8))
                    .cornerRadius(8)
                case .result:
                    aiResultPreview()
                case .error:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(aiErrorMessage ?? "Something went wrong while generating text.")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.9))
                        Text("Your prompt is preserved. Try again or dismiss.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .topLeading)
                    .background(Theme.sidebarBg.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.45), lineWidth: 0.8))
                    .cornerRadius(8)
                }
            }

            HStack(spacing: 8) {
                switch aiPanelState {
                case .input:
                    Button("Run") {
                        submitAskAI(note: note)
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                    .disabled(aiCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiIsRunning)

                    Button("Close") {
                        aiPopoverTrigger = nil
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                case .loading:
                    Button("Cancel") {
                        cancelAIRequest()
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                case .result:
                    Button("Replace selection") {
                        applyAIReplaceSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()

                    Button("Insert below") {
                        applyAIInsertBelowSelection()
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()

                    Button("Try again") {
                        retryLastAI(note: note)
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                    .disabled(!canRetryAIRequest || aiIsRunning)

                    Button("Close") {
                        aiPopoverTrigger = nil
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                case .error:
                    Button("Try again") {
                        retryLastAI(note: note)
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                    .disabled(!canRetryAIRequest || aiIsRunning)

                    Button("Dismiss") {
                        dismissAIError()
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
            }
        }
        .padding(12)
        .frame(width: 560)
        .background(Theme.sidebarBg)
    }

    private func diffSegments(from original: String, to rewritten: String) -> (
        prefix: String, removed: String, added: String, suffix: String
    ) {
        if original == rewritten {
            return (prefix: original, removed: "", added: "", suffix: "")
        }

        let originalChars = Array(original)
        let rewrittenChars = Array(rewritten)

        var prefixCount = 0
        let maxPrefix = min(originalChars.count, rewrittenChars.count)
        while prefixCount < maxPrefix && originalChars[prefixCount] == rewrittenChars[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        let remainingOriginal = originalChars.count - prefixCount
        let remainingRewritten = rewrittenChars.count - prefixCount
        let maxSuffix = min(remainingOriginal, remainingRewritten)
        while suffixCount < maxSuffix
            && originalChars[originalChars.count - 1 - suffixCount]
                == rewrittenChars[rewrittenChars.count - 1 - suffixCount]
        {
            suffixCount += 1
        }

        let prefix = String(originalChars.prefix(prefixCount))
        let suffix = suffixCount > 0 ? String(originalChars.suffix(suffixCount)) : ""
        let removedRange = prefixCount..<(originalChars.count - suffixCount)
        let addedRange = prefixCount..<(rewrittenChars.count - suffixCount)
        let removed = removedRange.isEmpty ? "" : String(originalChars[removedRange])
        let added = addedRange.isEmpty ? "" : String(rewrittenChars[addedRange])
        return (prefix: prefix, removed: removed, added: added, suffix: suffix)
    }

    private func runAIQuickAction(_ action: AIQuickAction, note: Note) {
        runAIInstruction(action.instruction, note: note)
    }

    private func submitAskAI(note: Note) {
        let prompt = aiCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            aiErrorMessage = "Enter a prompt for Ask AI."
            return
        }
        runAIInstruction(prompt, note: note)
    }

    private func retryLastAI(note: Note) {
        guard !aiLastInstruction.isEmpty, !aiLastSelectionText.isEmpty else { return }
        runAIInstruction(
            aiLastInstruction,
            note: note,
            selectionOverride: aiLastSelectionText,
            rangeOverride: aiLastSelectionRange,
            attachmentPlaceholdersOverride: aiLastAttachmentPlaceholders
        )
    }

    private func runAIInstruction(
        _ instruction: String,
        note: Note,
        selectionOverride: String? = nil,
        rangeOverride: NSRange? = nil,
        attachmentPlaceholdersOverride: [EditorAIAttachmentPlaceholder]? = nil
    ) {
        let fullNoteText = note.plainTextCache
        let fullNoteRange = NSRange(location: 0, length: (fullNoteText as NSString).length)
        let hasSelection = (selectedEditorRange?.length ?? 0) > 0
        let sourceRange = rangeOverride ?? (hasSelection ? selectedEditorRange : fullNoteRange)
        guard let sourceRange, sourceRange.length > 0 else {
            aiErrorMessage = "Selection changed. Select text again and retry."
            return
        }

        let selectionPayload: AISelectionPayload = {
            if let selectionOverride {
                let placeholders = attachmentPlaceholdersOverride ?? []
                return AISelectionPayload(text: selectionOverride, placeholders: placeholders)
            }
            return buildAISelectionPayload(note: note, sourceRange: sourceRange)
        }()

        let sourceSelection = selectionPayload.text
        let trimmedSelection = sourceSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else {
            aiErrorMessage = "Note is empty. Add text before using AI."
            return
        }

        aiTask?.cancel()
        aiGeneratedText = ""
        aiErrorMessage = nil
        aiIsRunning = true
        aiLastInstruction = instruction
        aiLastSelectionText = sourceSelection
        aiLastSelectionRange = sourceRange
        aiLastAttachmentPlaceholders = selectionPayload.placeholders

        let contextSnapshot = note.plainTextCache
        let selectionSnapshot = sourceSelection
        let instructionSnapshot = instruction
        let aiVisionImages = aiInputImages(from: selectionPayload.placeholders)

        aiTask = Task {
            do {
                let rewritten = try await AIWritingService.shared.rewriteSelection(
                    selection: selectionSnapshot,
                    instruction: instructionSnapshot,
                    noteContext: contextSnapshot,
                    inputImages: aiVisionImages
                )
                try Task.checkCancellation()
                await MainActor.run {
                    aiGeneratedText = rewritten
                    aiIsRunning = false
                    aiErrorMessage = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    aiIsRunning = false
                }
            } catch {
                await MainActor.run {
                    aiGeneratedText = ""
                    aiIsRunning = false
                    aiErrorMessage = aiErrorMessageText(for: error)
                }
            }

            await MainActor.run {
                aiTask = nil
            }
        }
    }

    private func aiErrorMessageText(for error: Error) -> String {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("network") || lower.contains("offline") || lower.contains("connection") {
            return "Network connection lost. Check connection and try again."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Request timed out. Try again or shorten the prompt."
        }
        return error.localizedDescription
    }

    private func resetAIOverlay(
        clearSelection: Bool,
        clearPendingAction: Bool = true
    ) {
        aiTask?.cancel()
        aiTask = nil
        aiGeneratedText = ""
        aiErrorMessage = nil
        aiIsRunning = false
        aiLastInstruction = ""
        aiLastSelectionText = ""
        aiLastSelectionRange = nil
        aiLastAttachmentPlaceholders = []
        aiCustomPrompt = ""
        aiPopoverTrigger = nil
        if clearPendingAction {
            pendingEditorAIAction = nil
        }
        if clearSelection {
            selectedEditorText = ""
            selectedEditorRange = nil
        }
    }

    private func buildAISelectionPayload(note: Note, sourceRange: NSRange) -> AISelectionPayload {
        let attributedNote = note.stringRepresentation
        let noteLength = attributedNote.length
        guard sourceRange.location != NSNotFound,
              sourceRange.location >= 0,
              sourceRange.length >= 0,
              sourceRange.location + sourceRange.length <= noteLength else {
            return AISelectionPayload(text: note.plainTextCache, placeholders: [])
        }

        let selected = attributedNote.attributedSubstring(from: sourceRange)
        let mutableText = NSMutableString(string: selected.string)
        let selectedRange = NSRange(location: 0, length: selected.length)
        var placeholders: [EditorAIAttachmentPlaceholder] = []
        var replacementIndex = 1
        var delta = 0

        selected.enumerateAttribute(.attachment, in: selectedRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let token = "[[IMAGE_\(replacementIndex)]]"
            replacementIndex += 1

            let adjusted = NSRange(location: range.location + delta, length: range.length)
            mutableText.replaceCharacters(in: adjusted, with: token)
            delta += token.utf16.count - range.length

            let snippet = selected.attributedSubstring(from: range)
            let exportRange = NSRange(location: 0, length: snippet.length)
            let data = (try? snippet.data(
                from: exportRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )) ?? (try? snippet.data(
                from: exportRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ))
            let aiImage = aiImagePayload(from: attachment)

            if let data {
                placeholders.append(
                    EditorAIAttachmentPlaceholder(
                        token: token,
                        attributedData: data,
                        aiImageData: aiImage?.data,
                        aiImageMimeType: aiImage?.mimeType
                    )
                )
            }
        }

        return AISelectionPayload(text: mutableText as String, placeholders: placeholders)
    }

    private func aiInputImages(
        from placeholders: [EditorAIAttachmentPlaceholder]
    ) -> [AIInputImage] {
        var images: [AIInputImage] = []
        var seenTokens: Set<String> = []
        for placeholder in placeholders {
            guard !seenTokens.contains(placeholder.token) else { continue }
            guard let data = placeholder.aiImageData,
                  let mimeType = placeholder.aiImageMimeType else { continue }
            seenTokens.insert(placeholder.token)
            images.append(AIInputImage(token: placeholder.token, data: data, mimeType: mimeType))
        }
        return images
    }

    private func aiImagePayload(from attachment: NSTextAttachment) -> (data: Data, mimeType: String)? {
        if let fileData = attachment.fileWrapper?.regularFileContents,
           !fileData.isEmpty,
           fileData.count <= 8_000_000 {
            let mimeType = mimeTypeForAttachment(attachment) ?? "image/png"
            return (fileData, mimeType)
        }

        guard let image = attachment.image
                ?? attachment.fileWrapper?.regularFileContents.flatMap({ NSImage(data: $0) }),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        if let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.78]
        ),
        !jpeg.isEmpty {
            return (jpeg, "image/jpeg")
        }

        if let png = rep.representation(using: .png, properties: [:]), !png.isEmpty {
            return (png, "image/png")
        }
        return nil
    }

    private func mimeTypeForAttachment(_ attachment: NSTextAttachment) -> String? {
        guard let filename = attachment.fileWrapper?.preferredFilename else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if let type = UTType(filenameExtension: ext),
           let preferred = type.preferredMIMEType {
            return preferred
        }

        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    private func postColorAction(_ action: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("NotsyToolbarAction"),
            object: nil,
            userInfo: ["action": action]
        )
    }

    private func postToolbarAction(_ action: String) {
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

    private func applyLinkEditor() {
        let trimmedURL = linkEditorURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let trimmedText = linkEditorText.trimmingCharacters(in: .whitespacesAndNewlines)

        NotificationCenter.default.post(
            name: NSNotification.Name("NotsyApplyLinkEditor"),
            object: nil,
            userInfo: ["text": trimmedText, "url": trimmedURL]
        )
        showLinkEditor = false
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
    private func formattingToolbar(note: Note) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("System") { postToolbarAction("font-system") }
                Button("Serif") { postToolbarAction("font-serif") }
                Button("Mono") { postToolbarAction("font-mono") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 4, weight: .semibold))
                    Text("Font")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.bg.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(
                        Theme.border.opacity(0.9), lineWidth: 0.8)
                )
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(PointerPlainButtonStyle())
            .pointingHandCursor()
            .fixedSize(horizontal: true, vertical: false)
            .help("Choose font style")

            HStack(spacing: 2) {
                Button(action: { postToolbarAction("font-size-down") }) {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Decrease font size")

                Button(action: { postToolbarAction("font-size-default") }) {
                    Text("A")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Reset font size")

                Button(action: { postToolbarAction("font-size-up") }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Increase font size")
            }

            Divider().frame(height: 14).background(Theme.border)

            HStack(spacing: 2) {
                Button(action: { postToolbarAction("bold") }) {
                    Text("B")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isBold ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Bold (Command-B)")

                Button(action: { postToolbarAction("italic") }) {
                    Text("I")
                        .font(.system(size: 12, weight: .semibold).italic())
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isItalic ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Italic (Command-I)")

                Button(action: { postToolbarAction("underline") }) {
                    Text("U")
                        .font(.system(size: 12, weight: .semibold))
                        .underline()
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isUnderline
                                ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Underline (Command-U)")

                Button(action: { postToolbarAction("strikethrough") }) {
                    Text("S")
                        .font(.system(size: 12, weight: .semibold))
                        .strikethrough()
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isStrikethrough
                                ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Strikethrough")
            }

            Divider().frame(height: 14).background(Theme.border)

            HStack(spacing: 2) {
                Button(action: { postToolbarAction("list") }) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isBullet ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Bullet list")

                Button(action: { postToolbarAction("checkbox") }) {
                    Image(systemName: "checkmark.square")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(
                            editorState.isCheckbox ? Theme.selection.opacity(0.32) : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Checklist")
            }

            Divider().frame(height: 14).background(Theme.border)

            HStack(spacing: 4) {
                ColorDot(color: activeEditorColor) { showColorPalette.toggle() }
                    .help("Text color")
                    .popover(
                        isPresented: $showColorPalette, attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        ColorPalettePopover { color in
                            postCustomColor(color)
                            showColorPalette = false
                        }
                    }

                Button(action: { postToolbarAction("link") }) {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Insert or edit link")

                Button(action: { spellCheckEnabled.toggle() }) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "textformat.abc.dottedunderline")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(
                                spellCheckEnabled ? Theme.selection.opacity(0.32) : Color.clear
                            )
                            .cornerRadius(4)

                        if spellCheckEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green.opacity(0.95))
                                .background(Theme.bg, in: Circle())
                                .offset(x: 2, y: 2)
                        }
                    }
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help(spellCheckEnabled ? "Disable spell check" : "Enable spell check")

                aiAssistantChipGroup(note: note)
            }
        }
        .foregroundColor(Theme.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.12), value: editorState.hasSelection)
    }

    @ViewBuilder
    private func titleEditor(for note: Note, selectedNoteID: UUID) -> some View {
        HStack {
            if note.pinned {
                Button(action: {
                    withAnimation(.spring()) {
                        if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                            store.togglePin(for: store.notes[idx])
                        }
                    }
                }) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.pinGold)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PointerPlainButtonStyle())
                .help("Unpin note")
            }
            TextField(
                "Untitled",
                text: Binding(
                    get: {
                        if let idx = store.notes.firstIndex(where: { $0.id == selectedNoteID }) {
                            return store.notes[idx].title
                        }
                        return note.title
                    },
                    set: { newValue in
                        let previousTitle =
                            store.notes.first(where: { $0.id == selectedNoteID })?.title ?? ""
                        let nextTitle =
                            previousTitle.isEmpty ? capitalizeFirstCharacter(newValue) : newValue
                        store.updateTitle(noteID: selectedNoteID, title: nextTitle)
                    }
                )
            )
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
    @State private var draggedNoteID: UUID?
    @State private var hoveredNoteID: UUID?
    @State private var hoveredSectionID: String?
    @State private var dragOverPinnedSection = false
    @State private var dragOverRecentSection = false
    @State private var dropTargetNoteID: UUID?
    @AppStorage("notsy.sidebar.section.pinned.collapsed") private var pinnedCollapsed = false
    @AppStorage("notsy.sidebar.section.today.collapsed") private var todayCollapsed = false
    @AppStorage("notsy.sidebar.section.yesterday.collapsed") private var yesterdayCollapsed = false
    @AppStorage("notsy.sidebar.section.recent.collapsed") private var recentCollapsed = true
    @AppStorage("notsy.sidebar.section.older.collapsed") private var olderCollapsed = true
    @State private var autoExpandedPreviousStates: [String: Bool] = [:]
    private let dragTypeIdentifier = UTType.plainText.identifier
    private let collapseAnimation = Animation.easeOut(duration: 0.14)

    private struct TimeBuckets {
        var today: [Note] = []
        var yesterday: [Note] = []
        var recent: [Note] = []
        var older: [Note] = []
    }

    var body: some View {
        let pinned = filteredNotes.filter { $0.pinned }
        let recent = filteredNotes.filter { !$0.pinned }
        let topHitID =
            (!queryBuffer.isEmpty && !filteredNotes.isEmpty) ? filteredNotes.first?.id : nil
        let displayPinned = pinned.filter { $0.id != topHitID }
        let displayRecent = recent.filter { $0.id != topHitID }
        let buckets = timeBuckets(from: displayRecent)

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !queryBuffer.isEmpty, let firstNote = filteredNotes.first {
                            topHitRow(note: firstNote)
                        }

                        if !displayPinned.isEmpty || draggedNoteID != nil {
                            sectionBlock(
                                id: "pinned",
                                title: "PINNED",
                                notes: displayPinned,
                                isCollapsed: $pinnedCollapsed,
                                destinationPinned: true
                            )
                        }

                        if !buckets.today.isEmpty {
                            sectionBlock(
                                id: "today",
                                title: "TODAY",
                                notes: buckets.today,
                                isCollapsed: $todayCollapsed,
                                destinationPinned: false
                            )
                        }

                        if !buckets.yesterday.isEmpty {
                            sectionBlock(
                                id: "yesterday",
                                title: "YESTERDAY",
                                notes: buckets.yesterday,
                                isCollapsed: $yesterdayCollapsed,
                                destinationPinned: false
                            )
                        }

                        if !buckets.recent.isEmpty {
                            sectionBlock(
                                id: "recent",
                                title: "LAST 7 DAYS",
                                notes: buckets.recent,
                                isCollapsed: $recentCollapsed,
                                destinationPinned: false
                            )
                        }

                        if !buckets.older.isEmpty {
                            sectionBlock(
                                id: "older",
                                title: "OLDER / ARCHIVE",
                                notes: buckets.older,
                                isCollapsed: $olderCollapsed,
                                destinationPinned: false
                            )
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
                                Text(
                                    queryBuffer.isEmpty
                                        ? "Create New Note" : "Create \"\(queryBuffer)\""
                                )
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
                        .pointingHandCursor()
                        .padding(.horizontal, 4)
                    }
                    .padding(.bottom, 16)
                }
                .onAppear {
                    expandSectionForSelection()
                    scrollSelectionIntoView(using: proxy, animated: false)
                }
                .onChange(of: selectedNoteID) { _, _ in
                    expandSectionForSelection()
                }
                .onChange(of: filteredNotes.map(\.id)) { _, _ in
                    expandSectionForSelection()
                }
                .onChange(of: draggedNoteID) { _, newValue in
                    if newValue == nil {
                        restoreAutoExpandedSections()
                    }
                }
            }
            .focused($focus, equals: .list)
        }
    }

    @ViewBuilder
    private func topHitRow(note: Note) -> some View {
        Text("TOP HIT")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

        NoteRowView(
            note: note,
            isSelected: selectedNoteID == note.id,
            contentPreviewText: contentPreviewCache[note.id] ?? note.plainTextCache,
            showsPinBadge: note.pinned
        )
        .id(note.id)
        .onDrag {
            makeDragProvider(for: note)
        }
        .onTapGesture {
            selectedNoteID = note.id
            focus = .editor
        }
    }

    private func sectionBlock(
        id: String,
        title: String,
        notes: [Note],
        isCollapsed: Binding<Bool>,
        destinationPinned: Bool
    ) -> some View {
        let selectedInSection = selectedNoteID.flatMap { selectedID in
            notes.first(where: { $0.id == selectedID })
        }
        let visibleNotes: [Note]
        if isCollapsed.wrappedValue, let selectedInSection {
            visibleNotes = [selectedInSection]
        } else if isCollapsed.wrappedValue {
            visibleNotes = []
        } else {
            visibleNotes = notes
        }

        return VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                autoExpandedPreviousStates.removeValue(forKey: id)
                withAnimation(collapseAnimation) {
                    isCollapsed.wrappedValue.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text(isCollapsed.wrappedValue ? "▸" : "▾")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .opacity(hoveredSectionID == id ? 1 : 0)
                        .frame(width: 12, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { isHovering in
                if isHovering {
                    hoveredSectionID = id
                } else if hoveredSectionID == id {
                    hoveredSectionID = nil
                }
            }

            if !visibleNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleNotes) { note in
                        noteRow(note: note, destinationPinned: destinationPinned)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(sectionDropHighlight(destinationPinned: destinationPinned))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    sectionDropBorder(destinationPinned: destinationPinned),
                    lineWidth: 1
                )
        )
        .cornerRadius(8)
        .animation(collapseAnimation, value: isCollapsed.wrappedValue)
        .onDrop(
            of: [dragTypeIdentifier],
            isTargeted: sectionDropTargetBinding(
                sectionID: id,
                isCollapsed: isCollapsed,
                destinationPinned: destinationPinned
            )
        ) { providers in
            handleDrop(providers: providers, toPinned: destinationPinned)
        }
    }

    private func sectionDropTargetBinding(
        sectionID: String,
        isCollapsed: Binding<Bool>,
        destinationPinned: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { destinationPinned ? dragOverPinnedSection : dragOverRecentSection },
            set: { isTargeted in
                if destinationPinned {
                    dragOverPinnedSection = isTargeted
                } else {
                    dragOverRecentSection = isTargeted
                }
                if isTargeted, isCollapsed.wrappedValue {
                    if autoExpandedPreviousStates[sectionID] == nil {
                        autoExpandedPreviousStates[sectionID] = isCollapsed.wrappedValue
                    }
                    withAnimation(collapseAnimation) {
                        isCollapsed.wrappedValue = false
                    }
                }
            }
        )
    }

    private func sectionDropHighlight(destinationPinned: Bool) -> Color {
        let isActive = destinationPinned ? dragOverPinnedSection : dragOverRecentSection
        return isActive ? Theme.selection.opacity(0.12) : .clear
    }

    private func sectionDropBorder(destinationPinned: Bool) -> Color {
        let isActive = destinationPinned ? dragOverPinnedSection : dragOverRecentSection
        return isActive ? Theme.selection.opacity(0.35) : .clear
    }

    private func timeBuckets(from notes: [Note]) -> TimeBuckets {
        var buckets = TimeBuckets()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let noteDay = calendar.startOfDay(for: note.updatedAt)
            if calendar.isDate(noteDay, inSameDayAs: startOfToday) {
                buckets.today.append(note)
                continue
            }
            if let yesterdayDate, calendar.isDate(noteDay, inSameDayAs: yesterdayDate) {
                buckets.yesterday.append(note)
                continue
            }
            if let daysAgo = calendar.dateComponents([.day], from: noteDay, to: startOfToday).day,
                daysAgo > 1, daysAgo <= 7
            {
                buckets.recent.append(note)
            } else {
                buckets.older.append(note)
            }
        }
        return buckets
    }

    private func expandSectionForSelection() {
        guard let selectedNoteID else { return }
        let pinned = filteredNotes.filter { $0.pinned }
        let unpinned = filteredNotes.filter { !$0.pinned }
        let topHitID =
            (!queryBuffer.isEmpty && !filteredNotes.isEmpty) ? filteredNotes.first?.id : nil
        let buckets = timeBuckets(from: unpinned.filter { $0.id != topHitID })

        if pinned.contains(where: { $0.id == selectedNoteID }) {
            pinnedCollapsed = false
        }
        if buckets.today.contains(where: { $0.id == selectedNoteID }) {
            todayCollapsed = false
        }
        if buckets.yesterday.contains(where: { $0.id == selectedNoteID }) {
            yesterdayCollapsed = false
        }
        if buckets.recent.contains(where: { $0.id == selectedNoteID }) {
            recentCollapsed = false
        }
        if buckets.older.contains(where: { $0.id == selectedNoteID }) {
            olderCollapsed = false
        }
    }

    private func restoreAutoExpandedSections() {
        guard !autoExpandedPreviousStates.isEmpty else { return }
        withAnimation(collapseAnimation) {
            if let previous = autoExpandedPreviousStates["pinned"] { pinnedCollapsed = previous }
            if let previous = autoExpandedPreviousStates["today"] { todayCollapsed = previous }
            if let previous = autoExpandedPreviousStates["yesterday"] { yesterdayCollapsed = previous }
            if let previous = autoExpandedPreviousStates["recent"] { recentCollapsed = previous }
            if let previous = autoExpandedPreviousStates["older"] { olderCollapsed = previous }
        }
        autoExpandedPreviousStates.removeAll()
    }

    @ViewBuilder
    private func noteRow(note: Note, destinationPinned: Bool) -> some View {
        NoteRowView(
            note: note,
            isSelected: selectedNoteID == note.id,
            contentPreviewText: contentPreviewCache[note.id] ?? note.plainTextCache,
            showsPinBadge: destinationPinned
        )
        .id(note.id)
        .onDrag {
            makeDragProvider(for: note)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.selection)
                .frame(height: dropTargetNoteID == note.id ? 2 : 0)
                .opacity(dropTargetNoteID == note.id ? 1 : 0)
                .padding(.horizontal, 8)
        }
        .overlay(alignment: .trailing) {
            if hoveredNoteID == note.id, draggedNoteID == nil {
                Menu {
                    Button(action: {
                        selectedNoteID = note.id
                        focus = .editor
                    }) {
                        Label("Open", systemImage: "arrow.up.forward.square")
                    }
                    Button(action: {
                        withAnimation(.spring()) { store.togglePin(for: note) }
                    }) {
                        Label(destinationPinned ? "Unpin" : "Pin", systemImage: destinationPinned ? "pin.slash" : "pin")
                    }
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.plainTextCache, forType: .string)
                    }) {
                        Label("Copy Content", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive, action: {
                        withAnimation { deleteNote(note) }
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Text("⋮")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .pointingHandCursor()
                .fixedSize()
                .help("More")
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .onDrop(of: [dragTypeIdentifier], isTargeted: dropTargetBinding(for: note.id)) {
            providers in
            handleDrop(providers: providers, toPinned: destinationPinned, before: note.id)
        }
        .onHover { isHovering in
            if isHovering {
                hoveredNoteID = note.id
                refreshRowCursor()
            } else if hoveredNoteID == note.id {
                hoveredNoteID = nil
                NSCursor.arrow.set()
            }
        }
        .onChange(of: draggedNoteID) { _, _ in
            if hoveredNoteID == note.id {
                refreshRowCursor()
            }
        }
        .onTapGesture {
            selectedNoteID = note.id
            focus = .editor
        }
        .contextMenu {
            Button(action: { withAnimation(.spring()) { store.togglePin(for: note) } }) {
                Text(destinationPinned ? "Unpin" : "Pin")
                Image(systemName: destinationPinned ? "pin.slash" : "pin")
            }
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.plainTextCache, forType: .string)
            }) {
                Text("Copy Content")
                Image(systemName: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: {
                withAnimation {
                    deleteNote(note)
                }
            }) {
                Text("Delete")
                Image(systemName: "trash")
            }
        }
    }

    private func deleteNote(_ note: Note) {
        store.delete(note)
        if selectedNoteID == note.id {
            if note.pinned {
                selectedNoteID = filteredNotes.first(where: { $0.id != note.id })?.id
            } else {
                selectedNoteID = filteredNotes.first(where: { $0.id != note.id && !$0.pinned })?.id
            }
        }
    }

    private func makeDragProvider(for note: Note) -> NSItemProvider {
        draggedNoteID = note.id
        dropTargetNoteID = nil
        refreshRowCursor()
        return NSItemProvider(object: note.id.uuidString as NSString)
    }

    private func handleDrop(
        providers: [NSItemProvider], toPinned: Bool, before beforeNoteID: UUID? = nil
    ) -> Bool {
        guard queryBuffer.isEmpty else { return false }

        if let draggedID = draggedNoteID {
            applyDrop(draggedID: draggedID, toPinned: toPinned, before: beforeNoteID)
            return true
        }

        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(dragTypeIdentifier)
            })
        else {
            return false
        }

        provider.loadItem(forTypeIdentifier: dragTypeIdentifier, options: nil) { item, _ in
            let rawValue: String?
            if let data = item as? Data {
                rawValue = String(data: data, encoding: .utf8)
            } else if let text = item as? String {
                rawValue = text
            } else if let text = item as? NSString {
                rawValue = text as String
            } else {
                rawValue = nil
            }

            guard let rawValue,
                let draggedID = UUID(
                    uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return
            }

            Task { @MainActor in
                applyDrop(draggedID: draggedID, toPinned: toPinned, before: beforeNoteID)
            }
        }

        return true
    }

    @MainActor
    private func applyDrop(draggedID: UUID, toPinned: Bool, before beforeNoteID: UUID? = nil) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.92, blendDuration: 0.05)) {
            store.moveNote(noteID: draggedID, toPinned: toPinned, before: beforeNoteID)
        }
        selectedNoteID = draggedID
        dropTargetNoteID = nil
        draggedNoteID = nil
        dragOverPinnedSection = false
        dragOverRecentSection = false
        refreshRowCursor()
        focus = .editor
    }

    private func refreshRowCursor() {
        guard hoveredNoteID != nil else { return }
        if draggedNoteID != nil {
            NSCursor.closedHand.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    private func dropTargetBinding(for noteID: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargetNoteID == noteID },
            set: { isTargeted in
                if isTargeted {
                    dropTargetNoteID = noteID
                } else if dropTargetNoteID == noteID {
                    dropTargetNoteID = nil
                }
            }
        )
    }

    private func scrollSelectionIntoView(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedNoteID else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(selectedNoteID, anchor: .center)
                }
            } else {
                proxy.scrollTo(selectedNoteID, anchor: .center)
            }
        }
    }
}
struct RichTextEditorWrapper: View {
    let note: Note
    let store: NoteStore
    @Binding var editorState: EditorState
    @Binding var activeEditorColor: NSColor
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    @Binding var pendingAIAction: EditorAIActionRequest?
    let spellCheckEnabled: Bool
    @FocusState var isFocused: MainPanel.FocusField?
    @AppStorage(Theme.themeDefaultsKey) private var themeVariantRaw: String = NotsyThemeVariant
        .bluish.rawValue
    private let placeholderLineHeight: CGFloat = CustomTextView.editorFontSize + 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            RichTextEditorView(
                note: note,
                store: store,
                editorState: $editorState,
                activeEditorColor: $activeEditorColor,
                selectedText: $selectedText,
                selectedRange: $selectedRange,
                pendingAIAction: $pendingAIAction,
                themeVariantRaw: themeVariantRaw,
                spellCheckEnabled: spellCheckEnabled
            )
            .focused($isFocused, equals: .editor)

            if note.plainTextCache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Start writing...")
                    .font(.system(size: CustomTextView.editorFontSize, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.textMuted.opacity(0.85))
                    .padding(
                        .leading,
                        CustomTextView.editorTextInset.width
                            + CustomTextView.editorLineFragmentPadding
                            + 4
                    )
                    .padding(.top, CustomTextView.editorTextInset.height + placeholderVerticalOffset)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    Theme.border.opacity(isFocused == .editor ? 0.95 : 0.78),
                    lineWidth: isFocused == .editor ? 1.6 : 1.2
                )
        )
    }

    private var placeholderVerticalOffset: CGFloat {
        guard let caretLocation = selectedRange?.location else { return 0 }
        let safeLocation = max(0, min(caretLocation, note.plainTextCache.utf16.count))
        let prefix = (note.plainTextCache as NSString).substring(to: safeLocation)
        let lineBreaks = prefix.reduce(into: 0) { count, char in
            if char == "\n" { count += 1 }
        }
        return CGFloat(lineBreaks) * placeholderLineHeight
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
        .white, .systemGray, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple, .systemPink,
        NSColor(red: 0.92, green: 0.58, blue: 0.58, alpha: 1),
        NSColor(red: 0.86, green: 0.72, blue: 0.52, alpha: 1),
        NSColor(red: 0.61, green: 0.80, blue: 0.45, alpha: 1),
        NSColor(red: 0.45, green: 0.77, blue: 0.73, alpha: 1),
        NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1),
        NSColor(red: 0.65, green: 0.52, blue: 0.95, alpha: 1),
        NSColor(red: 0.88, green: 0.50, blue: 0.83, alpha: 1),
        NSColor(red: 0.74, green: 0.74, blue: 0.74, alpha: 1),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textMuted)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(20), spacing: 8), count: 6), spacing: 8
            ) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button(action: { onSelect(color) }) {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
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
    let showsPinBadge: Bool
    @AppStorage("notsy.selection.color") private var selectionColorChoice: String = "blue"

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                        .foregroundColor(isSelected ? .white : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note.title.isEmpty ? "Untitled" : note.title)

                    if showsPinBadge {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isSelected ? .white.opacity(0.9) : Theme.pinGold)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(metadataText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.72) : Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(metadataText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(isSelected ? rowSelectionColor : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.selection.opacity(isSelected ? 1 : 0))
                .frame(width: 2)
                .padding(.vertical, 6)
        }
        .cornerRadius(8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var rowSelectionColor: Color {
        selectionColorChoice == "gray"
            ? Color(red: 0.38, green: 0.40, blue: 0.45)
            : Theme.selection
    }

    private var metadataText: String {
        if let categoryLabel {
            return "\(timeString(from: note.updatedAt)) · \(categoryLabel)"
        }
        return timeString(from: note.updatedAt)
    }

    private var categoryLabel: String? {
        if let tag = firstHashtagToken(in: note.title), !tag.isEmpty {
            return tag
        }
        if let tag = firstHashtagToken(in: contentPreviewText), !tag.isEmpty {
            return tag
        }
        if note.pinned {
            return "Pinned"
        }
        return nil
    }

    private func firstHashtagToken(in text: String) -> String? {
        for token in text.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("#"), token.count > 1 else { continue }
            let cleaned = token
                .trimmingCharacters(in: .punctuationCharacters)
                .dropFirst()
            if !cleaned.isEmpty {
                return String(cleaned).capitalized
            }
        }
        return nil
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
