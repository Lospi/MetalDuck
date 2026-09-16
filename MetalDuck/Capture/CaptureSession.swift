//
//  CaptureSession.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia

@available(macOS 12.3, *)
class CaptureSession {
    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private var streamOutput: StreamOutput?
    private let settings: CaptureSettings

    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?

    init(settings: CaptureSettings) {
        self.settings = settings
    }

    func startCapture() async throws -> AsyncThrowingStream<CapturedFrame, Error> {
        guard let contentFilter = await settings.contentFilter() else {
            throw CaptureError.invalidContentFilter
        }

        let streamConfig: SCStreamConfiguration
        if #available(macOS 15.0, *), let preset = settings.selectedDynamicRangePreset?.scDynamicRangePreset {
            streamConfig = SCStreamConfiguration(preset: preset)
        } else {
            streamConfig = SCStreamConfiguration()
        }

        streamConfig.width = Int(settings.captureResolution.width)
        streamConfig.height = Int(settings.captureResolution.height)
        streamConfig.minimumFrameInterval = CaptureSettings.frameInterval(for: settings.frameRate)
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = false
        streamConfig.capturesAudio = false
        self.streamConfig = streamConfig

        let (frameStream, continuation) = AsyncThrowingStream.makeStream(of: CapturedFrame.self)
        self.continuation = continuation

        streamOutput = StreamOutput(continuation: continuation)

        stream = SCStream(filter: contentFilter, configuration: streamConfig, delegate: nil)

        try stream?.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.metalduck.capture", qos: .userInitiated)
        )

        try await stream?.startCapture()

        return frameStream
    }

    func updateFrameRate(_ frameRate: Int) async throws {
        guard let stream, let streamConfig else { return }

        streamConfig.minimumFrameInterval = CaptureSettings.frameInterval(for: frameRate)
        try await stream.updateConfiguration(streamConfig)
    }

    func updateContentFilter(_ filter: SCContentFilter) async {
        do {
            try await stream?.updateContentFilter(filter)
        } catch {
            print("Error updating content filter: \(error.localizedDescription)")
        }
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            print("Error stopping capture: \(error.localizedDescription)")
        }
        continuation?.finish()
        continuation = nil
        stream = nil
        streamConfig = nil
        streamOutput = nil
    }

    enum CaptureError: Error {
        case invalidContentFilter
        case streamCreationFailed
    }
}

@available(macOS 12.3, *)
private class StreamOutput: NSObject, SCStreamOutput {
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation

    init(continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let frame = CapturedFrame.from(sampleBuffer: sampleBuffer) else { return }
        continuation.yield(frame)
    }
}
