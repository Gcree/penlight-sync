import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Continuous low-resolution capture of the main display (or a region of it) with ScreenCaptureKit.
/// ScreenCaptureKit only delivers a frame when the screen content changes, at up to `frameRate` per second.
/// Each frame's average color and capture latency (display time → color ready, in ms) are reported on the main queue.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    static let frameRate = 30

    private let onColor: (ScreenRGB, Double) -> Void
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "penlight.screen")
    private let ticksToMilliseconds: Double
    private var stream: SCStream?
    private var display: SCDisplay?

    init(onColor: @escaping (ScreenRGB, Double) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onColor = onColor
        self.onFailure = onFailure
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToMilliseconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    func start(region: CGRect?) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenColorError.screenCapturePermissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            throw ScreenColorError.noDisplaysAvailable
        }
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: Self.configuration(display: display, region: region),
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.display = display
        self.stream = stream
    }

    /// Switches the sampled area without restarting the stream.
    func update(region: CGRect?) {
        guard let stream, let display else { return }
        stream.updateConfiguration(Self.configuration(display: display, region: region)) { _ in }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    private static func configuration(display: SCDisplay, region: CGRect?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        ScreenColorSampler.configure(configuration, display: display, region: region)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 3
        configuration.showsCursor = false
        return configuration
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
        guard let color = ScreenColorSampler.averageColor(
            pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow, bgra: true
        ) else { return }

        let displayTime = info[.displayTime] as? UInt64
        DispatchQueue.main.async { [onColor, ticksToMilliseconds] in
            // Measured on arrival at the main queue, where the color reaches the light engine.
            let now = mach_absolute_time()
            let latency = displayTime.map { now > $0 ? Double(now - $0) * ticksToMilliseconds : 0 } ?? 0
            onColor(color, latency)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onFailure(error)
        }
    }
}
