import Foundation

@main
struct LightEngineTest {
    static func main() {
        let red = ScreenRGB(red: 255, green: 0, blue: 0)
        let blue = ScreenRGB(red: 0, green: 0, blue: 255)

        var engine = LightEngine(fadeTime: 0.6, breathing: false)
        engine.sceneCuts = false
        expect(engine.step(dt: 0.05) == nil, "No output before the first sample.")
        engine.setTarget(red)
        expect(engine.step(dt: 0.05) == red, "The first sample must show immediately.")

        // Fading: moves part of the way, monotonically, and reaches the target.
        engine.setTarget(blue)
        let first = engine.step(dt: 0.05)!
        expect(first.red < 255 && first.red > 128 && first.blue > 0 && first.blue < 128, "One frame must be partway: \(first)")
        var previousBlue = first.blue
        for _ in 0..<11 {
            let frame = engine.step(dt: 0.05)!
            expect(frame.blue >= previousBlue, "Fade must not reverse: \(frame)")
            previousBlue = frame.blue
        }
        let atFadeTime = engine.step(dt: 0)!
        expect(atFadeTime.blue >= 240, "Fade must be ~95% done after fadeTime: \(atFadeTime)")
        for _ in 0..<40 { _ = engine.step(dt: 0.05) }
        expect(engine.step(dt: 0.05) == blue, "Fade must settle on the target.")

        var instant = LightEngine(fadeTime: 0, breathing: false)
        instant.setTarget(red)
        _ = instant.step(dt: 0.05)
        instant.setTarget(blue)
        expect(instant.step(dt: 0.05) == blue, "fadeTime 0 must switch instantly.")

        // Breathing: dims a steady color by at most breathDepth and comes back up.
        var breath = LightEngine(fadeTime: 0.6, breathing: true)
        let white = ScreenRGB(red: 200, green: 200, blue: 200)
        breath.setTarget(white)
        var minimum = 255, maximum = 0
        for _ in 0..<200 { // 10 s at 20 Hz
            let frame = breath.step(dt: 0.05)!
            minimum = min(minimum, Int(frame.red))
            maximum = max(maximum, Int(frame.red))
        }
        expect(maximum == 200, "Breathing must return to full brightness: max \(maximum)")
        expect(minimum < 160 && minimum >= 139, "Breathing must dim to about 70%: min \(minimum)")

        // Breathing stays out of the way while a new color is fading in.
        breath.setTarget(red)
        let changing = breath.step(dt: 0.05)!
        expect(changing.red > 0 && changing.blue > 0, "A color change must start fading: \(changing)")
        var redMinimum = 255
        for _ in 0..<200 { redMinimum = min(redMinimum, Int(breath.step(dt: 0.05)!.red)) }
        expect(redMinimum < 200, "Breathing must resume once the new color settles: min \(redMinimum)")

        var noBreath = LightEngine(fadeTime: 0.6, breathing: false)
        noBreath.setTarget(white)
        for _ in 0..<200 { expect(noBreath.step(dt: 0.05) == white, "Breathing off must hold steady.") }

        // Scene cuts: a big jump fades much faster than the normal fade time; small changes do not.
        var cuts = LightEngine(fadeTime: 0.6, breathing: false)
        cuts.setTarget(red)
        _ = cuts.step(dt: 0.05)
        cuts.setTarget(blue)
        var cutFrame = cuts.step(dt: 0.05)!
        for _ in 0..<3 { cutFrame = cuts.step(dt: 0.05)! }
        expect(cutFrame.blue >= 240, "A scene cut must land within ~0.2 s: \(cutFrame)")
        let nearBlue = ScreenRGB(red: 0, green: 60, blue: 255)
        cuts.setTarget(nearBlue)
        let drift = cuts.step(dt: 0.05)!
        expect(drift.green > 0 && drift.green < 30, "A small change must fade normally: \(drift)")

        // Vibrance lifts dull colors, keeps hue and brightness, and leaves grays alone.
        let dull = ScreenRGB(red: 150, green: 120, blue: 110)
        let graded = LightEngine.grade(dull, vibrance: 0.5, minBrightness: 0)
        expect(graded[0] == 150 && graded[1] < 120 && graded[2] < 110 && graded[2] < graded[1],
               "Vibrance must raise saturation without changing hue or peak: \(graded)")
        expect(LightEngine.grade(dull, vibrance: 0, minBrightness: 0) == [150, 120, 110], "Vibrance 0 must not change colors.")
        expect(LightEngine.grade(ScreenRGB(red: 90, green: 90, blue: 90), vibrance: 1, minBrightness: 0) == [90, 90, 90],
               "Gray must stay gray.")

        // Brightness floor raises dark colors (keeping hue) and lights black as dim white.
        let darkRed = LightEngine.grade(ScreenRGB(red: 20, green: 10, blue: 0), vibrance: 0, minBrightness: 0.2)
        expect(abs(darkRed[0] - 51) < 0.01 && abs(darkRed[1] - 25.5) < 0.01, "Floor must scale dark colors up: \(darkRed)")
        expect(LightEngine.grade(ScreenRGB(red: 0, green: 0, blue: 0), vibrance: 0, minBrightness: 0.2) == [51, 51, 51],
               "Floor must light black as dim white.")
        expect(LightEngine.grade(ScreenRGB(red: 200, green: 0, blue: 0), vibrance: 0, minBrightness: 0.2) == [200, 0, 0],
               "Floor must not touch bright colors.")

        // Beat sync: dims between beats, pops on beats, and releases in silence.
        var music = LightEngine(fadeTime: 0.6, breathing: false)
        music.beatSync = true
        music.setTarget(white)
        var lowest = 255, peakAfterBeat = 0
        for frameIndex in 0..<80 { // 4 s, a beat every 0.5 s
            if frameIndex % 10 == 0 { music.beat(strength: 1) }
            let frame = music.step(dt: 0.05)!
            if frameIndex >= 40 {
                lowest = min(lowest, Int(frame.red))
                if frameIndex % 10 == 0 { peakAfterBeat = max(peakAfterBeat, Int(frame.red)) }
            }
        }
        expect(music.musicDetected, "Steady beats must engage beat sync.")
        expect(peakAfterBeat >= 185, "A beat must lift the lamp near full brightness: \(peakAfterBeat)")
        expect(lowest <= 130, "Between beats the lamp must rest dimmer: \(lowest)")
        for _ in 0..<100 { _ = music.step(dt: 0.05) } // 5 s of silence
        expect(!music.musicDetected && music.step(dt: 0.05)! == white, "Silence must release beat sync to full brightness.")

        // Beat detector: finds 120 BPM kicks, ignores silence and a steady tone.
        let rate = 48_000.0
        var detector = BeatDetector(sampleRate: rate)
        var kicks: [Float] = []
        for index in 0..<Int(rate * 4) {
            let t = Double(index) / rate
            let inKick = t.truncatingRemainder(dividingBy: 0.5) < 0.08
            let noise = Float.random(in: -0.002...0.002)
            kicks.append((inKick ? Float(0.8 * sin(2 * Double.pi * 60 * t)) : 0) + noise)
        }
        let beats = detector.process(kicks)
        expect((6...9).contains(beats.count), "Expected ~8 kicks in 4 s at 120 BPM, got \(beats.count)")
        expect(beats.allSatisfy { $0 > 0 && $0 <= 1 }, "Beat strengths must be within 0–1.")
        var quiet = BeatDetector(sampleRate: rate)
        expect(quiet.process([Float](repeating: 0, count: Int(rate * 2))).isEmpty, "Silence must not produce beats.")
        var tone = BeatDetector(sampleRate: rate)
        let steadyTone = (0..<Int(rate * 3)).map { Float(0.5 * sin(2 * Double.pi * 60 * Double($0) / rate)) }
        expect(tone.process(steadyTone).count <= 1, "A steady tone must not keep producing beats.")

        print("LightEngine self-tests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
