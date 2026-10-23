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

        guard rendered, let color = Self.averageColor(
            pixels: Array(rgba),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        ) else {
            throw ScreenColorError.couldNotReadScreenshot
        }
        return color
    }

    /// Average color of 8-bit premultiplied RGBA rows. Transparent pixels are skipped.
    /// Returns nil for malformed or fully transparent buffers.
    public static func averageColor(
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

        var redSum = 0, greenSum = 0, blueSum = 0, count = 0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let offset = row + x * 4
                let alpha = Int(pixels[offset + 3])
                guard alpha > 0 else { continue }
                redSum += min(255, Int(pixels[offset]) * 255 / alpha)
                greenSum += min(255, Int(pixels[offset + 1]) * 255 / alpha)
                blueSum += min(255, Int(pixels[offset + 2]) * 255 / alpha)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return ScreenRGB(
            red: UInt8((redSum + count / 2) / count),
            green: UInt8((greenSum + count / 2) / count),
            blue: UInt8((blueSum + count / 2) / count)
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
