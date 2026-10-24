import CoreBluetooth
import CoreGraphics
import Foundation

private let targetName = "Ado Light Stick"
private let controlUUID = CBUUID(string: "0000")
private let selectedLampKey = "selectedLampID"
private let fadeTimeKey = "fadeTime"
private let breathingKey = "breathing"
private let vibranceKey = "vibrance"
private let minBrightnessKey = "minBrightness"
private let warmthKey = "warmth"
private let brightnessKey = "brightness"
private let sceneCutsKey = "sceneCuts"
private let beatSyncKey = "beatSync"
private let beatStyleKey = "beatStyle"
private let captureRegionKey = "captureRegion"
private let lowLatencyKey = "lowLatency"

struct DiscoveredLamp: Identifiable, Equatable {
    let id: UUID
    var rssi: Int?
    var remembered: Bool
}

/// GUI counterpart of the CLI's BLESession: same target checks, write-with-response and watchdogs,
/// but long-lived, driven by buttons, rendering a smoothed color stream through LightEngine,
/// and reconnecting on its own (for up to `reconnectWindow`) when the lamp drops the link.
final class PenlightController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Phase: Equatable {
        case idle
        case connecting
        case syncing
        /// The link dropped while syncing; a pending connect is waiting for the lamp to come back.
        case reconnecting
        case stopping
    }

    /// How often the write watchdog and the latency readout run; screen colors arrive continuously from `ScreenStream`.
    static let watchdogInterval: TimeInterval = 0.2
    /// Output frame rate; each frame writes only if the color changed and the previous write was acknowledged.
    /// A frame is also rendered right after each new screen color and each write acknowledgement.
    static let renderInterval: TimeInterval = 1.0 / 60
    static let latencyReportInterval: TimeInterval = 5
    /// Fade time used while low-latency mode is on (unless the slider is already shorter).
    static let lowLatencyFade: TimeInterval = 0.15
    static let operationTimeout: TimeInterval = 8
    static let connectTimeout: TimeInterval = 15
    static let scanDuration: TimeInterval = 10
    static let reconnectWindow: TimeInterval = 30

    @Published private(set) var bluetoothReady = false
    @Published private(set) var isScanning = false
    @Published private(set) var lamps: [DiscoveredLamp] = []
    @Published var selectedLampID: UUID? {
        didSet { UserDefaults.standard.set(selectedLampID?.uuidString, forKey: selectedLampKey) }
    }
    @Published var fadeTime: TimeInterval {
        didSet {
            engine.fadeTime = effectiveFadeTime
            UserDefaults.standard.set(fadeTime, forKey: fadeTimeKey)
        }
    }
    /// Caps the fade at `lowLatencyFade` so the lamp follows the screen as closely as possible.
    @Published var lowLatency: Bool {
        didSet {
            engine.fadeTime = effectiveFadeTime
            UserDefaults.standard.set(lowLatency, forKey: lowLatencyKey)
        }
    }
    @Published var breathing: Bool {
        didSet {
            engine.breathing = breathing
            UserDefaults.standard.set(breathing, forKey: breathingKey)
        }
    }
    @Published var vibrance: Double {
        didSet {
            engine.vibrance = vibrance
            UserDefaults.standard.set(vibrance, forKey: vibranceKey)
            regrade()
        }
    }
    @Published var minBrightness: Double {
        didSet {
            engine.minBrightness = minBrightness
            UserDefaults.standard.set(minBrightness, forKey: minBrightnessKey)
            regrade()
        }
    }
    /// -1 (cool) … 1 (warm); the UI offers ±0.5.
    @Published var warmth: Double {
        didSet {
            engine.warmth = warmth
            UserDefaults.standard.set(warmth, forKey: warmthKey)
            regrade()
        }
    }
    /// Overall lamp level (0.1–1).
    @Published var brightness: Double {
        didSet {
            engine.brightness = brightness
            UserDefaults.standard.set(brightness, forKey: brightnessKey)
            regrade()
        }
    }
    @Published var sceneCuts: Bool {
        didSet {
            engine.sceneCuts = sceneCuts
            UserDefaults.standard.set(sceneCuts, forKey: sceneCutsKey)
        }
    }
    @Published var beatSync: Bool {
        didSet {
            engine.beatSync = beatSync
            UserDefaults.standard.set(beatSync, forKey: beatSyncKey)
            guard phase == .syncing || phase == .reconnecting else { return }
            beatSync ? startAudio() : stopAudio()
        }
    }
    @Published var beatStyle: BeatStyle {
        didSet {
            engine.beatStyle = beatStyle
            UserDefaults.standard.set(beatStyle.rawValue, forKey: beatStyleKey)
        }
    }
    /// Area of the main display to sample (normalized 0–1, top-left origin); nil samples the whole display.
    /// Applies from the next sample, also while syncing.
    @Published var captureRegion: CGRect? {
        didSet {
            let stored = captureRegion.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
            UserDefaults.standard.set(stored, forKey: captureRegionKey)
            screenStream?.update(region: captureRegion)
            if phase == .syncing { status = syncingStatus }
        }
    }
    /// True while beat sync hears music and is shaping the light.
    @Published private(set) var musicDetected = false
    /// The music's tempo (rounded BPM) while beat sync is shaping the light.
    @Published private(set) var bpm: Int?
    /// The style shaping the light right now (what auto picked) while beat sync is shaping the light.
    @Published private(set) var activeBeatStyle: BeatStyle?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var screenColor: ScreenRGB?
    @Published private(set) var lampColor: ScreenRGB?
    @Published private(set) var status = "正在啟動藍牙…若系統詢問藍牙權限，請按「允許」。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var logLines: [String] = []
    /// Recent average capture and Bluetooth round-trip times while syncing.
    @Published private(set) var latencySummary: String?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var scanStopWork: DispatchWorkItem?
    private var connectTimeoutWork: DispatchWorkItem?
    private var reconnectDeadlineWork: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private var renderTimer: Timer?
    private var screenStream: ScreenStream?
    private var engine: LightEngine
    private var lastRenderAt: TimeInterval?
    private var writeStartedAt: TimeInterval?
    private var captureLatency = LatencyMeter()
    private var bluetoothLatency = LatencyMeter()
    private var lastLatencyReport: TimeInterval = 0
    private var latencyReports = 0
    private var pendingRGB: ScreenRGB?
    private var stopReason: String?
    private var audioMonitor: SystemAudioMonitor?

    override init() {
        let defaults = UserDefaults.standard
        let savedFade = defaults.object(forKey: fadeTimeKey) as? Double ?? 0.6
        fadeTime = savedFade
        breathing = defaults.bool(forKey: breathingKey)
        vibrance = defaults.object(forKey: vibranceKey) as? Double ?? 0.4
        minBrightness = defaults.object(forKey: minBrightnessKey) as? Double ?? 0
        warmth = defaults.object(forKey: warmthKey) as? Double ?? 0
        brightness = defaults.object(forKey: brightnessKey) as? Double ?? 1
        sceneCuts = defaults.object(forKey: sceneCutsKey) as? Bool ?? true
        beatSync = defaults.bool(forKey: beatSyncKey)
        beatStyle = defaults.string(forKey: beatStyleKey).flatMap(BeatStyle.init(rawValue:)) ?? .flash
        lowLatency = defaults.bool(forKey: lowLatencyKey)
        if let stored = defaults.array(forKey: captureRegionKey) as? [Double], stored.count == 4 {
            captureRegion = CGRect(x: stored[0], y: stored[1], width: stored[2], height: stored[3])
        }
        engine = LightEngine(fadeTime: savedFade, breathing: false)
        super.init()
        engine = makeEngine()
        if let saved = UserDefaults.standard.string(forKey: selectedLampKey) {
            selectedLampID = UUID(uuidString: saved)
        }
        needsScreenPermission = !CGPreflightScreenCaptureAccess()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var canStart: Bool {
        bluetoothReady && phase == .idle && selectedLampID != nil
    }

    /// The preset whose color settings match the current ones, if any.
    var activePreset: ColorPreset? {
        ColorPreset.all.first {
            abs($0.vibrance - vibrance) < 0.001 && abs($0.minBrightness - minBrightness) < 0.001
                && abs($0.brightness - brightness) < 0.001 && abs($0.warmth - warmth) < 0.001
        }
    }

    func apply(_ preset: ColorPreset) {
        vibrance = preset.vibrance
        minBrightness = preset.minBrightness
        brightness = preset.brightness
        warmth = preset.warmth
    }

    /// Puts every light effect back to its default; the lamp choice and capture area stay.
    func resetEffects() {
        apply(.standard)
        fadeTime = 0.6
        lowLatency = false
        sceneCuts = true
        breathing = false
        beatSync = false
        beatStyle = .flash
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
            fail("找不到選擇的手燈。請先按「掃描」。")
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
        engine = makeEngine()
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
        guard phase == .connecting || phase == .syncing || phase == .reconnecting else { return }
        shutDown(reason: nil)
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            status = "藍牙就緒。按「掃描」尋找手燈。"
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
        guard phase == .connecting || phase == .reconnecting, peripheral === self.peripheral else {
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
        if phase == .reconnecting {
            retryConnect()
            return
        }
        fail("無法連線：\(error?.localizedDescription ?? "未知錯誤")。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        switch phase {
        case .stopping:
            finishStop()
        case .syncing:
            let detail = error.map { "（\($0.localizedDescription)）" } ?? ""
            reconnect(because: "手燈連線中斷\(detail)")
        case .reconnecting:
            retryConnect()
        case .connecting:
            shutDown(reason: "手燈連線中斷。請讓手燈重新進入配對模式後再按「開始連動」。")
        case .idle:
            break
        }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .connecting || phase == .reconnecting else { return }
        if let error { fail("服務探索失敗：\(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == controlUUID }) else {
            fail("手燈沒有控制服務 0000。")
            return
        }
        peripheral.discoverCharacteristics([controlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard phase == .connecting || phase == .reconnecting else { return }
        if let error { fail("特徵探索失敗：\(error.localizedDescription)"); return }
        guard let found = service.characteristics?.first(where: { $0.uuid == controlUUID }),
              found.properties.contains(.write) else {
            fail("手燈的控制特徵 0000 不支援有回應寫入。")
            return
        }
        connectTimeoutWork?.cancel()
        characteristic = found
        let reconnected = phase == .reconnecting
        reconnectDeadlineWork?.cancel()
        reconnectDeadlineWork = nil
        phase = .syncing
        status = syncingStatus
        if reconnected {
            log("已自動重新連線，繼續連動。")
            return // Timers and audio kept running while the link was down.
        }
        log("連動開始。")
        captureLatency = LatencyMeter()
        bluetoothLatency = LatencyMeter()
        lastLatencyReport = ProcessInfo.processInfo.systemUptime
        latencyReports = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            self?.watchdog()
        }
        renderTimer = Timer.scheduledTimer(withTimeInterval: Self.renderInterval, repeats: true) { [weak self] _ in
            self?.render()
        }
        startScreenStream()
        if beatSync { startAudio() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let started = writeStartedAt else { return }
        writeStartedAt = nil
        let color = pendingRGB
        pendingRGB = nil
        if let error {
            if phase == .syncing { reconnect(because: "藍牙寫入失敗（\(error.localizedDescription)）") }
            return
        }
        bluetoothLatency.add((ProcessInfo.processInfo.systemUptime - started) * 1000)
        if let color { lampColor = color }
        if phase == .stopping {
            beginDisconnect()
        } else {
            render() // Send the next frame without waiting for the render timer.
        }
    }

    // MARK: - Sync loop

    private func watchdog() {
        guard phase == .syncing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let started = writeStartedAt, now - started >= Self.operationTimeout {
            reconnect(because: "藍牙寫入超過 8 秒沒有回應")
            return
        }
        if now - lastLatencyReport >= Self.latencyReportInterval {
            lastLatencyReport = now
            reportLatency()
        }
    }

    private func startScreenStream() {
        let stream = ScreenStream(
            onColor: { [weak self] color, latency in self?.screenSampled(color, latency: latency) },
            onFailure: { [weak self] error in self?.screenStreamFailed(error) }
        )
        screenStream = stream
        let region = captureRegion
        Task { @MainActor [weak self] in
            do {
                try await stream.start(region: region)
                guard let self, self.screenStream === stream else {
                    stream.stop() // Stopped or replaced while starting.
                    return
                }
                if self.captureRegion != region { stream.update(region: self.captureRegion) }
            } catch {
                guard let self, self.screenStream === stream else { return }
                self.screenStreamFailed(error)
            }
        }
    }

    private func screenSampled(_ color: ScreenRGB, latency: Double) {
        guard phase == .syncing || phase == .reconnecting else { return }
        captureLatency.add(latency)
        if color != screenColor { screenColor = color }
        engine.setTarget(color)
        render() // React to the new color right away instead of waiting for the render timer.
    }

    private func screenStreamFailed(_ error: Error) {
        screenStream = nil
        guard phase == .syncing || phase == .reconnecting else { return }
        if case ScreenColorError.screenCapturePermissionDenied = error { needsScreenPermission = true }
        shutDown(reason: "螢幕擷取失敗：\(error.localizedDescription)")
    }

    /// Advances the effects and writes the frame when it differs from the lamp's acknowledged color.
    private func render() {
        guard phase == .syncing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastRenderAt.map { now - $0 } ?? 0
        lastRenderAt = now
        let frame = engine.step(dt: dt)
        if engine.musicDetected != musicDetected { musicDetected = engine.musicDetected }
        let roundedBPM = engine.bpm.map { Int($0.rounded()) }
        if roundedBPM != bpm { bpm = roundedBPM }
        if engine.activeBeatStyle != activeBeatStyle { activeBeatStyle = engine.activeBeatStyle }
        guard let frame,
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

    /// Shows recent averages in the window and writes them to the log about every 30 seconds.
    private func reportLatency() {
        let capture = captureLatency.drain()
        let bluetooth = bluetoothLatency.drain()
        guard capture != nil || bluetooth != nil else { return }
        func describe(_ stats: LatencyMeter.Summary?) -> String {
            stats.map { String(format: "%.0f ms（最高 %.0f）", $0.average, $0.maximum) } ?? "—"
        }
        let summary = "延遲（近 \(Int(Self.latencyReportInterval)) 秒平均）：畫面擷取 \(describe(capture))・藍牙來回 \(describe(bluetooth))"
        latencySummary = summary
        latencyReports += 1
        if latencyReports % 6 == 1 { log(summary) }
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
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        renderTimer?.invalidate()
        renderTimer = nil
        screenStream?.stop()
        screenStream = nil
        stopAudio()
        connectTimeoutWork?.cancel()
        reconnectDeadlineWork?.cancel()
        reconnectDeadlineWork = nil
        if writeStartedAt == nil {
            beginDisconnect()
        }
        // Bound the wait for an outstanding write acknowledgement or disconnect callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .stopping else { return }
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
        writeStartedAt = nil
        pendingRGB = nil
        lastRenderAt = nil
        latencySummary = nil
        if let reason = stopReason {
            errorMessage = reason
            status = "連動已因錯誤停止。"
            log("錯誤：\(reason)")
        } else {
            status = "已停止連動。"
            log("使用者停止連動。")
        }
    }

    /// Shows the full-screen overlay to drag-select the sampling area; Esc keeps the current one.
    func selectRegion() {
        RegionSelector.select { [weak self] region in
            guard let self, let region else { return }
            self.captureRegion = region
            self.log(String(format: "取色範圍改為框選區域（寬 %.0f%%、高 %.0f%%）。", region.width * 100, region.height * 100))
        }
    }

    func useWholeScreen() {
        guard captureRegion != nil else { return }
        captureRegion = nil
        log("取色範圍改回整個主螢幕。")
    }

    // MARK: - Reconnect

    /// Keeps sampling and effect state, drops the link and waits (up to `reconnectWindow`) for the lamp
    /// to accept a new connection. CoreBluetooth's connect request stays pending until the lamp is reachable.
    private func reconnect(because reason: String) {
        guard phase == .syncing, let peripheral else { return }
        phase = .reconnecting
        characteristic = nil
        writeStartedAt = nil
        pendingRGB = nil
        lampColor = nil // Rewrite the current color as soon as the link is back.
        status = "\(reason)，正在自動重新連線（最多 \(Int(Self.reconnectWindow)) 秒）…若一直連不上，請長按手燈背面按鈕進入配對模式。"
        log("\(reason)，自動重新連線中。")
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .reconnecting else { return }
            self.shutDown(reason: "\(reason)，\(Int(Self.reconnectWindow)) 秒內無法重新連上手燈。請讓手燈重新進入配對模式後再按「開始連動」。")
        }
        reconnectDeadlineWork = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectWindow, execute: deadline)
        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral) // didDisconnect then issues the new connect.
        } else {
            retryConnect()
        }
    }

    private func retryConnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .reconnecting, let peripheral = self.peripheral,
                  peripheral.state == .disconnected else { return }
            self.central.connect(peripheral, options: nil)
        }
    }

    // MARK: - Beat sync audio

    private func startAudio() {
        guard audioMonitor == nil else { return }
        let monitor = SystemAudioMonitor(
            onBeat: { [weak self] strength, bpm in self?.engine.beat(strength: strength, bpm: bpm) },
            onFailure: { [weak self] error in self?.audioFailed(error) }
        )
        audioMonitor = monitor
        Task { @MainActor [weak self] in
            do {
                try await monitor.start()
                guard let self, self.audioMonitor === monitor else {
                    monitor.stop() // Stopped or replaced while starting.
                    return
                }
                self.log("節拍偵測：開始聆聽系統音訊。")
            } catch {
                guard let self, self.audioMonitor === monitor else { return }
                self.audioFailed(error)
            }
        }
    }

    private func stopAudio() {
        audioMonitor?.stop()
        audioMonitor = nil
        musicDetected = false
        bpm = nil
        activeBeatStyle = nil
    }

    /// Beat sync is an extra; losing audio keeps the color sync running and reports why.
    private func audioFailed(_ error: Error) {
        guard audioMonitor != nil else { return }
        audioMonitor = nil
        musicDetected = false
        bpm = nil
        activeBeatStyle = nil
        errorMessage = "無法擷取系統音訊，節拍同步暫停（顏色連動照常）：\(error.localizedDescription)"
        log("節拍偵測失敗：\(error.localizedDescription)")
    }

    // MARK: - Helpers

    private var syncingStatus: String {
        captureRegion == nil ? "連動中：跟隨主螢幕平均色。" : "連動中：跟隨框選範圍的平均色。"
    }

    /// Re-grades the last screen color so color changes show right away, even on a still screen.
    private func regrade() {
        guard phase == .syncing || phase == .reconnecting, let screenColor else { return }
        engine.setTarget(screenColor)
    }

    private var effectiveFadeTime: TimeInterval { lowLatency ? min(fadeTime, Self.lowLatencyFade) : fadeTime }

    private func makeEngine() -> LightEngine {
        var engine = LightEngine(fadeTime: effectiveFadeTime, breathing: breathing)
        engine.vibrance = vibrance
        engine.minBrightness = minBrightness
        engine.warmth = warmth
        engine.brightness = brightness
        engine.sceneCuts = sceneCuts
        engine.beatSync = beatSync
        engine.beatStyle = beatStyle
        return engine
    }

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

/// Collects millisecond measurements between reports.
struct LatencyMeter {
    struct Summary {
        let average: Double
        let maximum: Double
    }

    private var total = 0.0
    private var count = 0
    private var maximum = 0.0

    mutating func add(_ milliseconds: Double) {
        total += milliseconds
        count += 1
        maximum = max(maximum, milliseconds)
    }

    /// Returns the average and maximum since the last call (nil if nothing was measured) and starts over.
    mutating func drain() -> Summary? {
        defer { self = LatencyMeter() }
        return count > 0 ? Summary(average: total / Double(count), maximum: maximum) : nil
    }
}
