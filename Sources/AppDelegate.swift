import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makePanel()
        applyLevel()
        panel.orderFrontRegardless()
        model.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after sleep.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.model.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        }
        registerLoginItemOnFirstLaunch()
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let hostingView = WidgetHostingView(rootView: WidgetView(model: model))
        hostingView.menuProvider = { [weak self] in self?.makeMenu() }
        hostingView.onClick = { [weak self] in self?.model.refresh() }
        hostingView.onMoved = { [weak self] in self?.savePosition() }
        let size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = makeBackground(containing: hostingView, size: size)
        panel.setFrameOrigin(savedOrigin(for: size) ?? defaultOrigin(for: size))
        return panel
    }

    /// Dark clear Liquid Glass on macOS 26, which matches the system's own desktop widgets; a dark blur before that.
    private func makeBackground(containing content: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .clear
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = WidgetView.cornerRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .popover
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = cardMask(size: size)
        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }

    /// Same continuous-corner shape the SwiftUI card uses, so the blur doesn't peek out at the corners.
    private func cardMask(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(RoundedRectangle(cornerRadius: WidgetView.cornerRadius, style: .continuous).path(in: rect).cgPath)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
    }

    private var keepOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "keepOnTop") }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepOnTop")
            applyLevel()
        }
    }

    private func applyLevel() {
        // Desktop mode sits just above the desktop icons, under every regular window.
        panel.level = keepOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    // MARK: - Position

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 24, y: area.maxY - size.height - 24)
    }

    private func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let saved = UserDefaults.standard.string(forKey: "topLeft") else { return nil }
        let topLeft = NSPointFromString(saved)
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard let area = NSScreen.screens.map(\.visibleFrame).first(where: { $0.intersects(frame) }) else { return nil }
        // Keep it fully on that screen, e.g. after the widget grows.
        return NSPoint(
            x: min(max(frame.minX, area.minX), area.maxX - size.width),
            y: min(max(frame.minY, area.minY), area.maxY - size.height)
        )
    }

    /// Saved by top-left corner so the widget stays put if its height changes.
    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: "topLeft")
    }

    /// Pulls the widget back if the display it was on went away.
    private func keepOnScreen() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return }
        panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Refresh Now", #selector(refreshNow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Keep on Top of Windows", #selector(toggleKeepOnTop), checked: keepOnTop))
        menu.addItem(menuItem("Launch at Login", #selector(toggleLaunchAtLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Usage in Browser", #selector(openUsagePage)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Claude Usage", #selector(quit)))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func refreshNow() { model.refresh() }

    @objc private func toggleKeepOnTop() { keepOnTop.toggle() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func registerLoginItemOnFirstLaunch() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

/// Lets the whole widget be dragged around, refreshed with a click, and right-clicked for options.
final class WidgetHostingView: NSHostingView<WidgetView> {
    var menuProvider: (() -> NSMenu?)?
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        dragStart = window.map { (NSEvent.mouseLocation, $0.frame.origin) }
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
            y: dragStart.origin.y + mouse.y - dragStart.mouse.y
        ))
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if didDrag { onMoved?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
