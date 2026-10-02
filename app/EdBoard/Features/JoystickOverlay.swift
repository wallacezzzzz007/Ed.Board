import AppKit
import SwiftUI
import BoardCore

@MainActor
final class JoystickOverlayController {
    struct Icon {
        let image: Image
        let disabled: Bool
    }
    private final class Display: ObservableObject {
        @Published var x = 0.0
        @Published var y = 0.0
        @Published var candidate = 0
        @Published var icons: [Icon] = []
    }
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let display = Display()
    private var panel: NSPanel?
    private var gesture: UInt32?
    func hide() { panel?.orderOut(nil); gesture = nil }
    func update(_ frame: JoystickFrame, icons: () -> [Icon]) {
        guard frame.visible else { hide(); return }
        if panel == nil {
            let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 260),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false; panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: Overlay(display: display))
            self.panel = panel
        }
        if gesture != frame.gesture {
            gesture = frame.gesture
            display.icons = icons() // At most eight decoded images; never decode on motion frames.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let rect = screen?.visibleFrame {
                panel?.setFrameOrigin(NSPoint(x: rect.midX - 130, y: rect.midY - 130))
            }
        }
        let x = Double(frame.x) / 1000, y = Double(frame.y) / 1000
        if display.x != x { display.x = x }
        if display.y != y { display.y = y }
        if display.candidate != frame.candidate { display.candidate = frame.candidate }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }
    static func icon(presentation: KeyPresentation, application: String?, disabled: Bool) -> Icon {
        let image: Image
        if let data = presentation.image, let value = NSImage(data: data) { image = Image(nsImage: value) }
        else if presentation.symbol == "folder" { image = Image("FolderAction") }
        else if presentation.symbol == "globe" { image = Image("URLAction") }
        else if presentation.symbol == "text.alignleft" { image = Image("PasteAction") }
        else if let application { image = Image(nsImage: NSWorkspace.shared.icon(forFile: application)) }
        else { image = ActionIconImage.image(presentation.symbol.isEmpty ? "keyboard" : presentation.symbol) }
        return Icon(image: image, disabled: disabled)
    }
    private struct Overlay: View {
        @ObservedObject var display: Display
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            ZStack {
                Circle().fill(Color(nsColor: .windowBackgroundColor))
                ForEach(Array(Control.stickIDs.enumerated()), id: \.element) { index, id in
                    let angle = Double(index) * .pi / 4
                    let selected = display.candidate == id
                    RingSector(index: index).fill(selected ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.07))
                        .overlay(RingSector(index: index).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                    if display.icons.indices.contains(index) {
                        display.icons[index].image.resizable().scaledToFit().frame(width: 28, height: 28)
                            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
                            .opacity(display.icons[index].disabled ? 0.4 : 1)
                            .offset(x: sin(angle) * 82, y: -cos(angle) * 82)
                    }
                }
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 20, weight: .regular)).foregroundStyle(.secondary))
                    .offset(x: display.x * 8, y: display.y * 8)
                    .animation(reduceMotion ? nil : .linear(duration: 0.045), value: display.x)
                    .animation(reduceMotion ? nil : .linear(duration: 0.045), value: display.y)
            }.frame(width: 240, height: 240).padding(10)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
