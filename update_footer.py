import sys

path = "Sources/notsy/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# Remove from sidebar Actions
old_sidebar_action = """                        Button(action: {
                            withAnimation {
                                // Delete all unpinned
                                let toDelete = store.notes.filter { !$0.pinned }
                                for note in toDelete {
                                    store.delete(note)
                                }
                                if let selected = selectedNoteID, !store.notes.contains(where: { $0.id == selected }) {
                                    selectedNoteID = store.notes.first?.id
                                }
                            }
                        }) {
                            HStack(spacing: 12) {
                                ZRectangleIcon(icon: "trash", isSelected: false)
                                Text("Clear Unpinned Notes")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)"""
                        
content = content.replace(old_sidebar_action, "")

# Add to Footer
old_footer = """            // BOTTOM BAR
            HStack {
                HStack(spacing: 16) {
                    ShortcutBadge(key: "↵", label: "Open")
                    ShortcutBadge(key: "Tab", label: "Actions")
                }"""

new_footer = """            // BOTTOM BAR
            HStack {
                HStack(spacing: 16) {
                    ShortcutBadge(key: "↵", label: "Open")
                    ShortcutBadge(key: "Tab", label: "Actions")
                }
                
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
                .padding(.left, 8)"""

content = content.replace(old_footer, new_footer)

with open(path, "w") as f:
    f.write(content)
