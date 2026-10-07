import SwiftUI
import Combine
import AppKit
import ApplicationServices
import CoreBluetooth
import ServiceManagement
import UniformTypeIdentifiers
import BoardCore

private enum BoardPage: String { case keymap, settings, system }

struct BoardView: View {
    @ObservedObject var model: BoardModel
    @AppStorage("appearance") private var appearance = "System"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = BoardPage.keymap
    @State private var inspector = false
    @State private var component = "layout"
    @State private var keySelected = false
    @State private var layerMenu = false
    @State private var layerSearch = ""
    @State private var layerOperation: String?
    @State private var confirmingLayerOperation = false
    @State private var renamingLayer = false
    @State private var permissionCheck = Date.distantPast
    @State private var bluetoothAuthorized = CBManager.authorization == .allowedAlways
    @State private var accessibilityAuthorized = AXIsProcessTrusted()
    @State private var lighting = false
    @State private var linking = false
    @State private var timedOut = false
    @State private var phaseStarted = Date()
    @State private var confirmingPairingClear = false
    @State private var diagnostics = false
    @State private var dragging: Int?
    @State private var dropTarget: Int?
    @State private var movedLayer: Int?
    @State private var hoverKey: Int?
    @State private var tooltipKey: Int?
    @State private var hoverWork: DispatchWorkItem?
    @FocusState private var namingLayer: Bool
    @State private var windowVisible = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .keymap:
                    if model.firmwareMismatch || model.firmware.blocksEditor { FirmwareLoadingView(model: model, openSystem: { navigate(.system) }) }
                    else if model.snapshot != nil { keymap }
                    else { connectionPage }
                case .settings: settings.disabled(model.firmware.active)
                case .system: system
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 640)
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
        .background(WindowConfiguration())
        .background(DragEndMonitor(finishDrag: { dragging = nil; dropTarget = nil }).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Ed.Board").font(.system(size: 19, weight: .semibold))
                    .frame(height: 44)
            }.withoutSharedToolbarBackground()
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: Binding<BoardPage?>(
                    get: { page == .system ? nil : page },
                    set: { if let target = $0 { navigate(target) } }
                )) {
                    Text("Keymap").tag(Optional(BoardPage.keymap))
                    Text("Settings").tag(Optional(BoardPage.settings))
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 220, height: 44)
            }.withoutSharedToolbarBackground()
            ToolbarItem(placement: .primaryAction) {
                Button { navigate(.system) } label: {
                    Image(systemName: model.firmwareMismatch || model.firmware.blocksEditor ? "exclamationmark.triangle.fill" : "gearshape")
                        .font(.system(size: 19))
                        .foregroundStyle(model.firmwareMismatch || model.firmware.blocksEditor ? Color.red : page == .system ? Color.accentColor : .secondary)
                        .frame(width: 36, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("System")
            }
        }
        .onChange(of: model.openSystemRequested) { requested in
            if requested { navigate(.system); model.openSystemRequested = false }
        }
        .onAppear { if model.openSystemRequested { navigate(.system); model.openSystemRequested = false }; windowVisible = true; model.beginInitialDiscovery(); model.setPreviewVisible(page == .keymap); model.setStatusVisible(page == .settings) }
        .onDisappear { windowVisible = false; model.setPreviewVisible(false); model.setStatusVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title == "Ed.Board" { windowVisible = window.occlusionState.contains(.visible); model.setPreviewVisible(page == .keymap && windowVisible); model.setStatusVisible(page == .settings && window.occlusionState.contains(.visible)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title == "Ed.Board" { windowVisible = false; model.setPreviewVisible(false); model.setStatusVisible(false) }
        }
        .onChange(of: page) { value in clearSelection(); model.setPreviewVisible(value == .keymap && windowVisible); model.setStatusVisible(value == .settings && windowVisible) }
        .onChange(of: model.firmware.stage) { stage in
            if stage == "entering" { navigate(.keymap) }
        }
        .onChange(of: model.selectedLayer) { _ in clearSelection(); if model.selectedLayer == 1 { component = "layout" } }
        .onChange(of: model.layer.mode) { _ in clearSelection() }
        .onChange(of: model.selectedControl) { _ in ShortcutRecorder.cancelAll() }
        .onChange(of: inspector) { value in if !value { ShortcutRecorder.cancelAll() } }
        .onChange(of: model.info?.serial) { _ in phaseStarted = Date(); timedOut = false }
        .onChange(of: model.connected) { _ in phaseStarted = Date(); timedOut = false }
        .task(id: windowVisible) {
            guard windowVisible else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard !Task.isCancelled, windowVisible else { return }
                model.previewTick(); model.statusTick()
                if page == .system && Date().timeIntervalSince(permissionCheck) >= 1 { permissionCheck = Date(); bluetoothAuthorized = CBManager.authorization == .allowedAlways; accessibilityAuthorized = AXIsProcessTrusted() }
                if !timedOut && model.snapshot == nil && Date().timeIntervalSince(phaseStarted) >= 10 { timedOut = true }
            }
        }
        .alert(layerOperation == "Delete" ? "Delete this layer?" : "Reset this layer?", isPresented: $confirmingLayerOperation) {
            Button("Cancel", role: .cancel) {}
            Button(layerOperation ?? "Reset", role: .destructive) {
                if layerOperation == "Delete" { model.deleteLayer() } else { model.resetLayer() }
                clearSelection()
            }
        } message: {
            Text(layerOperation == "Delete" ? "Remove this layer.\nSave Changes to apply." : (model.selectedLayer == 1 ? "Restore all actions to Managed by Codex and remove app links.\nSwitch to Custom mode." : "Disable custom actions and remove app links.") + "\nReset lighting to white at 15%. Keep the name." + "\nSave Changes to apply.")
        }
        .onChange(of: model.applicationLinkConflict) { message in
            if message != nil { linking = false }
        }
        .alert("Application already linked", isPresented: Binding(
            get: { model.applicationLinkConflict != nil },
            set: { if !$0 { model.applicationLinkConflict = nil } }
        )) {
            Button("OK", role: .cancel) { model.applicationLinkConflict = nil }
        } message: { Text(model.applicationLinkConflict ?? "") }
        .alert("Clear keyboard pairing?", isPresented: $confirmingPairingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear pairing", role: .destructive) { model.clearPairing() }
        } message: { Text("Keep layer settings.\nBefore pairing again, forget Codex Micro in macOS Bluetooth settings.") }
    }

    private func navigate(_ target: BoardPage) {
        clearSelection(); page = target
        if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDown {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
    private func clearSelection() { keySelected = false; clearTooltip(); ShortcutRecorder.cancelAll() }
    private func dismissSelection() { inspector = false; clearSelection() }
    private func clearTooltip() { hoverWork?.cancel(); hoverWork = nil; hoverKey = nil; tooltipKey = nil }
    private func hover(_ id: Int, inside: Bool) {
        if !inside { if hoverKey == id { clearTooltip() }; return }
        clearTooltip(); hoverKey = id
        let work = DispatchWorkItem { if hoverKey == id { tooltipKey = id } }
        hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    private var connectionPage: some View {
        VStack(spacing: 16) {
            if timedOut || model.errorText != nil {
                Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 42)).foregroundStyle(.secondary)
                Text(model.info == nil ? "No keyboard found" : "Couldn't load keyboard settings").font(.title2.weight(.semibold))
                Text(model.errorText ?? "Check your USB or Bluetooth connection and try again.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("Retry") { timedOut = false; phaseStarted = Date(); model.retryConnection() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                ProgressView().controlSize(.large)
                Text(model.info == nil ? "Connecting to your keyboard…" : "Loading keyboard settings…").font(.title2.weight(.semibold))
                Text(model.info == nil ? "Looking for a USB or Bluetooth connection." : "Codex Micro connected")
                    .foregroundStyle(.secondary)
            }
            if !model.connected {
                Button("Connect via Bluetooth") { timedOut = false; phaseStarted = Date(); model.connect(wireless: true) }
                    .disabled(model.busy)
            }
        }.padding(32)
    }
    private var keymap: some View {
        HStack(spacing: 0) {
            extendedSidebar
            Divider()
            VStack(spacing: 0) {
                layers.padding(.top, 22).padding(.bottom, 14)
                Spacer(minLength: 12)
                if component == "layout" { keyboard }
                else {
                    ScrollView {
                    ControlComponentEditor(model: model, knob: component == "knob", selected: keySelected ? model.selectedControl : nil, select: { id in
                        ShortcutRecorder.cancelAll(); model.selectedControl = id; keySelected = true; inspector = true
                    }, back: { clearSelection(); component = "layout" }).frame(maxWidth: .infinity)
                    }.frame(maxHeight: 420)
                }
                Spacer(minLength: 16)
                saveBar.padding(.horizontal, 24).padding(.bottom, 26)
            }.frame(maxWidth: .infinity)
            if inspector {
                Divider()
                KeyInspector(model: model, selected: keySelected && model.layer.mode != .native && (model.selectedControl < 13 || model.selectedLayer != 1), close: dismissSelection).frame(width: 320)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
    private var visibleExtendedLayers: [Layer] {
        model.draft.extendedLayers.filter { layerSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(layerSearch) }
    }
    private var extendedSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Extended").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { if model.addLayer(favorite: false) { layerSearch = ""; renamingLayer = true } } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.plain).accessibilityLabel("Add extended layer").disabled(!model.canEdit)
            }
            TextField("Search layers", text: $layerSearch).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search extended layers")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleExtendedLayers) { layer in
                        Button { clearSelection(); model.selectedLayer = layer.id } label: {
                            HStack {
                                Text(layer.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 10)
                                .foregroundStyle(model.selectedLayer == layer.id ? Color.white : .primary)
                                .background(model.selectedLayer == layer.id ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { model.selectedLayer = layer.id; renamingLayer = true })
                            .contextMenu { layerContextMenu(layer) }
                        if layer.id != visibleExtendedLayers.last?.id {
                            Divider().padding(.horizontal, 10).padding(.vertical, 3)
                        }
                    }
                    if model.draft.extendedLayers.isEmpty {
                        Text("Extra layers live here.\nAdd one or move a favorite.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    } else if visibleExtendedLayers.isEmpty {
                        Text("No matching layers").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
            }
            Text("\(model.draft.layers.count) / 16 layers").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 180).frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.025))
    }
    @ViewBuilder private func layerContextMenu(_ layer: Layer) -> some View {
        Group {
            let favorite = model.draft.favorites.contains(layer.id)
            let order = favorite ? model.draft.favorites : model.draft.extendedLayers.map(\.id)
            let index = order.firstIndex(of: layer.id) ?? 0
            Button("Rename") { model.selectedLayer = layer.id; renamingLayer = true }
            Button(favorite ? "Move to Extended" : "Move to Favorites") { model.setLayerFavorite(layer.id, !favorite) }
            Divider()
            Button(favorite ? "Move Left" : "Move Up") { model.selectedLayer = layer.id; model.moveLayer(-1) }.disabled(index == 0)
            Button(favorite ? "Move Right" : "Move Down") { model.selectedLayer = layer.id; model.moveLayer(1) }.disabled(index == order.count - 1)
            if layer.id != 1 {
                Button("Delete layer", role: .destructive) { model.selectedLayer = layer.id; layerOperation = "Delete"; confirmingLayerOperation = true }
                    .disabled(!model.draft.canDelete(layer.id))
            }
        }.disabled(!model.canEdit)
    }
    private var layers: some View {
        VStack(spacing: 16) {
            GeometryReader { space in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Favorites").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        Divider().frame(height: 22).padding(.horizontal, 6)
                        ForEach(model.draft.favoriteLayers) { layer in
                            Button { clearSelection(); model.selectedLayer = layer.id } label: {
                                Text(layer.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    .frame(maxWidth: 120).padding(.horizontal, 12).frame(height: 34)
                                    .foregroundStyle(model.selectedLayer == layer.id ? Color.white : .primary)
                                    .background(model.selectedLayer == layer.id ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { model.selectedLayer = layer.id; renamingLayer = true })
                                .opacity(dragging == layer.id ? 0.4 : 1)
                                .overlay(alignment: .leading) {
                                    if dropTarget == layer.id && dragging != layer.id { Capsule().fill(Color.accentColor).frame(width: 3, height: 30).offset(x: -5) }
                                }
                                .onDrag {
                                    clearSelection(); dragging = layer.id
                                    return NSItemProvider(object: "edboard-layer:\(layer.id)" as NSString)
                                }
                                .onDrop(of: [.text], delegate: LayerReorderDrop(model: model, target: layer.id, dragging: $dragging, targetID: $dropTarget, moved: $movedLayer, reduceMotion: reduceMotion))
                                .contextMenu { layerContextMenu(layer) }
                        }
                        Button { if model.addLayer() { renamingLayer = true } } label: {
                            Image(systemName: "plus").frame(width: 34, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("Add favorite layer")
                    }.fixedSize(horizontal: true, vertical: false).frame(minWidth: space.size.width, alignment: .center)
                }
            }.frame(height: 34)
            GeometryReader { space in
                // Use the name's natural width; reserve room for the fixed controls on narrow windows.
                let measured = (model.layer.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
                let nameWidth = min(max(32, ceil(measured) + 4), max(32, min(260, space.size.width - 230)))
                HStack(spacing: 12) {
                    Text("Editing:").foregroundStyle(.secondary).fixedSize()
                    Button { renamingLayer = true } label: { Text(model.layer.name).lineLimit(1).truncationMode(.tail).frame(width: nameWidth, alignment: .leading) }
                        .buttonStyle(.plain).accessibilityLabel("Rename current layer")
                        .popover(isPresented: $renamingLayer, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Layer Name").font(.headline)
                                TextField("Layer name", text: $model.layer.name).textFieldStyle(.roundedBorder).focused($namingLayer).onSubmit { renamingLayer = false }
                                Button("Done") { renamingLayer = false }.frame(maxWidth: .infinity, alignment: .trailing)
                            }.padding(18).frame(width: 260).onAppear { DispatchQueue.main.async { namingLayer = true } }
                        }
                    Divider().frame(height: 22).padding(.horizontal, 4)
                    Button { lighting.toggle() } label: { LayerLightingIndicator(layer: model.layer) }.buttonStyle(.plain)
                        .disabled(model.layer.mode == .native).accessibilityLabel("Layer lighting")
                        .accessibilityValue(model.layer.mode == .native ? "Managed by Codex" : "Keys: \(model.layer.keysLight.title), \(String(format: "#%06X", model.layer.color)). Outer Lighting: \(model.layer.outerLight.title), \(String(format: "#%06X", model.layer.ringColor)).")
                        .popover(isPresented: $lighting, arrowEdge: .bottom) { lightingPanel }
                    Button { linking.toggle() } label: {
                        Image("LayerLink").resizable().scaledToFit().frame(width: 17, height: 17)
                            .foregroundStyle(model.selectedAutoRule.enabled ? Color.accentColor : .secondary)
                            .frame(width: 32, height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel("Auto-link applications")
                        .popover(isPresented: $linking, arrowEdge: .bottom) { linkPanel }
                    Button { layerMenu.toggle() } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel("Layer options")
                        .popover(isPresented: $layerMenu, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 12) {
                                Button(model.draft.favorites.contains(model.layer.id) ? "Move to Extended" : "Move to Favorites") {
                                    layerMenu = false; model.setLayerFavorite(model.layer.id, !model.draft.favorites.contains(model.layer.id))
                                }
                                Button("Rename") { layerMenu = false; renamingLayer = true }
                                Divider()
                                if model.layer.id != 1 {
                                    Button("Delete", role: .destructive) { layerOperation = "Delete"; layerMenu = false; confirmingLayerOperation = true }
                                        .disabled(!model.draft.canDelete(model.layer.id))
                                    if !model.draft.canDelete(model.layer.id) {
                                        Text(model.draft.favorites == [model.layer.id] ? "Keep at least one favorite." : "Other layers inherit from this layer.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Button("Reset", role: .destructive) { layerOperation = "Reset"; layerMenu = false; confirmingLayerOperation = true }
                            }.frame(width: 190, alignment: .leading).padding(16)
                        }
                }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .center)
            }.frame(height: 32)
            if model.layer.id == 1 {
                HStack(spacing: 10) {
                    Text("Codex Mode:").font(.callout)
                    Picker("Codex mode", selection: $model.layer.mode) {
                        Text("Native").tag(LayerMode.native); Text("Custom").tag(LayerMode.custom)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
        }.padding(.horizontal, 18).controlSize(.small).disabled(!model.canEdit)
    }
    private var lightingPanel: some View {
        LayerLightingPanel(layer: $model.layer, done: { lighting = false }).disabled(model.layer.mode == .native)
    }
    private var linkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Auto-detect", isOn: SwiftUI.Binding(get: { model.selectedAutoRule.enabled }, set: { model.setAutoEnabled($0) }))
            ForEach(model.selectedAutoRule.applications) { app in
                HStack { Text(app.name); Spacer(); Button { model.removeLinkedApplication(app.bundleID) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove \(app.name)") }
            }
            Button("Add application…") { model.chooseApplication() }.disabled(model.selectedAutoRule.applications.count >= 8)
            if let error = model.autoError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(20).frame(width: 300).disabled(!model.canLinkApplication)
    }
    private var keyboard: some View {
        VStack(spacing: 12) {
            ZStack {
                VStack(spacing: 7) {
                    HStack(spacing: 7) { knob; key(0); key(1); stick }
                    HStack(spacing: 7) { key(2); key(3); key(4); key(5) }
                    HStack(spacing: 7) { key(6); key(7); key(8); key(9) }
                    HStack(spacing: 7) { touch; key(10); key(11); key(12) }
                }.padding(15).background(Color.black, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(rgb: model.layer.ringColor).opacity(Double(model.layer.outerLight.effect == 0 ? 0 : model.layer.outerLight.brightness)/180), lineWidth: 2))
                    .opacity(model.layer.mode == .native ? 0.3 : 1)
                if model.layer.mode == .native {
                    Text("All settings are managed in Codex.").font(.callout.weight(.medium)).multilineTextAlignment(.center)
                        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).frame(width: 250)
                        .allowsHitTesting(false)
                }
            }.frame(width: 355, height: 355)
                .overlay(alignment: .top) {
                    if let id = tooltipKey {
                        let rows = [0,0,1,1,1,1,2,2,2,2,3,3,3]
                        let cols = [1,2,0,1,2,3,0,1,2,3,1,2,3]
                        Text(id == 13 ? knobHelp : id == 14 ? (model.selectedLayer == 1 ? "Quick Selection\nManaged by Codex" : "Quick Selection") : model.actionName(id)).font(.system(size: 16, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
                            .frame(maxWidth: 260).fixedSize(horizontal: false, vertical: true)
                            .offset(x: id >= 13 ? 0 : (Double(cols[id]) - 1.5) * 55, y: id >= 13 ? -50 : Double(rows[id]) * 83 - 35)
                            .allowsHitTesting(false)
                    }
                }
            if model.info?.previewVersion != 1 || model.previewUnavailable {
                HStack(spacing: 6) { Text("Live preview unavailable").font(.caption).foregroundStyle(.secondary); HelpNote(text: "Live input feedback requires firmware with preview support.") }
            }
        }
    }
    private func key(_ id: Int) -> some View {
        let content = model.presentationFor(layer: model.selectedLayer, control: id)
        let effective = model.draft.resolved(layer: model.selectedLayer, control: id)
        let disabled = effective?.kind == .disabled
        let pressed = (model.previewKeys | model.previewPressed) & (1 << id) != 0
        return Button { clearTooltip(); model.selectedControl = id; keySelected = true; inspector = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: disabled ? 0.09 : 0.18))
                if model.layer.mode != .native, let light = model.draft.resolvedLight(layer: model.selectedLayer, control: id) {
                    KeyLightPreview(light: light, pressed: pressed, active: windowVisible)
                }
                if model.layer.mode != .native {
                    ActionIcon(presentation: content, application: model.applicationTarget(id), codex: effective?.kind == .native)
                        .frame(width: 40, height: 40).foregroundStyle(.white.opacity(disabled ? 0.3 : 0.95))
                }
                RoundedRectangle(cornerRadius: 10).stroke(pressed ? Color.white.opacity(0.85) : model.selectedControl == id && inspector && keySelected ? Color.accentColor : .clear, lineWidth: 2)
                if pressed { RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)) }
            }.frame(width: 76, height: 76)
        }.buttonStyle(.plain).onHover { hover(id, inside: $0) }.accessibilityLabel("Key \(id + 1), \(model.actionName(id))")
            .disabled(model.layer.mode == .native || !model.canEdit)
    }
    private var knobHelp: String {
        "Key Knob\nTurn left: \(model.actionName(15))\nTurn right: \(model.actionName(14))\nClick: \(model.actionName(13))\nPress and hold: \(model.actionName(20))"
    }
    private var knob: some View {
        let pressed = (model.previewKeys | model.previewPressed) & (1 << 13) != 0
        return Button { if model.selectedLayer != 1 && model.canEdit { clearSelection(); component = "knob" } } label: { ZStack {
            Circle().fill(Color(white: 0.14))
            Capsule().fill(.black.opacity(0.32)).frame(width: 65, height: 3).rotationEffect(.degrees(-45))
            Circle().stroke(.white.opacity(pressed || model.previewTurnLeft || model.previewTurnRight ? 0.8 : 0), lineWidth: 2)
            if model.previewTurnLeft { Circle().fill(.white).frame(width: 7, height: 7).offset(x: -27) }
            if model.previewTurnRight { Circle().fill(.white).frame(width: 7, height: 7).offset(x: 27) }
        }.padding(3).frame(width: 76, height: 76).contentShape(Circle()) }.buttonStyle(.plain)
            .accessibilityLabel(model.selectedLayer == 1 ? "Knob, managed by Codex" : "Edit knob")
            .accessibilityAddTraits(.isButton)
            .onHover { hover(13, inside: $0) }
    }
    private var stick: some View {
        Button { if model.selectedLayer != 1 && model.canEdit { clearSelection(); component = "stick" } } label: { ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
            Circle().fill(.black).frame(width: 57, height: 57)
            Circle().fill(Color(white: 0.2)).frame(width: 48, height: 48)
                .overlay(Image(systemName: "plus").foregroundStyle(.black.opacity(0.5)))
                .offset(x: model.previewX * 10, y: model.previewY * 10)
        }.frame(width: 76, height: 76).contentShape(Rectangle()) }.buttonStyle(.plain)
            .accessibilityAddTraits(.isButton).accessibilityLabel(model.selectedLayer == 1 ? "Joystick, managed by Codex" : "Edit Quick Selection")
            .onHover { hover(14, inside: $0) }
    }
    private var touch: some View {
        HStack(spacing: 9) {
            VStack(spacing: 4) {
                ForEach(0..<3) { index in Circle().fill(led(index) ? Color(rgb: model.layer.color) : Color(white: 0.23)).frame(width: 5, height: 5) }
            }
            Circle().fill(Color(white: 0.14)).frame(width: 47, height: 47)
                .overlay(Circle().stroke(.white.opacity(model.previewTouch ? 0.8 : 0), lineWidth: 2))
        }.frame(width: 76, height: 76).accessibilityLabel("Editing layer \(model.layer.name)")
    }
    private func led(_ index: Int) -> Bool { model.draft.indicatorMask(for: model.selectedLayer) & (1 << index) != 0 }
    private var saveBar: some View {
        VStack(spacing: 10) {
            if !model.migrationNotice.isEmpty {
                Text(model.migrationNotice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.configurationConflict {
                Text("The keyboard configuration changed. Your draft is preserved.").font(.caption).foregroundStyle(.orange)
                HStack { Button("Use keyboard settings") { model.discardEdits() }; Button("Keep my draft") { model.acceptConflict() } }
            }
            if let error = model.errorText ?? model.draft.validationError ?? model.appearanceError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text(model.dirty ? "Unsaved changes" : " ").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Discard changes") { model.discardEdits() }.disabled(!model.dirty || model.busy)
                Button { model.save() } label: { Text("Save changes").frame(minWidth: 110) }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }.frame(maxWidth: .infinity).overlay(alignment: .trailing) { if model.busy { ProgressView().controlSize(.small) } }
        }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings").font(.title.weight(.semibold))
                InfoSection("Connection") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 18) {
                        StatusItem(title: "Status", value: model.snapshot != nil ? "Connected" : model.connected || model.busy ? "Connecting" : "Disconnected", symbol: "circle.fill", color: model.snapshot != nil ? .green : .secondary, working: model.snapshot == nil && model.busy)
                        StatusItem(title: "Transport", value: model.connected ? (model.usingBluetooth ? "Bluetooth" : "USB") : "Unavailable", symbol: model.usingBluetooth ? "antenna.radiowaves.left.and.right" : "cable.connector", color: .accentColor)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Battery").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                BatteryGauge(percent: model.batteryPercent, known: model.batteryKnown, charging: model.batteryCharging)
                                Text(model.batteryLabel).font(.system(size: 15, weight: .semibold))
                            }.padding(.horizontal, 10).padding(.vertical, 7)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DisclosureGroup("USB Port") {
                    HStack(spacing: 12) {
                        Picker("Port", selection: $model.selectedPort) {
                            if model.ports.isEmpty { Text("No USB device").tag("") }
                            ForEach(model.ports) { Text($0.label).tag($0.path) }
                        }.disabled(model.connected || model.busy)
                        if model.connected || model.busy { Button(model.connected ? "Disconnect" : "Cancel connection") { model.disconnect() }.disabled(model.firmware.active) }
                        else { Button("Connect USB") { model.connect() }.disabled(model.selectedPort.isEmpty || model.busy) }
                    }.padding(.top, 8)
                    }
                    if !model.connected {
                        HStack {
                            Button("Refresh Ports") { model.refreshPorts() }
                            Button("Connect Bluetooth") { model.connect(wireless: true) }.disabled(model.busy)
                        }
                    }
                    if let error = model.errorText { Text(error).font(.callout).foregroundStyle(.orange) }
                }
                InfoSection("Bluetooth Pairing", help: "Hold touch for 3 seconds to open a 60-second pairing window. A key or knob press cancels it. Clear pairing requires USB; forget the old device in macOS before pairing again.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 18) {
                        StatusItem(title: "Binding", value: model.pairingBound.map { $0 ? "Paired" : "Not Paired" } ?? "Not Read", symbol: "link", color: model.pairingBound == true ? .green : .secondary)
                        StatusItem(title: "Input", value: model.pairingReady ? "Ready" : model.pairingConnected ? "Connecting" : model.pairingBound == nil ? "Not Read" : "Disconnected", symbol: "keyboard", color: model.pairingReady ? .green : .secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Refresh Status") { model.readPairingStatus() }.disabled(!model.canManagePairing)
                        Spacer()
                        Button("Clear Pairing…") { confirmingPairingClear = true }.disabled(!model.canManagePairing || model.usingBluetooth)
                        if model.pairingBusy { ProgressView().controlSize(.small) }
                    }
                    if model.pairingNoticeVisible { Text(model.pairingMessage).font(.callout).foregroundStyle(model.pairingBusy ? Color.secondary : .orange) }
                }
                InfoSection("Power & Sleep", help: "Both timers start at the last physical input. Lights Off After: Off disables automatic dimming. Deep Sleep After: Off keeps Bluetooth connected. Press and release the knob to wake from deep sleep. USB data and charging suspend both timers.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lights Off After").font(.callout.weight(.medium))
                            Picker("Lights Off After", selection: lightsSelection) {
                                ForEach(lightsOptions, id: \.self) { seconds in
                                    Text(PowerOptions.duration(seconds)).tag(seconds).disabled(seconds == 30 && !model.supportsSeconds)
                                }
                            }.labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Deep Sleep After").font(.callout.weight(.medium))
                            Picker("Deep Sleep After", selection: deepSelection) {
                                ForEach(deepOptions, id: \.self) { minutes in
                                    Text(PowerOptions.duration(minutes * 60)).tag(minutes)
                                        .disabled(minutes > 0 && model.idleLightsEnabled && minutes * 60 <= model.idleSeconds)
                                }
                            }.labelsHidden()
                        }
                    }.disabled(!model.connected || model.busy)
                    if let reason = model.powerSaveBlockReason { Text(reason).foregroundStyle(.orange).font(.callout) }
                    if model.powerTimingInvalid { Text("Choose a deep sleep time later than lights off, or select Off.").foregroundStyle(.orange).font(.callout) }
                    if model.legacyPowerIncompatible { Text("Update firmware to save these power settings.").foregroundStyle(.orange).font(.callout) }
                    if !model.supportsSeconds { HelpNote(text: "30 seconds requires firmware with second-based power settings.") }
                    HStack(spacing: 12) {
                        Button("Read Settings") { model.readPower() }.disabled(!model.canManagePower || model.powerDirty)
                        Spacer()
                        Button("Discard Changes") { model.discardPower() }.disabled(!model.powerDirty || model.busy)
                        Button("Save Changes") { model.savePower() }.buttonStyle(.borderedProminent).disabled(!model.canSavePower)
                    }
                    Text(model.powerMessage).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(32)
        }
    }
    private var lightsSelection: SwiftUI.Binding<Int> {
        SwiftUI.Binding(get: { model.idleLightsEnabled ? model.idleSeconds : 0 }, set: { value in
            model.idleLightsEnabled = value != 0
            if value != 0 { model.idleSeconds = value }
        })
    }
    private var deepSelection: SwiftUI.Binding<Int> {
        SwiftUI.Binding(get: { model.keepConnected ? 0 : model.deepMinutes }, set: { value in
            model.keepConnected = value == 0
            if value != 0 { model.deepMinutes = value }
        })
    }
    private var lightsOptions: [Int] { Array(Set(PowerOptions.lights + [model.idleSeconds])).sorted() }
    private var deepOptions: [Int] { Array(Set(PowerOptions.deepSleep + [model.deepMinutes])).sorted() }
    private var system: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("System").font(.title.weight(.semibold))
                InfoSection("Application") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Version").font(.callout).foregroundStyle(.secondary)
                            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.body)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Appearance").font(.callout).foregroundStyle(.secondary)
                            Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }.labelsHidden()
                        }
                        LaunchAtLoginPreference()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Language").font(.callout).foregroundStyle(.secondary)
                            Text("English").font(.body)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                InfoSection("Device & Firmware") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 18) {
                        StatusItem(title: "Device", value: model.firmwareIdentity == nil ? "Not checked" : "Codex Micro", symbol: "keyboard", color: .primary)
                        StatusItem(title: "Connection", value: model.firmware.active ? "Updating" : model.connected ? "Connected" : "Disconnected", symbol: "circle.fill", color: model.connected ? .green : .secondary)
                        FirmwareStatusView(model: model)
                    }
                    if (model.firmware.showPreparation && model.firmwareMismatch) || model.firmware.blocksEditor {
                        Divider()
                        FirmwarePanel(model: model)
                    }
                    if model.hasPendingFirmwareDraft {
                        Divider().padding(.vertical, 6)
                        Text("Unsaved changes from before the firmware update are available.").font(.callout)
                        HStack {
                            Button("Restore saved local draft") { model.restoreFirmwareDraft() }
                                .disabled(model.dirty || model.powerDirty || model.busy)
                            Button("Dismiss") { model.firmware.markDraftHandled() }
                        }
                        if model.dirty || model.powerDirty { Text("Save or discard current changes before restoring.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let identity = model.firmwareIdentity {
                        DisclosureGroup("Details") { Text(identity.serial).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    }
                }
                if !bluetoothAuthorized || !accessibilityAuthorized {
                    InfoSection("Permissions") {
                        if !bluetoothAuthorized {
                            Text("Allow Bluetooth access to connect wirelessly.").foregroundStyle(.orange)
                            Button("Open Bluetooth Settings") { openSettings("Privacy_Bluetooth") }
                        }
                        if !accessibilityAuthorized {
                            Text("Allow Accessibility access to insert text into other apps.").foregroundStyle(.orange)
                            Button("Grant Accessibility Access") { model.requestTextPermission() }
                        }
                    }
                }
                InfoSection("Diagnostics") {
                    Toggle("Detailed diagnostics (30 minutes)", isOn: Binding(
                        get: { model.appLog.detailed }, set: { model.appLog.setDetailed($0) }))
                    Text("Routine logs: up to 10 MB. Detailed logs: up to 20 MB. Action contents are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure = model.appLog.failure { Text(failure).foregroundStyle(.red) }
                    if model.firmware.hasRecoveryFiles { FirmwareDiagnosticsView(model: model) }
                    DisclosureGroup("View Logs", isExpanded: $diagnostics) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Refresh") { model.showDiagnostics() }
                                Button("Show Logs in Finder") { NSWorkspace.shared.open(model.appLog.directory) }
                            }
                            ScrollView([.vertical, .horizontal]) {
                                Text(model.diagnosticText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 220)
                        }.padding(.top, 12)
                    }.onChange(of: diagnostics) { expanded in if expanded { model.showDiagnostics() } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(32)
        }
    }
    private func openSettings(_ anchor: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) } }
    private func rgb(_ path: WritableKeyPath<Layer, Int>) -> SwiftUI.Binding<Color> {
        SwiftUI.Binding(get: { Color(rgb: model.layer[keyPath: path]) }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            model.layer[keyPath: path] = (Int(color.redComponent * 255) << 16) | (Int(color.greenComponent * 255) << 8) | Int(color.blueComponent * 255)
        })
    }
}

private struct KeyInspector: View {
    @ObservedObject var model: BoardModel
    var selected: Bool
    var close: () -> Void
    @State private var iconPicker = false
    @State private var openAsFile = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(selected ? (model.selectedControl < 13 ? "Key \(model.selectedControl + 1)" : Control.all[model.selectedControl].title) : "Key Settings").font(.headline); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close key editor") }.padding(20)
            Divider()
            if !selected {
                Text(model.layer.mode == .native ? "All settings are managed in Codex." : "Select a key to configure.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Actions").font(.headline)
                        if model.quickSelectionLocked {
                            Text("All directions follow the selected source layer. Choose Off beside Quick Selection to edit them independently.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        FullWidthPopup(title: "Action type", selection: actionChoice, options: actionOptions)
                            .frame(maxWidth: .infinity).frame(height: 32)
                        actionForm.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.selectedControl < 13 { Divider(); KeyLightingPanel(model: model) }
                    if model.binding.kind == .shortcut || model.binding.kind == .media {
                        Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Name & Icon").font(.headline)
                        TextField("Action name", text: $model.currentPresentation.name).textFieldStyle(.roundedBorder)
                        HStack {
                            Button { ShortcutRecorder.cancelAll(); iconPicker.toggle() } label: {
                                Group {
                                    if let data = model.currentPresentation.image, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                                    else if ActionIconImage.assets[model.currentPresentation.symbol] != nil { ActionIconImage.image(model.currentPresentation.symbol).resizable().scaledToFit().frame(width: 24, height: 24) }
                                    else { Image(systemName: model.currentPresentation.symbol.isEmpty ? "plus" : model.currentPresentation.symbol).font(.title2) }
                                }.frame(width: 44, height: 44)
                            }.accessibilityLabel("Choose icon").popover(isPresented: $iconPicker) {
                                ShortcutIconPicker(selected: model.currentPresentation.symbol) { symbol in
                                    model.currentPresentation.symbol = symbol
                                    model.currentPresentation.image = nil
                                    iconPicker = false
                                }
                            }
                            VStack(alignment: .leading) {
                                Button("Choose image…") { model.chooseKeyImage() }
                                Button("Remove icon") { model.currentPresentation.symbol = ""; model.currentPresentation.image = nil }
                                    .disabled(model.currentPresentation.symbol.isEmpty && model.currentPresentation.image == nil)
                            }
                        }
                    }

                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20).disabled(!model.canEdit || model.quickSelectionLocked)
            }
            }
        }
        .onChange(of: model.selectedControl) { _ in openAsFile = model.hostValue.hasPrefix("/"); iconPicker = false }
        .onChange(of: model.selectedLayer) { _ in openAsFile = model.hostValue.hasPrefix("/"); iconPicker = false }
    }
    private var actionOptions: [PopupOption] {
        var options = [PopupOption(id: "shortcut", title: "Shortcut"), PopupOption(id: "media", title: "Media Control", enabled: model.info?.mediaVersion == 1), PopupOption(id: "inherit", title: "Inherit from layer"), PopupOption(id: "application", title: "Open application"), PopupOption(id: "url", title: "Open URL"), PopupOption(id: "file", title: "Open file or folder"), PopupOption(id: "text", title: "Insert text")]
        if model.selectedLayer == 1 && model.selectedControl < 13 { options.append(PopupOption(id: "native", title: "Managed by Codex")) }
        else if model.binding.kind == .native && model.selectedControl < 13 { options.append(PopupOption(id: "native", title: "Codex · Existing", enabled: false)) }
        if Control.isStick(model.selectedControl) { options.append(PopupOption(id: "cancel", title: "Cancel")) }
        options += [PopupOption(id: "separator", title: ""), PopupOption(id: "disabled", title: "Disabled")]
        return options
    }
    private var actionChoice: SwiftUI.Binding<String> {
        SwiftUI.Binding(get: { model.binding.kind == .open ? (openAsFile || model.hostValue.hasPrefix("/") ? "file" : "url") : model.binding.kind.rawValue }, set: { value in
            ShortcutRecorder.cancelAll(); openAsFile = value == "file"
            model.chooseKind(value == "file" || value == "url" ? .open : ActionKind(rawValue: value) ?? .disabled)
        })
    }
    @ViewBuilder private var actionForm: some View {
        switch model.binding.kind {
        case .media:
            Text("Media action").font(.callout).foregroundStyle(.secondary)
            FullWidthPopup(title: "Media action", selection: SwiftUI.Binding(get: { String(model.binding.usage) }, set: { if let usage = Int($0), MediaAction(rawValue: usage) != nil { model.binding.usage = usage } }), options: MediaAction.allCases.map { PopupOption(id: String($0.rawValue), title: $0.title) })
                .frame(maxWidth: .infinity).frame(height: 32)
        case .shortcut:
            ShortcutEditor(binding: $model.binding).id("\(model.selectedLayer):\(model.selectedControl)")
        case .inherit:
            Text("Source layer").font(.callout).foregroundStyle(.secondary)
            FullWidthPopup(title: "Source layer", selection: SwiftUI.Binding(get: { String(model.binding.source) }, set: { model.binding.source = Int($0) ?? 0 }), options: [PopupOption(id: "0", title: "Choose a layer")] + model.draft.layers.filter { $0.id != model.selectedLayer && (model.selectedControl < 13 || $0.id != 1) }.map { PopupOption(id: String($0.id), title: $0.name) })
                .frame(maxWidth: .infinity).frame(height: 32)
            HStack(spacing: 10) {
                ActionIcon(presentation: model.presentationFor(layer: model.selectedLayer, control: model.selectedControl), application: model.applicationTarget(model.selectedControl), codex: model.draft.resolved(layer: model.selectedLayer, control: model.selectedControl)?.kind == .native).frame(width: 28, height: 28)
                Text(model.actionName(model.selectedControl)).font(.callout)
            }
        case .application:
            TextField("Application path", text: $model.hostValue).textFieldStyle(.roundedBorder)
            Button { model.chooseHostFile(application: true) } label: { Text("Choose application…").frame(maxWidth: .infinity) }
        case .open:
            TextField(actionChoice.wrappedValue == "file" ? "File or folder path" : "https://example.com", text: $model.hostValue).textFieldStyle(.roundedBorder)
            if actionChoice.wrappedValue == "file" { Button { model.chooseHostFile(application: false) } label: { Text("Choose file or folder…").frame(maxWidth: .infinity) } }
        case .text:
            TextEditor(text: $model.hostValue).font(.body).frame(height: 180).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack { Text("\(model.hostValue.utf8.count) / 4096 bytes").font(.caption).foregroundStyle(.secondary); Spacer(); HelpNote(text: "Ed.Board must be running. Some apps may handle text or line breaks differently. Text entry needs Accessibility permission.") }
        case .native:
            HStack(spacing: 10) { Image("CodexMark").resizable().scaledToFit().frame(width: 24, height: 24); Text("Codex") }.foregroundStyle(.secondary)
            if model.selectedLayer != 1 { HelpNote(text: "This existing native action is preserved. Choose Inherit from layer to follow the Codex layer; that may change its behavior if Codex uses a custom action here.") }
        case .cancel: Label("Cancel", systemImage: "xmark")
        case .disabled: Label("Disabled", systemImage: "nosign").foregroundStyle(.secondary)
        }
    }
}

struct HelpNote: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).fastHelp(text).accessibilityLabel("Help").accessibilityHint(text)
            .popover(isPresented: $expanded) { Text(text).font(.callout).padding(16).frame(width: 290) }
    }
}
private extension Color {
    init(rgb: Int) { self.init(red: Double((rgb >> 16) & 255)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255) }
}

// Only the header background moves the window; content owns its drag gestures.
private struct WindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowAnchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private class WindowAnchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 900, height: 640)
            // Native toolbar owns titlebar height, traffic-light placement and hit testing.
        }
    }
}

// Shared by action editors so changing an action cancels any active recording.
enum ShortcutRecorder {
    static func cancelAll() { NotificationCenter.default.post(name: Notification.Name("EdBoardStopShortcutRecording"), object: nil) }
}

private struct InfoSection<Content: View>: View {
    let title: String
    let help: String?
    let content: Content
    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.help = help; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) { Text(title).font(.headline); if let help { HelpNote(text: help) } }
            content
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))
    }
}
private struct StatusItem: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).foregroundStyle(color).font(.system(size: symbol == "circle.fill" ? 9 : 17)) }
                Text(value).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
@MainActor
private enum ActionImageCache {
    static let images = NSCache<NSString, NSImage>()
    static func application(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = images.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        images.setObject(icon, forKey: path as NSString); images.countLimit = 64
        return icon
    }

}
struct ActionIcon: View {
    let presentation: KeyPresentation
    let application: String?
    let codex: Bool
    var body: some View {
        Group {
            if codex { Image("CodexMark").resizable().scaledToFit() }
            else if let data = presentation.image, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else if presentation.symbol == "folder" { Image("FolderAction").resizable().scaledToFit() }
            else if presentation.symbol == "globe" { Image("URLAction").resizable().scaledToFit() }
            else if presentation.symbol == "text.alignleft" { Image("PasteAction").resizable().scaledToFit() }
            else if let application, let icon = ActionImageCache.application(application) { Image(nsImage: icon).resizable().scaledToFit().scaleEffect(1.15) }
            else { ActionIconImage.image(presentation.symbol.isEmpty ? "keyboard" : presentation.symbol).resizable().scaledToFit() }
        }.accessibilityHidden(true)
    }
}

private struct DragEndMonitor: NSViewRepresentable {
    var finishDrag: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator, event.window === coordinator.view?.window else { return event }
            if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { coordinator.finishDrag?() }
            }
            return event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.finishDrag = finishDrag }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var finishDrag: (() -> Void)?
    }
}
private struct LayerReorderDrop: DropDelegate {
    let model: BoardModel
    let target: Int
    @SwiftUI.Binding var dragging: Int?
    @SwiftUI.Binding var targetID: Int?
    @SwiftUI.Binding var moved: Int?
    let reduceMotion: Bool
    func validateDrop(info: DropInfo) -> Bool { dragging != nil && model.canEdit && info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { targetID = target } }
    func dropExited(info: DropInfo) { if targetID == target { targetID = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = dragging, let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: String.self) { object, _ in
            guard object == "edboard-layer:\(source)" else { return }
            Task { @MainActor in
                guard model.canEdit, let from = model.draft.favorites.firstIndex(of: source),
                      let to = model.draft.favorites.firstIndex(of: target) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    let id = model.draft.favorites.remove(at: from); model.draft.favorites.insert(id, at: to)
                    model.selectedLayer = source; moved = source; dragging = nil; targetID = nil
                }
            }
        }
        return true
    }
}

private struct BatteryGauge: View {
    let percent: Int
    let known: Bool
    let charging: Bool
    private var tint: Color { charging ? .green : known && percent <= 10 ? .red : .gray }
    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1.5)
                if known { RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 25 * CGFloat(max(0, min(100, percent))) / 100, height: 9).padding(.leading, 3) }
            }.frame(width: 31, height: 15)
            Capsule().fill(tint).frame(width: 2, height: 6)
            if charging { Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.green) }
        }.accessibilityLabel(!known ? "Battery unavailable" : "Battery \(percent) percent\(charging ? ", charging" : "")")
    }
}

struct PopupOption: Equatable {
    let id: String
    let title: String
    var enabled = true
}

/// A native popup whose width follows the form, not its selected item's intrinsic size.
struct FullWidthPopup: NSViewRepresentable {
    let title: String
    @SwiftUI.Binding var selection: String
    let options: [PopupOption]
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = ExpandingPopup(frame: .zero, pullsDown: false)
        button.alignment = .left
        button.autoenablesItems = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.options != options {
            button.removeAllItems()
            for option in options {
                if option.id == "separator" { button.menu?.addItem(.separator()); continue }
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id; item.isEnabled = option.enabled
                button.menu?.addItem(item)
            }
            context.coordinator.options = options
        }
        if let index = options.firstIndex(where: { $0.id == selection }), button.indexOfSelectedItem != index { button.selectItem(at: index) }
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }
    final class Coordinator: NSObject {
        var selection: SwiftUI.Binding<String>
        var options: [PopupOption] = []
        init(selection: SwiftUI.Binding<String>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem, item.isEnabled, let id = item.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
    private final class ExpandingPopup: NSPopUpButton {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    }
}

// A consistent delay without changing macOS global tooltip preferences.
extension View {
    func fastHelp(_ text: String) -> some View { modifier(FastHelp(text: text)) }
}
private struct FastHelp: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in hovering = inside; if !inside { visible = false } }
            .task(id: hovering) {
                guard hovering else { return }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled, hovering else { return }
                visible = true
            }
            .overlay(alignment: .bottom) {
                if visible {
                    Text(text).font(.system(size: 16, weight: .medium))
                        .multilineTextAlignment(.leading).padding(12)
                        .frame(width: 260).fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12)))
                        .alignmentGuide(.bottom) { $0[.top] - 8 }
                        .allowsHitTesting(false)
                }
            }
            .zIndex(visible ? 100 : 0)
            .accessibilityHint(text)
            .onDisappear { hovering = false; visible = false }
    }
}

/// macOS owns the preference; never persist a separate boolean that can become stale.
private struct LaunchAtLoginPreference: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failure: String?
    private var requested: Bool { status == .enabled || status == .requiresApproval }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch at Login").font(.callout).foregroundStyle(.secondary)
            Toggle("Launch at Login", isOn: Binding(get: { requested }, set: setEnabled))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Launch at Login")
                .accessibilityValue(status == .requiresApproval ? "Approval required" : requested ? "On" : "Off")
            if status == .requiresApproval {
                Text("Allow in System Settings.").font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { status = SMAppService.mainApp.status }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                status = SMAppService.mainApp.status
            }
    }
    private func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = "Could not change login setting. " + error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

// Suppress only the decorative glass grouping; retain native toolbar layout/hit testing.
private extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
