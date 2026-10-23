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

    /// Samples the main display, or only `region` when given (normalized 0–1, top-left origin).
    @available(macOS 14.0, *)
    public func sample(region: CGRect? = nil) async throws -> ScreenRGB {
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
        if let region = region?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), !region.isEmpty {
            let source = CGRect(
                x: region.minX * CGFloat(display.width),
                y: region.minY * CGFloat(display.height),
                width: region.width * CGFloat(display.width),
                height: region.height * CGFloat(display.height)
            )
            configuration.sourceRect = source
            // Keep the 96×54 budget but match the region's shape so nothing is padded.
            let aspect = source.width / max(source.height, 1)
            if aspect >= 96.0 / 54.0 {
                configuration.height = max(8, Int((96 / aspect).rounded()))
            } else {
                configuration.width = max(8, Int((54 * aspect).rounded()))
            }
        }

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

    /// Video-oriented average of 8-bit premultiplied RGBA rows. Transparent pixels are skipped.
    /// - Letterbox/pillarbox bars (near-black edge rows and columns) are trimmed.
    /// - Near-white pixels in the bottom quarter (subtitles) are skipped.
    /// - Pixels near the center count up to twice as much as the corners.
    /// A frame that is entirely black, white, or subtitle-like falls back to its plain average.
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

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int)? {
            let offset = y * bytesPerRow + x * 4
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0 else { return nil }
            return (
                min(255, Int(pixels[offset]) * 255 / alpha),
                min(255, Int(pixels[offset + 1]) * 255 / alpha),
                min(255, Int(pixels[offset + 2]) * 255 / alpha)
            )
        }
        func isBar(_ p: (r: Int, g: Int, b: Int)?) -> Bool {
            guard let p else { return true }
            return max(p.r, p.g, p.b) < 16
        }

        // Trim letterbox rows and pillarbox columns while they are entirely near-black.
        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < bottom, (left...right).allSatisfy({ isBar(pixel($0, top)) }) { top += 1 }
        while bottom > top, (left...right).allSatisfy({ isBar(pixel($0, bottom)) }) { bottom -= 1 }
        while left < right, (top...bottom).allSatisfy({ isBar(pixel(left, $0)) }) { left += 1 }
        while right > left, (top...bottom).allSatisfy({ isBar(pixel(right, $0)) }) { right -= 1 }

        let subtitleTop = bottom - (bottom - top + 1) / 4 + 1
        var content = (r: 0.0, g: 0.0, b: 0.0, w: 0.0)
        var all = (r: 0.0, g: 0.0, b: 0.0, w: 0.0)
        for y in top...bottom {
            for x in left...right {
                guard let p = pixel(x, y) else { continue }
                let nx = (Double(x - left) + 0.5) / Double(right - left + 1) * 2 - 1
                let ny = (Double(y - top) + 0.5) / Double(bottom - top + 1) * 2 - 1
                let weight = 2 - min(1, (nx * nx + ny * ny).squareRoot() / 2.0.squareRoot())
                all = (all.r + Double(p.r) * weight, all.g + Double(p.g) * weight, all.b + Double(p.b) * weight, all.w + weight)
                if y >= subtitleTop, min(p.r, p.g, p.b) > 200 { continue }
                content = (content.r + Double(p.r) * weight, content.g + Double(p.g) * weight, content.b + Double(p.b) * weight, content.w + weight)
            }
        }
        let chosen = content.w > 0 ? content : all
        guard chosen.w > 0 else { return nil }
        return ScreenRGB(
            red: UInt8((chosen.r / chosen.w).rounded()),
            green: UInt8((chosen.g / chosen.w).rounded()),
            blue: UInt8((chosen.b / chosen.w).rounded())
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
