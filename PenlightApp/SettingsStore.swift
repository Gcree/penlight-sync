import CoreGraphics
import Foundation

enum ColorSource: String, CaseIterable, Identifiable {
    case screen = "screen"
    case site = "site"

    var id: String { rawValue }
}

/// Persists user preferences for light effects, source, selected lamp, and capture region in `UserDefaults`.
struct SettingsStore {
    private enum Keys {
        static let selectedLamp = "selectedLampID"
        static let colorSource = "colorSource"
        static let fadeTime = "fadeTime"
        static let breathing = "breathing"
        static let vibrance = "vibrance"
        static let minBrightness = "minBrightness"
        static let warmth = "warmth"
        static let brightness = "brightness"
        static let sceneCuts = "sceneCuts"
        static let beatSync = "beatSync"
        static let beatStyle = "beatStyle"
        static let captureRegion = "captureRegion"
        static let lowLatency = "lowLatency"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedLampID: UUID? {
        get { defaults.string(forKey: Keys.selectedLamp).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Keys.selectedLamp) }
    }

    var colorSource: ColorSource {
        get { defaults.string(forKey: Keys.colorSource).flatMap(ColorSource.init(rawValue:)) ?? .screen }
        set { defaults.set(newValue.rawValue, forKey: Keys.colorSource) }
    }

    var fadeTime: TimeInterval {
        get { clamp(defaults.object(forKey: Keys.fadeTime) as? Double ?? 0.6, 0...2) }
        set { defaults.set(clamp(newValue, 0...2), forKey: Keys.fadeTime) }
    }

    var lowLatency: Bool {
        get { defaults.bool(forKey: Keys.lowLatency) }
        set { defaults.set(newValue, forKey: Keys.lowLatency) }
    }

    var breathing: Bool {
        get { defaults.bool(forKey: Keys.breathing) }
        set { defaults.set(newValue, forKey: Keys.breathing) }
    }

    var vibrance: Double {
        get { clamp(defaults.object(forKey: Keys.vibrance) as? Double ?? 0.4, 0...1) }
        set { defaults.set(clamp(newValue, 0...1), forKey: Keys.vibrance) }
    }

    var minBrightness: Double {
        get { clamp(defaults.object(forKey: Keys.minBrightness) as? Double ?? 0, 0...0.5) }
        set { defaults.set(clamp(newValue, 0...0.5), forKey: Keys.minBrightness) }
    }

    var warmth: Double {
        get { clamp(defaults.object(forKey: Keys.warmth) as? Double ?? 0, -0.5...0.5) }
        set { defaults.set(clamp(newValue, -0.5...0.5), forKey: Keys.warmth) }
    }

    var brightness: Double {
        get { clamp(defaults.object(forKey: Keys.brightness) as? Double ?? 1, 0.1...1) }
        set { defaults.set(clamp(newValue, 0.1...1), forKey: Keys.brightness) }
    }

    var sceneCuts: Bool {
        get { defaults.object(forKey: Keys.sceneCuts) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.sceneCuts) }
    }

    var beatSync: Bool {
        get { defaults.bool(forKey: Keys.beatSync) }
        set { defaults.set(newValue, forKey: Keys.beatSync) }
    }

    var beatStyle: BeatStyle {
        get { defaults.string(forKey: Keys.beatStyle).flatMap(BeatStyle.init(rawValue:)) ?? .flash }
        set { defaults.set(newValue.rawValue, forKey: Keys.beatStyle) }
    }

    var captureRegion: CGRect? {
        get {
            guard let stored = defaults.array(forKey: Keys.captureRegion) as? [Double],
                  stored.count == 4,
                  stored.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                  stored[2] > 0, stored[3] > 0 else { return nil }
            return CGRect(x: stored[0], y: stored[1], width: stored[2], height: stored[3])
        }
        set {
            let stored = newValue.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
            defaults.set(stored, forKey: Keys.captureRegion)
        }
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
