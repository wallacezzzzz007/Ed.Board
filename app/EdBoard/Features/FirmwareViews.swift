import SwiftUI
import AppKit

struct FirmwareStatusView: View {
    @ObservedObject var model: BoardModel
    private var upToDate: Bool {
        model.connected && model.firmwareIdentity != nil && !model.firmwareMismatch && !model.firmware.active
    }
    private var statusColor: Color {
        model.firmwareMismatch ? .red : upToDate ? .green : .secondary
    }
    private var badge: some View {
        HStack(spacing: 8) {
            Image(systemName: model.firmwareMismatch ? "exclamationmark.triangle.fill" : upToDate ? "checkmark.circle.fill" : "cpu")
                .foregroundStyle(statusColor).font(.system(size: 17))
            Text(model.firmwareIdentity?.firmware ?? "Not checked")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Firmware").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if model.firmwareMismatch && model.connected && !model.usingBluetooth && !model.firmware.active {
                Button { model.firmware.showPreparation.toggle() } label: { badge }
                    .buttonStyle(.plain).accessibilityLabel("Firmware \(model.firmwareIdentity?.firmware ?? ""), update required")
                    .accessibilityHint("Open firmware update options")
            } else {
                badge.accessibilityElement(children: .combine)
                    .accessibilityValue(upToDate ? "Up to date" : model.firmwareMismatch ? "Update required" : "Not checked")
            }
            if model.firmwareMismatch && model.usingBluetooth {
                Text("Connect via USB to update").font(.caption).foregroundStyle(.red)
            }
            if !model.connected && model.firmwareIdentity != nil { Text("Last read").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FirmwarePanel: View {
    @ObservedObject var model: BoardModel
    @State private var confirm = false
    @State private var details = false
    @State private var recovery = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.firmware.active {
                Text(model.firmware.title).font(.headline)
                if let progress = model.firmware.progress {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%").monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Text("Keep your keyboard connected.").font(.callout)
            } else {
                Text("Required firmware: \(FirmwareUpdater.required)").font(.callout)
                    .foregroundStyle(model.firmwareMismatch ? Color.red : Color.secondary)
                if !model.firmware.message.isEmpty { Text(model.firmware.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if model.firmware.blocksEditor {
                    Button("Reconnect") { model.reconnectAfterFirmware() }
                }
                if model.firmware.stage != "settings" && model.firmware.stage != "awaitingRestart" && (model.firmwareMismatch || model.firmware.blocksEditor) {
                    Button(model.hasCurrentFirmwareAttempt ? "Retry installation" : "Install required firmware") { confirm = true }
                        .disabled(!model.canBeginFirmware)
                }
                if let path = model.firmware.record?.backup {
                    Button("Show backup in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                if model.firmware.blocksEditor {
                    DisclosureGroup("Recovery help", isExpanded: $recovery) {
                        Text("Connect the same keyboard via USB and close serial monitors. If automatic download mode fails: hold B, press and release R, then release B. Click Retry installation. If writing already succeeded but the keyboard did not restart, release B and press R once, then Reconnect. No settings partition will be erased.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DisclosureGroup("Update details", isExpanded: $details) {
                if model.firmware.record?.stage != "success" {
                    Button("Show update log") { NSWorkspace.shared.activateFileViewerSelecting([model.firmware.log]) }
                }
                ScrollView { Text(model.firmware.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130)
            }
        }
        .alert("Install required firmware?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}
            Button("Start update") { model.startFirmwareUpdate() }
        } message: {
            Text("Install firmware \(FirmwareUpdater.required).\nKeyboard input will pause. Keep USB connected.\nSettings are backed up before writing.")
        }
    }
}

struct FirmwareLoadingView: View {
    @ObservedObject var model: BoardModel
    let openSystem: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            if model.firmware.active {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 42)).foregroundStyle(.red)
            }
            Text(model.firmware.blocksEditor ? model.firmware.title : "Firmware update required").font(.title2.weight(.semibold))
            if let progress = model.firmware.progress {
                ProgressView(value: progress).frame(width: 280)
                Text("\(Int(progress * 100))%").monospacedDigit()
            }
            if model.firmware.active {
                Text("Keep your keyboard connected.").foregroundStyle(.secondary)
            } else if !model.firmware.message.isEmpty {
                Text(model.firmware.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text("Current: \(model.firmwareIdentity?.firmware ?? "Not checked")\nRequired: \(FirmwareUpdater.required)").foregroundStyle(.secondary)
            }
            if !model.firmware.active && model.firmware.blocksEditor {
                Button("Reconnect") { model.reconnectAfterFirmware() }
            }
            Button("Open System", action: openSystem)
        }.frame(maxWidth: 500).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FirmwareDiagnosticsView: View {
    @ObservedObject var model: BoardModel
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Firmware update", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let path = model.firmware.record?.backup {
                    Button("Show backup in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                if model.firmware.record?.stage != "success" {
                    Button("Show update log") { NSWorkspace.shared.activateFileViewerSelecting([model.firmware.log]) }
                }
                if !model.firmware.details.isEmpty {
                    ScrollView {
                        Text(model.firmware.details).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 130)
                }
            }.padding(.top, 12)
        }
    }
}

// A native button makes the entire disclosure header clickable and keyboard accessible.
struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
