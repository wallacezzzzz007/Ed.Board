"""Offline macOS image import checks using synthetic images and in-memory preferences."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ImageImportTests(unittest.TestCase):
    def test_actual_importer_and_directory_preferences(self):
        source = (ROOT / 'app/EdBoard/Services/BoardModel.swift').read_text()
        importer = source[source.index('enum KeyImageImport {'):]
        harness = r'''
import AppKit
import ImageIO
import Foundation
'''+importer+r'''
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func save(_ name: String, _ text: String) -> URL {
    let url = root.appendingPathComponent(name)
    try! Data(text.utf8).write(to: url)
    return url
}
func check(_ url: URL, _ width: Int, _ height: Int, transparent: Bool = true) {
    guard let data = KeyImageImport.png(from: url), let rep = NSBitmapImageRep(data: data) else { fatalError("Import failed: \(url.lastPathComponent)") }
    assert(Array(data.prefix(8)) == [137,80,78,71,13,10,26,10])
    assert(rep.pixelsWide == width && rep.pixelsHigh == height)
    assert(rep.colorAt(x: width/2, y: height/2)!.alphaComponent > 0.9)
    if transparent { assert(rep.hasAlpha); assert(rep.colorAt(x: 0, y: 0)!.alphaComponent < 0.01) }
    assert(data.count <= 131072)
}
let wide = save("wide.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"400\" height=\"200\"><rect x=\"100\" y=\"50\" width=\"200\" height=\"100\" fill=\"red\"/></svg>")
check(wide,128,64)
let tall = save("tall.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 400\"><circle cx=\"50\" cy=\"200\" r=\"30\" fill=\"blue\"/></svg>")
check(tall,32,128)
let png = root.appendingPathComponent("raster.png")
try! KeyImageImport.png(from: wide)!.write(to: png)
check(png,128,64)
let rep = NSBitmapImageRep(data: try! Data(contentsOf: png))!
for (name,type) in [("raster.jpg",NSBitmapImageRep.FileType.jpeg),("raster.tiff",.tiff)] {
    let url = root.appendingPathComponent(name)
    try! rep.representation(using:type,properties:[:])!.write(to:url)
    check(url,128,64,transparent:false)
}
assert(KeyImageImport.png(from: save("bad.svg","<svg><broken")) == nil)
assert(KeyImageImport.png(from: save("empty.svg","")) == nil)
let huge = root.appendingPathComponent("huge.svg")
try! Data(repeating: 32,count:8_000_001).write(to:huge)
assert(KeyImageImport.png(from: huge) == nil)
let prefs = MemoryDefaults()
assert(KeyImageImport.lastDirectory(defaults:prefs) == nil)
KeyImageImport.rememberDirectory(of:wide,defaults:prefs)
assert(KeyImageImport.lastDirectory(defaults:prefs)?.standardizedFileURL == root.standardizedFileURL)
KeyImageImport.rememberDirectory(of:root.appendingPathComponent("missing/icon.svg"),defaults:prefs)
assert(KeyImageImport.lastDirectory(defaults:prefs) == nil)
KeyImageImport.rememberDirectory(of:wide.appendingPathComponent("icon.svg"),defaults:prefs)
assert(KeyImageImport.lastDirectory(defaults:prefs) == nil)
print("PASS: SVG dimensions/viewBox/aspect/alpha, PNG/JPEG/TIFF, invalid/empty/oversize images and local directory fallback")
'''
        with tempfile.TemporaryDirectory(prefix='edboard-image-import-') as folder:
            path = Path(folder)
            (path / 'main.swift').write_text(harness)
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(ROOT / 'private/reconnect-check/ModuleCache'), str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
            subprocess.run([str(path / 'check'), folder], check=True)


if __name__ == '__main__':
    unittest.main()
