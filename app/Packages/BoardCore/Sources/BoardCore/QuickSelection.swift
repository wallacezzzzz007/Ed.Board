import Foundation

public enum QuickSelection {
    public static func source(in config: BoardConfiguration, layer: Int) -> Int? {
        guard layer != 1, let value = config.layers.first(where: { $0.id == layer }), value.bindings.count == 25 else { return nil }
        let first = value.bindings[Control.stickIDs[0]]
        guard first.kind == .inherit, first.source != 1, first.source != layer,
              Control.stickIDs.allSatisfy({ value.bindings[$0].kind == .inherit && value.bindings[$0].source == first.source }) else { return nil }
        return first.source
    }

    public static func inheriting(_ config: BoardConfiguration, layer: Int, source: Int) -> BoardConfiguration? {
        guard layer != 1, source != 1, layer != source,
              let index = config.layers.firstIndex(where: { $0.id == layer }),
              config.layers[index].bindings.count == 25,
              config.layers.contains(where: { $0.id == source && $0.mode == .custom }) else { return nil }
        var result = config
        for id in Control.stickIDs { result.layers[index].bindings[id] = Binding(kind: .inherit, source: source) }
        // Resolve every direction before applying any change, including indirect cycles.
        guard Control.stickIDs.allSatisfy({ result.resolved(layer: layer, control: $0).map { $0.kind != .native } == true }) else { return nil }
        return result
    }

    public struct Detached {
        public var configuration: BoardConfiguration
        public var presentation: PresentationCatalog
        public var actions: [Int: HostAction]
    }
    public static func detached(_ config: BoardConfiguration, layer: Int, presentation: PresentationCatalog,
                                actions: [Int: HostAction], reservedIDs: Set<Int> = []) -> Detached? {
        guard source(in: config, layer: layer) != nil,
              let index = config.layers.firstIndex(where: { $0.id == layer }) else { return nil }
        var result = Detached(configuration: config, presentation: presentation, actions: actions)
        var used = reservedIDs.union(actions.keys).union(config.layers.flatMap { $0.bindings.filter { $0.kind.isHost }.map(\.source) })
        for id in Control.stickIDs {
            guard var binding = config.resolved(layer: layer, control: id), binding.kind != .native else { return nil }
            if binding.kind.isHost {
                guard let action = actions[binding.source], action.kind == binding.kind, action.isValid else { return nil }
                var next = 1
                while used.contains(next) && next < 0x7fffffff { next += 1 }
                guard !used.contains(next) else { return nil }
                used.insert(next); result.actions[next] = action; binding.source = next
            }
            result.configuration.layers[index].bindings[id] = binding
            result.presentation.keys["\(layer):\(id)"] = presentation.resolved(config: config, layer: layer, control: id)
        }
        guard result.presentation.isValid else { return nil }
        return result
    }
}
