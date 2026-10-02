import Foundation

/// Conservatively prune only recognized update artifacts, never unknown recovery data.
public enum FirmwareHistory {
    private struct Receipt: Decodable {
        let serial: String
        let stage: String
        let draftHandled: Bool?
    }
    public static func prune(root: URL, current: URL?, keep: Int = 3) throws {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { return }
        let allowed = Set(["record.json", "device-nvs.bin", "app-draft.json", "update.log"] + (1...4).map { "update.log.\($0)" })
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                guard UUID(uuidString: url.lastPathComponent) != nil,
                      let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return v.isDirectory == true && v.isSymbolicLink != true && url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
            }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
            }
        var protected = Set(directories.filter { $0.standardizedFileURL.path != current?.standardizedFileURL.path }.prefix(max(0, keep)).map { $0.standardizedFileURL.path })
        if let current { protected.insert(current.standardizedFileURL.path) }
        var backupDevices = Set<String>()
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("record.json")),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { continue }
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let names = Set(children.map(\.lastPathComponent))
            // Always retain the newest available NVS recovery backup for each device.
            if names.contains("device-nvs.bin"), receipt.stage != "success", backupDevices.insert(receipt.serial).inserted {
                protected.insert(directory.standardizedFileURL.path)
            }
            if names.contains("app-draft.json"), receipt.draftHandled != true { protected.insert(directory.standardizedFileURL.path) }
            guard !protected.contains(directory.standardizedFileURL.path), names.isSubset(of: allowed),
                  children.allSatisfy({ file in
                      guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                      return v.isRegularFile == true && v.isSymbolicLink != true
                  }) else { continue }
            for file in children { try fm.removeItem(at: file) }
            try fm.removeItem(at: directory)
        }
    }
}
