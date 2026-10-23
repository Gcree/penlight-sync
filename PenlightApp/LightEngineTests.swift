import Foundation

@main
struct LightEngineTest {
    static func main() {
        let red = ScreenRGB(red: 255, green: 0, blue: 0)
        let blue = ScreenRGB(red: 0, green: 0, blue: 255)

        var engine = LightEngine(fadeTime: 0.6, breathing: false)
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

        print("LightEngine self-tests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
