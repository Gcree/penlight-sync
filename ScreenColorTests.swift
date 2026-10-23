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

        let redBlue = [UInt8](repeating: 0, count: 8)
        var mixed = redBlue
        mixed[0...3] = [255, 0, 0, 255]
        mixed[4...7] = [0, 0, 255, 255]
        guard let selected = ScreenColorSampler.dominantColor(
            pixels: mixed, width: 2, height: 1, bytesPerRow: 8
        ), max(selected.red, selected.blue) > 200, selected.green < 16,
           !(selected.red > 100 && selected.blue > 100) else {
            fatalError("Mixed red and blue pixels must select a real dominant color, not average purple.")
        }

        let paddedRows: [UInt8] = [
            240, 8, 10, 255, 0, 0, 0, 0, 0xEE, 0xEE, 0xEE, 0xEE,
            240, 8, 10, 255, 0, 0, 0, 0, 0xDD, 0xDD, 0xDD, 0xDD,
        ]
        guard ScreenColorSampler.dominantColor(
            pixels: paddedRows, width: 2, height: 2, bytesPerRow: 12
        ) == ScreenRGB(red: 240, green: 8, blue: 10) else {
            fatalError("Padded rows or transparent pixels were read incorrectly.")
        }
        guard ScreenColorSampler.dominantColor(
            pixels: [0, 0, 0, 255], width: 2, height: 1, bytesPerRow: 8
        ) == nil else {
            fatalError("Malformed buffers must return nil.")
        }

        print("ScreenColorSampler self-tests passed")
    }

    private static func testSolidColor(_ expected: ScreenRGB) {
        let bytes = [expected.red, expected.green, expected.blue, 255]
        guard ScreenColorSampler.dominantColor(
            pixels: bytes, width: 1, height: 1, bytesPerRow: 4
        ) == expected else {
            fatalError("Expected \(expected) from a solid-color pixel.")
        }
    }
}
