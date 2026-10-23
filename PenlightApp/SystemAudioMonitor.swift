import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Listens to system audio output with ScreenCaptureKit (same Screen & System Audio Recording permission
/// as screen sampling) and reports detected beats (strength, current tempo) on the main queue. Audio is analyzed in memory only.
final class SystemAudioMonitor: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let sampleRate = 48_000

    private let onBeat: (Double, Double?) -> Void
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "penlight.audio")
    private var detector = BeatDetector(sampleRate: Double(sampleRate))
    private var stream: SCStream?

    init(onBeat: @escaping (Double, Double?) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onBeat = onBeat
        self.onFailure = onFailure
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            throw ScreenColorError.noDisplaysAvailable
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = 1
        // A stream always carries video; keep it tiny and slow since only audio is used.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var beats: [Double] = []
        var bpm: Double?
        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            // ScreenCaptureKit delivers 32-bit float PCM; with one channel the first buffer holds all samples.
            guard let buffer = bufferList.first, let data = buffer.mData else { return }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            beats = detector.process(samples)
            bpm = detector.bpm
        }
        guard !beats.isEmpty else { return }
        DispatchQueue.main.async { [onBeat] in beats.forEach { onBeat($0, bpm) } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onFailure(error)
        }
    }
}
