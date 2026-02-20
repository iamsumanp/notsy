import sys

path = "Sources/notsy/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# Add a "Delete All Unpinned" action under the ACTIONS section in the sidebar.
old_actions = """                        Text("ACTIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 4)
                        
                        Button(action: createNewNote) {
                            HStack(spacing: 12) {
                                ZRectangleIcon(icon: "plus", isSelected: false)
                                Text(queryBuffer.isEmpty ? "Create New Note" : "Create \\"\\(queryBuffer)\\"")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.text)
                                Spacer()
                                Text("Cmd+N")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textMuted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)"""
                        
new_actions = """                        Text("ACTIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 4)
                        
                        Button(action: createNewNote) {
                            HStack(spacing: 12) {
                                ZRectangleIcon(icon: "plus", isSelected: false)
                                Text(queryBuffer.isEmpty ? "Create New Note" : "Create \\"\\(queryBuffer)\\"")
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
                        
                        Button(action: {
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

content = content.replace(old_actions, new_actions)
with open(path, "w") as f:
    f.write(content)
