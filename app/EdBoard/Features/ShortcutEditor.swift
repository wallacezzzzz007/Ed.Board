import SwiftUI
import AppKit
import CoreGraphics
import BoardCore

@MainActor
struct ShortcutEditor: View {
    @SwiftUI.Binding var binding: BoardCore.Binding
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recording = false
    @State private var rows: [Int] = []
    @State private var monitor: Any?
    @State private var choosing = false
    @State private var replacing: Int?
    @State private var search = ""
    @State private var hoveredChoice: Int?
    @State private var error = ""
    @State private var pulse = false
    @State private var highlightedKey: Int?
    private var displayed: [Int] { recording ? rows : binding.chord }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if displayed.isEmpty && !recording {
                Text("No shortcut assigned").foregroundStyle(.secondary)
            }
            ForEach(Array(displayed.enumerated()), id: \.element) { index, key in
                HStack(spacing: 8) {
                    Button { replacing = index; search = ""; choosing = true } label: {
                        HStack(spacing: 6) {
                            Text(ShortcutKeys.title(key)).lineLimit(2)
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.down").font(.caption)
                        }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Change \(ShortcutKeys.title(key))")
                    Divider().frame(height: 24)
                    HStack(spacing: 4) {
                        rowButton("arrow.up", "Move \(ShortcutKeys.title(key)) up") { move(index, -1) }.disabled(index == 0)
                        rowButton("arrow.down", "Move \(ShortcutKeys.title(key)) down") { move(index, 1) }.disabled(index == displayed.count - 1)
                        rowButton("xmark", "Remove \(ShortcutKeys.title(key))") { var keys = displayed; keys.remove(at: index); edit(keys) }
                    }
                }.padding(8).background(highlightedKey == key ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            Button { replacing = nil; search = ""; choosing = true } label: { Label("Add key", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .popover(isPresented: $choosing) { keyChooser }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button { if recording { finish() } else { start() } } label: {
                    HStack {
                        if recording { Circle().fill(.red).frame(width: 7, height: 7).opacity(pulse ? 0.35 : 1) }
                        Text(recording ? "Stop recording" : "Record shortcut")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderedProminent).tint(recording ? .red : .accentColor)
                if recording { Button("Cancel") { cancel() } }
            }
            if recording {
                Text("Press keys together or one at a time. Escape is recorded too.").font(.caption).foregroundStyle(.secondary)
            } else {
                HelpNote(text: "Up to 6 keys plus left/right modifiers. Add key can supply supported keys your keyboard or macOS does not expose. Fn and media keys are not supported.")
            }
        }
        .onChange(of: enabled) { if !$0 { cancel() } }
        .onDisappear { cancel() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("EdBoardStopShortcutRecording"))) { _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancel() }
    }
    private var keyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a key").font(.headline)
            TextField("Search keys", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach((HIDKey.choices.map(\.id) + Array(224...231)).filter { search.isEmpty || ShortcutKeys.title($0).localizedCaseInsensitiveContains(search) }, id: \.self) { key in
                        Button {
                            var keys = displayed
                            if keys.contains(key), replacing.flatMap({ displayed.indices.contains($0) ? displayed[$0] : nil }) != key { error = "That key is already in the combination."; return }
                            if let replacing, keys.indices.contains(replacing) { keys[replacing] = key } else { keys.append(key) }
                            if accept(keys) { choosing = false }
                        } label: {
                            Text(ShortcutKeys.title(key))
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .background(hoveredChoice == key ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { hoveredChoice = key }
                                else if hoveredChoice == key { hoveredChoice = nil }
                            }
                    }
                }
            }.frame(height: 300)
            Button("Done") { choosing = false }
        }.padding(16).frame(width: 270)
    }
    private func edit(_ keys: [Int]) {
        error = ""
        if recording { rows = keys }
        else if ShortcutKeys.valid(keys) { var b = BoardCore.Binding(kind: .shortcut); b.keys = keys; binding = b }
        else { error = "A shortcut needs at least one key. Use Disabled to disable the action." }
    }
    private func accept(_ keys: [Int]) -> Bool {
        guard ShortcutKeys.valid(keys) else { error = "Use at most 6 different keys and 8 modifiers."; return false }
        edit(keys); return true
    }
    private func rowButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.bordered).controlSize(.small).buttonBorderShape(.roundedRectangle)
            .accessibilityLabel(title).fastHelp(title)
    }
    private func move(_ index: Int, _ offset: Int) {
        guard displayed.indices.contains(index), displayed.indices.contains(index + offset) else { return }
        var keys = displayed; keys.swapAt(index, index + offset)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { edit(keys) }
    }
    private func cancel() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false; rows = []; choosing = false; pulse = false }
    private func finish() { guard accept(rows) else { return }; var b = BoardCore.Binding(kind: .shortcut); b.keys = rows; binding = b; cancel() }
    private func start() {
        // There is one recorder in the inspector. Do not broadcast cancellation
        // here: SwiftUI may deliver it after this new recording has started.
        cancel()
        NSApp.keyWindow?.makeFirstResponder(nil)
        rows = []; error = ""; recording = true; pulse = false
        if !reduceMotion { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard recording, !choosing else { return event }
            if event.type == .keyUp { return nil }
            let key: Int?
            if event.type == .flagsChanged {
                key = Self.modifiers[event.keyCode]
                guard CGEventSource.keyState(.combinedSessionState, key: event.keyCode) else { return nil }
            } else { key = Self.usages[event.keyCode] }
            guard let key else { error = "This key cannot be captured here. Use Add key if available."; return nil }
            highlightedKey = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if highlightedKey == key { highlightedKey = nil } }
            if !rows.contains(key) { _ = accept(rows + [key]) }
            return nil
        }
    }
    private static let modifiers: [UInt16:Int] = [59:224,56:225,58:226,55:227,62:228,60:229,61:230,54:231,57:57]
    private static let usages: [UInt16: Int] = [0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,11:5,12:20,13:26,14:8,15:21,16:28,17:23,18:30,19:31,20:32,21:33,22:35,23:34,24:46,25:38,26:36,27:45,28:37,29:39,30:48,31:18,32:24,33:47,34:12,35:19,36:40,37:15,38:13,39:52,40:14,41:51,42:49,43:54,44:56,45:17,46:16,47:55,48:43,49:44,50:53,51:42,53:41,71:83,65:99,67:85,69:87,75:84,76:88,78:86,81:103,82:98,83:89,84:90,85:91,86:92,87:93,88:94,89:95,91:96,92:97,96:62,97:63,98:64,99:60,100:65,101:66,103:68,105:104,106:107,107:105,109:67,111:69,113:106,114:73,115:74,116:75,117:76,118:61,119:77,120:59,121:78,122:58,123:80,124:79,125:81,126:82,10:100,93:137,94:135,95:133,102:144,104:145,64:108,79:109,80:110,90:111]
}
