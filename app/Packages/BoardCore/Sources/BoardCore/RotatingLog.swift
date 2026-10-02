import Foundation

/// Five bounded files; callers serialize writes. No payload interpretation.
public enum RotatingLog {
    public static func append(_ data: Data, to url: URL, limit: Int) throws {
        let fm = FileManager.default
        guard data.count <= limit else { return }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > limit {
            let oldest = URL(fileURLWithPath: url.path + ".4")
            if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
            for index in stride(from: 3, through: 0, by: -1) {
                let source = index == 0 ? url : URL(fileURLWithPath: url.path + ".\(index)")
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: URL(fileURLWithPath: url.path + ".\(index + 1)")) }
            }
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}
