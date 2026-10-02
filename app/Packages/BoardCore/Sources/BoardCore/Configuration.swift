import Foundation

public enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case native, shortcut, disabled, inherit, application, open, text, cancel
    public var isHost: Bool { self == .application || self == .open || self == .text }
    public var id: String { rawValue }
    public var title: String {
        switch self { case .cancel: return "Cancel"; case .native: return "Managed by Codex"; case .shortcut: return "Shortcut"; case .disabled: return "Disabled"; case .inherit: return "Inherit from layer"; case .application: return "Open application"; case .open: return "Open URL or file"; case .text: return "Insert text" }
    }
}
public enum LayerMode: String, Codable, CaseIterable { case native, custom }
public struct Binding: Codable, Equatable {
    public var kind: ActionKind
    public var usage: Int
    public var modifiers: Int
    public var source: Int
    public var keys: [Int] = []
    public init(kind: ActionKind = .native, usage: Int = 0, modifiers: Int = 0, source: Int = 0) {
        self.kind = kind; self.usage = usage; self.modifiers = modifiers; self.source = source
    }
    enum CodingKeys: String, CodingKey { case kind, usage, modifiers, source, keys }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ActionKind.self, forKey: .kind); usage = try c.decode(Int.self, forKey: .usage)
        modifiers = try c.decode(Int.self, forKey: .modifiers); source = try c.decode(Int.self, forKey: .source)
        keys = try c.decodeIfPresent([Int].self, forKey: .keys) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(usage, forKey: .usage); try c.encode(modifiers, forKey: .modifiers); try c.encode(source, forKey: .source)
        if !keys.isEmpty { try c.encode(keys, forKey: .keys) }
    }
    public var chord: [Int] { keys.isEmpty ? [(1,224),(2,225),(4,226),(8,227)].filter { modifiers & $0.0 != 0 }.map { $0.1 } + (usage > 0 ? [usage] : []) : keys }
    public var isValid: Bool {
        if !keys.isEmpty { return kind == .shortcut && usage == 0 && modifiers == 0 && source == 0 && ShortcutKeys.valid(keys) }
        switch kind {
        case .shortcut: return (4...115).contains(usage) && (0...15).contains(modifiers) && source == 0
        case .inherit: return usage == 0 && modifiers == 0 && (1...255).contains(source)
        case .application, .open, .text: return usage == 0 && modifiers == 0 && (1...0x7fffffff).contains(source)
        default: return usage == 0 && modifiers == 0 && source == 0
        }
    }
    public var description: String {
        if kind != .shortcut { return kind.title }
        if !keys.isEmpty { return keys.map(ShortcutKeys.title).joined(separator: " + ") }
        let mods = [(8, "⌘"), (2, "⇧"), (4, "⌥"), (1, "⌃")].filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined()
        return mods + (HIDKey.choices.first { $0.id == usage }?.title ?? "HID \(usage)")
    }
}
public struct Control: Identifiable {
    public let id: Int
    public let title: String
    public static let knobIDs = [15, 14, 13, 20]
    public static let stickIDs = [16, 21, 17, 22, 18, 23, 19, 24]
    public static func isStick(_ id: Int) -> Bool { stickIDs.contains(id) }
    public static let all: [Control] = (["A1", "A2", "A3", "A4", "A5", "A6", "C1", "C2", "C3", "C4", "C5", "C6", "C7", "Knob press", "Knob clockwise", "Knob counterclockwise", "Joystick up", "Joystick right", "Joystick down", "Joystick left", "Knob press and hold", "Joystick up right", "Joystick down right", "Joystick down left", "Joystick up left"]).enumerated().map { Control(id: $0.offset, title: $0.element) }
}
public struct Layer: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var mode: LayerMode
    public var color: Int = 0xffffff
    public var ringColor: Int = 0xffffff
    public var brightness: Int = 15
    public var bindings: [Binding]
    public var effects: [Int] = [1, 100, 1, -1, 100]
    public var keyLights: [LightSpec?] = Array(repeating: nil, count: 13)
    enum CodingKeys: String, CodingKey { case id, name, mode, color, ringColor, brightness, bindings, effects, keyLights }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); name = try c.decode(String.self, forKey: .name); mode = try c.decode(LayerMode.self, forKey: .mode)
        color = try c.decode(Int.self, forKey: .color); ringColor = try c.decode(Int.self, forKey: .ringColor); brightness = try c.decode(Int.self, forKey: .brightness); bindings = try c.decode([Binding].self, forKey: .bindings)
        effects = try c.decodeIfPresent([Int].self, forKey: .effects) ?? [1,100,1,-1,100]
        keyLights = try c.decodeIfPresent([LightSpec?].self, forKey: .keyLights) ?? Array(repeating: nil, count: 13)
        guard effects.count == 5, keyLights.count == 13 else { throw DecodingError.dataCorruptedError(forKey: .effects, in: c, debugDescription: "Invalid lighting fields") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(mode, forKey: .mode)
        try c.encode(color, forKey: .color); try c.encode(ringColor, forKey: .ringColor); try c.encode(brightness, forKey: .brightness); try c.encode(bindings, forKey: .bindings)
        if effects != [1,100,1,-1,100] || keyLights.contains(where: { $0 != nil }) { try c.encode(effects, forKey: .effects); try c.encode(keyLights, forKey: .keyLights) }
    }
    public init(id: Int = 1, name: String = "Codex", mode: LayerMode = .native, bindings: [Binding] = Array(repeating: Binding(), count: 25)) {
        self.id = id; self.name = name; self.mode = mode; self.bindings = bindings
        if self.bindings.count == 25 {
            for c in 13..<25 {
                if id == 1 { self.bindings[c] = Binding() }
                else if self.bindings[c].kind == .native { self.bindings[c] = Binding(kind: .disabled) }
            }
        }
    }
}
extension Layer {
    public static func blank(id: Int, name: String) -> Layer {
        var layer = Layer(id: id, name: name, mode: .custom, bindings: Array(repeating: Binding(kind: .disabled), count: 25))
        layer.color = 0xffffff; layer.ringColor = 0xffffff; layer.brightness = 15
        return layer
    }
}
public struct BoardConfiguration: Codable, Equatable {
    public var schemaVersion = 6
    public var layers: [Layer] = [Layer()]

    /// Preserve an existing editor selection; otherwise use display order, not Codex identity.
    public func editorLayer(preferred: Int) -> Int {
        layers.contains(where: { $0.id == preferred }) ? preferred : (layers.first?.id ?? 1)
    }

    public init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, layers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        schemaVersion = (4...5).contains(version) ? 6 : version
        layers = try c.decode([Layer].self, forKey: .layers)
        if (4...5).contains(version) {
            for i in layers.indices where layers[i].bindings.count == 20 {
                layers[i].bindings += Array(repeating: Binding(kind: .disabled), count: 5)
                for control in 13..<25 {
                    let b = layers[i].bindings[control]
                    if layers[i].id == 1 { layers[i].bindings[control] = Binding() }
                    else if b.kind == .native || (b.kind == .inherit && b.source == 1) { layers[i].bindings[control] = Binding(kind: .disabled) }
                }
            }
        }
    }
    public var startupLayerID: Int { layers.first?.id ?? 1 }
    public mutating func moveLayer(_ id: Int, offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(index + offset) else { return }
        layers.swapAt(index, index + offset)
    }
    public func resolved(layer: Int, control: Int) -> Binding? {
        guard (0..<25).contains(control) else { return nil }
        var id = layer; var seen = Set<Int>()
        while seen.insert(id).inserted {
            guard let source = layers.first(where: { $0.id == id }), source.bindings.count == 25 else { return nil }
            if source.mode == .native || (source.id == 1 && control >= 13) { return Binding() }
            let binding = source.bindings[control]
            if binding.kind != .inherit { return binding }
            id = binding.source
        }
        return nil
    }
    public var validationError: String? {
        guard schemaVersion == 6, (1...6).contains(layers.count) else { return "Unsupported configuration or layer count (1–6)." }
        let ids = Set(layers.map { $0.id })
        guard ids.count == layers.count, ids.contains(1) else { return "Invalid layer identity or missing Codex layer." }
        for layer in layers {
            guard (1...255).contains(layer.id), !layer.name.isEmpty, layer.name.utf8.count <= 48,
                  !layer.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  layer.id == 1 || layer.mode == .custom, (0...0xffffff).contains(layer.color),
                  (0...0xffffff).contains(layer.ringColor), (0...100).contains(layer.brightness),
                  layer.bindings.count == 25, layer.bindings.allSatisfy({ $0.isValid }) else { return "Invalid layer settings. Names must be 1–48 UTF-8 bytes." }
            guard layer.effects.count == 5, (-1...100).contains(layer.effects[3]), layer.keyLights.count == 13, layer.keysLight.valid, layer.keysLight.effect <= 4,
                  layer.outerLight.valid, layer.outerLight.effect != 2, layer.keyLights.allSatisfy({ $0 == nil || ($0!.valid && $0!.effect <= 4) }) else { return "Invalid lighting settings. Active brightness must be at least base brightness." }
            for control in 0..<25 {
                let b = layer.bindings[control]
                if b.kind == .cancel && !Control.isStick(control) { return "Cancel is only available for joystick directions." }
                if control >= 13 {
                    if layer.id == 1 && b.kind != .native { return "Codex manages its knob and joystick." }
                    if layer.id != 1 && (b.kind == .native || (b.kind == .inherit && b.source == 1)) { return "Knob and joystick can only inherit ordinary layers." }
                }
            }
            // Check the retained custom plan even while native mode bypasses it.
            for control in 0..<25 {
                var id = layer.id; var seen = Set<Int>()
                while true {
                    guard seen.insert(id).inserted else { return "\(layer.name) contains an inheritance cycle." }
                    guard let source = layers.first(where: { $0.id == id }), source.bindings.count == 25 else { return "The source layer no longer exists." }
                    let binding = source.bindings[control]
                    if binding.kind != .inherit { break }
                    id = binding.source
                }
            }
        }
        return nil
    }
    public var isValid: Bool { validationError == nil }
    public func canDelete(_ id: Int) -> Bool {
        id != 1 && layers.contains(where: { $0.id == id }) && !layers.contains { layer in
            layer.id != id && layer.bindings.contains { $0.kind == .inherit && $0.source == id }
        }
    }
    public mutating func deleteLayer(_ id: Int) {
        guard canDelete(id) else { return }
        layers.removeAll { $0.id == id }
    }
}
public struct Snapshot: Codable, Equatable {
    public var revision: Int
    public var config: BoardConfiguration
    public var writable: Bool?
    public var storageError: String?
    public var isValid: Bool { (0...0x7fffffff).contains(revision) && config.isValid }
}
public struct DeviceInfo: Decodable {
    public let device: String
    public let serial: String
    public let firmware: String
    public let controlId: String
    public let schemaVersion: Int
    public let migrationNote: String?
    public let powerVersion: Int?
    public let full: Bool?
    public let joystickVersion: Int?
    public let previewVersion: Int?
    public let runtimeVersion: Int?
    public let writable: Bool
    public let storageError: String
    public let ready: Bool
    public let batteryValid: Bool
    public let battery: Int
    public let charging: Bool
    public var isCompatible: Bool { device == "Ed.Board" && schemaVersion == 6 && runtimeVersion == 2 && controlId == "board.layers" }
}

public struct HIDKey: Identifiable {
    public let id: Int
    public let title: String
    public static let choices: [HIDKey] = {
        var keys = (0..<26).map { HIDKey(id: 4 + $0, title: String(UnicodeScalar(65 + $0)!)) }
        keys += (1...9).map { HIDKey(id: 29 + $0, title: String($0)) }
        keys += [HIDKey(id: 39, title: "0"), HIDKey(id: 40, title: "Return"),
                 HIDKey(id: 41, title: "Escape"), HIDKey(id: 42, title: "Delete"),
                 HIDKey(id: 43, title: "Tab"), HIDKey(id: 44, title: "Space")]
        keys += (1...12).map { HIDKey(id: 57 + $0, title: "F\($0)") }
        keys += [HIDKey(id: 79, title: "→"), HIDKey(id: 80, title: "←"),
                 HIDKey(id: 81, title: "↓"), HIDKey(id: 82, title: "↑")]
        let extras: [(Int,String)] = [(45,"- / _"),(46,"= / +"),(47,"[ / {"),(48,"] / }"),(49,"Backslash"),(50,"Non-US #"),(51,"; / :"),(52,"Quote"),(53,"Grave"),(54,", / <"),(55,". / >"),(56,"/ / ?"),(57,"Caps Lock"),(70,"Print Screen"),(71,"Scroll Lock"),(72,"Pause"),(73,"Insert"),(74,"Home"),(75,"Page Up"),(76,"Forward Delete"),(77,"End"),(78,"Page Down"),(83,"Num Lock"),(84,"Keypad /"),(85,"Keypad *"),(86,"Keypad -"),(87,"Keypad +"),(88,"Keypad Enter"),(98,"Keypad 0"),(99,"Keypad ."),(100,"Non-US Backslash"),(101,"Application Menu"),(103,"Keypad ="),(130,"Locking Caps Lock"),(131,"Locking Num Lock"),(132,"Locking Scroll Lock"),(133,"Keypad ,"),(134,"Keypad = (AS/400)")]
        keys += extras.map { HIDKey(id: $0.0, title: $0.1) }
        keys += (1...9).map { HIDKey(id: 88 + $0, title: "Keypad \($0)") }
        keys += (13...24).map { HIDKey(id: 104 + $0 - 13, title: "F\($0)") }
        return keys
    }()
}

/// Runtime selection is deliberately separate from persistent configuration and revision.
public struct RuntimeState: Decodable, Equatable {
    public let manualLayer: Int
    public let activeLayer: Int
    public let autoLayer: Int?
    public let session: Int?
    public let pending: Bool?
    public func isValid(for config: BoardConfiguration) -> Bool {
        let ids = Set(config.layers.map(\.id))
        guard ids.contains(manualLayer), ids.contains(activeLayer) else { return false }
        if let autoLayer, autoLayer != 0 && !ids.contains(autoLayer) { return false }
        if let session, !(0...0x7fffffff).contains(session) { return false }
        if let pending, !pending, activeLayer != ((autoLayer ?? 0) == 0 ? manualLayer : autoLayer!) { return false }
        return true
    }
}
