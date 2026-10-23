import Foundation

/// Energy-onset beat detector tuned for kick drums: low-passes mono audio (~150 Hz), measures energy in
/// ~23 ms windows, and reports a beat when a window is clearly louder than the recent (~1.2 s) average.
struct BeatDetector {
    static let cutoff = 150.0
    static let window: TimeInterval = 0.023
    static let averageTime: TimeInterval = 1.2
    /// A window must be this many times louder than the running average.
    static let threshold = 1.6
    /// Ignores near-silence so quiet noise never flashes the lamp.
    static let minimumEnergy = 1e-5
    /// At most one beat per this interval (300 BPM).
    static let refractory: TimeInterval = 0.2

    let sampleRate: Double
    private let alpha: Double
    private let windowSize: Int
    private var lowPass = 0.0
    private var energy = 0.0
    private var count = 0
    private var average: Double?
    private var sinceBeat = TimeInterval.infinity

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        alpha = 1 - exp(-2 * Double.pi * Self.cutoff / sampleRate)
        windowSize = max(1, Int(sampleRate * Self.window))
    }

    /// Feeds mono samples; returns the strength (0–1) of each beat found in them.
    mutating func process<S: Sequence>(_ samples: S) -> [Double] where S.Element == Float {
        var beats: [Double] = []
        let windowDuration = Double(windowSize) / sampleRate
        for sample in samples {
            lowPass += (Double(sample) - lowPass) * alpha
            energy += lowPass * lowPass
            count += 1
            guard count == windowSize else { continue }
            let windowEnergy = energy / Double(count)
            energy = 0
            count = 0
            sinceBeat += windowDuration
            guard let previous = average else {
                average = windowEnergy
                continue
            }
            let ratio = windowEnergy / max(previous, 1e-12)
            if ratio > Self.threshold, windowEnergy > Self.minimumEnergy, sinceBeat >= Self.refractory {
                beats.append(min(1, 0.4 + (ratio - Self.threshold) / 2.5))
                sinceBeat = 0
            }
            average = previous + (windowEnergy - previous) * (1 - exp(-windowDuration / Self.averageTime))
        }
        return beats
    }
}
