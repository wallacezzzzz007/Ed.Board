import AppKit
import ApplicationServices
import Carbon
import BoardCore

@MainActor
final class HostActionExecutor {
    private var textTask: Task<Void, Never>?
    private var lastStart = Date.distantPast
    func cancel() { textTask?.cancel() }
    func requestTextPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func execute(_ action: HostAction, report: @escaping @MainActor @Sendable (String) -> Void) {
        guard action.isValid else { report("Invalid action content. Configure the action again."); return }
        guard textTask == nil, Date().timeIntervalSince(lastStart) >= 0.2 else {
            report("Action skipped: input is too fast or text is still being entered."); return
        }
        lastStart = Date()
        if action.kind == .text { typeText(action.value, report: report); return }
        let url: URL
        if action.value.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: action.value) else {
                report("Application or file not found. Choose it again."); return
            }
            url = URL(fileURLWithPath: action.value)
        } else {
            guard let parsed = URL(string: action.value) else { report("Invalid URL."); return }
            url = parsed
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            let failed = error != nil
            Task { @MainActor in report(failed ? "Could not open the target. Check that it is available." : "Target opened.") }
        }
        if action.kind == .application {
            NSWorkspace.shared.openApplication(at: url, configuration: options, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(url, configuration: options, completionHandler: completion)
        }
    }
    private func typeText(_ text: String, report: @escaping @MainActor @Sendable (String) -> Void) {
        guard AXIsProcessTrusted() else { report("Text entry requires Accessibility permission."); return }
        guard !IsSecureEventInputEnabled(), let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            report("Focus a text field in the target application first."); return
        }
        let blocked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard CGEventSource.flagsState(.hidSystemState).intersection(blocked).isEmpty else {
            report("Release modifier keys before entering text."); return
        }
        let pid = target.processIdentifier
        let units = Array(text.utf16)
        textTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.textTask = nil }
            var offset = 0
            while offset < units.count {
                guard !Task.isCancelled else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
                      CGEventSource.flagsState(.hidSystemState).intersection(blocked).isEmpty else {
                    report("Focus or input permission changed. Remaining text was cancelled."); return
                }
                var end = min(offset + 16, units.count)
                if end < units.count && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                let chunk = Array(units[offset..<end])
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                    report("Could not create text input events."); return
                }
                down.flags = []; up.flags = []
                chunk.withUnsafeBufferPointer { buffer in
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                offset = end
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
            }
            report("Text input events sent.")
        }
    }
}
