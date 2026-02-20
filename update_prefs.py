import sys

path = "Sources/notsy/UI/MainPanel.swift"
with open(path, "r") as f:
    content = f.read()

# Add Cmd+, (Preferences) shortcut
old_handle = """    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {
            createNewNote(fromQuery: false)
            return nil
        }"""
        
new_handle = """    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Cmd + , (Preferences)
        if event.modifierFlags.contains(.command) && event.keyCode == 43 {
            NotificationCenter.default.post(name: NSNotification.Name("NotsyShowPreferences"), object: nil)
            return nil
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 45 {
            createNewNote(fromQuery: false)
            return nil
        }"""
content = content.replace(old_handle, new_handle)

with open(path, "w") as f:
    f.write(content)
