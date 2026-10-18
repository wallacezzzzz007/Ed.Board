import Foundation

public struct KeyPresentation: Codable, Equatable {
    public var name = ""
    public var symbol = ""
    public var image: Data?
    public var imageIsTemplate: Bool?
    public init(name: String = "", symbol: String = "", image: Data? = nil, imageIsTemplate: Bool? = nil) {
        self.name = name; self.symbol = symbol; self.image = image; self.imageIsTemplate = imageIsTemplate
    }
    public mutating func setImportedImage(_ data: Data, template: Bool) {
        image = data; symbol = ""; imageIsTemplate = template ? true : nil
    }
    public mutating func clearImage() { image = nil; imageIsTemplate = nil }
}
public struct PresentationCatalog: Codable, Equatable {
    public var version = 1
    public var serial: String
    public var keys: [String: KeyPresentation] = [:]
    public var hiddenDesktopOverlayLayers: Set<Int> = []
    public init(serial: String = "") { self.serial = serial }
    enum CodingKeys: String, CodingKey { case version, serial, keys, hiddenDesktopOverlayLayers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        serial = try c.decode(String.self, forKey: .serial)
        keys = try c.decode([String: KeyPresentation].self, forKey: .keys)
        hiddenDesktopOverlayLayers = try c.decodeIfPresent(Set<Int>.self, forKey: .hiddenDesktopOverlayLayers) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(serial, forKey: .serial)
        try c.encode(keys, forKey: .keys)
        if !hiddenDesktopOverlayLayers.isEmpty {
            try c.encode(hiddenDesktopOverlayLayers.sorted(), forKey: .hiddenDesktopOverlayLayers)
        }
    }
    public func showsDesktopOverlay(layer: Int) -> Bool {
        (2...255).contains(layer) && !hiddenDesktopOverlayLayers.contains(layer)
    }
    public mutating func setDesktopOverlay(_ enabled: Bool, layer: Int) {
        guard (2...255).contains(layer) else { return } // Codex is always off.
        if enabled { hiddenDesktopOverlayLayers.remove(layer) }
        else { hiddenDesktopOverlayLayers.insert(layer) }
    }
    public var isValid: Bool {
        version == 1 && serial.utf8.count <= 128 && hiddenDesktopOverlayLayers.count <= 16
            && hiddenDesktopOverlayLayers.allSatisfy { (2...255).contains($0) } && keys.count <= 400 && keys.allSatisfy { key, value in
            let parts = key.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 && key == parts.map(String.init).joined(separator: ":") && (1...255).contains(parts[0]) && (0..<25).contains(parts[1])
                && value.name.utf8.count <= 256 && value.symbol.utf8.count <= 128 && (value.image?.count ?? 0) <= 131072
        }
    }
    public func resolved(config: BoardConfiguration, layer: Int, control: Int) -> KeyPresentation {
        guard (0..<25).contains(control) else { return KeyPresentation() }
        var id = layer; var visited = Set<Int>()
        while visited.insert(id).inserted {
            guard let source = config.layers.first(where: { $0.id == id }), source.bindings.count == 25 else { return KeyPresentation() }
            let binding = source.bindings[control]
            if source.mode != .native && binding.kind == .inherit { id = binding.source; continue }
            return keys["\(id):\(control)"] ?? KeyPresentation()
        }
        return KeyPresentation()
    }
    /// Drop local appearance when disabling, or editing a legacy disabled binding.
    /// Never remove the appearance of an inherited source.
    public mutating func bindingChanged(layer: Int, control: Int, from old: Binding, to new: Binding) {
        if old.kind == .disabled || new.kind == .disabled {
            keys.removeValue(forKey: "\(layer):\(control)")
        }
    }
    public mutating func removeLayer(_ id: Int) {
        keys = keys.filter { !$0.key.hasPrefix("\(id):") }
        hiddenDesktopOverlayLayers.remove(id)
    }
}

public struct PreviewFrame: Decodable {
    public let `protocol`: Int
    public let event: String
    public let token: Int
    public let sequence: UInt32
    public let keys: Int
    public let pressed: Int
    public let left: UInt32
    public let right: UInt32
    public let touchCount: UInt32
    public let cancelled: Bool?
    public let touched: Bool
    public let x: Int
    public let y: Int
    public func accepts(token expected: Int, after previous: UInt32?) -> Bool {
        self.protocol == 1 && event == "preview" && token == expected && token > 0
            && (0..<16384).contains(keys) && (0..<16384).contains(pressed)
            && (-1000...1000).contains(x) && (-1000...1000).contains(y)
            && (previous.map { sequence > $0 } ?? true)
    }
    public static func isPreviewLine(_ line: String) -> Bool {
        // Only omit successfully parsed, valid telemetry; malformed input stays diagnostic.
        guard let data = Wire.payload(line), let frame = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return frame.accepts(token: frame.token, after: nil)
    }
}

/// Names and symbols describe the effective action, not the editable inheritance link.
public enum ActionPresentation {
    public static func standard(binding: Binding, custom: KeyPresentation, target: String, folder: Bool = false) -> KeyPresentation {
        switch binding.kind {
        case .native: return KeyPresentation(name: "Codex", symbol: "terminal")
        case .appSwitcher: return KeyPresentation(name: "App Switcher", symbol: "rectangle.on.rectangle")
        case .cancel: return KeyPresentation(name: "Cancel", symbol: "xmark")
        case .disabled: return KeyPresentation(name: "Disabled", symbol: "nosign")
        case .mouse:
            let action = MouseAction(rawValue: binding.usage)
            return KeyPresentation(name: custom.name.isEmpty ? binding.description : custom.name,
                                   symbol: custom.symbol.isEmpty && custom.image == nil ? (action?.symbol ?? "computermouse") : custom.symbol, image: custom.image, imageIsTemplate: custom.imageIsTemplate)
        case .media:
            let action = MediaAction(rawValue: binding.usage)
            return KeyPresentation(name: custom.name.isEmpty ? binding.description : custom.name,
                                   symbol: custom.symbol.isEmpty && custom.image == nil ? (action?.symbol ?? "playpause.fill") : custom.symbol, image: custom.image, imageIsTemplate: custom.imageIsTemplate)
        case .shortcut:
            return KeyPresentation(name: custom.name.isEmpty ? binding.description : custom.name,
                                   symbol: custom.symbol.isEmpty && custom.image == nil ? "keyboard" : custom.symbol, image: custom.image, imageIsTemplate: custom.imageIsTemplate)
        case .application:
            let name = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
            return KeyPresentation(name: target.isEmpty ? "Open application" : "Open \(name)", symbol: "app")
        case .open:
            if target.hasPrefix("/") {
                return KeyPresentation(name: "Open \(URL(fileURLWithPath: target).lastPathComponent)", symbol: folder ? "folder" : "doc")
            }
            return KeyPresentation(name: URL(string: target)?.host.map { "Open \($0)" } ?? "Open URL", symbol: "globe")
        case .text: return KeyPresentation(name: "Insert text", symbol: "text.alignleft")
        case .inherit: return KeyPresentation(name: "Choose a source layer", symbol: "arrow.turn.down.right")
        }
    }
}
