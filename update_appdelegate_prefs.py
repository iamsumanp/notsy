import sys

path = "Sources/notsy/App/AppDelegate.swift"
with open(path, "r") as f:
    content = f.read()

# Setup Preferences Window
old_appdelegate = """    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setupPanel()
        setupStatusBarItem()

        GlobalHotkeyManager.shared.action = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWindow()
            }
        }

        NSApp.setActivationPolicy(.accessory)
    }"""
    
new_appdelegate = """    var prefsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setupPanel()
        setupStatusBarItem()

        GlobalHotkeyManager.shared.action = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWindow()
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(settingsAction), name: NSNotification.Name("NotsyShowPreferences"), object: nil)

        NSApp.setActivationPolicy(.accessory)
    }"""
content = content.replace(old_appdelegate, new_appdelegate)

old_settings = """    @objc private func settingsAction() {}"""

new_settings = """    @objc private func settingsAction() {
        if prefsWindow == nil {
            let prefsView = PreferencesView()
                .environment(store)
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Notsy Preferences"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: prefsView)
            self.prefsWindow = window
        }
        
        prefsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }"""
content = content.replace(old_settings, new_settings)

with open(path, "w") as f:
    f.write(content)
