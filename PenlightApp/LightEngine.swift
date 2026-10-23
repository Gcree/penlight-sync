import Foundation

/// Turns sparse screen samples into a smooth lamp color stream: an exponential fade toward the latest
/// sample, plus an optional slow brightness "breath" that only appears while the color is steady,
/// so it never fights the video's own color changes.
struct LightEngine {
    static let breathPeriod: TimeInterval = 4
    /// Brightness dips to 70% at the bottom of each breath.
    static let breathDepth = 0.3
    /// RGB distance below which the faded color counts as steady enough to breathe.
    static let steadyDistance = 24.0
    /// How quickly breathing fades in or out after the color settles or changes.
    static let breathRamp: TimeInterval = 0.8

    /// Time to cover ~95% of the way to a new color; 0 switches instantly.
    var fadeTime: TimeInterval
    var breathing: Bool

    private var target: [Double]?
    private var current: [Double] = [0, 0, 0]
    private var breathLevel = 0.0
    private var phase = 0.0

    init(fadeTime: TimeInterval, breathing: Bool) {
        self.fadeTime = fadeTime
        self.breathing = breathing
    }

    mutating func setTarget(_ rgb: ScreenRGB) {
        let next = [Double(rgb.red), Double(rgb.green), Double(rgb.blue)]
        if target == nil { current = next } // The first sample shows immediately instead of fading in from black.
        target = next
    }

    /// Advances the effect by `dt` seconds. Returns nil until the first sample arrives.
    mutating func step(dt: TimeInterval) -> ScreenRGB? {
        guard let target else { return nil }
        let dt = max(0, dt)
        if fadeTime <= 0 {
            current = target
        } else {
            let k = 1 - exp(-3 * dt / fadeTime)
            current = zip(current, target).map { $0 + ($1 - $0) * k }
        }

        let distance = sqrt(zip(current, target).map { ($1 - $0) * ($1 - $0) }.reduce(0, +))
        let wanted = breathing && distance < Self.steadyDistance ? 1.0 : 0.0
        breathLevel += (wanted - breathLevel) * (1 - exp(-dt / Self.breathRamp))
        phase = (phase + dt / Self.breathPeriod).truncatingRemainder(dividingBy: 1)
        let scale = 1 - Self.breathDepth * breathLevel * (0.5 - 0.5 * cos(2 * Double.pi * phase))

        let channels = current.map { UInt8(max(0, min(255, ($0 * scale).rounded()))) }
        return ScreenRGB(red: channels[0], green: channels[1], blue: channels[2])
    }
}
