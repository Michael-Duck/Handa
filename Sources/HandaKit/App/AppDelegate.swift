import AppKit
import HandaCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var welcome: WelcomeWindowController?
    private var settings: SettingsWindowController?
    private var escapeMonitor: Any?
    private var preferenceObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Automation.mark("willFinishLaunching")
        Preferences.register()
        Automation.applyAppearance()
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
        NSWindow.allowsAutomaticWindowTabbing = true
        Automation.mark("menuBuilt")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Automation.mark("didFinishLaunching")
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  let controller = NSApp.keyWindow?.windowController as? DocumentWindowController else { return event }
            return controller.handleEscape() ? nil : event
        }
        preferenceObserver = NotificationCenter.default.addObserver(forName: .handaPreferencesChanged, object: nil, queue: .main) { _ in
            AppDelegate.applyAIPreference()
        }
        AppDelegate.applyAIPreference()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        switch Automation.showOnLaunch {
        case "welcome"?: showWelcome(nil)
        case "settings"?: showSettings(nil)
        case "settings-ai"?: showSettings(nil); settings?.select(tab: 2)
        default: break
        }
    }

    private static func applyAIPreference() {
        if Preferences.aiEnabled {
            ReviewCoordinator.shared.startWatching()
        } else {
            ReviewCoordinator.shared.stopWatching()
        }
        SessionPublisher.shared.update()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Started at login to keep ready: stay out of the way until a file is opened.
        if Automation.showOnLaunch == nil, !KeepReady.isLoginLaunch { showWelcome(nil) }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SessionPublisher.shared.removeFile()
    }

    // MARK: Windows

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(sender)
        welcome?.window?.makeKeyAndOrderFront(sender)
    }

    func closeWelcome() {
        welcome?.close()
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(sender)
        settings?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showDefaultAppSettings(_ sender: Any?) {
        showSettings(sender)
        settings?.select(tab: 0)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: AppInfo.slogan + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.append(NSAttributedString(string: AppInfo.repository.absoluteString, attributes: [
            .link: AppInfo.repository, .font: NSFont.systemFont(ofSize: 11),
        ]))
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Handa",
            .credits: credits,
        ])
    }

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.repository.appendingPathComponent("#readme"))
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.repository.appendingPathComponent("issues"))
    }

    // MARK: Open With

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let document = NSApp.keyWindow.flatMap({ ($0.windowController as? DocumentWindowController)?.document as? Document }),
              let url = document.fileURL else {
            menu.addItem(withTitle: "No File", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier }
        if apps.isEmpty {
            menu.addItem(withTitle: "No Other Apps", action: nil, keyEquivalent: "").isEnabled = false
        }
        for app in apps.prefix(20) {
            let item = NSMenuItem(title: DefaultApps.appName(for: app), action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [app, url]
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[1]], withApplicationAt: pair[0], configuration: NSWorkspace.OpenConfiguration())
    }
}
