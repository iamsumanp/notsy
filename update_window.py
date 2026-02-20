import sys

path = "Sources/notebar/App/AppDelegate.swift"
with open(path, "r") as f:
    content = f.read()

# Make sure window background is clear so we can control it entirely from SwiftUI
old_panel = """        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear"""
        
new_panel = """        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.hasShadow = true"""

content = content.replace(old_panel, new_panel)

with open(path, "w") as f:
    f.write(content)
