import CoreBluetooth
import Darwin
import Foundation

private let targetName = "Ado Light Stick"
private let zeroUUIDBase = "0000000000001000800000805F9B34FB"

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidPayload(let message):
            return message
        }
    }
}

private enum Mode {
    case probe
    case replay(Data)
    case rgb(ScreenRGB)
    case sync
    case calibrate
}

private enum CalibrationCommand {
    case quit
    case write(Data)
}

private struct Options {
    let mode: Mode
    let device: UUID?
    let duration: Int

    static let usage = """
    Usage:
      PenlightSync --probe [--duration SECONDS]
      PenlightSync --replay OBSERVED_HEX --device UUID [--duration SECONDS]
      PenlightSync --rgb RRGGBB --device UUID [--duration SECONDS]
      PenlightSync --sync --device UUID [--duration SECONDS]
      PenlightSync --calibrate --device UUID [--duration SECONDS]
      PenlightSync --self-test
      PenlightSync --stdin-self-test (input transport test)

    OBSERVED_HEX is exactly 32 hexadecimal characters (16 bytes). Calibration
    accepts newline-delimited observed hex or `quit` on stdin. RGB values are
    encoded with the device's public command protocol.
    """

    static func parse(_ arguments: [String]) throws -> Options? {
        if arguments == ["--self-test"] { return nil }
        guard !arguments.isEmpty else { throw CLIError.usage(usage) }

        var modeName: String?
        var replayHex: String?
        var rgbHex: String?
        var deviceText: String?
        var duration = 60
        var sawDuration = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func valueAfterFlag() throws -> String {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIError.usage("Missing value after \(argument).\n\(usage)")
                }
                index += 1
                return arguments[index]
            }

            switch argument {
            case "--probe", "--sync", "--calibrate":
                guard modeName == nil, replayHex == nil else {
                    throw CLIError.usage("Choose exactly one mode.\n\(usage)")
                }
                modeName = argument
            case "--rgb":
                guard modeName == nil, replayHex == nil else {
                    throw CLIError.usage("Choose exactly one mode.\n\(usage)")
                }
                modeName = argument
                rgbHex = try valueAfterFlag()
            case "--replay":
                guard modeName == nil, replayHex == nil else {
                    throw CLIError.usage("Choose exactly one mode.\n\(usage)")
                }
                replayHex = try valueAfterFlag()
            case "--device":
                guard deviceText == nil else { throw CLIError.usage("Duplicate --device.") }
                deviceText = try valueAfterFlag()
            case "--duration":
                guard !sawDuration else { throw CLIError.usage("Duplicate --duration.") }
                sawDuration = true
                let raw = try valueAfterFlag()
                guard let value = Int(raw), (1...3600).contains(value) else {
                    throw CLIError.usage("--duration must be an integer from 1 to 3600 seconds.")
                }
                duration = value
            default:
                throw CLIError.usage("Unknown argument: \(argument)\n\(usage)")
            }
            index += 1
        }

        if modeName == "--probe" {
            guard replayHex == nil, deviceText == nil else {
                throw CLIError.usage("--probe does not take --device.\n\(usage)")
            }
            return Options(mode: .probe, device: nil, duration: duration)
        }

        guard let deviceText, let device = UUID(uuidString: deviceText) else {
            throw CLIError.usage("--device must be a UUID returned by --probe.\n\(usage)")
        }
        if let replayHex {
            guard modeName == nil else {
                throw CLIError.usage("--replay cannot be combined with another mode.\n\(usage)")
            }
            return Options(
                mode: .replay(try Data(validatedHex: replayHex)), device: device, duration: duration
            )
        }
        if modeName == "--calibrate" {
            return Options(mode: .calibrate, device: device, duration: duration)
        }
        if modeName == "--rgb", let rgbHex {
            return Options(mode: .rgb(try parseRGBHex(rgbHex)), device: device, duration: duration)
        }
        guard modeName == "--sync" else { throw CLIError.usage(usage) }
        return Options(mode: .sync, device: device, duration: duration)
    }
}

private extension Data {
    init(validatedHex: String) throws {
        guard validatedHex.utf8.count == 32,
              validatedHex.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }),
              let value = Data(hex: validatedHex), value.count == 16 else {
            throw CLIError.invalidPayload("Payload must be exactly 32 hexadecimal characters (16 bytes).")
        }
        self = value
    }

    init?(hex: String) {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var highNibble: UInt8?
        for scalar in hex.utf8 {
            let nibble: UInt8
            switch scalar {
            case 48...57: nibble = scalar - 48
            case 65...70: nibble = scalar - 55
            case 97...102: nibble = scalar - 87
            default: return nil
            }
            if let high = highNibble {
                bytes.append((high << 4) | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }
        self.init(bytes)
    }
}

private func parseRGBHex(_ raw: String) throws -> ScreenRGB {
    guard raw.utf8.count == 6,
          raw.utf8.allSatisfy({
              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
          }),
          let components = Data(hex: raw), components.count == 3 else {
        throw CLIError.invalidPayload("RGB must be exactly six hexadecimal characters (RRGGBB).")
    }
    return ScreenRGB(red: components[0], green: components[1], blue: components[2])
}

private func parseCalibrationLine(_ rawLine: [UInt8]) throws -> CalibrationCommand {
    var line = rawLine
    if line.last == 13 { line.removeLast() } // Accept a CRLF line ending.
    guard let text = String(bytes: line, encoding: .utf8) else {
        throw CLIError.invalidPayload("Input line must be ASCII hex or `quit`.")
    }
    if text == "quit" { return .quit }
    return .write(try Data(validatedHex: text))
}

private func isZeroUUID(_ raw: String) -> Bool {
    let normalized = raw.uppercased().filter { $0 != "-" }
    return normalized == "0000" || normalized == zeroUUIDBase
}

private func isExactExplicitTarget(identifier: UUID, name: String?, requested: UUID?) -> Bool {
    requested == identifier && name == targetName
}

private func isProbeAdvertisementMatch(advertisedName: String?, peripheralName: String?) -> Bool {
    guard peripheralName == targetName, let advertisedName else { return false }
    return advertisedName.caseInsensitiveCompare(targetName) == .orderedSame
}

private enum CalibrationInputEvent {
    case data(Data)
    case eof
    case failure(String)
}

private final class CalibrationInputReader {
    private let handle: FileHandle
    private var onEvent: ((CalibrationInputEvent) -> Void)?

    init(handle: FileHandle = .standardInput) {
        self.handle = handle
    }

    func start(onEvent: @escaping (CalibrationInputEvent) -> Void) throws {
        self.onEvent = onEvent
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            self.onEvent = nil
            throw CLIError.usage("Could not enable nonblocking stdin: \(String(cString: strerror(errno))).")
        }

        handle.readabilityHandler = { [weak self] readableHandle in
            guard let self else {
                readableHandle.readabilityHandler = nil
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count < 0 {
                let readError = errno
                if readError == EAGAIN || readError == EWOULDBLOCK || readError == EINTR { return }
                readableHandle.readabilityHandler = nil
                self.onEvent?(.failure(String(cString: strerror(readError))))
                return
            }
            if count == 0 {
                readableHandle.readabilityHandler = nil
                self.onEvent?(.eof)
                return
            }
            self.onEvent?(.data(Data(buffer.prefix(count))))
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        onEvent = nil
    }
}

private final class CalibrationInputReaderSelfTest {
    private let reader = CalibrationInputReader()
    private var finished = false
    private var exitStatus: Int32 = 0

    func run() -> Int32 {
        do {
            try reader.start { [weak self] event in
                DispatchQueue.main.async { [weak self] in self?.consume(event) }
            }
        } catch {
            fputs("stdin self-test: \(error.localizedDescription)\n", stderr)
            return 2
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return exitStatus
    }

    private func consume(_ event: CalibrationInputEvent) {
        switch event {
        case .data(let data):
            print("STDIN_DATA bytes=\(data.count)")
        case .eof:
            reader.stop()
            print("STDIN_EOF")
            finished = true
        case .failure(let message):
            reader.stop()
            fputs("stdin self-test: \(message)\n", stderr)
            exitStatus = 2
            finished = true
        }
    }
}

private func syncDurationExitStatus(acknowledgedWrites: Int) -> Int32 {
    acknowledgedWrites > 0 ? 0 : 2
}

private enum SyncOperationWatchdog {
    static let timeout: TimeInterval = 8

    static func expired(active: Bool, startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard active, let startedAt, now >= startedAt else { return false }
        return now - startedAt >= timeout
    }
}

private func requiresScreenCapturePermission(for mode: Mode) -> Bool {
    if case .sync = mode { return true }
    return false
}

private final class BLESession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let options: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var targetCharacteristic: CBCharacteristic?
    private var timeoutTimer: Timer?
    private var syncTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var shutdownFallback: DispatchWorkItem?
    private var sampleTask: Task<Void, Never>?
    private var sampling = false
    private var sampleStartedAt: TimeInterval?
    private var writePending = false
    private var pendingRGB: ScreenRGB?
    private var lastWrittenRGB: ScreenRGB?
    private var lastWriteStartedAt: TimeInterval?
    private var pendingSyncWriteStartedAt: TimeInterval?
    private var calibrationInput = [UInt8]()
    private var discardingOversizedCalibrationLine = false
    private var calibrationInputReader: CalibrationInputReader?
    private var acknowledgedSyncWrites = 0
    private var shutdownRequested = false
    private var finished = false
    private var exitStatus: Int32 = 0

    init(options: Options) {
        self.options = options
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func run() -> Int32 {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in self?.requestShutdown(code: 130, message: "Interrupted.") }
        source.resume()
        signalSource = source

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(options.duration), repeats: false) { [weak self] _ in
            guard let self, !self.finished, !self.shutdownRequested else { return }
            switch self.options.mode {
            case .sync where self.targetCharacteristic != nil:
                let status = self.writePending ? 0 : syncDurationExitStatus(
                    acknowledgedWrites: self.acknowledgedSyncWrites
                )
                self.requestShutdown(
                    code: status,
                    message: "Sync duration elapsed (acknowledged writes: \(self.acknowledgedSyncWrites))."
                )
            case .calibrate where self.targetCharacteristic != nil:
                self.requestShutdown(code: 0, message: "Calibration duration elapsed.")
            default:
                self.requestShutdown(code: 2, message: "Timed out before BLE setup completed.")
            }
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        signalSource?.cancel()
        timeoutTimer?.invalidate()
        return exitStatus
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished, !shutdownRequested else { return }
        guard central.state == .poweredOn else {
            if central.state == .poweredOff || central.state == .unauthorized || central.state == .unsupported {
                finish(code: 2, message: "Bluetooth is unavailable (state: \(central.state.rawValue)).")
            }
            return
        }
        switch options.mode {
        case .probe:
            print("Scanning for \(targetName)…")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .replay, .rgb, .sync, .calibrate:
            guard let device = options.device else {
                finish(code: 2, message: "Missing target device UUID.")
                return
            }
            let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "0000")])
            if let peripheral = connected.first(where: {
                isExactExplicitTarget(identifier: $0.identifier, name: $0.name, requested: device)
            }) {
                print("Reusing connected target \(targetName) (\(device.uuidString)).")
                connect(to: peripheral)
                return
            }
            print("Scanning for explicit target UUID \(device.uuidString)…")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !finished, !shutdownRequested, self.peripheral == nil else { return }
        switch options.mode {
        case .probe:
            let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            guard isProbeAdvertisementMatch(advertisedName: advertised, peripheralName: peripheral.name) else { return }
        case .replay, .rgb, .sync, .calibrate:
            // Match the explicit CoreBluetooth identifier before considering the advertised name.
            guard peripheral.identifier == options.device else { return }
            guard isExactExplicitTarget(
                identifier: peripheral.identifier,
                name: peripheral.name,
                requested: options.device
            ) else {
                print("Ignored explicit UUID whose peripheral name did not exactly match \(targetName).")
                return
            }
        }
        central.stopScan()
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !finished, !shutdownRequested else { central.cancelPeripheralConnection(peripheral); return }
        let identityMatches: Bool
        if let requested = options.device {
            identityMatches = isExactExplicitTarget(
                identifier: peripheral.identifier,
                name: peripheral.name,
                requested: requested
            )
        } else {
            identityMatches = peripheral.name == targetName
        }
        guard identityMatches else {
            finish(code: 2, message: "Connected peripheral identity did not match the selected Ado Light Stick target.")
            return
        }
        self.peripheral = peripheral
        beginDiscovery(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(code: 2, message: "Could not connect: \(error?.localizedDescription ?? "unknown error").")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if shutdownRequested {
            if writePending {
                writePending = false
                pendingSyncWriteStartedAt = nil
                exitStatus = 2
                print("Write was not acknowledged before disconnect.")
            }
            completeShutdown()
        } else if let error {
            if writePending {
                writePending = false
                pendingSyncWriteStartedAt = nil
                print("CALIBRATION_ERROR write was not acknowledged before disconnect.")
            }
            requestShutdown(code: 2, message: "Disconnected with error: \(error.localizedDescription).")
        } else {
            if writePending {
                writePending = false
                pendingSyncWriteStartedAt = nil
                print("CALIBRATION_ERROR write was not acknowledged before disconnect.")
            }
            requestShutdown(code: 2, message: "Peripheral disconnected unexpectedly.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !finished, !shutdownRequested else { return }
        if let error { requestShutdown(code: 2, message: "Service discovery failed: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { isZeroUUID($0.uuid.uuidString) }) else {
            requestShutdown(code: 2, message: "Required service UUID 0000 was not found.")
            return
        }
        print("Found service \(service.uuid.uuidString).")
        peripheral.discoverCharacteristics([CBUUID(string: "0000")], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !finished, !shutdownRequested else { return }
        if let error { requestShutdown(code: 2, message: "Characteristic discovery failed: \(error.localizedDescription)"); return }
        guard isZeroUUID(service.uuid.uuidString),
              let characteristic = service.characteristics?.first(where: { isZeroUUID($0.uuid.uuidString) }) else {
            requestShutdown(code: 2, message: "Required characteristic UUID 0000 was not found under service 0000.")
            return
        }
        guard characteristic.properties.contains(.write) else {
            requestShutdown(code: 2, message: "Control characteristic does not support writes with response.")
            return
        }
        targetCharacteristic = characteristic
        switch options.mode {
        case .probe:
            print("PROBE_OK identifier=\(peripheral.identifier.uuidString) name=\(targetName) service=\(service.uuid.uuidString) characteristic=\(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)")
            requestShutdown(code: 0, message: "Probe completed; no write was sent.")
        case .replay(let payload):
            print("Writing one observed 16-byte payload with response…")
            writePending = true
            peripheral.writeValue(payload, for: characteristic, type: .withResponse)
        case .rgb(let color):
            do {
                let payload = try PenlightProtocol.encode(rgb: color)
                pendingRGB = color
                writePending = true
                print("Writing encoded RGB \(color) with response…")
                peripheral.writeValue(payload, for: characteristic, type: .withResponse)
            } catch {
                requestShutdown(code: 2, message: "Could not encode RGB command: \(error.localizedDescription)")
            }
        case .sync:
            print("Screen sync active (maximum 4 samples/writes per second).")
            syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.sampleAndMaybeWrite()
            }
        case .calibrate:
            startCalibrationInput(peripheral: peripheral, characteristic: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard writePending else { return }
        writePending = false
        pendingSyncWriteStartedAt = nil
        if let error {
            pendingRGB = nil
            requestShutdown(code: 2, message: "Write failed: \(error.localizedDescription).")
            return
        }
        if let color = pendingRGB {
            lastWrittenRGB = color
            if case .sync = options.mode { acknowledgedSyncWrites += 1 }
            print("RGB write acknowledged: \(color).")
        }
        pendingRGB = nil
        if case .replay = options.mode {
            requestShutdown(code: 0, message: "Replay write acknowledged.")
        } else if case .rgb = options.mode {
            requestShutdown(code: 0, message: "RGB write acknowledged.")
        } else if case .calibrate = options.mode {
            print("CALIBRATION_ACK")
            if shutdownRequested { beginDisconnect() }
        } else if shutdownRequested {
            beginDisconnect()
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        guard !finished, !shutdownRequested else { return }
        if let requested = options.device, peripheral.identifier != requested { return }
        guard peripheral.name == targetName else {
            finish(code: 2, message: "Refusing peripheral whose exact name is not \(targetName).")
            return
        }
        self.peripheral = peripheral
        print("Connecting to \(targetName) (\(peripheral.identifier.uuidString))…")
        central.connect(peripheral, options: nil)
    }

    private func beginDiscovery(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        print("Connected to \(targetName) (\(peripheral.identifier.uuidString)).")
        peripheral.discoverServices([CBUUID(string: "0000")])
    }

    private func sampleAndMaybeWrite() {
        guard !finished, !shutdownRequested, case .sync = options.mode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if SyncOperationWatchdog.expired(active: sampling, startedAt: sampleStartedAt, now: now) {
            requestShutdown(
                code: 2,
                message: "螢幕取樣超過 8 秒仍未完成，已停止同步。請確認螢幕錄製權限後重新啟動程式。"
            )
            return
        }
        if SyncOperationWatchdog.expired(active: writePending, startedAt: pendingSyncWriteStartedAt, now: now) {
            requestShutdown(
                code: 2,
                message: "藍牙寫入超過 8 秒未收到確認，已停止同步。請確認裝置仍連線後重新啟動程式。"
            )
            return
        }
        guard !sampling, !writePending else { return }
        sampling = true
        sampleStartedAt = now
        sampleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let color = try await ScreenColorSampler().sample()
                self.sampling = false
                self.sampleStartedAt = nil
                self.sampleTask = nil
                if self.shutdownRequested {
                    self.beginDisconnect()
                    return
                }
                guard !self.finished else { return }
                guard color != self.lastWrittenRGB,
                      let peripheral = self.peripheral,
                      let characteristic = self.targetCharacteristic else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let previous = self.lastWriteStartedAt, now - previous < 0.25 { return }
                do {
                    let payload = try PenlightProtocol.encode(rgb: color)
                    self.lastWriteStartedAt = now
                    self.pendingRGB = color
                    self.writePending = true
                    self.pendingSyncWriteStartedAt = now
                    print("Screen \(color) → encoded RGB write.")
                    peripheral.writeValue(payload, for: characteristic, type: .withResponse)
                } catch {
                    self.requestShutdown(code: 2, message: "Could not encode screen RGB: \(error.localizedDescription)")
                }
            } catch {
                self.sampling = false
                self.sampleStartedAt = nil
                self.sampleTask = nil
                self.requestShutdown(code: 2, message: "Screen sampling failed: \(error.localizedDescription)")
            }
        }
    }

    private func startCalibrationInput(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let reader = CalibrationInputReader()
        calibrationInputReader = reader
        do {
            try reader.start { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    self?.consumeCalibrationEvent(event, peripheral: peripheral, characteristic: characteristic)
                }
            }
        } catch {
            calibrationInputReader = nil
            requestShutdown(code: 2, message: error.localizedDescription)
            return
        }
        print("CALIBRATION_READY identifier=\(peripheral.identifier.uuidString) name=\(targetName) service=0000 characteristic=0000")
        print("Enter one observed 32-character hex payload per line, or `quit` to disconnect.")
    }

    private func consumeCalibrationEvent(
        _ event: CalibrationInputEvent,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard !finished, !shutdownRequested else { return }
        switch event {
        case .data(let data):
            consumeCalibrationInput(data, peripheral: peripheral, characteristic: characteristic)
        case .eof:
            calibrationInputReader?.stop()
            if !calibrationInput.isEmpty {
                print("CALIBRATION_ERROR ignored unterminated final input line.")
                calibrationInput.removeAll(keepingCapacity: true)
            }
            requestShutdown(code: 0, message: "Calibration input closed; disconnecting.")
        case .failure(let message):
            calibrationInputReader?.stop()
            requestShutdown(code: 2, message: "Calibration input read failed: \(message)")
        }
    }

    private func consumeCalibrationInput(
        _ data: Data,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard !finished, !shutdownRequested else { return }
        if data.isEmpty {
            calibrationInputReader?.stop()
            if !calibrationInput.isEmpty {
                print("CALIBRATION_ERROR ignored unterminated final input line.")
                calibrationInput.removeAll(keepingCapacity: true)
            }
            requestShutdown(code: 0, message: "Calibration input closed; disconnecting.")
            return
        }

        for byte in data {
            if discardingOversizedCalibrationLine {
                if byte == 10 { discardingOversizedCalibrationLine = false }
                continue
            }
            if byte == 10 {
                let line = calibrationInput
                calibrationInput.removeAll(keepingCapacity: true)
                handleCalibrationLine(line, peripheral: peripheral, characteristic: characteristic)
                if finished || shutdownRequested { return }
            } else if calibrationInput.count >= 4096 {
                calibrationInput.removeAll(keepingCapacity: true)
                discardingOversizedCalibrationLine = true
                print("CALIBRATION_ERROR input line exceeds 4096 bytes; skipped.")
            } else {
                calibrationInput.append(byte)
            }
        }
    }

    private func handleCalibrationLine(
        _ line: [UInt8],
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard case .calibrate = options.mode else { return }
        if writePending {
            print("CALIBRATION_ERROR a write is awaiting acknowledgement; command ignored.")
            return
        }
        do {
            switch try parseCalibrationLine(line) {
            case .quit:
                calibrationInputReader?.stop()
                requestShutdown(code: 0, message: "Calibration stopped by command.")
            case .write(let payload):
                writePending = true
                print("CALIBRATION_WRITE_SENT bytes=\(payload.count)")
                peripheral.writeValue(payload, for: characteristic, type: .withResponse)
            }
        } catch {
            print("CALIBRATION_ERROR \(error.localizedDescription)")
        }
    }

    private func requestShutdown(code: Int32, message: String) {
        guard !finished else { return }
        if shutdownRequested, exitStatus == 0, code != 0 { exitStatus = code }
        if !shutdownRequested {
            exitStatus = code
            print(message)
            shutdownRequested = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            syncTimer?.invalidate()
            syncTimer = nil
            shutdownFallback = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                if self.writePending {
                    self.exitStatus = 2
                    print("Write acknowledgement timed out during shutdown.")
                }
                self.sampleTask?.cancel()
                self.writePending = false
                self.completeShutdown()
            }
            if let shutdownFallback {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: shutdownFallback)
            }
        }
        if !writePending && !sampling { beginDisconnect() }
    }

    private func beginDisconnect() {
        guard !finished else { return }
        syncTimer?.invalidate()
        syncTimer = nil
        central.stopScan()
        guard let peripheral, peripheral.state == .connected || peripheral.state == .connecting else {
            completeShutdown()
            return
        }
        central.cancelPeripheralConnection(peripheral)
        // CoreBluetooth normally calls didDisconnect; bound shutdown if it does not.
        if shutdownFallback == nil {
            shutdownFallback = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.completeShutdown()
            }
            if let shutdownFallback {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: shutdownFallback)
            }
        }
    }

    private func completeShutdown() {
        guard !finished else { return }
        if case .sync = options.mode, exitStatus == 0, acknowledgedSyncWrites == 0 {
            exitStatus = 2
            print("Sync ended without an acknowledged screen write.")
        }
        shutdownFallback?.cancel()
        shutdownFallback = nil
        sampleTask?.cancel()
        calibrationInputReader?.stop()
        calibrationInputReader = nil
        finished = true
        signalSource?.cancel()
        central.stopScan()
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func finish(code: Int32, message: String) {
        requestShutdown(code: code, message: message)
    }

}

private enum SelfTests {
    static func run() throws {
        guard isZeroUUID("0000"),
              isZeroUUID("00000000-0000-1000-8000-00805F9B34FB"),
              !isZeroUUID("1800") else { throw CLIError.usage("UUID normalization self-test failed.") }
        let requestedDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        guard isExactExplicitTarget(identifier: requestedDevice, name: targetName, requested: requestedDevice),
              !isExactExplicitTarget(identifier: otherDevice, name: targetName, requested: requestedDevice),
              !isExactExplicitTarget(identifier: requestedDevice, name: "ado light stick", requested: requestedDevice),
              isProbeAdvertisementMatch(advertisedName: "ado light stick", peripheralName: targetName),
              !isProbeAdvertisementMatch(advertisedName: targetName, peripheralName: "ado light stick") else {
            throw CLIError.usage("Peripheral identity self-test failed.")
        }
        guard requiresScreenCapturePermission(for: .sync),
              !requiresScreenCapturePermission(for: .probe),
              !requiresScreenCapturePermission(for: .rgb(ScreenRGB(red: 1, green: 2, blue: 3))),
              !requiresScreenCapturePermission(for: .replay(Data())),
              !requiresScreenCapturePermission(for: .calibrate) else {
            throw CLIError.usage("Screen permission mode routing self-test failed.")
        }

        var permissionCalls: [String] = []
        let alreadyGranted = ScreenCapturePermission.ensureAccess(
            preflight: { permissionCalls.append("preflight"); return true },
            request: { permissionCalls.append("request"); return false }
        )
        guard alreadyGranted, permissionCalls == ["preflight"] else {
            throw CLIError.usage("Granted screen permission must not trigger a request.")
        }
        permissionCalls.removeAll()
        var grantIsUsable = false
        let grantedByRequest = ScreenCapturePermission.ensureAccess(
            preflight: { permissionCalls.append("preflight"); return grantIsUsable },
            request: { permissionCalls.append("request"); grantIsUsable = true; return true }
        )
        guard grantedByRequest, permissionCalls == ["preflight", "request", "preflight"] else {
            throw CLIError.usage("Denied preflight must request access exactly once.")
        }
        permissionCalls.removeAll()
        let restartRequired = ScreenCapturePermission.ensureAccess(
            preflight: { permissionCalls.append("preflight"); return false },
            request: { permissionCalls.append("request"); return true }
        )
        guard !restartRequired, permissionCalls == ["preflight", "request", "preflight"] else {
            throw CLIError.usage("A first grant requiring restart must not start BLE.")
        }
        permissionCalls.removeAll()
        let deniedByRequest = ScreenCapturePermission.ensureAccess(
            preflight: { permissionCalls.append("preflight"); return false },
            request: { permissionCalls.append("request"); return false }
        )
        guard !deniedByRequest, permissionCalls == ["preflight", "request"] else {
            throw CLIError.usage("Denied screen permission decision self-test failed.")
        }

        let vectors: [(ScreenRGB, String)] = [
            (ScreenRGB(red: 255, green: 0, blue: 0), "3644466a660f0d623318df1966e5dc63"),
            (ScreenRGB(red: 0, green: 255, blue: 0), "205cd7598c7fc8712ae2d380d6eee13f"),
            (ScreenRGB(red: 0, green: 0, blue: 255), "847f6d09abe341f384b8de8736b40833"),
            (ScreenRGB(red: 0, green: 0, blue: 0), "ed3823c3d92e1b9d69000194db6c5244"),
            (ScreenRGB(red: 255, green: 255, blue: 255), "5c55abaf41e5fcf2b04b1e9d713967bc"),
        ]
        for (color, expectedHex) in vectors {
            guard try PenlightProtocol.encode(rgb: color) == Data(hex: expectedHex) else {
                throw CLIError.usage("RGB protocol vector failed for \(color).")
            }
        }
        guard try Data(validatedHex: String(repeating: "aB", count: 16)).count == 16,
              try parseRGBHex("aB12fF") == ScreenRGB(red: 0xAB, green: 0x12, blue: 0xFF),
              !SyncOperationWatchdog.expired(active: false, startedAt: 0, now: 20),
              !SyncOperationWatchdog.expired(active: true, startedAt: nil, now: 20),
              !SyncOperationWatchdog.expired(active: true, startedAt: 10, now: 17.999),
              SyncOperationWatchdog.expired(active: true, startedAt: 10, now: 18),
              !SyncOperationWatchdog.expired(active: true, startedAt: 19, now: 18),
              syncDurationExitStatus(acknowledgedWrites: 0) == 2,
              syncDurationExitStatus(acknowledgedWrites: 1) == 0 else {
            throw CLIError.usage("Protocol or sync status self-test failed.")
        }
        do {
            _ = try Data(validatedHex: "12")
            throw CLIError.usage("Invalid payload unexpectedly passed validation.")
        } catch CLIError.invalidPayload {
            // Expected.
        }
        var rejectedBadRGB = false
        do {
            _ = try parseRGBHex("00XX00")
        } catch CLIError.invalidPayload {
            rejectedBadRGB = true
        }
        guard rejectedBadRGB else { throw CLIError.usage("Malformed RGB unexpectedly passed validation.") }
        var rejectedMissingDevice = false
        do {
            _ = try Options.parse(["--replay", String(repeating: "00", count: 16)])
        } catch CLIError.usage {
            rejectedMissingDevice = true
        }
        guard rejectedMissingDevice else {
            throw CLIError.usage("Replay without an explicit device unexpectedly passed validation.")
        }
        guard try Options.parse(["--probe"])?.device == nil else {
            throw CLIError.usage("CLI parsing self-test failed.")
        }
        guard let parsedOptions = try Options.parse(["--rgb", "FF0080", "--device", requestedDevice.uuidString]),
              case .rgb(let parsedRGB) = parsedOptions.mode,
              parsedRGB == ScreenRGB(red: 255, green: 0, blue: 128) else {
            throw CLIError.usage("RGB CLI parsing self-test failed.")
        }
        let observedHex = String(repeating: "aB", count: 16)
        guard case .write(let observedPayload) = try parseCalibrationLine(Array(observedHex.utf8)),
              observedPayload.count == 16,
              case .quit = try parseCalibrationLine(Array("quit\r".utf8)) else {
            throw CLIError.usage("Calibration input parsing self-test failed.")
        }
        var rejectedBadCalibrationLine = false
        do {
            _ = try parseCalibrationLine(Array("00 11".utf8))
        } catch CLIError.invalidPayload {
            rejectedBadCalibrationLine = true
        }
        guard rejectedBadCalibrationLine else {
            throw CLIError.usage("Malformed calibration line unexpectedly passed validation.")
        }
        print("PenlightSync self-tests passed")
    }
}

@main
private struct PenlightSync {
    static func main() {
        setbuf(stdout, nil)
        do {
            if CommandLine.arguments.dropFirst().first == "--self-test" {
                guard CommandLine.arguments.count == 2 else { throw CLIError.usage(Options.usage) }
                try SelfTests.run()
                return
            }
            if CommandLine.arguments.dropFirst().first == "--stdin-self-test" {
                guard CommandLine.arguments.count == 2 else { throw CLIError.usage(Options.usage) }
                let stdinTest = CalibrationInputReaderSelfTest()
                let status = stdinTest.run()
                if status != 0 { Darwin.exit(status) }
                return
            }
            guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
                try SelfTests.run()
                return
            }
            if requiresScreenCapturePermission(for: options.mode),
               !ScreenColorSampler.requestPermissionIfNeeded() {
                throw ScreenColorError.screenCapturePermissionDenied
            }
            let session = BLESession(options: options)
            let status = session.run()
            if status != 0 { Darwin.exit(status) }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(2)
        }
    }
}
