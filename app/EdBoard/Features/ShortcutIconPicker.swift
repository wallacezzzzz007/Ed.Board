import SwiftUI
import AppKit

private struct ShortcutIcon: Identifiable {
    let id: String
    let title: String
    let category: String
}

struct ShortcutIconPicker: View {
    let selected: String
    let choose: (String) -> Void
    @State private var search = ""
    @State private var category = "All"
    @State private var hovered: String?
    private static let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("arrow.up.right.square", "Open externally"), ("arrow.uturn.backward", "Undo"),
            ("arrow.uturn.forward", "Redo"), ("arrow.left", "Back"), ("arrow.right", "Forward"),
            ("arrow.up", "Up"), ("arrow.down", "Down"), ("arrow.clockwise", "Refresh"),
            ("arrow.triangle.branch", "Branch"), ("arrow.triangle.merge", "Merge"),
            ("arrow.up.left.and.arrow.down.right", "Expand"), ("house", "Home")
        ]),
        ("Editing", [
            ("fa-highlighter", "Highlighter"), ("fa-language", "Language"),
            ("fa-spell-check", "Spell check"), ("pencil", "Edit"), ("scissors", "Cut"), ("doc.on.doc", "Copy"),
            ("doc.on.clipboard", "Paste"), ("trash", "Delete"), ("checkmark", "Confirm"),
            ("xmark", "Cancel"), ("plus", "Add"), ("minus", "Remove"),
            ("textformat", "Text"), ("bold", "Bold"), ("italic", "Italic"),
            ("underline", "Underline"), ("list.bullet", "List"), ("paintbrush", "Paint"),
            ("eyedropper", "Pick color")
        ]),
        ("Files & Apps", [
            ("folder", "Folder"), ("folder.badge.plus", "New folder"), ("doc", "Document"),
            ("doc.text", "Text document"), ("square.and.arrow.down", "Download"),
            ("square.and.arrow.up", "Share"), ("archivebox", "Archive"),
            ("globe", "Web"), ("link", "Link"), ("terminal", "Terminal"),
            ("curlybraces", "Code"), ("chevron.left.forwardslash.chevron.right", "Source code"),
            ("app", "Application"), ("rectangle.on.rectangle", "Windows")
        ]),
        ("Communication", [
            ("bubble.left", "Chat"), ("bubble.left.and.bubble.right", "Conversation"),
            ("envelope", "Mail"), ("paperplane", "Send"), ("phone", "Call"),
            ("person", "Person"), ("person.2", "People"), ("at", "Mention"),
            ("bell", "Notifications"), ("bell.slash", "Mute notifications")
        ]),
        ("Media", [
            ("play", "Play"), ("pause", "Pause"), ("stop", "Stop"),
            ("backward.end", "Previous"), ("forward.end", "Next"),
            ("speaker.wave.2", "Volume"), ("speaker.slash", "Mute"),
            ("mic", "Microphone"), ("camera", "Camera"), ("video", "Video"),
            ("photo", "Image"), ("music.note", "Music")
        ]),
        ("Tools & Symbols", [
            ("magnifyingglass", "Search"), ("slider.horizontal.3", "Adjust"),
            ("gearshape", "Settings"), ("keyboard", "Keyboard"), ("command", "Command"),
            ("clock", "Clock"), ("calendar", "Calendar"), ("bookmark", "Bookmark"),
            ("star", "Star"), ("heart", "Heart"), ("bolt", "Quick action"),
            ("sparkles", "Sparkles"), ("flag", "Flag"), ("lock", "Lock"),
            ("eye", "Show"), ("eye.slash", "Hide")
        ])
    ]
    // Resolve availability locally so older supported macOS versions never show blank tiles.
    private static let icons: [ShortcutIcon] = groups.flatMap { group in
        group.1.compactMap { symbol, title in
            (ActionIconImage.assets[symbol] == nil && NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil) ? nil : ShortcutIcon(id: symbol, title: title, category: group.0)
        }
    }
    private var results: [ShortcutIcon] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.icons.filter {
            (category == "All" || category == $0.category) &&
            (query.isEmpty || "\($0.title) \($0.id) \($0.category)".localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose icon").font(.headline)
            TextField("Search icons", text: $search).textFieldStyle(.roundedBorder)
            FullWidthPopup(title: "Category", selection: $category, options: (["All"] + Self.groups.map { $0.0 }).map { PopupOption(id: $0, title: $0) }).frame(height: 32)
            ScrollView {
                if results.isEmpty {
                    Text("No icons found").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(results) { icon in
                            Button { choose(icon.id) } label: {
                                ActionIconImage.image(icon.id).resizable().scaledToFit().frame(width: 22, height: 22)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(selected == icon.id ? Color.accentColor.opacity(0.18) : hovered == icon.id ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected == icon.id ? Color.accentColor : .clear))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(icon.title)
                                .accessibilityValue(selected == icon.id ? "Selected" : "")
                                .onHover { inside in
                                    if inside { hovered = icon.id } else if hovered == icon.id { hovered = nil }
                                }
                        }
                    }.padding(3)
                }
            }.frame(height: 270)
            Button("Remove icon") { choose("") }
        }.padding(16).frame(width: 310)
    }
}


// Stable IDs are stored in the existing presentation symbol field.
enum ActionIconImage {
    static let assets = [
        "fa-highlighter": "HighlighterAction",
        "fa-language": "LanguageAction",
        "fa-spell-check": "SpellCheckAction"
    ]
    static func image(_ symbol: String) -> Image {
        if let asset = assets[symbol] { return Image(asset) }
        return Image(systemName: symbol)
    }
}
