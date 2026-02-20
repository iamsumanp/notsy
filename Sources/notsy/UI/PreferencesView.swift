import SwiftUI

struct PreferencesView: View {
    @Environment(NoteStore.self) private var store
    
    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 20) {
                Text("Notsy Preferences")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Hotkey")
                        .font(.subheadline)
                    HStack {
                        Text("⌘ ⇧ Space")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                        Text("*(Configurable via Xcode)*")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Management")
                        .font(.subheadline)
                    
                    Button(action: {
                        let toDelete = store.notes.filter { !$0.pinned }
                        for note in toDelete {
                            store.delete(note)
                        }
                    }) {
                        Text("Delete All Unpinned Notes")
                    }
                    
                    Button(role: .destructive, action: {
                        for note in store.notes {
                            store.delete(note)
                        }
                    }) {
                        Text("Delete Entire Database")
                            .foregroundColor(.red)
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Quit Notsy") {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 400, height: 320)
    }
}
