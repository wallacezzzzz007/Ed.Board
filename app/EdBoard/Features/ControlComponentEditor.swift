import SwiftUI
import BoardCore

struct ControlComponentEditor: View {
    @ObservedObject var model: BoardModel
    let knob: Bool
    let selected: Int?
    let select: (Int) -> Void
    let back: () -> Void
    @State private var holdFeedback = false
    @State private var holdWork: DispatchWorkItem?
    private let knobTitles = ["Turn left", "Turn right", "Click", "Press and hold"]
    private let directionTitles = ["Up", "Up right", "Right", "Down right", "Down", "Down left", "Left", "Up left"]
    private var liveDirection: Int? {
        guard max(abs(model.previewX), abs(model.previewY)) > 0.3 else { return nil }
        var angle = atan2(model.previewX, -model.previewY)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (.pi / 4) + 0.5).rounded(.down)) % 8
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(knob ? "Knob" : "Quick Selection").font(.title3.weight(.semibold))
                if knob {
                    HelpNote(text: "Click runs on release. Hold for 0.6 seconds to run Press and hold once, without Click.")
                } else if model.selectedLayer != 1 {
                    FullWidthPopup(title: "Inherit all directions", selection: SwiftUI.Binding(
                        get: { String(model.quickSelectionSource) },
                        set: { if let source = Int($0) { ShortcutRecorder.cancelAll(); model.setQuickSelectionSource(source) } }),
                        options: [PopupOption(id: "0", title: "Off")] + model.quickSelectionSources.map {
                            PopupOption(id: String($0.id), title: "Inherit: \($0.name)")
                        }).frame(width: 170, height: 30)
                }
            }
            if knob {
                LazyVGrid(columns: [GridItem(.fixed(156)), GridItem(.fixed(156))], spacing: 12) {
                    ForEach(Array(Control.knobIDs.enumerated()), id: \.element) { index, id in
                        Button { select(id) } label: {
                            VStack(spacing: 10) {
                                Text(knobTitles[index]).font(.callout.weight(.medium))
                                icon(id).frame(width: 32, height: 32)
                                Text(model.actionName(id)).font(.caption).lineLimit(2).frame(height: 30)
                            }.frame(width: 148, height: 124)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(activeKnob(id) ? 0.22 : 0)).allowsHitTesting(false))
                                .overlay(RoundedRectangle(cornerRadius: 9).inset(by: 5).stroke(.white.opacity(activeKnob(id) ? 0.95 : 0), lineWidth: 3).allowsHitTesting(false))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == id ? Color.accentColor : .clear, lineWidth: 2))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).fastHelp("\(knobTitles[index]): \(model.actionName(id))").accessibilityLabel("\(knobTitles[index]), \(model.actionName(id))")
                    }
                }
            } else {
                ZStack {
                    ForEach(Array(Control.stickIDs.enumerated()), id: \.element) { index, id in
                        let angle = Double(index) * .pi / 4
                        Button { select(id) } label: {
                            RingSector(index: index)
                                .fill(Color.primary.opacity(0.07))
                                .overlay(RingSector(index: index).fill(.white.opacity(liveDirection == index ? 0.24 : 0)))
                                .overlay(RingSector(index: index).stroke(.white.opacity(liveDirection == index ? 0.95 : 0), lineWidth: 7))
                                .overlay(RingSector(index: index).stroke(selected == id ? Color.accentColor : .clear, lineWidth: 2))
                                .overlay {
                                    icon(id).frame(width: 28, height: 28)
                                        .offset(x: sin(angle) * 112, y: -cos(angle) * 112)
                                }.contentShape(RingSector(index: index))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(directionTitles[index]), \(model.actionName(id))")
                    }
                    Circle().fill(Color.primary.opacity(0.08)).frame(width: 68, height: 68)
                        .overlay(Image(systemName: model.previewCancelled ? "xmark" : "plus").foregroundStyle(model.previewCancelled ? Color.orange : .secondary))
                        .offset(x: model.previewX * 12, y: model.previewY * 12).allowsHitTesting(false)
                }.frame(width: 324, height: 324)
            }
            if !knob && model.previewCancelled { Text("Release to cancel").font(.caption).foregroundStyle(.orange) }
            Button(action: back) { Label("Back to layout", systemImage: "arrow.left") }
        }.padding(.horizontal, 12).disabled(!model.canEdit)
            .onChange(of: model.previewKeys & (1 << 13) != 0) { pressed in
                holdWork?.cancel(); holdFeedback = false
                if pressed {
                    let work = DispatchWorkItem { holdFeedback = true }
                    holdWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
            }.onDisappear { holdWork?.cancel() }
    }
    private func activeKnob(_ id: Int) -> Bool {
        if id == 15 { return model.previewTurnLeft }
        if id == 14 { return model.previewTurnRight }
        return (model.previewKeys | model.previewPressed) & (1 << 13) != 0 && (id == 20 ? holdFeedback : !holdFeedback)
    }
    private func icon(_ id: Int) -> some View {
        ActionIcon(presentation: model.presentationFor(layer: model.selectedLayer, control: id), application: model.applicationTarget(id), codex: false)
    }
}
struct RingSector: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 3
        let inner = outer * 0.43
        let start = Double(index) * 45 - 110
        let end = start + 40
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
