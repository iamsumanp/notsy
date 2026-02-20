import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var store = NoteStore()

    static var shared: AppDelegate!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        setupPanel()
        setupStatusBarItem()

        GlobalHotkeyManager.shared.action = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWindow()
            }
        }

        NSApp.setActivationPolicy(.accessory)
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear

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
                systemSymbolName: "note.text", accessibilityDescription: "Notebar")
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
        menu.addItem(NSMenuItem(title: "Quit Notebar", action: #selector(quitAction), keyEquivalent: "q"))

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
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: NSNotification.Name("NotebarOpened"), object: nil)
    }

    func hideWindow() {
        panel.orderOut(nil)
    }

    @objc private func newNoteAction() {
        showWindow()
        NotificationCenter.default.post(name: NSNotification.Name("NotebarNewNote"), object: nil)
    }

    @objc private func searchAction() {
        showWindow()
        NotificationCenter.default.post(name: NSNotification.Name("NotebarFocusSearch"), object: nil)
    }

    @objc private func settingsAction() {}

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
