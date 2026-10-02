import Foundation

public struct LightSpec: Codable, Equatable {
    public var effect: Int
    public var color: Int
    public var brightness: Int
    public var active: Int
    public init(effect: Int = 1, color: Int = 0xffffff, brightness: Int = 15, active: Int = 100) {
        self.effect = effect; self.color = color; self.brightness = brightness; self.active = active
    }
    public var valid: Bool { (0...5).contains(effect) && (0...0xffffff).contains(color) && (0...100).contains(brightness) && (0...100).contains(active) && (effect != 4 || active >= brightness) }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer(); effect = try c.decode(Int.self); color = try c.decode(Int.self); brightness = try c.decode(Int.self); active = try c.decode(Int.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid light") }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.unkeyedContainer(); try c.encode(effect); try c.encode(color); try c.encode(brightness); try c.encode(active) }
    public var title: String { ["Off", "Solid", "Breathing", "Light on press", "Brighten on press", "Slow rotation"].indices.contains(effect) ? ["Off", "Solid", "Breathing", "Light on press", "Brighten on press", "Slow rotation"][effect] : "Unknown" }
}
extension Layer {
    public var keysLight: LightSpec {
        get { LightSpec(effect: effects[0], color: color, brightness: brightness, active: effects[1]) }
        set { if effects[3] < 0 { effects[3] = brightness }; color = newValue.color; brightness = newValue.brightness; effects[0] = newValue.effect; effects[1] = newValue.active }
    }
    public var outerLight: LightSpec {
        get { LightSpec(effect: effects[2], color: ringColor, brightness: effects[3] < 0 ? brightness : effects[3], active: effects[4]) }
        set { ringColor = newValue.color; effects[2] = newValue.effect; effects[3] = newValue.brightness; effects[4] = newValue.active }
    }
}
extension BoardConfiguration {
    public func lightOverride(layer id: Int, control: Int) -> LightSpec? {
        guard (0..<13).contains(control) else { return nil }
        var id = id; var seen = Set<Int>()
        while seen.insert(id).inserted {
            guard let source = layers.first(where: { $0.id == id }), source.mode != .native else { return nil }
            let b = source.bindings[control]
            if b.kind == .inherit { id = b.source; continue }
            return source.keyLights[control]
        }
        return nil
    }
    /// A terminal override follows inheritance; absent override uses the destination layer.
    public func resolvedLight(layer id: Int, control: Int) -> LightSpec? {
        guard (0..<13).contains(control), let destination = layers.first(where: { $0.id == id }) else { return nil }
        var sourceID = id; var seen = Set<Int>()
        while seen.insert(sourceID).inserted {
            guard let source = layers.first(where: { $0.id == sourceID }) else { return nil }
            if source.mode == .native { return control < 6 ? nil : destination.keysLight }
            let b = source.bindings[control]
            if b.kind == .inherit { sourceID = b.source; continue }
            if b.kind == .native && control < 6 { return nil }
            return source.keyLights[control] ?? destination.keysLight
        }
        return nil
    }
}
public enum ShortcutKeys {
    public static func valid(_ keys: [Int]) -> Bool {
        !keys.isEmpty && Set(keys).count == keys.count && keys.allSatisfy { (4...164).contains($0) || (224...231).contains($0) } && keys.filter { $0 < 224 }.count <= 6 && keys.count <= 14
    }
    public static func title(_ usage: Int) -> String {
        let modifiers = ["Left Control", "Left Shift", "Left Option", "Left Command", "Right Control", "Right Shift", "Right Option", "Right Command"]
        if (224...231).contains(usage) { return modifiers[usage - 224] }
        return HIDKey.choices.first { $0.id == usage }?.title ?? "HID \(usage)"
    }
}
