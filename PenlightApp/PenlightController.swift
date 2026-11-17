import AppKit
import CoreBluetooth
import CoreGraphics
import Foundation

private let targetName = "Ado Light Stick"
private let controlUUID = CBUUID(string: "0000")

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
        didSet { settings.selectedLampID = selectedLampID }
    }
    @Published var colorSource: ColorSource {
        didSet {
            settings.colorSource = colorSource
            switchColorSource()
        }
    }
    @Published private(set) var siteSongId: String = ""
    @Published private(set) var siteSongTitle: String = ""
    @Published private(set) var sitePlayingState: SitePlayingState = .waiting
    @Published private(set) var portInUse: Bool = false
    @Published var fadeTime: TimeInterval {
        didSet {
            engine.fadeTime = effectiveFadeTime
            settings.fadeTime = fadeTime
        }
    }
    /// Caps the fade at `lowLatencyFade` so the lamp follows the screen as closely as possible.
    @Published var lowLatency: Bool {
        didSet {
            engine.fadeTime = effectiveFadeTime
            settings.lowLatency = lowLatency
        }
    }
    @Published var breathing: Bool {
        didSet {
            engine.breathing = breathing
            settings.breathing = breathing
        }
    }
    @Published var vibrance: Double {
        didSet {
            engine.vibrance = vibrance
            settings.vibrance = vibrance
            regrade()
        }
    }
    @Published var minBrightness: Double {
        didSet {
            engine.minBrightness = minBrightness
            settings.minBrightness = minBrightness
            regrade()
        }
    }
    /// -1 (cool) … 1 (warm); the UI offers ±0.5.
    @Published var warmth: Double {
        didSet {
            engine.warmth = warmth
            settings.warmth = warmth
            regrade()
        }
    }
    /// Overall lamp level (0.1–1).
    @Published var brightness: Double {
        didSet {
            engine.brightness = brightness
            settings.brightness = brightness
            regrade()
        }
    }
    @Published var sceneCuts: Bool {
        didSet {
            engine.sceneCuts = sceneCuts
            settings.sceneCuts = sceneCuts
        }
    }
    @Published var beatSync: Bool {
        didSet {
            engine.beatSync = beatSync
            settings.beatSync = beatSync
            guard phase == .syncing || phase == .reconnecting else { return }
            beatSync ? startAudio() : stopAudio()
        }
    }
    @Published var beatStyle: BeatStyle {
        didSet {
            engine.beatStyle = beatStyle
            settings.beatStyle = beatStyle
        }
    }
    /// Area of the main display to sample (normalized 0–1, top-left origin); nil samples the whole display.
    /// Applies from the next sample, also while syncing.
    @Published var captureRegion: CGRect? {
        didSet {
            settings.captureRegion = captureRegion
            screenStream?.update(region: captureRegion)
            if phase == .syncing { statusText = syncingStatusText }
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
    @Published private(set) var statusText = LText(id: "bt_starting") { L10n.statusBtStarting($0) }
    @Published private(set) var errorText: LText?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var logLines: [String] = []
    /// Recent average capture and Bluetooth round-trip times while syncing.
    @Published private(set) var latencyText: LText?

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
    private var stopReason: LText?
    private var settings = SettingsStore()
    private var audioMonitor: SystemAudioMonitor?
    private var siteLink = SiteLink()
    private var siteEvaluator = SiteLightEvaluator()
    private var siteDirector = SiteStageDirector()

    override init() {
        let savedFade = settings.fadeTime
        let savedSource = settings.colorSource
        let savedBreathing = settings.breathing
        let savedVibrance = settings.vibrance
        let savedMinBrightness = settings.minBrightness
        let savedWarmth = settings.warmth
        let savedBrightness = settings.brightness
        let savedSceneCuts = settings.sceneCuts
        let savedBeatSync = settings.beatSync
        let savedBeatStyle = settings.beatStyle
        let savedLowLatency = settings.lowLatency

        fadeTime = savedFade
        colorSource = savedSource
        breathing = savedBreathing
        vibrance = savedVibrance
        minBrightness = savedMinBrightness
        warmth = savedWarmth
        brightness = savedBrightness
        sceneCuts = savedSceneCuts
        beatSync = savedBeatSync
        beatStyle = savedBeatStyle
        lowLatency = savedLowLatency
        captureRegion = settings.captureRegion
        selectedLampID = settings.selectedLampID

        let effectiveFade = savedLowLatency ? min(savedFade, Self.lowLatencyFade) : savedFade
        var initialEngine = LightEngine(fadeTime: effectiveFade, breathing: savedBreathing)
        initialEngine.vibrance = savedVibrance
        initialEngine.minBrightness = savedMinBrightness
        initialEngine.warmth = savedWarmth
        initialEngine.brightness = savedBrightness
        initialEngine.sceneCuts = savedSceneCuts
        initialEngine.beatSync = savedBeatSync
        initialEngine.beatStyle = savedBeatStyle
        engine = initialEngine
        super.init()
        needsScreenPermission = !CGPreflightScreenCaptureAccess()
        central = CBCentralManager(delegate: self, queue: .main)
        setupSiteLink()
    }

    private func setupSiteLink() {
        siteLink.onStateUpdate = { [weak self] state, receivedAt in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.siteEvaluator.updateState(state, receivedAt: receivedAt)
                self.siteSongId = state.song
                self.siteSongTitle = state.title
                self.sitePlayingState = state.playing ? .playing : .paused
                if self.colorSource == .site, self.phase == .syncing {
                    self.render()
                }
            }
        }
        siteLink.onStop = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.siteEvaluator.reset()
                self.siteDirector.reset()
                self.siteSongId = ""
                self.siteSongTitle = ""
                self.sitePlayingState = .waiting
                if self.colorSource == .site, self.phase == .syncing {
                    self.render()
                }
            }
        }
        if colorSource == .site {
            startSiteLink()
        }
    }

    /// 開啟 Ado 應援預習網站（若正在播放歌曲，直接開啟該歌曲之應援頁面）
    func openAdoGuideSite() {
        let base = "https://gcree.github.io/ado-guide/"
        let urlString = siteSongId.isEmpty ? base : "\(base)#\(siteSongId)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func startSiteLink() {
        siteLink.start()
        portInUse = siteLink.portInUse
        if portInUse {
            if phase == .syncing { statusText = syncingStatusText }
            log { L10n.logPortInUse($0) }
        }
    }

    private func stopSiteLink() {
        siteLink.stop()
        portInUse = false
    }

    private func switchColorSource() {
        let source = colorSource
        log { L10n.logSourceSwitched(source, $0) }
        if colorSource == .site {
            startSiteLink()
            if phase == .syncing {
                screenStream?.stop()
                screenStream = nil
                stopAudio()
                siteLink.setLampStatus(.linked)
                statusText = syncingStatusText
                render()
            }
        } else {
            stopSiteLink()
            if phase == .syncing {
                siteEvaluator.reset()
                siteDirector.reset()
                siteSongTitle = ""
                sitePlayingState = .waiting
                if !ScreenColorSampler.requestPermissionIfNeeded() {
                    needsScreenPermission = true
                    fail(LText(id: "screen_perm") { L10n.errScreenPermission($0) })
                    return
                }
                needsScreenPermission = false
                startScreenStream()
                if beatSync { startAudio() }
                statusText = syncingStatusText
                render()
            }
        }
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
        errorText = nil
        lamps.removeAll { !$0.remembered && $0.id != selectedLampID }
        for index in lamps.indices { lamps[index].rssi = nil }
        isScanning = true
        statusText = LText(id: "scanning") { L10n.statusScanning($0) }
        log { L10n.logScanStart(targetName, $0) }
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
            statusText = found == 0
                ? LText(id: "scan_none") { L10n.statusScanNone($0) }
                : LText(id: "scan_found_\(found)") { L10n.statusScanFound(found, $0) }
        }
    }

    func start() {
        guard canStart, let id = selectedLampID else { return }
        errorText = nil
        stopScan()
        if colorSource == .screen {
            if !ScreenColorSampler.requestPermissionIfNeeded() {
                needsScreenPermission = true
                fail(LText(id: "screen_perm") { L10n.errScreenPermission($0) })
                return
            }
            needsScreenPermission = false
        } else {
            needsScreenPermission = false
            startSiteLink()
        }
        guard let target = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            fail(LText(id: "lamp_not_found") { L10n.errSelectedLampNotFound($0) })
            return
        }
        guard target.name == targetName else {
            fail(LText(id: "wrong_name") { L10n.errWrongDeviceName(targetName, $0) })
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
        siteLink.setLampStatus(.connecting)
        statusText = LText(id: "connecting") { L10n.statusConnecting($0) }
        log { L10n.logConnecting(targetName, id.uuidString, $0) }
        target.delegate = self
        central.connect(target, options: nil)
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting else { return }
            self.fail(LText(id: "connect_timeout") { L10n.errConnectTimeout($0) })
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
            statusText = LText(id: "bt_ready") { L10n.statusBtReady($0) }
            restoreRememberedLamp()
        case .unauthorized:
            statusText = LText(id: "bt_unauth") { L10n.statusBtUnauthorized($0) }
        case .poweredOff:
            statusText = LText(id: "bt_off") { L10n.statusBtOff($0) }
        case .unsupported:
            statusText = LText(id: "bt_unsupported") { L10n.statusBtUnsupported($0) }
        default:
            statusText = LText(id: "bt_starting") { L10n.statusBtStarting($0) }
        }
        if !bluetoothReady {
            isScanning = false
            if phase != .idle { shutDown(reason: LText(id: "bt_unavailable") { L10n.errBtUnavailable($0) }) }
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
            let uuid = peripheral.identifier.uuidString
            log { L10n.logLampFound(uuid, $0) }
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
            fail(LText(id: "connected_wrong") { L10n.errConnectedWrongLamp($0) })
            return
        }
        statusText = LText(id: "discovering") { L10n.statusDiscoveringServices($0) }
        log { L10n.logConnectedDiscovering($0) }
        peripheral.discoverServices([controlUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if phase == .reconnecting {
            retryConnect()
            return
        }
        let detail = error?.localizedDescription
        fail(LText(id: "connect_fail_\(detail ?? "")") { L10n.errFailedToConnect(detail, $0) })
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        switch phase {
        case .stopping:
            finishStop()
        case .syncing:
            let detail = error?.localizedDescription
            reconnect(because: LText(id: "disconnect_\(detail ?? "")") { L10n.reasonDisconnected(detail, $0) })
        case .reconnecting:
            retryConnect()
        case .connecting:
            shutDown(reason: LText(id: "disconnected") { L10n.errDisconnected($0) })
        case .idle:
            break
        }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .connecting || phase == .reconnecting else { return }
        if let error {
            let detail = error.localizedDescription
            fail(LText(id: "svc_fail_\(detail)") { L10n.errServiceDiscovery(detail, $0) })
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == controlUUID }) else {
            fail(LText(id: "no_svc") { L10n.errNoControlService($0) })
            return
        }
        peripheral.discoverCharacteristics([controlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard phase == .connecting || phase == .reconnecting else { return }
        if let error {
            let detail = error.localizedDescription
            fail(LText(id: "char_fail_\(detail)") { L10n.errCharDiscovery(detail, $0) })
            return
        }
        guard let found = service.characteristics?.first(where: { $0.uuid == controlUUID }),
              found.properties.contains(.write) else {
            fail(LText(id: "char_no_write") { L10n.errCharNoWrite($0) })
            return
        }
        connectTimeoutWork?.cancel()
        characteristic = found
        let reconnected = phase == .reconnecting
        reconnectDeadlineWork?.cancel()
        reconnectDeadlineWork = nil
        phase = .syncing
        siteLink.setLampStatus(.linked)
        statusText = syncingStatusText
        if reconnected {
            log { L10n.logReconnected($0) }
            return // Timers and audio kept running while the link was down.
        }
        log { L10n.logSyncStarted($0) }
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
        if colorSource == .screen {
            startScreenStream()
            if beatSync { startAudio() }
        } else {
            render()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let started = writeStartedAt else { return }
        writeStartedAt = nil
        let color = pendingRGB
        pendingRGB = nil
        if let error {
            if phase == .syncing {
                let detail = error.localizedDescription
                reconnect(because: LText(id: "write_fail_\(detail)") { L10n.reasonWriteFailed(detail, $0) })
            }
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
            reconnect(because: LText(id: "write_timeout") { L10n.reasonWriteTimeout($0) })
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
        if let screenError = error as? ScreenColorError {
            switch screenError {
            case .screenCapturePermissionDenied:
                needsScreenPermission = true
                shutDown(reason: LText(id: "screen_perm") { L10n.errScreenPermission($0) })
            case .noDisplaysAvailable:
                shutDown(reason: LText(id: "no_displays") { L10n.errNoDisplays($0) })
            case .couldNotReadScreenshot:
                shutDown(reason: LText(id: "read_screenshot") { L10n.errCouldNotReadScreenshot($0) })
            }
            return
        }
        let detail = error.localizedDescription
        shutDown(reason: LText(id: "screen_fail_\(detail)") { L10n.errScreenCaptureFailed(detail, $0) })
    }

    /// Advances the effects and writes the frame when it differs from the lamp's acknowledged color.
    private func render() {
        guard phase == .syncing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastRenderAt.map { now - $0 } ?? 0
        lastRenderAt = now

        if colorSource == .site {
            let stage = siteDirector.step(
                uptime: now,
                now: Date(),
                baseBrightness: brightness,
                effectiveFadeTime: effectiveFadeTime,
                lowLatency: lowLatency,
                userBeatStyle: beatStyle,
                evaluator: siteEvaluator
            )
            siteSongTitle = stage.songTitle
            sitePlayingState = stage.playingState
            engine.brightness = stage.effectiveBrightness
            engine.fadeTime = stage.effectiveFadeTime
            engine.beatDepth = stage.beatDepth
            engine.beatStyle = stage.beatStyle
            engine.beatSync = stage.beatSync
            engine.breathing = stage.breathing
            if let strength = stage.beatStrength {
                engine.beat(strength: strength, bpm: stage.beatBpm)
            }
            screenColor = stage.effectiveColor
            engine.setTarget(stage.effectiveColor)
        } else {
            engine.brightness = brightness
            engine.fadeTime = effectiveFadeTime
            engine.beatDepth = LightEngine.beatDepth
            engine.beatStyle = beatStyle
            engine.beatSync = beatSync
            engine.breathing = breathing
        }

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
            let detail = error.localizedDescription
            shutDown(reason: LText(id: "encode_fail_\(detail)") { L10n.errEncodeFailed(detail, $0) })
        }
    }

    /// Shows recent averages in the window and writes them to the log about every 30 seconds.
    private func reportLatency() {
        let capture = captureLatency.drain()
        let bluetooth = bluetoothLatency.drain()
        guard capture != nil || bluetooth != nil else { return }
        let interval = Int(Self.latencyReportInterval)
        let summary = LText(id: "latency_\(latencyReports)") { lang in
            L10n.latencySummary(
                intervalSeconds: interval,
                captureAvg: capture?.average,
                captureMax: capture?.maximum,
                btAvg: bluetooth?.average,
                btMax: bluetooth?.maximum,
                lang
            )
        }
        latencyText = summary
        latencyReports += 1
        if latencyReports % 6 == 1 { log { summary.resolve($0) } }
    }

    // MARK: - Shutdown

    private func fail(_ message: LText) {
        if phase == .idle {
            errorText = message
            statusText = LText(id: "not_syncing") { L10n.statusNotSyncing($0) }
            log { L10n.logErrorPrefix(message.resolve($0), $0) }
        } else {
            shutDown(reason: message)
        }
    }

    /// `reason == nil` means the user pressed Stop.
    private func shutDown(reason: LText?) {
        guard phase != .idle, phase != .stopping else { return }
        stopReason = reason
        phase = .stopping
        statusText = LText(id: "stopping") { L10n.statusStopping($0) }
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
        latencyText = nil
        siteLink.setLampStatus(.idle)
        if colorSource != .site {
            stopSiteLink()
        }
        if let reason = stopReason {
            errorText = reason
            statusText = LText(id: "stopped_err") { L10n.statusStoppedError($0) }
            log { L10n.logErrorPrefix(reason.resolve($0), $0) }
        } else {
            statusText = LText(id: "stopped_user") { L10n.statusStoppedUser($0) }
            log { L10n.logStoppedByUser($0) }
        }
    }

    /// Shows the full-screen overlay to drag-select the sampling area; Esc keeps the current one.
    func selectRegion() {
        RegionSelector.select { [weak self] region in
            guard let self, let region else { return }
            self.captureRegion = region
            self.log { L10n.logRegionCustom(widthPct: region.width * 100, heightPct: region.height * 100, $0) }
        }
    }

    func useWholeScreen() {
        guard captureRegion != nil else { return }
        captureRegion = nil
        log { L10n.logRegionWholeScreen($0) }
    }

    // MARK: - Reconnect

    /// Keeps sampling and effect state, drops the link and waits (up to `reconnectWindow`) for the lamp
    /// to accept a new connection. CoreBluetooth's connect request stays pending until the lamp is reachable.
    private func reconnect(because reason: LText) {
        guard phase == .syncing, let peripheral else { return }
        phase = .reconnecting
        siteLink.setLampStatus(.connecting)
        characteristic = nil
        writeStartedAt = nil
        pendingRGB = nil
        lampColor = nil // Rewrite the current color as soon as the link is back.
        let windowSeconds = Int(Self.reconnectWindow)
        statusText = LText(id: "reconnecting_\(windowSeconds)") {
            L10n.statusReconnecting(reason.resolve($0), windowSeconds: windowSeconds, $0)
        }
        log { L10n.logReconnecting(reason.resolve($0), $0) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .reconnecting else { return }
            self.shutDown(reason: LText(id: "reconnect_timeout") {
                L10n.errReconnectTimedOut(reason.resolve($0), windowSeconds: windowSeconds, $0)
            })
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
                self.log { L10n.logAudioStarted($0) }
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
        let detail = error.localizedDescription
        errorText = LText(id: "audio_fail_\(detail)") { L10n.errAudioFailed(detail, $0) }
        log { L10n.logAudioFailed(detail, $0) }
    }

    // MARK: - Helpers

    private var syncingStatusText: LText {
        if colorSource == .site {
            if portInUse {
                return LText(id: "sync_site_port") { L10n.statusSyncingSitePortInUse($0) }
            }
            return LText(id: "sync_site") { L10n.statusSyncingSite($0) }
        }
        let hasRegion = captureRegion != nil
        return LText(id: "sync_screen_\(hasRegion)") { L10n.statusSyncingScreen(hasRegion: hasRegion, $0) }
    }

    /// Re-grades the last screen color so color changes show right away, even on a still screen.
    private func regrade() {
        guard phase == .syncing || phase == .reconnecting else { return }
        if colorSource == .site {
            render()
        } else if let screenColor {
            engine.setTarget(screenColor)
        }
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

    private func log(_ make: (AppLanguage) -> String) {
        let line = make(MainActor.assumeIsolated { L10n.currentLanguage })
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
