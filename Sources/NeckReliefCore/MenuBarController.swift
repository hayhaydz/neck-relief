import AppKit
import ServiceManagement
import os

/// Owns the status item, menu, hotkey wiring, and lightweight "flash" feedback
/// (the plan's no-permission-needed alternative to user notifications).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let windowManager = WindowManager()
    private let hotKeys = HotKeyManager()
    private var feedbackTimer: Timer?

    override init() {
        super.init()
        restoreIcon()
        statusItem.menu = buildMenu()
        windowManager.onFeedback = { [weak self] message in
            self?.flash(message)
        }
        hotKeys.onHotKey = { [weak self] direction in
            self?.windowManager.toggle(direction: direction)
        }
        hotKeys.install()

        if !Permissions.isTrusted {
            // Open the pane once per install; after that the menu shows state quietly.
            let flagKey = "didOpenAccessibilityPaneOnce"
            if !UserDefaults.standard.bool(forKey: flagKey) {
                UserDefaults.standard.set(true, forKey: flagKey)
                Permissions.promptIfUntrusted()
                Permissions.openAccessibilitySettings()
            }
            flash("⚠︎ accessibility needed — see menu")
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        let toggle = NSMenuItem(title: "Toggle Window ⇄ Displays",
                                action: #selector(toggleFocused),
                                keyEquivalent: "→")
        toggle.target = self
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.isEnabled = Permissions.isTrusted
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let displayManager = DisplayManager()
        let displays = displayManager.currentDisplays()
        let mouse = NSEvent.mouseLocation
        if displays.isEmpty {
            let item = NSMenuItem(title: "No displays found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for (index, display) in displays.enumerated() {
            let role = display.isPrimary ? "Primary" : "Display \(index + 1)"
            let marker = display.frame.contains(mouse) ? "   ◂ mouse" : ""
            let item = NSMenuItem(title: "\(role): \(display.name)\(marker)",
                                  action: nil,
                                  keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let diagnostics = NSMenuItem(title: "Copy Diagnostics",
                                     action: #selector(copyDiagnostics),
                                     keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        let reset = NSMenuItem(title: "Reset Toggle State",
                               action: #selector(resetState),
                               keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLoginItem),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let axTitle = Permissions.isTrusted
            ? "Accessibility: granted ✓"
            : "Grant Accessibility…"
        let axItem = NSMenuItem(title: axTitle,
                                action: #selector(openAccessibility),
                                keyEquivalent: "")
        axItem.target = self
        axItem.isEnabled = !Permissions.isTrusted
        menu.addItem(axItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Neck Relief",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleFocused() {
        windowManager.toggle(direction: .right)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            flash("⚠︎ login item: \(error.localizedDescription)")
        }
        statusItem.menu = buildMenu()
    }

    @objc private func resetState() {
        windowManager.resetState()
        flash("state reset")
    }

    @objc private func copyDiagnostics() {
        let dump = windowManager.diagnosticsDump()
        os_log("%{public}s", dump)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dump, forType: .string)
        flash("diagnostics copied")
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Feedback

    private func flash(_ text: String) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = text
        feedbackTimer?.invalidate()
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreIcon()
            }
        }
    }

    private func restoreIcon() {
        guard let button = statusItem.button else { return }
        button.title = ""
        if let image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                               accessibilityDescription: "Neck Relief") {
            image.isTemplate = true
            button.image = image
        }
    }
}
