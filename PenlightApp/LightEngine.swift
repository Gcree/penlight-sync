import Foundation

/// Turns sparse screen samples (and optional music beats) into a smooth lamp color stream:
/// - each sample is graded (vibrance boost, color temperature, brightness floor, overall brightness) so averaged
///   video colors don't look muddy;
/// - output fades exponentially toward the graded sample, faster right after a scene cut;
/// - an optional slow brightness "breath" appears only while the color is steady;
/// - optional beat sync dims the lamp slightly between beats and pops it back up on each beat,
///   but only while beats keep arriving, so silence leaves the lamp at full brightness;
///   with a known tempo, fades speed up for fast songs (and slow down for slow ones) and each flash
///   lasts about a third of a beat.
struct LightEngine {
    static let breathPeriod: TimeInterval = 4
    /// Brightness dips to 70% at the bottom of each breath.
    static let breathDepth = 0.3
    /// RGB distance below which the faded color counts as steady enough to breathe.
    static let steadyDistance = 24.0
    /// How quickly breathing fades in or out after the color settles or changes.
    static let breathRamp: TimeInterval = 0.8
    /// RGB distance of a sample jump that counts as a scene cut.
    static let cutDistance = 140.0
    /// A cut fades this much faster than the normal fade time, but never faster than `minimumCutFade`.
    static let cutFadeFactor = 0.2
    static let minimumCutFade: TimeInterval = 0.08
    /// Between beats the lamp rests at 55% brightness; each beat lifts it back to full.
    static let beatDepth = 0.45
    static let beatDecay: TimeInterval = 0.18
    /// Beat sync engages while beats arrived within this window and releases after it.
    static let beatHold: TimeInterval = 2
    static let beatRamp: TimeInterval = 0.5
    /// Tempo at which the fade time is used as set; faster songs scale it down, slower ones up, within `tempoScaleRange`.
    static let referenceTempo = 120.0
    static let tempoScaleRange = 0.6...1.4

    /// Time to cover ~95% of the way to a new color; 0 switches instantly.
    var fadeTime: TimeInterval
    var breathing: Bool
    /// 0 leaves colors as sampled; 1 strongly boosts saturation (hue is preserved).
    var vibrance: Double = 0
    /// Lowest brightness (0–1) the lamp shows; 0 lets dark scenes go fully dark.
    var minBrightness: Double = 0
    /// -1 (cool) … 0 (as sampled) … 1 (warm).
    var warmth: Double = 0
    /// Overall output level (0–1), applied after the brightness floor.
    var brightness: Double = 1
    var sceneCuts = true
    var beatSync = false

    private var target: [Double]?
    private var current: [Double] = [0, 0, 0]
    private var cutInProgress = false
    private var breathLevel = 0.0
    private var phase = 0.0
    private var pulse = 0.0
    private var beatActivity = 0.0
    private var sinceBeat = TimeInterval.infinity
    private var tempo: Double?

    init(fadeTime: TimeInterval, breathing: Bool) {
        self.fadeTime = fadeTime
        self.breathing = breathing
    }

    /// True while beat sync is actively shaping the light.
    var musicDetected: Bool { beatSync && beatActivity > 0.5 }

    /// The music's tempo while beat sync is active and a tempo is known.
    var bpm: Double? { musicDetected ? tempo : nil }

    mutating func setTarget(_ rgb: ScreenRGB) {
        let next = Self.grade(rgb, vibrance: vibrance, minBrightness: minBrightness, warmth: warmth, brightness: brightness)
        if target == nil {
            current = next // The first sample shows immediately instead of fading in from black.
        } else if sceneCuts, Self.distance(next, current) > Self.cutDistance {
            cutInProgress = true
        }
        target = next
    }

    /// Registers a detected beat with strength 0–1 and, when known, the music's tempo in BPM.
    mutating func beat(strength: Double, bpm: Double? = nil) {
        pulse = max(pulse, min(1, max(0, strength)))
        sinceBeat = 0
        if let bpm, bpm > 0 { tempo = bpm }
    }

    /// Advances the effect by `dt` seconds. Returns nil until the first sample arrives.
    mutating func step(dt: TimeInterval) -> ScreenRGB? {
        guard let target else { return nil }
        let dt = max(0, dt)
        // Blend the tempo's effect in and out with beat activity so it never jumps.
        let tempoScale = tempo.map { 1 + (min(Self.tempoScaleRange.upperBound, max(Self.tempoScaleRange.lowerBound, Self.referenceTempo / $0)) - 1) * beatActivity } ?? 1
        let baseFade = fadeTime * tempoScale
        let activeFade = cutInProgress ? max(Self.minimumCutFade, baseFade * Self.cutFadeFactor) : baseFade
        if fadeTime <= 0 {
            current = target
        } else {
            let k = 1 - exp(-3 * dt / activeFade)
            current = zip(current, target).map { $0 + ($1 - $0) * k }
        }
        let distance = Self.distance(current, target)
        if distance < Self.steadyDistance { cutInProgress = false }

        sinceBeat += dt
        if sinceBeat >= Self.beatHold { tempo = nil }
        let beatsArriving = beatSync && sinceBeat < Self.beatHold ? 1.0 : 0.0
        beatActivity += (beatsArriving - beatActivity) * (1 - exp(-dt / Self.beatRamp))
        // The frame right after a beat shows it at full strength; the flash decays from the next frame on.
        let beatScale = 1 - Self.beatDepth * beatActivity * (1 - pulse)
        let decay = tempo.map { min(0.3, max(0.1, 0.35 * 60 / $0)) } ?? Self.beatDecay
        pulse *= exp(-dt / decay)

        // Music takes over from breathing while it plays.
        let wanted = breathing && distance < Self.steadyDistance ? 1 - beatActivity : 0.0
        breathLevel += (wanted - breathLevel) * (1 - exp(-dt / Self.breathRamp))
        phase = (phase + dt / Self.breathPeriod).truncatingRemainder(dividingBy: 1)
        let breathScale = 1 - Self.breathDepth * breathLevel * (0.5 - 0.5 * cos(2 * Double.pi * phase))

        let scale = beatScale * breathScale
        let channels = current.map { UInt8(max(0, min(255, ($0 * scale).rounded()))) }
        return ScreenRGB(red: channels[0], green: channels[1], blue: channels[2])
    }

    /// Boosts saturation along a curve that lifts dull colors most, keeps hue and brightness,
    /// shifts toward warm or cool, raises brightness to at least `minBrightness`, then scales by `brightness`.
    static func grade(_ rgb: ScreenRGB, vibrance: Double, minBrightness: Double, warmth: Double = 0, brightness: Double = 1) -> [Double] {
        var channels = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)]
        let maximum = channels.max()!
        let minimum = channels.min()!
        if maximum > 0, maximum > minimum, vibrance > 0 {
            let saturation = (maximum - minimum) / maximum
            let boosted = 1 - pow(1 - saturation, 1 + 3 * min(1, vibrance))
            channels = channels.map { maximum - (maximum - $0) * boosted / saturation }
        }
        // Temperature only ever dims the opposite channels, so it cannot clip.
        let warm = min(1, max(-1, warmth))
        if warm > 0 {
            channels[1] *= 1 - 0.15 * warm
            channels[2] *= 1 - 0.6 * warm
        } else if warm < 0 {
            channels[0] *= 1 + 0.6 * warm
            channels[1] *= 1 + 0.15 * warm
        }
        let floor = 255 * min(1, max(0, minBrightness))
        if maximum < floor {
            channels = maximum > 0 ? channels.map { $0 * floor / maximum } : [floor, floor, floor]
        }
        let level = min(1, max(0, brightness))
        return channels.map { $0 * level }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { ($1 - $0) * ($1 - $0) }.reduce(0, +).squareRoot()
    }
}

/// One-click combinations of the color settings offered in the apps (mirrored in PenlightCore.cs).
struct ColorPreset: Identifiable, Equatable {
    let name: String
    let vibrance: Double
    let minBrightness: Double
    let brightness: Double
    let warmth: Double
    var id: String { name }

    static let all = [
        ColorPreset(name: "自然", vibrance: 0.2, minBrightness: 0, brightness: 1, warmth: 0),
        ColorPreset(name: "標準", vibrance: 0.4, minBrightness: 0, brightness: 1, warmth: 0),
        ColorPreset(name: "鮮豔", vibrance: 0.75, minBrightness: 0.1, brightness: 1, warmth: 0),
        ColorPreset(name: "演唱會", vibrance: 0.9, minBrightness: 0.2, brightness: 1, warmth: -0.1),
        ColorPreset(name: "電影院", vibrance: 0.3, minBrightness: 0.05, brightness: 0.7, warmth: 0.15),
    ]
    /// The defaults a fresh install starts with.
    static let standard = all[1]
}
