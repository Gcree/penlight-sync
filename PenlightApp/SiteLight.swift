import Foundation

/// Beat configuration received from the website.
struct SiteBeat: Equatable, Sendable, Codable {
    let bpm: Double
    let offset: Double
    let barKnown: Bool

    init(bpm: Double, offset: Double, barKnown: Bool) {
        self.bpm = bpm
        self.offset = offset
        self.barKnown = barKnown
    }
}

/// Song playback state received from the website.
struct SiteState: Equatable, Sendable, Codable {
    let v: Int
    let type: String
    let seq: Int
    let song: String
    let title: String
    let playing: Bool
    let t: Double
    let rate: Double
    let colors: [String]
    let colorsSet: Bool?
    let beat: SiteBeat?
    let climax: Double?
    let cue: String?

    init(
        v: Int = 1,
        type: String = "state",
        seq: Int,
        song: String,
        title: String,
        playing: Bool,
        t: Double,
        rate: Double,
        colors: [String],
        colorsSet: Bool? = nil,
        beat: SiteBeat? = nil,
        climax: Double? = nil,
        cue: String? = nil
    ) {
        self.v = v
        self.type = type
        self.seq = seq
        self.song = song
        self.title = title
        self.playing = playing
        self.t = t
        self.rate = rate
        self.colors = colors
        self.colorsSet = colorsSet
        self.beat = beat
        self.climax = climax
        self.cue = cue
    }
}

/// The evaluated light frame for a given instant in website mode.
struct SiteLightFrame: Equatable {
    var targetColor: ScreenRGB
    var shouldBeat: Bool
    var beatStrength: Double
    var beatBpm: Double
    var isBarStart: Bool
    var isClimax: Bool
    var isWaiting: Bool
    var brightnessMultiplier: Double
    var movieTime: Double
    var colorIndex: Int
    var beatInBar: Int
    var isPreDownbeat: Bool

    init(
        targetColor: ScreenRGB,
        shouldBeat: Bool,
        beatStrength: Double,
        beatBpm: Double,
        isBarStart: Bool,
        isClimax: Bool,
        isWaiting: Bool,
        brightnessMultiplier: Double,
        movieTime: Double,
        colorIndex: Int,
        beatInBar: Int = 0,
        isPreDownbeat: Bool = false
    ) {
        self.targetColor = targetColor
        self.shouldBeat = shouldBeat
        self.beatStrength = beatStrength
        self.beatBpm = beatBpm
        self.isBarStart = isBarStart
        self.isClimax = isClimax
        self.isWaiting = isWaiting
        self.brightnessMultiplier = brightnessMultiplier
        self.movieTime = movieTime
        self.colorIndex = colorIndex
        self.beatInBar = beatInBar
        self.isPreDownbeat = isPreDownbeat
    }
}

extension ScreenRGB {
    static func fromHex(_ hex: String) -> ScreenRGB? {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let val = UInt32(str, radix: 16) else { return nil }
        let r = UInt8((val >> 16) & 0xff)
        let g = UInt8((val >> 8) & 0xff)
        let b = UInt8(val & 0xff)
        return ScreenRGB(red: r, green: g, blue: b)
    }
}

/// Pure logic engine that drives the lamp according to the website's state without network or Bluetooth dependencies.
final class SiteLightEvaluator {
    static let defaultBlue = ScreenRGB(red: 93, green: 157, blue: 254) // #5d9dfe
    static let waitingTimeout: TimeInterval = 5.0

    private(set) var latestState: SiteState?
    private(set) var stateReceivedAt: Date?
    private(set) var lastMovieTime: Double?
    private(set) var lastTargetColor: ScreenRGB = defaultBlue
    private(set) var colorChangeBeatCount: Int = 0

    init() {}

    /// Resets the evaluator state.
    func reset() {
        latestState = nil
        stateReceivedAt = nil
        lastMovieTime = nil
        lastTargetColor = Self.defaultBlue
        colorChangeBeatCount = 0
    }

    /// Ingests a new state. Older or equal seq numbers are discarded. Returns true if accepted.
    @discardableResult
    func updateState(_ state: SiteState, receivedAt: Date = Date()) -> Bool {
        if let current = latestState, state.seq <= current.seq {
            return false
        }
        latestState = state
        stateReceivedAt = receivedAt
        return true
    }

    /// Calculates the estimated video playback time.
    static func calculateMovieTime(state: SiteState, receivedAt: Date, now: Date) -> Double {
        if !state.playing {
            return state.t
        }
        let elapsed = max(0.0, now.timeIntervalSince(receivedAt))
        return state.t + elapsed * state.rate
    }

    /// Evaluates the target color and beat signals for `now`.
    func evaluate(now: Date = Date(), userBeatStyle: BeatStyle = .auto) -> SiteLightFrame {
        guard let state = latestState, let receivedAt = stateReceivedAt else {
            return SiteLightFrame(
                targetColor: lastTargetColor,
                shouldBeat: false,
                beatStrength: 0,
                beatBpm: 0,
                isBarStart: false,
                isClimax: false,
                isWaiting: true,
                brightnessMultiplier: 0.3,
                movieTime: 0,
                colorIndex: 0
            )
        }

        let elapsedSinceReceive = now.timeIntervalSince(receivedAt)
        if elapsedSinceReceive > Self.waitingTimeout {
            return SiteLightFrame(
                targetColor: lastTargetColor,
                shouldBeat: false,
                beatStrength: 0,
                beatBpm: 0,
                isBarStart: false,
                isClimax: false,
                isWaiting: true,
                brightnessMultiplier: 0.3,
                movieTime: lastMovieTime ?? state.t,
                colorIndex: 0
            )
        }

        let movieTime = Self.calculateMovieTime(state: state, receivedAt: receivedAt, now: now)

        // Parse colors
        let parsedColors = state.colors.compactMap { ScreenRGB.fromHex($0) }
        let availableColors = parsedColors.isEmpty ? [Self.defaultBlue] : parsedColors

        // Climax calculation (8 beats with BPM, or 4 seconds without)
        var isClimax = false
        if let climax = state.climax {
            let climaxDuration: Double
            if let beat = state.beat, beat.bpm > 0 {
                climaxDuration = 8.0 * (60.0 / beat.bpm)
            } else {
                climaxDuration = 4.0
            }
            if movieTime >= climax && movieTime < climax + climaxDuration {
                isClimax = true
            }
        }

        // Action / Cue
        let isListen = (state.cue == "listen")
        var brightnessMultiplier: Double = 1.0
        if isListen {
            brightnessMultiplier = 0.5
        }
        if isClimax {
            brightnessMultiplier = 1.0
        }

        // Beat triggering
        var shouldBeat = false
        var beatStrength: Double = 0.6
        var isBarStart = false
        var beatBpm: Double = 0
        var beatInBar = 0

        let isHypeCue = (state.cue == "jump" || state.cue == "call" || state.cue == "clap" || isClimax)

        if state.playing && !isListen, let beat = state.beat, beat.bpm > 0 {
            beatBpm = beat.bpm
            let beatInterval = 60.0 / beat.bpm
            if let prevTime = lastMovieTime {
                let prevBeat = Int(floor((prevTime - beat.offset) / beatInterval))
                let currBeat = Int(floor((movieTime - beat.offset) / beatInterval))
                let prevHalfBeat = Int(floor((prevTime - beat.offset) / (beatInterval / 2.0)))
                let currHalfBeat = Int(floor((movieTime - beat.offset) / (beatInterval / 2.0)))

                // 連續鼓聲判定（副歌高潮 drop、跳躍段落、或小節末鼓點過門）
                let isDrumRoll = isClimax || (isHypeCue && beat.bpm >= 125)

                if currBeat > prevBeat {
                    shouldBeat = true
                    beatInBar = ((currBeat % 4) + 4) % 4
                    isBarStart = (beatInBar == 0)
                    if beat.barKnown && isBarStart {
                        beatStrength = 1.0
                    } else {
                        beatStrength = 0.6
                    }
                    if userBeatStyle == .colors {
                        colorChangeBeatCount += 1
                    }
                } else if isDrumRoll && currHalfBeat > prevHalfBeat {
                    // 連續鼓聲半拍（8分音符）連擊脈衝
                    shouldBeat = true
                    beatInBar = ((currBeat % 4) + 4) % 4
                    isBarStart = false
                    beatStrength = 0.55
                    if userBeatStyle == .colors {
                        colorChangeBeatCount += 1
                    }
                }
            }
        }
        lastMovieTime = movieTime

        // Color index calculation
        let colorIndex: Int
        if availableColors.count <= 1 {
            colorIndex = 0
        } else if userBeatStyle == .colors {
            colorIndex = ((colorChangeBeatCount % availableColors.count) + availableColors.count) % availableColors.count
        } else if let beat = state.beat, beat.bpm > 0 {
            let beatInterval = 60.0 / beat.bpm
            let exactBeat = (movieTime - beat.offset) / beatInterval
            let beatIndex = Int(floor(exactBeat))
            let beatFraction = exactBeat - floor(exactBeat)

            // 連續鼓聲判定（高潮 drop、嗨歌段落、或第 4 拍後半過門）
            let isDrumRoll = isClimax || (isHypeCue && beat.bpm >= 125) || (beatInBar == 3 && beatFraction >= 0.5 && beat.bpm >= 115)

            let colorStepIndex: Int
            if isDrumRoll {
                // 連續鼓聲：每 0.5 拍（半拍）極速切換！
                colorStepIndex = Int(floor(exactBeat * 2.0))
            } else if isHypeCue || beat.bpm >= 135 {
                // 嗨歌／高潮／互動動作／快歌：每 1 拍換一次色！
                colorStepIndex = beatIndex
            } else {
                // 一般正常段落：每 2 拍換一次色（1～2 拍換一次）！
                colorStepIndex = Int(floor(Double(beatIndex) / 2.0))
            }
            colorIndex = ((colorStepIndex % availableColors.count) + availableColors.count) % availableColors.count
        } else {
            // No beat data: change color every 4 seconds
            let barIndex = Int(floor(movieTime / 4.0))
            colorIndex = ((barIndex % availableColors.count) + availableColors.count) % availableColors.count
        }

        let chosenColor = availableColors[colorIndex]
        lastTargetColor = chosenColor

        var isPreDownbeat = false
        if state.playing && !isListen, let beat = state.beat, beat.bpm > 0, beat.barKnown {
            let beatInterval = 60.0 / beat.bpm
            let exactBeat = (movieTime - beat.offset) / beatInterval
            let beatFraction = exactBeat - floor(exactBeat)
            let currBeatInBar = ((Int(floor(exactBeat)) % 4) + 4) % 4
            // 大鼓重拍前約 18% 拍子時間（約 70~90ms）進入下潛蓄力狀態
            if currBeatInBar == 3 && beatFraction >= 0.82 {
                isPreDownbeat = true
            }
        }

        return SiteLightFrame(
            targetColor: chosenColor,
            shouldBeat: shouldBeat,
            beatStrength: beatStrength,
            beatBpm: beatBpm,
            isBarStart: isBarStart,
            isClimax: isClimax,
            isWaiting: false,
            brightnessMultiplier: brightnessMultiplier,
            movieTime: movieTime,
            colorIndex: colorIndex,
            beatInBar: beatInBar,
            isPreDownbeat: isPreDownbeat
        )
    }
}
