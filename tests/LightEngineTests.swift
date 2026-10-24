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

        // Color temperature and overall brightness.
        let gray200 = ScreenRGB(red: 200, green: 200, blue: 200)
        expect(LightEngine.grade(gray200, vibrance: 0, minBrightness: 0, warmth: 0, brightness: 1) == [200, 200, 200],
               "Neutral temperature and full brightness must not change colors.")
        let warm = LightEngine.grade(gray200, vibrance: 0, minBrightness: 0, warmth: 1)
        expect(warm[0] == 200 && warm[1] < 200 && warm[2] < warm[1], "Warm must keep red and dim blue most: \(warm)")
        let cool = LightEngine.grade(gray200, vibrance: 0, minBrightness: 0, warmth: -1)
        expect(cool[2] == 200 && cool[1] < 200 && cool[0] < cool[1], "Cool must keep blue and dim red most: \(cool)")
        expect(LightEngine.grade(gray200, vibrance: 0, minBrightness: 0, brightness: 0.5) == [100, 100, 100], "Brightness must scale output.")
        expect(LightEngine.grade(ScreenRGB(red: 0, green: 0, blue: 0), vibrance: 0, minBrightness: 0.2, brightness: 0.5) == [25.5, 25.5, 25.5],
               "Brightness applies after the floor.")
        var dimmed = LightEngine(fadeTime: 0, breathing: false)
        dimmed.brightness = 0.5
        dimmed.setTarget(gray200)
        expect(dimmed.step(dt: 0.05) == ScreenRGB(red: 100, green: 100, blue: 100), "Engine must apply brightness.")

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

        // Blink style: lit right after each beat, dark for the rest of it, full again in silence.
        var blink = LightEngine(fadeTime: 0.6, breathing: false)
        blink.beatSync = true
        blink.beatStyle = .blink
        blink.setTarget(white)
        var litAfterBeat = 255, darkLate = 0
        for frameIndex in 0..<80 { // 4 s at 120 BPM
            if frameIndex % 10 == 0 { blink.beat(strength: 0.5, bpm: 120) }
            let frame = blink.step(dt: 0.05)!
            guard frameIndex >= 40 else { continue }
            if frameIndex % 10 < 4 { litAfterBeat = min(litAfterBeat, Int(frame.red)) }
            if frameIndex % 10 >= 6 { darkLate = max(darkLate, Int(frame.red)) }
        }
        expect(litAfterBeat == 200, "Blink must light fully on the beat: \(litAfterBeat)")
        expect(darkLate <= 10, "Blink must go dark between beats: \(darkLate)")
        for _ in 0..<100 { _ = blink.step(dt: 0.05) }
        expect(blink.step(dt: 0.05)! == white, "Silence must bring a blinking lamp back to full.")

        // Color style: beats step through screen color, similar, screen color, opposite; silence restores it.
        var stepping = LightEngine(fadeTime: 0, breathing: false)
        stepping.beatSync = true
        stepping.beatStyle = .colors
        stepping.setTarget(red)
        var onBeats: [ScreenRGB] = []
        for frameIndex in 0..<80 {
            if frameIndex % 10 == 0 { stepping.beat(strength: 1) }
            let frame = stepping.step(dt: 0.05)!
            if frameIndex % 10 == 5 { onBeats.append(frame) }
        }
        let orange = ScreenRGB(red: 255, green: 128, blue: 0), cyan = ScreenRGB(red: 0, green: 255, blue: 255)
        expect(onBeats == [red, orange, red, cyan, red, orange, red, cyan], "Colors must cycle per beat: \(onBeats)")
        for _ in 0..<50 { _ = stepping.step(dt: 0.05) }
        expect(stepping.step(dt: 0.05)! == red, "Silence must return to the screen color.")
        stepping.beat(strength: 1)
        expect(stepping.step(dt: 0.05)! == red, "Music after a pause must start again from the screen color.")
        expect(LightEngine.rotateHue([90, 90, 90], degrees: 180) == [90, 90, 90], "Grays have no hue to turn.")
        expect(LightEngine.rotateHue([200, 50, 50], degrees: 360) == [200, 50, 50], "A full turn must keep the color.")

        // Auto style: tempo picks blink, colors or breathe, and holds its pick near the lines.
        expect(LightEngine.autoStyle(tempo: 150, current: .flash) == .blink, "Fast songs must blink.")
        expect(LightEngine.autoStyle(tempo: 110, current: .flash) == .colors, "Mid-tempo songs must step colors.")
        expect(LightEngine.autoStyle(tempo: 70, current: .flash) == .breathe, "Slow songs must breathe.")
        expect(LightEngine.autoStyle(tempo: 128, current: .blink) == .blink, "Blink must hold just under the fast line.")
        expect(LightEngine.autoStyle(tempo: 132, current: .colors) == .colors, "Colors must hold just over the fast line.")
        expect(LightEngine.autoStyle(tempo: 88, current: .colors) == .colors, "Colors must hold just under the slow line.")
        expect(LightEngine.autoStyle(tempo: 92, current: .breathe) == .breathe, "Breathe must hold just over the slow line.")
        func autoRun(bpm: Double) -> (style: BeatStyle?, frames: [Int]) {
            var engine = LightEngine(fadeTime: 0, breathing: false)
            engine.beatSync = true
            engine.beatStyle = .auto
            engine.setTarget(white)
            let interval = 60 / bpm
            var nextBeat = 0.0, time = 0.0, frames: [Int] = []
            for _ in 0..<160 { // 8 s
                if time >= nextBeat - 1e-9 {
                    engine.beat(strength: 1, bpm: bpm)
                    nextBeat += interval
                }
                frames.append(Int(engine.step(dt: 0.05)!.red))
                time += 0.05
            }
            return (engine.activeBeatStyle, Array(frames.suffix(80)))
        }
        let fastRun = autoRun(bpm: 150)
        expect(fastRun.style == .blink && fastRun.frames.min()! <= 10, "Auto must blink a fast song: \(fastRun)")
        let midRun = autoRun(bpm: 110)
        expect(midRun.style == .colors && midRun.frames.allSatisfy { $0 == 200 }, "Auto must step colors at full brightness mid-tempo: \(midRun)")
        let slowRun = autoRun(bpm: 60) // A beat every 20 frames; one breath every 40.
        expect(slowRun.style == .breathe, "Auto must breathe a slow song: \(String(describing: slowRun.style))")
        expect(slowRun.frames.max()! >= 195 && (95...110).contains(slowRun.frames.min()!),
               "The slow-song breath must span full to about half: \(slowRun.frames)")
        let steps = zip(slowRun.frames, slowRun.frames.dropFirst()).map { abs($0 - $1) }
        expect(steps.max()! <= 15, "The slow-song breath must change smoothly: \(steps.max()!)")
        var unknownTempo = LightEngine(fadeTime: 0, breathing: false)
        unknownTempo.beatSync = true
        unknownTempo.beatStyle = .auto
        unknownTempo.setTarget(white)
        for index in 0..<40 {
            if index % 10 == 0 { unknownTempo.beat(strength: 1) }
            _ = unknownTempo.step(dt: 0.05)
        }
        expect(unknownTempo.activeBeatStyle == .flash, "Auto must flash until a tempo is known.")
        expect(BeatStyle.choices.map(\.name) == ["自動", "加亮", "亮滅", "換色"], "The apps offer auto first and hide breathe.")

        // Tempo: fast songs fade quicker than slow ones; the tempo is reported only while beats arrive.
        func fadeProgress(bpm: Double) -> Int {
            var engine = LightEngine(fadeTime: 0.6, breathing: false)
            engine.sceneCuts = false
            engine.beatSync = true
            engine.setTarget(ScreenRGB(red: 255, green: 0, blue: 0))
            for index in 0..<40 { // 2 s of beats so beat sync is fully engaged
                if index % 5 == 0 { engine.beat(strength: 1, bpm: bpm) }
                _ = engine.step(dt: 0.05)
            }
            expect(engine.bpm == bpm, "The engine must report the tempo while beats arrive: \(String(describing: engine.bpm))")
            engine.setTarget(ScreenRGB(red: 0, green: 0, blue: 255))
            engine.beat(strength: 1, bpm: bpm)
            var frame = engine.step(dt: 0.05)!
            for _ in 0..<3 { frame = engine.step(dt: 0.05)! }
            return Int(frame.blue)
        }
        let fast = fadeProgress(bpm: 170), slow = fadeProgress(bpm: 75)
        expect(fast > slow + 20, "A fast song must fade quicker than a slow one: fast \(fast), slow \(slow)")
        var tempoEngine = LightEngine(fadeTime: 0.6, breathing: false)
        tempoEngine.beatSync = true
        tempoEngine.setTarget(white)
        for index in 0..<40 {
            if index % 10 == 0 { tempoEngine.beat(strength: 1, bpm: 120) }
            _ = tempoEngine.step(dt: 0.05)
        }
        expect(tempoEngine.bpm == 120, "Tempo must be reported while music plays.")
        for _ in 0..<100 { _ = tempoEngine.step(dt: 0.05) }
        expect(tempoEngine.bpm == nil, "Tempo must clear after silence.")

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
        expect(detector.bpm.map { abs($0 - 120) <= 4 } ?? false, "Expected ~120 BPM, got \(String(describing: detector.bpm))")
        for (tempo, label) in [(150.0, "150"), (90.0, "90")] {
            var tempoDetector = BeatDetector(sampleRate: rate)
            let period = 60 / tempo
            let samples = (0..<Int(rate * 6)).map { index -> Float in
                let t = Double(index) / rate
                let inKick = t.truncatingRemainder(dividingBy: period) < 0.08
                return (inKick ? Float(0.8 * sin(2 * Double.pi * 60 * t)) : 0) + Float.random(in: -0.002...0.002)
            }
            _ = tempoDetector.process(samples)
            expect(tempoDetector.bpm.map { abs($0 - tempo) <= 5 } ?? false,
                   "Expected ~\(label) BPM, got \(String(describing: tempoDetector.bpm))")
        }
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
