import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct ScreenRGB: Equatable, Sendable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var description: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

public struct ScreenColorSampler {
    public init() {}

    /// Returns immediately when already authorized; otherwise asks macOS once.
    public static func requestPermissionIfNeeded() -> Bool {
        ScreenCapturePermission.ensureAccess(
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        )
    }

    @available(macOS 14.0, *)
    public func sample() async throws -> ScreenRGB {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenColorError.screenCapturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            throw ScreenColorError.noDisplaysAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 96
        configuration.height = 54
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true

        // ScreenCaptureKit returns SDR screenshots as BGRA; Core Graphics normalizes them to RGBA here.
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var rgba = Data(repeating: 0, count: bytesPerRow * height)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered, let color = Self.dominantColor(
            pixels: Array(rgba),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            throw ScreenColorError.couldNotReadScreenshot
        }
        return color
    }

    /// Reads 8-bit RGBA rows. Returns nil for malformed or empty buffers.
    public static func dominantColor(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> ScreenRGB? {
        guard width > 0, height > 0, width <= Int.max / 4 else { return nil }
        let rowBytes = width * 4
        guard bytesPerRow >= rowBytes,
              height - 1 <= (Int.max - rowBytes) / bytesPerRow else { return nil }
        let requiredBytes = (height - 1) * bytesPerRow + rowBytes
        guard pixels.count >= requiredBytes else { return nil }

        var counts = [Int](repeating: 0, count: 4096)
        var scores = [Double](repeating: 0, count: 4096)
        var redSums = [Int](repeating: 0, count: 4096)
        var greenSums = [Int](repeating: 0, count: 4096)
        var blueSums = [Int](repeating: 0, count: 4096)
        var chromaticPixels = 0

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let offset = row + x * 4
                let alpha = Int(pixels[offset + 3])
                guard alpha > 0 else { continue }
                let red = min(255, Int(pixels[offset]) * 255 / alpha)
                let green = min(255, Int(pixels[offset + 1]) * 255 / alpha)
                let blue = min(255, Int(pixels[offset + 2]) * 255 / alpha)
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let saturation = maximum == 0 ? 0.0 : Double(maximum - minimum) / Double(maximum)
                let brightness = Double(maximum) / 255.0
                if saturation > 0.08 { chromaticPixels += 1 }

                let bin = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
                counts[bin] += 1
                redSums[bin] += red
                greenSums[bin] += green
                blueSums[bin] += blue
                // Favor bright, saturated screen colors while keeping grayscale pixels count-weighted.
                scores[bin] += 1.0 + 2.5 * saturation * brightness
            }
        }

        guard let bestBin = counts.indices.max(by: { left, right in
            let leftScore = chromaticPixels == 0 ? Double(counts[left]) : scores[left]
            let rightScore = chromaticPixels == 0 ? Double(counts[right]) : scores[right]
            return leftScore < rightScore
        }), counts[bestBin] > 0 else {
            return nil
        }
        let count = counts[bestBin]
        return ScreenRGB(
            red: UInt8((redSums[bestBin] + count / 2) / count),
            green: UInt8((greenSums[bestBin] + count / 2) / count),
            blue: UInt8((blueSums[bestBin] + count / 2) / count)
        )
    }
}

public enum ScreenColorError: Error, LocalizedError {
    case screenCapturePermissionDenied
    case noDisplaysAvailable
    case couldNotReadScreenshot

    public var errorDescription: String? {
        switch self {
        case .screenCapturePermissionDenied:
            return "需要螢幕錄製權限。請到「系統設定」的「隱私權與安全性」允許目前使用的終端機進行螢幕錄製，然後重新啟動終端機再試。"
        case .noDisplaysAvailable:
            return "No screen displays are available to capture."
        case .couldNotReadScreenshot:
            return "Could not read pixels from the screen capture."
        }
    }
}

/// Small injectable decision point so permission ordering can be tested without showing TCC UI.
public enum ScreenCapturePermission {
    public static func ensureAccess(
        preflight: () -> Bool,
        request: () -> Bool
    ) -> Bool {
        if preflight() { return true }
        guard request() else { return false }
        return preflight()
    }
}
