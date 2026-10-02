import Foundation
import CoreBluetooth
import BoardCore

// CoreBluetooth callbacks and state are confined to the main queue. Scanning is
// bounded; normal operation uses notifications rather than device polling.
final class BluetoothConnection: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceID = CBUUID(string: "EDB00001-7B5A-4C31-9D62-0B6D7F820001")
    private let rxID = CBUUID(string: "EDB00002-7B5A-4C31-9D62-0B6D7F820001")
    private let txID = CBUUID(string: "EDB00003-7B5A-4C31-9D62-0B6D7F820001")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var callback: ((SerialConnection.Event) -> Void)?
    private var timer: DispatchWorkItem?
    private var framer = LineFramer()
    private var writes = BLEWriteBuffer()
    private var writeRetry: DispatchWorkItem?
    private var resourceRetries = 0
    private var opened = false
    private var searching = false
    private var retriedCharacteristics = false
    private var stage = "Waiting for Bluetooth"
    private var rememberedID: UUID?
    private var backgroundWait = false

    func open(backgroundWait: Bool = false, callback: @escaping (SerialConnection.Event) -> Void) {
        close(); self.callback = callback; self.backgroundWait = backgroundWait
        log("\nEd.Board BLE session \(Date().description)\n")
        stage = "Waiting for Bluetooth permission"
        armTimeout(seconds: 60, message: "Bluetooth initialization timed out. Check permission.")
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { beginDiscovery() }
    }
    func rememberVerifiedDevice() { rememberedID = peripheral?.identifier }
    var canRetrieveVerifiedDevice: Bool {
        guard let central, central.state == .poweredOn, let rememberedID else { return false }
        return !central.retrievePeripherals(withIdentifiers: [rememberedID]).isEmpty
    }
    func close() {
        writeRetry?.cancel(); writeRetry = nil; resourceRetries = 0
        timer?.cancel(); timer = nil; searching = false; opened = false; retriedCharacteristics = false
        central?.stopScan()
        let old = peripheral
        peripheral = nil; input = nil; output = nil; callback = nil
        old?.delegate = nil
        if let old { central?.cancelPeripheralConnection(old) }
        writes = BLEWriteBuffer(); framer = LineFramer()
    }
    func send(_ data: Data) {
        guard opened, writes.enqueue(data) else { fail("Bluetooth write queue unavailable. Reconnect."); return }
        log("app ble tx " + String(decoding: data, as: UTF8.self))
        armTimeout(seconds: 20, message: "Bluetooth write timed out. Save was not automatically retried.")
        writeNext()
    }
    private func writeNext() {
        guard writeRetry == nil, let peripheral, let input else { return }
        guard !writes.isEmpty else { timer?.cancel(); timer = nil; return }
        // withResponse may allow long ATT writes; cap to the negotiated
        // single-PDU limit as well so the firmware never needs prepare/execute.
        let limit = min(peripheral.maximumWriteValueLength(for: .withResponse),
                        peripheral.maximumWriteValueLength(for: .withoutResponse))
        guard limit > 0 else { fail("Invalid Bluetooth write length"); return }
        if let chunk = writes.next(maximum: limit) { peripheral.writeValue(chunk, for: input, type: .withResponse) }
    }
    private func armTimeout(seconds: Double, message: String) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in guard let self else { return }; self.fail(message + " (stage: " + self.stage + ")") }
        timer = item; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func fail(_ message: String, cause: Error? = nil) {
        guard let callback else { return }
        let code = cause.map { " domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? ""
        log("app ble error \(message)\(code)\n")
        close(); callback(.failed(message))
    }
    private func beginDiscovery() {
        guard callback != nil, !searching, peripheral == nil, let central else { return }
        switch central.state {
        case .poweredOn: break
        case .unknown, .resetting: return
        case .unauthorized: fail("Allow Ed.Board Bluetooth access in System Settings."); return
        case .poweredOff: fail("Bluetooth is turned off."); return
        default: fail("Bluetooth management is unavailable on this Mac."); return
        }
        searching = true; stage = "Finding connected devices"
        // Query services separately: HID-owned devices may only be exposed via
        // their Battery / Device Information services to this CoreBluetooth client.
        var candidates = [UUID: CBPeripheral]()
        for id in [serviceID, CBUUID(string: "1812"), CBUUID(string: "180A"), CBUUID(string: "180F")] {
            let devices = central.retrieveConnectedPeripherals(withServices: [id])
            log("app ble retrieve service=\(id.uuidString) count=\(devices.count)\n")
            for device in devices {
                let matches = Self.matchesName(device.name)
                log("app ble candidate id=\(device.identifier.uuidString) name=\(String((device.name ?? "nil").prefix(80)).replacingOccurrences(of: "\n", with: " ")) match=\(matches)\n")
                if id == serviceID || matches { candidates[device.identifier] = device }
            }
        }
        guard candidates.count <= 1 else { fail("Multiple keyboards found. Connect only the intended keyboard and retry."); return }
        if let device = candidates.values.first { attach(device); return }
        if let rememberedID, let device = central.retrievePeripherals(withIdentifiers: [rememberedID]).first {
            attach(device); return
        }
        stage = "Scanning advertisements"
        log("app ble scan started\n")
        armTimeout(seconds: backgroundWait ? 5 : 15, message: "No connectable Ed.Board device found. Check the log.")
        central.scanForPeripherals(withServices: [CBUUID(string: "1812"), serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    private static func matchesName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" } == "codexmicro"
    }

    private func attach(_ device: CBPeripheral) {
        guard peripheral == nil, callback != nil else { return }
        central?.stopScan(); peripheral = device; device.delegate = self
        log("app ble peripheral \(device.identifier.uuidString)\n")
        stage = "Connecting peripheral"
        // A known sleeping peripheral can remain pending without scanning. CoreBluetooth
        // completes this request when it returns; explicit close/USB/update cancels it.
        if backgroundWait && device.identifier == rememberedID {
            AppLog.shared.event("BLE known-device connection wait submitted; no discovery scan")
            timer?.cancel(); timer = nil
        } else { armTimeout(seconds: 15, message: "Bluetooth connection timed out. Check the log.") }
        central?.connect(device, options: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("app ble central state=\(central.state.rawValue)\n")
        if central.state == .poweredOn { beginDiscovery() }
        else if callback != nil, central.state != .unknown { fail("Bluetooth unavailable. Check Bluetooth and permission settings."); }
    }
    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard Self.matchesName(device.name) || Self.matchesName(advertisementData[CBAdvertisementDataLocalNameKey] as? String) else { return }
        log("app ble discovered id=\(device.identifier.uuidString)\n")
        attach(device)
    }
    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard device === peripheral else { return }
        stage = "Discovering management service"; log("app ble connected\n")
        armTimeout(seconds: 15, message: "Management service discovery timed out. Check the log.")
        device.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }; fail("Bluetooth connection failed: \(error?.localizedDescription ?? "Unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard device === peripheral else { return }; fail("Bluetooth management disconnected.", cause: error)
    }
    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral else { return }
        guard error == nil, let service = device.services?.first(where: { $0.uuid == serviceID }) else {
            fail("Ed.Board management service not found. Check firmware and logs before clearing pairing."); return
        }
        stage = "Discovering management characteristics"; log("app ble service found\n")
        armTimeout(seconds: 15, message: "Management characteristic discovery timed out. Check the log.")
        device.discoverCharacteristics([rxID, txID], for: service)
    }
    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral else { return }
        let summary = (service.characteristics ?? []).map { "\($0.uuid.uuidString):\($0.properties.rawValue)" }.joined(separator: ",")
        let detail = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code) \($0.localizedDescription)" } ?? "none"
        log("app ble characteristics service=\(service.uuid.uuidString) values=[\(summary)] error=\(detail)\n")
        // HID and other clients can cause unrelated service callbacks. Only our
        // management service can establish or invalidate this pair of handles.
        guard service.uuid == serviceID, !opened else { return }
        let rx = service.characteristics?.first { $0.uuid == rxID }
        let tx = service.characteristics?.first { $0.uuid == txID }
        guard error == nil, let input = rx, let output = tx,
              input.properties.contains(.write), output.properties.contains(.notify) else {
            if !retriedCharacteristics {
                retriedCharacteristics = true
                log("app ble retry all management characteristics\n")
                armTimeout(seconds: 15, message: "Complete characteristic discovery timed out. Check the log.")
                device.discoverCharacteristics(nil, for: service)
                return
            }
            fail("Incomplete Bluetooth management characteristics (\(detail)). Check the diagnostic log."); return
        }
        self.input = input; self.output = output
        stage = "Subscribing to management responses"; log("app ble characteristics found\n")
        armTimeout(seconds: 15, message: "Management subscription timed out. Check the log.")
        device.setNotifyValue(true, for: output)
    }
    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic.uuid == txID else { return }
        guard error == nil, characteristic.isNotifying else { fail("Cannot subscribe to Bluetooth responses.", cause: error); return }
        stage = "Management ready"; log("app ble notification ready\n")
        timer?.cancel(); timer = nil; opened = true; callback?(.opened)
    }
    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic.uuid == rxID else { return }
        if let error {
            let failure = error as NSError
            // ATT 0x11: our management characteristic atomically rejects a chunk
            // when its RX ring is full. The offset must NOT advance or replay a frame.
            if failure.domain == CBATTErrorDomain, failure.code == 0x11,
               let delay = BLEWriteBuffer.resourceRetryDelay(attempt: resourceRetries),
               writes.rejectUnacceptedChunk() {
                resourceRetries += 1
                AppLog.shared.event("BLE write backpressure; retrying unaccepted chunk attempt=\(resourceRetries)")
                let work = DispatchWorkItem { [weak self, weak device] in
                    guard let self, let device, self.peripheral === device, self.opened else { return }
                    self.writeRetry = nil; self.writeNext()
                }
                writeRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return
            }
            fail("Bluetooth write failed: \(error.localizedDescription)", cause: error); return
        }
        if resourceRetries > 0 { AppLog.shared.event("BLE write backpressure recovered") }
        resourceRetries = 0
        writes.acknowledge(); writeNext()
    }
    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, characteristic.uuid == txID else { return }
        guard error == nil, let data = characteristic.value else { fail("Cannot read Bluetooth response.", cause: error); return }
        let dropped = framer.droppedLines
        let lines = framer.feed(data)
        guard framer.droppedLines == dropped else { fail("Bluetooth response exceeds the frame limit."); return }
        if !lines.isEmpty {
            let diagnostic = lines.filter { !PreviewFrame.isPreviewLine($0) && !JoystickFrame.isJoystickLine($0) }
            if !diagnostic.isEmpty { log(diagnostic.joined(separator: "\n") + "\n") }
            callback?(.lines(lines))
        }
    }
    private func log(_ value: String) { AppLog.shared.ingest(value, transport: "bluetooth") }
}
