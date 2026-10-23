import Foundation

/// Turns sparse screen samples (and optional music beats) into a smooth lamp color stream:
/// - each sample is graded (vibrance boost, brightness floor) so averaged video colors don't look muddy;
/// - output fades exponentially toward the graded sample, faster right after a scene cut;
/// - an optional slow brightness "breath" appears only while the color is steady;
/// - optional beat sync dims the lamp slightly between beats and pops it back up on each beat,
///   but only while beats keep arriving, so silence leaves the lamp at full brightness.
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

    /// Time to cover ~95% of the way to a new color; 0 switches instantly.
    var fadeTime: TimeInterval
    var breathing: Bool
    /// 0 leaves colors as sampled; 1 strongly boosts saturation (hue is preserved).
    var vibrance: Double = 0
    /// Lowest brightness (0–1) the lamp shows; 0 lets dark scenes go fully dark.
    var minBrightness: Double = 0
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

    init(fadeTime: TimeInterval, breathing: Bool) {
        self.fadeTime = fadeTime
        self.breathing = breathing
    }

    /// True while beat sync is actively shaping the light.
    var musicDetected: Bool { beatSync && beatActivity > 0.5 }

    mutating func setTarget(_ rgb: ScreenRGB) {
        let next = Self.grade(rgb, vibrance: vibrance, minBrightness: minBrightness)
        if target == nil {
            current = next // The first sample shows immediately instead of fading in from black.
        } else if sceneCuts, Self.distance(next, current) > Self.cutDistance {
            cutInProgress = true
        }
        target = next
    }

    /// Registers a detected beat with strength 0–1.
    mutating func beat(strength: Double) {
        pulse = max(pulse, min(1, max(0, strength)))
        sinceBeat = 0
    }

    /// Advances the effect by `dt` seconds. Returns nil until the first sample arrives.
    mutating func step(dt: TimeInterval) -> ScreenRGB? {
        guard let target else { return nil }
        let dt = max(0, dt)
        let activeFade = cutInProgress ? max(Self.minimumCutFade, fadeTime * Self.cutFadeFactor) : fadeTime
        if fadeTime <= 0 {
            current = target
        } else {
            let k = 1 - exp(-3 * dt / activeFade)
            current = zip(current, target).map { $0 + ($1 - $0) * k }
        }
        let distance = Self.distance(current, target)
        if distance < Self.steadyDistance { cutInProgress = false }

        sinceBeat += dt
        let beatsArriving = beatSync && sinceBeat < Self.beatHold ? 1.0 : 0.0
        beatActivity += (beatsArriving - beatActivity) * (1 - exp(-dt / Self.beatRamp))
        // The frame right after a beat shows it at full strength; the flash decays from the next frame on.
        let beatScale = 1 - Self.beatDepth * beatActivity * (1 - pulse)
        pulse *= exp(-dt / Self.beatDecay)

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
    /// then raises brightness to at least `minBrightness`.
    static func grade(_ rgb: ScreenRGB, vibrance: Double, minBrightness: Double) -> [Double] {
        var channels = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)]
        let maximum = channels.max()!
        let minimum = channels.min()!
        if maximum > 0, maximum > minimum, vibrance > 0 {
            let saturation = (maximum - minimum) / maximum
            let boosted = 1 - pow(1 - saturation, 1 + 3 * min(1, vibrance))
            channels = channels.map { maximum - (maximum - $0) * boosted / saturation }
        }
        let floor = 255 * min(1, max(0, minBrightness))
        if maximum < floor {
            channels = maximum > 0 ? channels.map { $0 * floor / maximum } : [floor, floor, floor]
        }
        return channels
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { ($1 - $0) * ($1 - $0) }.reduce(0, +).squareRoot()
    }
}
