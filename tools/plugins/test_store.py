"""Offline macOS integration-store checks in a temporary directory; no App/server is launched."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class StoreTests(unittest.TestCase):
    def test_atomic_permissions_and_invalid_data(self):
        core = (ROOT/'app/Packages/BoardCore/Sources/BoardCore/ObsidianBridge.swift').read_text()
        service = (ROOT/'app/EdBoard/Services/ObsidianPlugin.swift').read_text()
        store = service[service.index('enum ObsidianPluginStore {'):service.index('\n@MainActor')]
        source = 'import Foundation\nimport Darwin\nstruct RPCError: Error { let code: String }\n'+core+'\n'+store+r'''
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let file = root.appendingPathComponent("Settings/obsidian-plugin.json")
var settings = ObsidianPluginSettings()
try ObsidianPluginStore.write(settings, to: file)
assert(try ObsidianPluginStore.read(file) == settings)
let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
assert((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
settings.enabled = true; settings.credential = String(repeating:"b",count:64)
try ObsidianPluginStore.write(settings,to:file)
assert(try ObsidianPluginStore.read(file) == settings)
let original = try Data(contentsOf:file)
var invalid = settings; invalid.credential = "bad"
do {try ObsidianPluginStore.write(invalid,to:file);fatalError("Invalid settings accepted")} catch {}
assert(try Data(contentsOf:file) == original)
let blocked = root.appendingPathComponent("blocked")
try Data("block".utf8).write(to:blocked)
do {try ObsidianPluginStore.write(settings,to:blocked.appendingPathComponent("settings.json"));fatalError("Write should fail")} catch {}
assert(try Data(contentsOf:file) == original)
try Data("corrupt".utf8).write(to:file)
do {_ = try ObsidianPluginStore.read(file);fatalError("Corrupt settings accepted")} catch {}
try Data(repeating:32,count:16385).write(to:file)
do {_ = try ObsidianPluginStore.read(file);fatalError("Oversize settings accepted")} catch {}
let leftovers = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),includingPropertiesForKeys:nil)
assert(leftovers.count == 1)
print("PASS: local settings, atomic replacement, 0600 permissions, invalid/corrupt/oversize files and failed writes")
'''
        # Throwing expressions are evaluated before assert's non-throwing autoclosure.
        source=source.replace('assert(try ObsidianPluginStore.read(file) == settings)', 'assert((try? ObsidianPluginStore.read(file)) == settings)')
        source=source.replace('assert(try Data(contentsOf:file) == original)', 'assert((try? Data(contentsOf:file)) == original)')
        with tempfile.TemporaryDirectory(prefix='edboard-plugin-store-') as temporary:
            p=Path(temporary);(p/'main.swift').write_text(source)
            subprocess.run(['xcrun','swiftc','-module-cache-path',str(ROOT/'private/reconnect-check/ModuleCache'),str(p/'main.swift'),'-o',str(p/'check')],check=True)
            subprocess.run([str(p/'check'),temporary],check=True)

if __name__=='__main__':unittest.main()
