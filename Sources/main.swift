import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// A borderless panel that floats over other apps without taking focus from them.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

let commandNotification = Notification.Name("local.usage-stats.command")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let store = UsageStore()
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard

    private var isHidden: Bool {
        get { defaults.bool(forKey: "hidden") }
        set { defaults.set(newValue, forKey: "hidden") }
    }
    private var onlyOverClaude: Bool {
        get { defaults.object(forKey: "onlyOverClaude") == nil ? true : defaults.bool(forKey: "onlyOverClaude") }
        set { defaults.set(newValue, forKey: "onlyOverClaude") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()
        registerHotKey()
        store.start()

        // `UsageStats --toggle|--show|--hide` from another process lands here.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)), name: commandNotification, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        updateVisibility()
    }

    /// Claude was just opened: bring the window back even if it was closed last time.
    @objc private func appLaunched(_ note: Notification) {
        let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard launched?.bundleIdentifier == claudeBundleID else { return }
        isHidden = false
        updateVisibility()
        store.refresh()
    }

    // MARK: Panel

    private func buildPanel() {
        let size = NSSize(width: CardView.width, height: 420)
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let root = CardView(
            store: store,
            onHide: { [weak self] in self?.setHidden(true) },
            onSize: { [weak self] size in self?.fit(to: size) }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        // Start where it was last left, else at the right edge of the main screen.
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var topLeft = NSPoint(x: visible.maxX - size.width - 28, y: visible.maxY - 90)
        if let x = defaults.object(forKey: "topLeftX") as? Double, let y = defaults.object(forKey: "topLeftY") as? Double {
            let saved = NSPoint(x: x, y: y)
            let probe = NSRect(x: saved.x, y: saved.y - 60, width: size.width, height: 60)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) { topLeft = saved }
        }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: false)
    }

    /// Resizes the panel to the card, keeping its top-left corner where it is.
    private func fit(to size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let frame = panel.frame
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard abs(frame.height - target.height) > 0.5 || abs(frame.width - target.width) > 0.5 else { return }
        panel.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - target.height, width: target.width, height: target.height),
            display: true
        )
        panel.invalidateShadow()
    }

    func windowDidMove(_ notification: Notification) {
        defaults.set(Double(panel.frame.minX), forKey: "topLeftX")
        defaults.set(Double(panel.frame.maxY), forKey: "topLeftY")
    }

    // MARK: Visibility

    @objc private func frontAppChanged() {
        updateVisibility()
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID {
            store.refresh(minInterval: 10)
        }
    }

    private func updateVisibility() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isClaudeUp = front == claudeBundleID || front == Bundle.main.bundleIdentifier
        if !isHidden && (!onlyOverClaude || isClaudeUp) {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func setHidden(_ hidden: Bool) {
        isHidden = hidden
        updateVisibility()
        // Shown on request: show it now even if Claude is not in front.
        if !hidden { panel.orderFrontRegardless() }
    }

    /// Opens the window if it is not on screen, closes it if it is.
    func toggle() { setHidden(panel.isVisible) }

    @objc private func remoteCommand(_ note: Notification) {
        switch note.object as? String {
        case "show": setHidden(false)
        case "hide": setHidden(true)
        default: toggle()
        }
    }

    /// Option-Command-U, from any app. Carbon hot keys need no extra permission.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5553_5447), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Usage Stats")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Usage Stats"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Stats Window", action: #selector(toggleShown), keyEquivalent: "u")
        show.keyEquivalentModifierMask = [.command, .option]
        show.state = panel.isVisible ? .on : .off
        menu.addItem(show)

        let only = NSMenuItem(title: "Only Show While Claude Is in Front", action: #selector(toggleOnlyOverClaude), keyEquivalent: "")
        only.state = onlyOverClaude ? .on : .off
        menu.addItem(only)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Usage Stats", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
    }

    @objc private func toggleShown() { toggle() }

    @objc private func toggleOnlyOverClaude() {
        onlyOverClaude.toggle()
        updateVisibility()
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the Open at Login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// `UsageStats --snapshot <folder>` writes a PNG of each tab, in dark and light, and exits.
func writeSnapshots(to folder: String) {
    let store = UsageStore()
    store.loadNow()
    for scheme in [ColorScheme.dark, .light] {
        for tab in CardTab.allCases {
            var size = CGSize.zero
            let view = CardView(store: store, onHide: {}, onSize: { size = $0 }, forcedTab: tab)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: CardView.width, height: 1000)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let fitting = host.fittingSize
            FileHandle.standardError.write(Data("\(tab.rawValue): reported \(size), fitting \(fitting)\n".utf8))
            if size.height < 10 { size = fitting }
            window.setContentSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = "\(tab.rawValue.lowercased())-\(scheme == .dark ? "dark" : "light").png"
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
    }
}

let app = NSApplication.shared
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    writeSnapshots(to: CommandLine.arguments[flag + 1])
    exit(0)
}
// --toggle / --show / --hide: hand the command to the running copy, if there is one.
if let command = ["toggle", "show", "hide"].first(where: { CommandLine.arguments.contains("--" + $0) }) {
    let me = NSRunningApplication.current
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.usage-stats")
        .filter { $0.processIdentifier != me.processIdentifier }
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: command, userInfo: nil, deliverImmediately: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        exit(0)
    }
    if command == "hide" { exit(0) }
    UserDefaults.standard.set(false, forKey: "hidden")
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
