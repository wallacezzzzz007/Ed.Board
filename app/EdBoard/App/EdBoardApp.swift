import SwiftUI
import AppKit
import CoreServices
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: BoardModel?
    private var quitTimer: Timer?
    private var statusItem: NSStatusItem?
    private var menuTimer: Timer?
    private var batteryObserver: AnyCancellable?
    private var mainWindow: NSWindow?
    var openMainWindow: (() -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var revealWhenAttached = false
    private var launchFinished = false
    private var backgroundLogin = false

    private func detectLoginLaunch() {
        if NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            backgroundLogin = true
        }
    }

    func mainContentAppeared() {
        guard launchFinished, !backgroundLogin else {
            keepLoginWindowHidden()
            return
        }
        NSApp.setActivationPolicy(.regular)
        restoreAppIcon()
    }

    private func keepLoginWindowHidden() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI can finish ordering the initial window after attaching its content.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.launchFinished || self.backgroundLogin else { return }
            self.mainWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Login launches can create the scene without ever displaying its content.
    // Menu actions must be wired before the first window onAppear.
    func configure(model: BoardModel, openWindow: @escaping () -> Void) {
        self.model = model
        if batteryObserver == nil {
            batteryObserver = model.$batteryWarningLevel
                .combineLatest(model.$usingBluetooth, model.$connected)
                .map { level, wireless, connected in connected && wireless ? level : 0 }
                .removeDuplicates()
                .sink { [weak self] level in
                    Task { @MainActor in self?.updateBatteryIndicator(level) }
                }
        }
        openMainWindow = openWindow
    }

    func attach(_ window: NSWindow) {
        mainWindow = window
        window.isReleasedWhenClosed = false
        if !launchFinished || backgroundLogin { keepLoginWindowHidden() }
        if revealWhenAttached {
            DispatchQueue.main.async { [weak self] in self?.revealMainWindow() }
        }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let closing = note.object as? NSWindow, closing === self.mainWindow else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard self?.mainWindow?.isVisible != true, self?.revealWhenAttached != true else { return }
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }

    @objc private func showApp() {
        backgroundLogin = false
        revealWhenAttached = true
        // Finish menu tracking before activating or creating the main window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.regular)
            if self.mainWindow == nil {
                if let window = NSApp.windows.first(where: { $0.title == "Ed.Board" && !($0 is NSPanel) }) {
                    self.attach(window)
                } else {
                    self.openMainWindow?()
                }
            }
            self.revealMainWindow()
        }
    }
    private func revealMainWindow() {
        guard revealWhenAttached, let mainWindow else { return }
        revealWhenAttached = false
        NSApp.setActivationPolicy(.regular)
        mainWindow.deminiaturize(nil)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreAppIcon()
        DispatchQueue.main.async { [weak self] in self?.restoreAppIcon() }
    }
    @objc private func showSystem() {
        model?.openSystemRequested = true
        showApp()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showApp()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }

    private func installStatusMenu() {
        // 18 pt artwork with 2 pt of horizontal padding on each side.
        let item = NSStatusBar.system.statusItem(withLength: 22)
        statusItem = item
        item.button?.imagePosition = .imageOnly
        item.button?.image = Self.microIcon
        item.button?.setAccessibilityLabel("Ed.Board")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Battery · Unknown", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        for (title, action) in [("Open Ed.Board…", #selector(showApp)), ("Open System…", #selector(showSystem))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ed.Board", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        updateBatteryIndicator(model?.connected == true && model?.usingBluetooth == true ? (model?.batteryWarningLevel ?? 0) : 0)
    }
    private func updateBatteryIndicator(_ level: Int) {
        statusItem?.button?.image = level == 2 ? Self.criticalBatteryIcon : level == 1 ? Self.lowBatteryIcon : Self.microIcon
        statusItem?.button?.setAccessibilityLabel(level > 0 ? "Ed.Board · Low keyboard battery" : "Ed.Board")
        statusItem?.button?.toolTip = level == 2 ? "Ed.Board · Battery very low — charge now" : level == 1 ? "Ed.Board · Low battery — charge soon" : "Ed.Board"
    }
    func menuWillOpen(_ menu: NSMenu) {
        model?.menuStatusVisible = true
        model?.statusTick()
        updateStatus(menu)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.statusItem?.menu else { return }
                self.model?.statusTick()
                self.updateStatus(menu)
            }
        }
        menuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate(); menuTimer = nil
        model?.menuStatusVisible = false
    }
    private func updateStatus(_ menu: NSMenu) {
        guard let model else { return }
        menu.items[0].title = model.connected ? "Connected · \(model.usingBluetooth ? "Bluetooth" : "USB")" : "Disconnected"
        menu.items[0].isEnabled = false
        menu.items[1].title = "Battery · " + (model.batteryKnown ? model.batteryLabel : "Unknown")
            + (model.batteryCharging ? " · Charging" : model.batteryFull ? " · Fully charged" : model.batteryWarningLevel > 0 ? " · Charge soon" : "")
        menu.items[1].isEnabled = false
    }
    private static let lowBatteryIcon = batteryIcon(color: .systemOrange)
    private static let criticalBatteryIcon = batteryIcon(color: .systemRed)
    private static func batteryIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Preserve the normal keyboard frame; only the vertical battery is colored.
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.2; outline.stroke()
            color.setStroke(); color.setFill()
            let battery = NSBezierPath(roundedRect: NSRect(x: 6.15, y: 4.5, width: 5.7, height: 8), xRadius: 1, yRadius: 1)
            battery.lineWidth = 1.05; battery.stroke()
            NSBezierPath(roundedRect: NSRect(x: 7.65, y: 12.8, width: 2.7, height: 1), xRadius: 0.35, yRadius: 0.35).fill()
            NSBezierPath(roundedRect: NSRect(x: 7.5, y: 5.85, width: 3, height: 1.65), xRadius: 0.35, yRadius: 0.35).fill()
            return true
        }
        image.isTemplate = false // Keep battery colors instead of tinting the entire frame.
        image.cacheMode = .never // Resolve the frame's label color in the menu bar's drawing appearance.
        return image
    }
    private static let microIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.2; outline.stroke()
            for row in 0..<4 {
                for col in 0..<4 {
                    let rect = NSRect(x: 3 + Double(col) * 3.1, y: 3 + Double(row) * 3.1, width: 2.5, height: 2.5)
                    if (row == 3 && (col == 0 || col == 3)) || (row == 0 && col == 0) { NSBezierPath(ovalIn: rect).fill() }
                    else { NSBezierPath(roundedRect: rect, xRadius: 0.6, yRadius: 0.6).fill() }
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
    func applicationWillFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        detectLoginLaunch()
        launchFinished = true
        installStatusMenu()
        restoreAppIcon()
        AppLog.shared.event("launch presentation=\(backgroundLogin ? "background-login" : "window")")
        if backgroundLogin { keepLoginWindowHidden() }
        else { showApp() }
    }
    func restoreAppIcon() {
        // Activation-policy changes can restore the system placeholder; reapply the bundled icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.firmware.active == true {
            showApp()
            let alert = NSAlert(); alert.messageText = "Firmware update in progress"
            alert.informativeText = "Keep the app open and the keyboard connected until the update finishes."
            alert.runModal(); return .terminateCancel
        }
        guard let model, model.dirty || model.powerDirty else { return .terminateNow }
        showApp()
        let alert = NSAlert()
        alert.messageText = "Save your changes before quitting?"
        alert.informativeText = "Unsaved changes will be lost if you discard them."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .terminateNow
        case .alertFirstButtonReturn:
            guard !model.busy, (!model.dirty || model.canSave), (model.dirty || model.canSavePower) else {
                let failure = NSAlert(); failure.messageText = "Changes cannot be saved yet."
                failure.informativeText = "Reconnect the keyboard and resolve any errors before quitting."; failure.runModal()
                return .terminateCancel
            }
            let deadline = Date().addingTimeInterval(75)
            let savedKeymap = model.dirty
            if savedKeymap { model.save() } else { model.savePower() }
            var powerStarted = !savedKeymap
            quitTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if model.busy && Date() < deadline { return }
                    if !model.dirty && model.powerDirty && !powerStarted && model.canSavePower {
                        powerStarted = true; model.savePower(); return
                    }
                    self.quitTimer?.invalidate(); self.quitTimer = nil
                    NSApp.reply(toApplicationShouldTerminate: !model.dirty && !model.powerDirty && !model.busy)
                }
            }
            return .terminateLater
        default: return .terminateCancel
        }
    }
}

@main
struct EdBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BoardModel()
    var body: some Scene {
        let _ = delegate.configure(model: model, openWindow: { openWindow(id: "main") })
        Window("Ed.Board", id: "main") {
            BoardView(model: model)
                .background(MainWindowReference { delegate.attach($0) })
                .onAppear {
                    delegate.mainContentAppeared()
                }
        }.windowStyle(.titleBar).windowToolbarStyle(.unified).defaultSize(width: 1080, height: 760)
    }
}

private struct MainWindowReference: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor(attach: attach) }
    func updateNSView(_ view: Anchor, context: Context) { view.attach = attach }
    final class Anchor: NSView {
        var attach: (NSWindow) -> Void
        init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach(window) }
        }
    }
}
