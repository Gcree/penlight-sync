import Foundation
import Network

/// Origin validator for incoming WebSocket handshakes.
enum SiteLinkOriginValidator {
    static func isValid(origin: String?) -> Bool {
        guard let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else {
            return false
        }
        if origin == "https://gcree.github.io" || origin == "https://ado.kuti.cc" {
            return true
        }
        guard let url = URL(string: origin),
              url.scheme == "http",
              let host = url.host else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }
        return false
    }
}

/// Parses and validates incoming messages according to protocol v1.
enum SiteLinkMessageParser {
    static let maxMessageSize = 4096 // 4 KB limit

    enum ParsedMessage: Equatable {
        case state(SiteState)
        case stop
        case ignored
    }

    static func parse(data: Data) -> ParsedMessage {
        guard data.count <= maxMessageSize else {
            return .ignored
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        guard let v = json["v"] as? Int, v == 1,
              let type = json["type"] as? String else {
            return .ignored
        }

        switch type {
        case "stop":
            return .stop
        case "state":
            guard let seq = json["seq"] as? Int,
                  let song = json["song"] as? String,
                  let title = json["title"] as? String,
                  let playing = json["playing"] as? Bool,
                  let t = (json["t"] as? NSNumber)?.doubleValue,
                  let rate = (json["rate"] as? NSNumber)?.doubleValue,
                  let colors = json["colors"] as? [String] else {
                return .ignored
            }
            let colorsSet = json["colorsSet"] as? Bool
            var beat: SiteBeat?
            if let beatDict = json["beat"] as? [String: Any],
               let bpm = (beatDict["bpm"] as? NSNumber)?.doubleValue,
               let offset = (beatDict["offset"] as? NSNumber)?.doubleValue,
               let barKnown = beatDict["barKnown"] as? Bool {
                beat = SiteBeat(bpm: bpm, offset: offset, barKnown: barKnown)
            }
            let climax = (json["climax"] as? NSNumber)?.doubleValue
            let cue = json["cue"] as? String

            let state = SiteState(
                v: 1,
                type: "state",
                seq: seq,
                song: song,
                title: title,
                playing: playing,
                t: t,
                rate: rate,
                colors: colors,
                colorsSet: colorsSet,
                beat: beat,
                climax: climax,
                cue: cue
            )
            return .state(state)
        default:
            return .ignored
        }
    }
}

/// WebSocket server that receives playback state from the Ado support website.
final class SiteLink: ObservableObject {
    static let port: UInt16 = 51730
    static let appVersion = "1.7.0"

    enum LampStatus: String {
        case linked
        case connecting
        case idle
    }

    @Published private(set) var isListening = false
    @Published private(set) var portInUse = false
    @Published private(set) var hasClient = false
    @Published private(set) var currentState: SiteState?
    @Published private(set) var isWaiting = true
    @Published private(set) var currentSongTitle: String = ""

    var onStateUpdate: ((SiteState, Date) -> Void)?
    var onStop: (() -> Void)?

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "local.penlight-sync.sitelink", qos: .userInteractive)
    private var watchdogTimer: DispatchSourceTimer?
    private var lastStateReceivedDate: Date?
    private var lampStatus: LampStatus = .idle
    private var isHandshakeAccepted = false

    init() {}

    deinit {
        stop()
    }

    /// Sets the current lamp connection status and broadcasts it if a client is connected.
    func setLampStatus(_ status: LampStatus) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lampStatus = status
            if let conn = self.activeConnection, self.isHandshakeAccepted {
                self.sendHello(on: conn, lamp: status)
            }
        }
    }

    /// Starts the server on 127.0.0.1:51730.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isListening { return }
            self.startServer()
        }
    }

    /// Stops the server and disconnects any active web client.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopWatchdog()
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.listener?.cancel()
            self.listener = nil
            DispatchQueue.main.async {
                self.isListening = false
                self.hasClient = false
                self.isWaiting = true
            }
        }
    }

    private func startServer() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()

        wsOptions.setClientRequestHandler(queue) { [weak self] _, headers in
            let origin = headers.first(where: { $0.name.caseInsensitiveCompare("origin") == .orderedSame })?.value
            if SiteLinkOriginValidator.isValid(origin: origin) {
                self?.isHandshakeAccepted = true
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            } else {
                self?.isHandshakeAccepted = false
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
        }

        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            guard let port = NWEndpoint.Port(rawValue: Self.port) else {
                return
            }
            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isListening = true
                        self.portInUse = false
                    }
                case .failed(let error):
                    let isAddrInUse = error.errorCode == 48 // EADDRINUSE
                    DispatchQueue.main.async {
                        self.isListening = false
                        self.portInUse = isAddrInUse
                    }
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isListening = false
                    }
                default:
                    break
                }
            }

            listener.start(queue: queue)
            startWatchdog()
        } catch {
            DispatchQueue.main.async {
                self.isListening = false
                self.portInUse = true
            }
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Enforce loopback only
        guard case let .hostPort(host, _) = connection.endpoint,
              (host == .ipv4(.loopback) || host == "127.0.0.1" || host == "::1") else {
            connection.cancel()
            return
        }

        // Only one active connection allowed; close the previous one
        activeConnection?.cancel()
        activeConnection = connection
        isHandshakeAccepted = false

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.isHandshakeAccepted else {
                    // Rejected connection must not send hello or receive messages
                    connection.cancel()
                    return
                }
                DispatchQueue.main.async {
                    self.hasClient = true
                }
                self.sendHello(on: connection, lamp: self.lampStatus)
                self.receiveNextMessage(on: connection)
            case .failed, .cancelled:
                if self.activeConnection === connection {
                    self.activeConnection = nil
                    DispatchQueue.main.async {
                        self.hasClient = false
                        self.isWaiting = true
                    }
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func sendHello(on connection: NWConnection, lamp: LampStatus) {
        let helloJSON = "{\"v\":1,\"type\":\"hello\",\"app\":\"PenlightSync\",\"version\":\"\(Self.appVersion)\",\"lamp\":\"\(lamp.rawValue)\"}"
        guard let data = helloJSON.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                return
            }
            if let data = content {
                self.handleIncomingData(data)
            }
            if connection.state == .ready {
                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        let parsed = SiteLinkMessageParser.parse(data: data)
        let now = Date()

        switch parsed {
        case .state(let state):
            lastStateReceivedDate = now
            DispatchQueue.main.async {
                self.currentState = state
                self.currentSongTitle = state.title
                self.isWaiting = false
            }
            onStateUpdate?(state, now)
        case .stop:
            lastStateReceivedDate = nil
            DispatchQueue.main.async {
                self.isWaiting = true
            }
            onStop?()
        case .ignored:
            break
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let lastDate = self.lastStateReceivedDate {
                if Date().timeIntervalSince(lastDate) > SiteLightEvaluator.waitingTimeout {
                    DispatchQueue.main.async {
                        self.isWaiting = true
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isWaiting = true
                }
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }
}
