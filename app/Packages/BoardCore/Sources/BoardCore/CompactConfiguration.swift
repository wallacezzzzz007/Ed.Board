import Foundation

/// Schema 7 uses a bounded hex payload so full sixteen-layer configurations do
/// not allocate thousands of JSON objects on the keyboard. Byte order is little endian.
extension BoardConfiguration {
    func compactPayload() throws -> String {
        guard isValid else { throw RPCError(code: "invalid_config") }
        var bytes: [UInt8] = [8, UInt8(layers.count), UInt8(favorites.count)]
        func put(_ value: Int, _ count: Int = 1) {
            for i in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
        }
        for id in favorites { put(id) }
        let kinds: [ActionKind] = [.native, .shortcut, .disabled, .inherit, .application, .open, .text, .cancel, .media]
        for layer in layers {
            let name = Array(layer.name.utf8)
            put(layer.id); put(name.count); bytes.append(contentsOf: name)
            put(layer.mode == .native ? 1 : 0); put(layer.color, 3); put(layer.ringColor, 3); put(layer.brightness)
            for effect in layer.effects { put(effect < 0 ? 255 : effect) }
            for b in layer.bindings {
                put(kinds.firstIndex(of: b.kind)! | (b.keys.count << 4))
                switch b.kind {
                case .shortcut:
                    if b.keys.isEmpty { put(b.usage); put(b.modifiers) }
                    else { for key in b.keys { put(key) } }
                case .inherit: put(b.source)
                case .application, .open, .text: put(b.source, 4)
                case .media: put(b.usage)
                default: break
                }
            }
            for light in layer.keyLights {
                if let light { put(128 | light.effect); put(light.color, 3); put(light.brightness); put(light.active) }
                else { put(0) }
            }
        }
        guard bytes.count <= 8192 else { throw RPCError(code: "config_too_large") }
        let digits = Array("0123456789abcdef".utf8)
        return String(bytes: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, encoding: .utf8)!
    }
    init(compactPayload: String) throws {
        let hex = Array(compactPayload.utf8)
        guard hex.count <= 16384, hex.count % 2 == 0 else { throw RPCError(code: "invalid_config") }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 97...102: return c - 87; default: return nil }
        }
        var data: [UInt8] = []
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let a = nibble(hex[i]), let b = nibble(hex[i + 1]) else { throw RPCError(code: "invalid_config") }
            data.append(a << 4 | b)
        }
        var at = 0
        func get(_ count: Int = 1) throws -> Int {
            guard at + count <= data.count else { throw RPCError(code: "invalid_config") }
            var value = 0
            for i in 0..<count { value |= Int(data[at + i]) << (8 * i) }
            at += count; return value
        }
        guard try get() == 8 else { throw RPCError(code: "invalid_config") }
        let count = try get(), favoriteCount = try get()
        guard (1...16).contains(count), (1...6).contains(favoriteCount) else { throw RPCError(code: "invalid_config") }
        self.init(); favorites = []; layers = []
        for _ in 0..<favoriteCount { favorites.append(try get()) }
        let kinds: [ActionKind] = [.native, .shortcut, .disabled, .inherit, .application, .open, .text, .cancel, .media]
        for _ in 0..<count {
            let id = try get(), length = try get()
            guard (1...48).contains(length), at + length <= data.count,
                  let name = String(bytes: data[at..<(at + length)], encoding: .utf8) else { throw RPCError(code: "invalid_config") }
            at += length
            let native = try get()
            guard native <= 1 else { throw RPCError(code: "invalid_config") }
            var layer = Layer(id: id, name: name, mode: native == 1 ? .native : .custom)
            layer.color = try get(3); layer.ringColor = try get(3); layer.brightness = try get()
            for i in 0..<5 { let e = try get(); layer.effects[i] = i == 3 && e == 255 ? -1 : e }
            for i in 0..<25 {
                let header = try get(), kind = header & 15, keyCount = header >> 4
                guard kinds.indices.contains(kind), keyCount <= 14, keyCount == 0 || kinds[kind] == .shortcut else { throw RPCError(code: "invalid_config") }
                var b = Binding(kind: kinds[kind])
                switch b.kind {
                case .shortcut:
                    if keyCount == 0 { b.usage = try get(); b.modifiers = try get() }
                    else { for _ in 0..<keyCount { b.keys.append(try get()) } }
                case .inherit: b.source = try get()
                case .application, .open, .text: b.source = try get(4)
                case .media: b.usage = try get()
                default: break
                }
                layer.bindings[i] = b
            }
            for i in 0..<13 {
                let header = try get()
                guard header == 0 || (128...132).contains(header) else { throw RPCError(code: "invalid_config") }
                if header != 0 { layer.keyLights[i] = LightSpec(effect: header & 7, color: try get(3), brightness: try get(), active: try get()) }
            }
            layers.append(layer)
        }
        guard at == data.count, isValid else { throw RPCError(code: "invalid_config") }
    }
}
