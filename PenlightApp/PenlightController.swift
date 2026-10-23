import CoreBluetooth
import CoreGraphics
import Foundation

private let targetName = "Ado Light Stick"
private let controlUUID = CBUUID(string: "0000")
private let selectedLampKey = "selectedLampID"
private let fadeTimeKey = "fadeTime"
private let breathingKey = "breathing"

struct DiscoveredLamp: Identifiable, Equatable {
    let id: UUID
    var rssi: Int?
    var remembered: Bool
}

/// GUI counterpart of the CLI's BLESession: same target checks, write-with-response and watchdogs,
/// but long-lived, driven by buttons, and rendering a smoothed color stream through LightEngine.
final class PenlightController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Phase: Equatable {
        case idle
        case connecting
        case syncing
        case stopping
    }

    static let sampleInterval: TimeInterval = 0.2
    /// Output frame rate; each frame writes only if the color changed and the previous write was acknowledged.
    static let renderInterval: TimeInterval = 0.05
    static let operationTimeout: TimeInterval = 8
    static let connectTimeout: TimeInterval = 15
    static let scanDuration: TimeInterval = 10

    @Published private(set) var bluetoothReady = false
    @Published private(set) var isScanning = false
    @Published private(set) var lamps: [DiscoveredLamp] = []
    @Published var selectedLampID: UUID? {
        didSet { UserDefaults.standard.set(selectedLampID?.uuidString, forKey: selectedLampKey) }
    }
    @Published var fadeTime: TimeInterval {
        didSet {
            engine.fadeTime = fadeTime
            UserDefaults.standard.set(fadeTime, forKey: fadeTimeKey)
        }
    }
    @Published var breathing: Bool {
        didSet {
            engine.breathing = breathing
            UserDefaults.standard.set(breathing, forKey: breathingKey)
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var screenColor: ScreenRGB?
    @Published private(set) var lampColor: ScreenRGB?
    @Published private(set) var status = "正在啟動藍牙…若系統詢問藍牙權限，請按「允許」。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var logLines: [String] = []

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var scanStopWork: DispatchWorkItem?
    private var connectTimeoutWork: DispatchWorkItem?
    private var sampleTimer: Timer?
    private var renderTimer: Timer?
    private var engine: LightEngine
    private var lastRenderAt: TimeInterval?
    private var sampleTask: Task<Void, Never>?
    private var sampleStartedAt: TimeInterval?
    private var writeStartedAt: TimeInterval?
    private var pendingRGB: ScreenRGB?
    private var stopReason: String?

    override init() {
        let defaults = UserDefaults.standard
        let savedFade = defaults.object(forKey: fadeTimeKey) as? Double ?? 0.6
        let savedBreathing = defaults.bool(forKey: breathingKey)
        fadeTime = savedFade
        breathing = savedBreathing
        engine = LightEngine(fadeTime: savedFade, breathing: savedBreathing)
        super.init()
        if let saved = UserDefaults.standard.string(forKey: selectedLampKey) {
            selectedLampID = UUID(uuidString: saved)
        }
        needsScreenPermission = !CGPreflightScreenCaptureAccess()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var canStart: Bool {
        bluetoothReady && phase == .idle && selectedLampID != nil
    }

    // MARK: - Actions

    func startScan() {
        guard bluetoothReady, phase == .idle else { return }
        errorMessage = nil
        lamps.removeAll { !$0.remembered && $0.id != selectedLampID }
        for index in lamps.indices { lamps[index].rssi = nil }
        isScanning = true
        status = "掃描中：請讓手燈進入配對模式（長按背面按鈕至藍燈閃爍）。"
        log("開始掃描 \(targetName)。")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopScan(finished: true) }
        scanStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanDuration, execute: work)
    }

    func stopScan(finished: Bool = false) {
        scanStopWork?.cancel()
        scanStopWork = nil
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        if finished, phase == .idle {
            let found = lamps.filter { $0.rssi != nil }.count
            status = found == 0 ? "沒有找到手燈。確認手燈在配對模式，且手機 App 已關閉。" : "找到 \(found) 支手燈，選擇後按「開始連動」。"
        }
    }

    func start() {
        guard canStart, let id = selectedLampID else { return }
        errorMessage = nil
        stopScan()
        if !ScreenColorSampler.requestPermissionIfNeeded() {
            needsScreenPermission = true
            fail("需要螢幕錄製權限。請在「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許本 App，然後結束並重新開啟本 App。")
            return
        }
        needsScreenPermission = false
        guard let target = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            fail("找不到選擇的手燈。請先按「掃描手燈」。")
            return
        }
        guard target.name == targetName else {
            fail("選擇的裝置名稱不是 \(targetName)，已拒絕連線。請重新掃描。")
            return
        }
        peripherals[id] = target
        peripheral = target
        stopReason = nil
        screenColor = nil
        lampColor = nil
        engine = LightEngine(fadeTime: fadeTime, breathing: breathing)
        lastRenderAt = nil
        phase = .connecting
        status = "連線中…"
        log("連線 \(targetName)（\(id.uuidString)）。")
        target.delegate = self
        central.connect(target, options: nil)
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting else { return }
            self.fail("連線逾時。請讓手燈重新進入配對模式後再試。")
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    func stop() {
        guard phase == .connecting || phase == .syncing else { return }
        shutDown(reason: nil)
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            status = "藍牙就緒。按「掃描手燈」尋找手燈。"
            restoreRememberedLamp()
        case .unauthorized:
            status = "未允許藍牙權限。請在「系統設定 › 隱私權與安全性 › 藍牙」允許本 App。"
        case .poweredOff:
            status = "藍牙已關閉，請開啟藍牙。"
        case .unsupported:
            status = "這台電腦不支援低功耗藍牙。"
        default:
            status = "正在啟動藍牙…若系統詢問藍牙權限，請按「允許」。"
        }
        if !bluetoothReady {
            isScanning = false
            if phase != .idle { shutDown(reason: "藍牙已無法使用，連動已停止。") }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard peripheral.name == targetName,
              advertised.map({ $0.caseInsensitiveCompare(targetName) == .orderedSame }) ?? true else { return }
        peripherals[peripheral.identifier] = peripheral
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        if let index = lamps.firstIndex(where: { $0.id == peripheral.identifier }) {
            lamps[index].rssi = rssi ?? lamps[index].rssi
        } else {
            lamps.append(DiscoveredLamp(id: peripheral.identifier, rssi: rssi, remembered: false))
            log("找到手燈 \(peripheral.identifier.uuidString)。")
        }
        if selectedLampID == nil || !lamps.contains(where: { $0.id == selectedLampID }) {
            selectedLampID = peripheral.identifier
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard phase == .connecting, peripheral === self.peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard peripheral.identifier == selectedLampID, peripheral.name == targetName else {
            fail("連上的裝置與選擇的手燈不符，已中斷。")
            return
        }
        status = "已連線，尋找控制服務…"
        log("已連線，探索服務 0000。")
        peripheral.discoverServices([controlUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        fail("無法連線：\(error?.localizedDescription ?? "未知錯誤")。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if phase == .stopping {
            finishStop()
        } else if phase != .idle {
            let detail = error.map { "（\($0.localizedDescription)）" } ?? ""
            shutDown(reason: "手燈連線中斷\(detail)。請讓手燈重新進入配對模式後再按「開始連動」。")
        }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .connecting else { return }
        if let error { fail("服務探索失敗：\(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == controlUUID }) else {
            fail("手燈沒有控制服務 0000。")
            return
        }
        peripheral.discoverCharacteristics([controlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard phase == .connecting else { return }
        if let error { fail("特徵探索失敗：\(error.localizedDescription)"); return }
        guard let found = service.characteristics?.first(where: { $0.uuid == controlUUID }),
              found.properties.contains(.write) else {
            fail("手燈的控制特徵 0000 不支援有回應寫入。")
            return
        }
        connectTimeoutWork?.cancel()
        characteristic = found
        phase = .syncing
        status = "連動中：跟隨主螢幕平均色。"
        log("連動開始。")
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        renderTimer = Timer.scheduledTimer(withTimeInterval: Self.renderInterval, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard writeStartedAt != nil else { return }
        writeStartedAt = nil
        let color = pendingRGB
        pendingRGB = nil
        if let error {
            if phase == .syncing { shutDown(reason: "藍牙寫入失敗：\(error.localizedDescription)") }
            return
        }
        if let color { lampColor = color }
        if phase == .stopping, sampleStartedAt == nil { beginDisconnect() }
    }

    // MARK: - Sync loop

    private func tick() {
        guard phase == .syncing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let started = sampleStartedAt, now - started >= Self.operationTimeout {
            shutDown(reason: "螢幕取樣超過 8 秒沒有完成，已停止連動。請確認螢幕錄製權限後再試。")
            return
        }
        if let started = writeStartedAt, now - started >= Self.operationTimeout {
            shutDown(reason: "藍牙寫入超過 8 秒沒有回應，已停止連動。請確認手燈仍在附近。")
            return
        }
        guard sampleStartedAt == nil else { return }
        sampleStartedAt = now
        sampleTask = Task { @MainActor [weak self] in
            do {
                let color = try await ScreenColorSampler().sample()
                self?.sampled(color)
            } catch {
                self?.sampleFailed(error)
            }
        }
    }

    private func sampled(_ color: ScreenRGB) {
        sampleStartedAt = nil
        sampleTask = nil
        guard phase == .syncing else {
            if phase == .stopping, writeStartedAt == nil { beginDisconnect() }
            return
        }
        screenColor = color
        engine.setTarget(color)
    }

    /// Advances the fade/breath effect and writes the frame when it differs from the lamp's acknowledged color.
    private func render() {
        guard phase == .syncing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastRenderAt.map { now - $0 } ?? 0
        lastRenderAt = now
        guard let frame = engine.step(dt: dt),
              writeStartedAt == nil,
              frame != lampColor,
              let peripheral,
              let characteristic else { return }
        do {
            let payload = try PenlightProtocol.encode(rgb: frame)
            writeStartedAt = now
            pendingRGB = frame
            peripheral.writeValue(payload, for: characteristic, type: .withResponse)
        } catch {
            shutDown(reason: "無法編碼顏色指令：\(error.localizedDescription)")
        }
    }

    private func sampleFailed(_ error: Error) {
        sampleStartedAt = nil
        sampleTask = nil
        if phase == .stopping {
            if writeStartedAt == nil { beginDisconnect() }
            return
        }
        guard phase == .syncing else { return }
        if case ScreenColorError.screenCapturePermissionDenied = error { needsScreenPermission = true }
        shutDown(reason: "螢幕取樣失敗：\(error.localizedDescription)")
    }

    // MARK: - Shutdown

    private func fail(_ message: String) {
        if phase == .idle {
            errorMessage = message
            status = "未連動。"
            log("錯誤：\(message)")
        } else {
            shutDown(reason: message)
        }
    }

    /// `reason == nil` means the user pressed Stop.
    private func shutDown(reason: String?) {
        guard phase != .idle, phase != .stopping else { return }
        stopReason = reason
        phase = .stopping
        status = "停止中…"
        sampleTimer?.invalidate()
        sampleTimer = nil
        renderTimer?.invalidate()
        renderTimer = nil
        connectTimeoutWork?.cancel()
        if writeStartedAt == nil, sampleStartedAt == nil {
            beginDisconnect()
        }
        // Bound the wait for an outstanding sample, write acknowledgement or disconnect callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .stopping else { return }
            self.sampleTask?.cancel()
            self.beginDisconnect()
            self.finishStop()
        }
    }

    private func beginDisconnect() {
        guard phase == .stopping else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        } else {
            finishStop()
        }
    }

    private func finishStop() {
        guard phase == .stopping else { return }
        phase = .idle
        characteristic = nil
        sampleStartedAt = nil
        writeStartedAt = nil
        pendingRGB = nil
        if let reason = stopReason {
            errorMessage = reason
            status = "連動已因錯誤停止。"
            log("錯誤：\(reason)")
        } else {
            status = "已停止連動。"
            log("使用者停止連動。")
        }
    }

    // MARK: - Helpers

    private func restoreRememberedLamp() {
        guard let id = selectedLampID, !lamps.contains(where: { $0.id == id }),
              let known = central.retrievePeripherals(withIdentifiers: [id]).first,
              known.name == targetName else { return }
        peripherals[id] = known
        lamps.append(DiscoveredLamp(id: id, rssi: nil, remembered: true))
    }

    private func log(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date())) \(line)")
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
