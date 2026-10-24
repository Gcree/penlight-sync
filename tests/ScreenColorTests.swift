import Foundation

@main
struct ScreenColorTest {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().contains("--capture") {
            let rgb = try await ScreenColorSampler().sample()
            print(rgb)
            return
        }

        testSolidColor(ScreenRGB(red: 235, green: 15, blue: 10))
        testSolidColor(ScreenRGB(red: 10, green: 220, blue: 30))
        testSolidColor(ScreenRGB(red: 12, green: 18, blue: 240))
        testSolidColor(ScreenRGB(red: 255, green: 255, blue: 255))
        testSolidColor(ScreenRGB(red: 0, green: 0, blue: 0))
        testSolidColor(ScreenRGB(red: 128, green: 128, blue: 128))

        let redBlue: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        guard ScreenColorSampler.averageColor(
            pixels: redBlue, width: 2, height: 1, bytesPerRow: 8
        ) == ScreenRGB(red: 128, green: 0, blue: 128) else {
            fatalError("Mixed red and blue pixels must average to purple.")
        }

        let paddedRows: [UInt8] = [
            240, 8, 10, 255, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE, 0xEE,
            240, 8, 10, 255, 0, 0, 0, 0, 0xDD, 0xDD, 0xDD, 0xDD,
        ]
        guard ScreenColorSampler.averageColor(
            pixels: paddedRows, width: 2, height: 2, bytesPerRow: 12
        ) == ScreenRGB(red: 240, green: 8, blue: 10) else {
            fatalError("Padded rows or transparent pixels were read incorrectly.")
        }
        guard ScreenColorSampler.averageColor(
            pixels: [0, 0, 0, 255], width: 2, height: 1, bytesPerRow: 8
        ) == nil, ScreenColorSampler.averageColor(
            pixels: [0, 0, 0, 0], width: 1, height: 1, bytesPerRow: 4
        ) == nil else {
            fatalError("Malformed buffers must return nil.")
        }

        // A 16x9 frame: black letterbox rows, red picture, white subtitle text near the bottom.
        let red = ScreenRGB(red: 220, green: 30, blue: 20)
        let white = ScreenRGB(red: 255, green: 255, blue: 255)
        let black = ScreenRGB(red: 0, green: 0, blue: 0)
        var frame = Self.frame(width: 16, height: 9, fill: black)
        for y in 2...6 { for x in 0..<16 { Self.set(&frame, x, y, 16, red) } }
        for x in 5...10 { Self.set(&frame, x, 6, 16, white) }
        guard ScreenColorSampler.averageColor(pixels: frame, width: 16, height: 9, bytesPerRow: 64) == red else {
            fatalError("Letterbox bars and subtitles must not dilute the picture color.")
        }
        // Pillarbox columns are trimmed too.
        var pillar = Self.frame(width: 16, height: 9, fill: black)
        for y in 0..<9 { for x in 3...12 { Self.set(&pillar, x, y, 16, red) } }
        guard ScreenColorSampler.averageColor(pixels: pillar, width: 16, height: 9, bytesPerRow: 64) == red else {
            fatalError("Pillarbox bars must be trimmed.")
        }
        // Entirely black or white frames stay black or white.
        for solid in [black, white] {
            let plain = Self.frame(width: 16, height: 9, fill: solid)
            guard ScreenColorSampler.averageColor(pixels: plain, width: 16, height: 9, bytesPerRow: 64) == solid else {
                fatalError("A solid \(solid) frame must stay \(solid).")
            }
        }
        // White above the subtitle zone is picture content, not a subtitle.
        var sky = Self.frame(width: 16, height: 8, fill: white)
        for y in 6..<8 { for x in 0..<16 { Self.set(&sky, x, y, 16, ScreenRGB(red: 0, green: 0, blue: 200)) } }
        guard let skyColor = ScreenColorSampler.averageColor(pixels: sky, width: 16, height: 8, bytesPerRow: 64),
              skyColor.red > 150 else {
            fatalError("Bright picture areas above the subtitle zone must still count.")
        }
        // Center pixels outweigh the edges.
        var centered = Self.frame(width: 9, height: 9, fill: ScreenRGB(red: 0, green: 0, blue: 255))
        for y in 3...5 { for x in 3...5 { Self.set(&centered, x, y, 9, ScreenRGB(red: 255, green: 0, blue: 0)) } }
        guard let centerColor = ScreenColorSampler.averageColor(pixels: centered, width: 9, height: 9, bytesPerRow: 36),
              Int(centerColor.red) >= 255 * 9 / 81 + 5 else { // Unweighted average would be 28.
            fatalError("Center weighting must favor the middle of the frame.")
        }

        print("ScreenColorSampler self-tests passed")
    }

    private static func frame(width: Int, height: Int, fill: ScreenRGB) -> [UInt8] {
        Array((0..<(width * height)).map { _ in [fill.red, fill.green, fill.blue, 255] }.joined())
    }

    private static func set(_ pixels: inout [UInt8], _ x: Int, _ y: Int, _ width: Int, _ color: ScreenRGB) {
        let offset = (y * width + x) * 4
        pixels[offset] = color.red
        pixels[offset + 1] = color.green
        pixels[offset + 2] = color.blue
        pixels[offset + 3] = 255
    }

    private static func testSolidColor(_ expected: ScreenRGB) {
        let bytes = [expected.red, expected.green, expected.blue, 255]
        guard ScreenColorSampler.averageColor(
            pixels: bytes, width: 1, height: 1, bytesPerRow: 4
        ) == expected else {
            fatalError("Expected \(expected) from a solid-color pixel.")
        }
        // The continuous screen stream delivers BGRA.
        guard ScreenColorSampler.averageColor(
            pixels: [expected.blue, expected.green, expected.red, 255], width: 1, height: 1, bytesPerRow: 4, bgra: true
        ) == expected else {
            fatalError("Expected \(expected) from a solid-color BGRA pixel.")
        }
    }
}
