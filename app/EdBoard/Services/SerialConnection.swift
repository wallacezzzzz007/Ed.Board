import Foundation
import IOKit
import IOKit.serial
import Darwin
import BoardCore

struct SerialPort: Identifiable, Hashable {
    let path: String
    let serial: String?
    let vendor: Int?
    let product: Int?
    var id: String { path }
    var label: String { URL(fileURLWithPath: path).lastPathComponent + (vendor == 0x303a && product == 0x1001 ? " · Download mode" : "") }
}

final class SerialConnection {
    enum Event { case opened, lines([String]), failed(String) }
    private let queue = DispatchQueue(label: "cn.edboard.serial", qos: .utility)
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var framer = LineFramer()
    private var generation = 0
    private var callback: ((Event) -> Void)?

    static func ports() -> [SerialPort] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = [SerialPort]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, path.hasPrefix("/dev/cu.usbmodem") {
                func property(_ key: String) -> Any? {
                    IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                }
                result.append(SerialPort(path: path, serial: property("USB Serial Number") as? String,
                    vendor: (property("idVendor") as? NSNumber)?.intValue,
                    product: (property("idProduct") as? NSNumber)?.intValue))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    func open(path: String, callback: @escaping (Event) -> Void) {
        queue.async { [self] in
            self.closeOnQueue(); self.callback = callback; self.framer = LineFramer()
            let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else { self.fail("Cannot open port: \(String(cString: strerror(errno)))"); return }
            self.descriptor = fd
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, ioctl(fd, TIOCEXCL, 0) == 0 else {
                self.fail("Serial port is in use. Close Monitor, Input or other management clients."); return
            }
            var options = termios()
            guard tcgetattr(fd, &options) == 0 else { self.fail("Cannot read serial settings"); return }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            withUnsafeMutableBytes(of: &options.c_cc) { controls in
                controls[Int(VMIN)] = 1; controls[Int(VTIME)] = 0
            }
            cfsetspeed(&options, speed_t(B115200))
            guard tcsetattr(fd, TCSANOW, &options) == 0 else { self.fail("Cannot configure serial port"); return }
            tcflush(fd, TCIFLUSH)
            self.appendLog("\nEd.Board App session \(Date().description) port=\(path)\n")
            guard self.descriptor == fd else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            // Close only in cancellation handler, so a reused descriptor cannot race the old source.
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in self?.readAvailable() }
            self.reader = source; source.resume(); self.emit(.opened)
        }
    }
    func send(_ data: Data) {
        queue.async {
            guard self.descriptor >= 0 else { return }
            self.appendLog("app tx " + String(decoding: data, as: UTF8.self))
            self.write(data, offset: 0, generation: self.generation, deadline: .now() + 3)
        }
    }
    func close() { queue.async { self.closeOnQueue() } }
    func shutdown() { queue.sync { self.closeOnQueue() } }
    private func emit(_ event: Event) {
        let handler = callback
        DispatchQueue.main.async { handler?(event) }
    }
    private func fail(_ message: String) { appendLog("app error \(message)\n"); emit(.failed(message)); closeOnQueue() }
    private func appendLog(_ text: String) { AppLog.shared.ingest(text, transport: "usb") }
    private func closeOnQueue() {
        generation += 1
        if let source = reader { reader = nil; source.cancel() }
        else if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        callback = nil
    }
    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var batch = [String]()
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { batch += framer.feed(Data(buffer.prefix(count))) }
            else if count == 0 { fail("Device disconnected. Reconnect to continue."); return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { fail("Read failed: \(String(cString: strerror(errno)))"); return }
        }
        if !batch.isEmpty {
            let diagnostic = batch.filter { !PreviewFrame.isPreviewLine($0) && !JoystickFrame.isJoystickLine($0) }
            if !diagnostic.isEmpty { appendLog(diagnostic.joined(separator: "\n") + "\n") }
            emit(.lines(batch))
        }
    }
    private func write(_ data: Data, offset: Int, generation: Int, deadline: DispatchTime) {
        guard generation == self.generation, descriptor >= 0 else { return }
        let count = data.withUnsafeBytes { pointer in
            Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if count == data.count - offset { return }
        if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            fail("Serial write failed: \(String(cString: strerror(errno)))"); return
        }
        guard DispatchTime.now() < deadline else { fail("Serial write timed out"); return }
        queue.asyncAfter(deadline: .now() + 0.02) {
            self.write(data, offset: offset + max(0, count), generation: generation, deadline: deadline)
        }
    }
}

// Event-driven USB port inventory; iterators must be drained to re-arm notifications.
final class SerialPortWatcher {
    private var port: IONotificationPortRef?
    private var arrivals: io_iterator_t = 0
    private var removals: io_iterator_t = 0
    private let changed: () -> Void
    private(set) var available = false
    init(changed: @escaping () -> Void) {
        self.changed = changed
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let context else { return }
            Unmanaged<SerialPortWatcher>.fromOpaque(context).takeUnretainedValue().changed()
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let first = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
            IOServiceMatching(kIOSerialBSDServiceValue), callback, context, &arrivals)
        let second = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            IOServiceMatching(kIOSerialBSDServiceValue), callback, context, &removals)
        if first == KERN_SUCCESS { callback(context, arrivals) }
        if second == KERN_SUCCESS { callback(context, removals) }
        available = first == KERN_SUCCESS && second == KERN_SUCCESS
    }
    deinit {
        if arrivals != 0 { IOObjectRelease(arrivals) }
        if removals != 0 { IOObjectRelease(removals) }
        if let port { IONotificationPortDestroy(port) }
    }
}
