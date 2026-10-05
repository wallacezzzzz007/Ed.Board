import SwiftUI
import AppKit
import BoardCore

struct LayerLightingPanel: View {
    @SwiftUI.Binding var layer: Layer
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ColorChoice(title: "Keys", color: $layer.color)
                Spacer()
                ColorChoice(title: "Outer Lighting", color: $layer.ringColor)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                LightControls(value: $layer.keysLight, outer: false, showColor: false)
                Divider()
                LightControls(value: $layer.outerLight, outer: true, showColor: false)
            }
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 440)
    }
}
struct KeyLightingPanel: View {
    @ObservedObject var model: BoardModel
    private var inherited: Bool { model.binding.kind == .inherit }
    private var native: Bool { model.selectedControl < 6 && model.draft.resolved(layer: model.selectedLayer, control: model.selectedControl)?.kind == .native }
    private var custom: SwiftUI.Binding<Bool> { SwiftUI.Binding(get: { model.layer.keyLights[model.selectedControl] != nil }, set: { model.layer.keyLights[model.selectedControl] = $0 ? model.layer.keysLight : nil }) }
    private var light: SwiftUI.Binding<LightSpec> { SwiftUI.Binding(get: { model.layer.keyLights[model.selectedControl] ?? model.layer.keysLight }, set: { model.layer.keyLights[model.selectedControl] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lighting").font(.headline)
            if native { Text("Managed by Codex").foregroundStyle(.secondary) }
            else if model.binding.kind == .disabled { Text("Use layer lighting").foregroundStyle(.secondary) }
            else if inherited {
                if let value = model.draft.lightOverride(layer: model.selectedLayer, control: model.selectedControl) {
                    HStack { Circle().fill(Color(lightRGB: value.color)).frame(width: 14, height: 14); Text(value.effect == 4 ? "\(value.title) · \(value.brightness)% → \(value.active)%" : "\(value.title) · \(value.brightness)%") }.foregroundStyle(.secondary)
                } else { Text("Use layer lighting").foregroundStyle(.secondary) }
            } else {
                FullWidthPopup(title: "Lighting", selection: SwiftUI.Binding(get: { custom.wrappedValue ? "custom" : "layer" }, set: { custom.wrappedValue = $0 == "custom" }), options: [PopupOption(id: "layer", title: "Use layer lighting"), PopupOption(id: "custom", title: "Custom")]).frame(height: 32)
                if custom.wrappedValue { LightControls(value: light, outer: false, showColor: true) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct LightControls: View {
    @SwiftUI.Binding var value: LightSpec
    var outer: Bool
    var showColor: Bool
    private var modes: [(Int,String)] { outer ? [(0,"Off"),(1,"Solid"),(5,"Slow rotation"),(3,"Light on input"),(4,"Brighten on input")] : [(0,"Off"),(1,"Solid"),(2,"Breathing"),(3,"Light on press"),(4,"Brighten on press")] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showColor { ColorChoice(title: "Color", color: $value.color) }
            FullWidthPopup(title: outer ? "Outer Lighting" : "Keys", selection: SwiftUI.Binding(get: { String(value.effect) }, set: { value.effect = Int($0) ?? 0 }), options: modes.map { PopupOption(id: String($0.0), title: $0.1) }).frame(height: 32)
            level("Brightness", value: SwiftUI.Binding(get: { value.brightness }, set: { value.brightness = $0; value.active = max(value.active, $0) }))
            if value.effect == 4 { level("Active brightness", value: $value.active, minimum: value.brightness) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func level(_ title: String, value: SwiftUI.Binding<Int>, minimum: Int = 0) -> some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue)%").monospacedDigit() }.font(.callout)
            Slider(value: SwiftUI.Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }), in: Double(min(minimum, 99))...100)
                .disabled(minimum == 100)
        }
    }
}
struct ColorChoice: View {
    let title: String
    @SwiftUI.Binding var color: Int
    @State private var open = false
    var body: some View {
        HStack {
            Text(title).font(.callout)
            Button { open.toggle() } label: { RoundedRectangle(cornerRadius: 5).fill(Color(lightRGB: color)).frame(width: 32, height: 24).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.5))) }
                .buttonStyle(.plain).accessibilityLabel("Choose \(title) color")
                .popover(isPresented: $open) { InlineColorChooser(color: $color, done: { open = false }) }
        }
    }
}
private struct InlineColorChooser: View {
    @SwiftUI.Binding var color: Int
    var done: () -> Void
    @State private var hex = ""
    @FocusState private var focusedSwatch: Int?
    private let swatches = [0xffffff,0xff4545,0xff922b,0xffdc40,0x4ed66a,0x30cce0,0x3478f6,0xa66bff,0xff69bb,0x000000]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 5)) {
                ForEach(swatches, id: \.self) { value in
                    Button { color = value; sync(); clearMouseFocus() } label: {
                        Circle().fill(Color(lightRGB: value)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.secondary))
                            .overlay(Circle().stroke(color == value ? Color.accentColor : .clear, lineWidth: 2).padding(-3))
                    }.buttonStyle(.plain).focused($focusedSwatch, equals: value)
                        .accessibilityLabel(String(format: "%06X", value))
                        .accessibilityValue(color == value ? "Selected" : "")
                }
            }
            ForEach(Array([(16,"Red"),(8,"Green"),(0,"Blue")].enumerated()), id: \.offset) { _, channel in
                HStack { Text(channel.1).frame(width: 44, alignment: .leading); Slider(value: SwiftUI.Binding(get: { Double((color >> channel.0) & 255) }, set: { color = (color & ~(255 << channel.0)) | (Int($0.rounded()) << channel.0); sync() }), in: 0...255) }
            }
            HStack {
                Text("HEX")
                TextField("RRGGBB", text: $hex).textFieldStyle(.roundedBorder).onChange(of: hex) { text in
                    let raw = text.replacingOccurrences(of: "#", with: "")
                    if raw.count == 6, let parsed = Int(raw, radix: 16) { color = parsed }
                }
            }
            HStack { Spacer(); Button("Done", action: done) }
        }.padding(16).frame(width: 230).onAppear {
            sync()
            DispatchQueue.main.async { focusedSwatch = nil }
        }.onChange(of: color) { _ in clearMouseFocus() }
    }
    private func clearMouseFocus() {
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            DispatchQueue.main.async { focusedSwatch = nil }
        }
    }
    private func sync() { hex = String(format: "%06X", color) }
}
private extension Color {
    init(lightRGB: Int) { self.init(red: Double((lightRGB >> 16) & 255)/255, green: Double((lightRGB >> 8) & 255)/255, blue: Double(lightRGB & 255)/255) }
}

struct KeyLightPreview: View {
    let light: LightSpec
    let pressed: Bool
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || light.effect != 2 || reduceMotion)) { context in
            let base = Double(light.brightness) / 100
            let breathing = 0.1 + 0.9 * (0.5 - 0.5 * cos(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi))
            let level = light.effect == 0 ? 0 : light.effect == 3 ? (pressed ? base : 0) : light.effect == 4 && pressed ? Double(light.active) / 100 : light.effect == 2 && !reduceMotion ? base * breathing : base
            RoundedRectangle(cornerRadius: 10).fill(Color(lightRGB: light.color).opacity(level * 0.3))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(lightRGB: light.color).opacity(level * 0.7), lineWidth: 1))
        }.allowsHitTesting(false)
    }
}

/// Static summary of the layer's configured colors, independent of effect phase/brightness.
struct LayerLightingIndicator: View {
    let layer: Layer
    private var managed: Bool { layer.mode == .native }
    private var keysOn: Bool { !managed && layer.keysLight.effect != 0 }
    private var outerOn: Bool { !managed && layer.outerLight.effect != 0 }
    private func needsContrast(_ rgb: Int) -> Bool {
        let r = Double((rgb >> 16) & 255) / 255
        let g = Double((rgb >> 8) & 255) / 255
        let b = Double(rgb & 255) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.12 || luminance > 0.88
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary)
            if outerOn {
                if needsContrast(layer.ringColor) {
                    RoundedRectangle(cornerRadius: 6).inset(by: 1.5)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 3)
                }
                RoundedRectangle(cornerRadius: 6).inset(by: 1.5)
                    .stroke(Color(lightRGB: layer.ringColor), lineWidth: 2)
            }
            ZStack {
                if keysOn && needsContrast(layer.color) {
                    BacklightGlyph(rays: true, bar: true)
                        .stroke(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                }
                BacklightGlyph(rays: false, bar: true)
                    .stroke(keysOn ? Color(lightRGB: layer.color) : Color.secondary,
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                BacklightGlyph(rays: true, bar: false)
                    .stroke(keysOn ? Color(lightRGB: layer.color) : Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }.frame(width: 22, height: 17)
        }.frame(width: 32, height: 32).contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Original vector artwork: five rounded rays above a horizontal keyboard edge.
private struct BacklightGlyph: Shape {
    var rays: Bool
    var bar: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: CGPoint(x: rect.minX + x1 * rect.width / 24, y: rect.minY + y1 * rect.height / 18))
            path.addLine(to: CGPoint(x: rect.minX + x2 * rect.width / 24, y: rect.minY + y2 * rect.height / 18))
        }
        if bar { line(8, 15, 16, 15) }
        if rays {
            line(2, 15, 4, 15)
            line(4.5, 6.5, 6.5, 8.5)
            line(12, 2, 12, 5)
            line(19.5, 6.5, 17.5, 8.5)
            line(20, 15, 22, 15)
        }
        return path
    }
}
