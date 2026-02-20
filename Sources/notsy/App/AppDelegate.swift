import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var store = NoteStore()

    static var shared: AppDelegate!

    var prefsWindow: NSWindow?

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
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.styleMask.insert(.fullSizeContentView)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = MainPanel(onClose: { [weak self] in
            self?.hideWindow()
        })
        .environment(store)

        let hostingView = NSHostingView(rootView: contentView)
        panel.contentView = hostingView
        panel.center()
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "note.text", accessibilityDescription: "Notsy")
            button.action = #selector(statusBarButtonClicked(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusBarButtonClicked(sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleWindow()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Note", action: #selector(newNoteAction), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Search", action: #selector(searchAction), keyEquivalent: "f"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(settingsAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Notsy", action: #selector(quitAction), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func toggleWindow() {
        if panel.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    func showWindow() {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let x = screen.frame.origin.x + (screen.frame.width - panel.frame.width) / 2
            let y = screen.frame.origin.y + (screen.frame.height - panel.frame.height) / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: NSNotification.Name("NotsyOpened"), object: nil)
    }

    func hideWindow() {
        panel.orderOut(nil)
    }

    @objc private func newNoteAction() {
        showWindow()
        NotificationCenter.default.post(name: NSNotification.Name("NotsyNewNote"), object: nil)
    }

    @objc private func searchAction() {
        showWindow()
        NotificationCenter.default.post(name: NSNotification.Name("NotsyFocusSearch"), object: nil)
    }

    @objc private func settingsAction() {
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
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
