//
//  RealTimeFrameInterpolation.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 08/11/25.
//
//  Real-time frame interpolation using VTLowLatencyFrameInterpolation.
//  This actor processes live CVPixelBuffer frames (previous + current)
//  and produces one or more interpolated frames between them.
//

import Foundation
import CoreVideo
import CoreMedia
import AVFoundation
@preconcurrency import VideoToolbox

/// Default timeout for model loading (seconds). If the model hasn't produced
/// a frame by this time, it's considered unsupported at this resolution.
private nonisolated let kModelLoadTimeoutSeconds: Double = 5.0

@available(macOS 14.0, *)
actor RealTimeFrameInterpolation {

    // MARK: - Configuration

    let numFrames: Int
    /// Dimensions the processor was configured with (may be capped)
    let processingDimensions: CMVideoDimensions
    /// Output dimensions (may be 2x processingDimensions if spatial upscale is on)
    let outputDimensions: CMVideoDimensions
    /// Original input dimensions (from capture)
    let originalDimensions: CMVideoDimensions
    let needsDownscale: Bool
    let spatialScaleFactor: Int
    let spatialUpscaleEnabled: Bool

    let configuration: VTLowLatencyFrameInterpolationConfiguration
    let pixelBufferPool: CVPixelBufferPool          // destination buffers
    let sourcePixelBufferPool: CVPixelBufferPool    // source-compatible buffers
    let sourcePixelBufferAttributes: [String: Any]
    nonisolated(unsafe) let frameProcessor = VTFrameProcessor()

    // MARK: - State

    private var sessionStarted = false
    private var previousFrame: (buffer: CVPixelBuffer, timestamp: CMTime)?
    private var transferSession: VTPixelTransferSession?
    private(set) var modelReady = false
    private(set) var modelFailed = false
    private var passthroughCount = 0
    private var firstFrameTime: Date?

    // MARK: - Init

    init(numFrames: Int, inputDimensions: CMVideoDimensions, maxWidth: Int, maxHeight: Int, spatialUpscale: Bool = false) throws {
        // When spatial upscale is enabled, only 1 interpolated frame is supported
        self.spatialUpscaleEnabled = spatialUpscale
        self.spatialScaleFactor = spatialUpscale ? 2 : 1
        self.numFrames = spatialUpscale ? 1 : min(3, numFrames)
        self.originalDimensions = inputDimensions

        var width = Int(inputDimensions.width)
        var height = Int(inputDimensions.height)

        // Cap to user-selected max resolution
        if width > maxWidth || height > maxHeight {
            let scaleX = Double(maxWidth) / Double(width)
            let scaleY = Double(maxHeight) / Double(height)
            let scale = min(scaleX, scaleY)
            width = Int(Double(width) * scale) & ~1
            height = Int(Double(height) * scale) & ~1
            self.needsDownscale = true
            print("   📐 Capping interpolation resolution: \(Int(inputDimensions.width))x\(Int(inputDimensions.height)) → \(width)x\(height)")
        } else {
            self.needsDownscale = false
        }

        self.processingDimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
        self.outputDimensions = CMVideoDimensions(
            width: Int32(width * spatialScaleFactor),
            height: Int32(height * spatialScaleFactor)
        )

        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw Fault.unsupportedProcessor
        }

        let configuration: VTLowLatencyFrameInterpolationConfiguration?
        if spatialUpscale {
            // Separate init for spatial+temporal: gives 1 interpolated frame + 2x upscale
            configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                spatialScaleFactor: 2
            )
            print("   🔬 Spatial upscale enabled: \(width)x\(height) → \(width*2)x\(height*2)")
        } else {
            configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: self.numFrames
            )
        }

        guard let configuration else {
            throw Fault.failedToCreateConfiguration
        }
        self.configuration = configuration

        let srcAttrs = configuration.sourcePixelBufferAttributes
        let dstAttrs = configuration.destinationPixelBufferAttributes
        print("   📊 Source attributes: \(Self.describeAttributes(srcAttrs))")
        print("   📊 Destination attributes: \(Self.describeAttributes(dstAttrs))")

        self.pixelBufferPool = try Self.createPixelBufferPool(for: dstAttrs)
        self.sourcePixelBufferAttributes = srcAttrs
        self.sourcePixelBufferPool = try Self.createPixelBufferPool(for: srcAttrs)

        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                        pixelTransferSessionOut: &session) == noErr {
            self.transferSession = session
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !sessionStarted else { return }
        try frameProcessor.startSession(configuration: configuration)
        sessionStarted = true
    }

    func stop() {
        guard sessionStarted else { return }
        frameProcessor.endSession()
        sessionStarted = false
        previousFrame = nil
        modelReady = false
        passthroughCount = 0
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
            transferSession = nil
        }
    }

    // MARK: - Processing

    func process(currentBuffer: CVPixelBuffer, currentTimestamp: CMTime) async throws -> [CVPixelBuffer] {
        guard sessionStarted else {
            throw Fault.sessionNotStarted
        }
        guard !modelFailed else {
            return [currentBuffer]
        }

        // Downscale + verify source buffer
        let compatibleBuffer = prepareSourceBuffer(currentBuffer)

        // Need previous frame for interpolation
        guard let previous = previousFrame else {
            previousFrame = (buffer: compatibleBuffer, timestamp: currentTimestamp)
            return [currentBuffer]
        }

        guard let sourceFrame = VTFrameProcessorFrame(buffer: previous.buffer, presentationTimeStamp: previous.timestamp),
              let nextFrame = VTFrameProcessorFrame(buffer: compatibleBuffer, presentationTimeStamp: currentTimestamp) else {
            throw Fault.failedToCreateFrames
        }

        let intervals = interpolationIntervals()
        let destinationFrames = try framesBetween(firstPTS: previous.timestamp,
                                                  lastPTS: currentTimestamp,
                                                  interpolationIntervals: intervals)

        let intervalArray = intervals.map { Float($0) }
        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: nextFrame,
            previousFrame: sourceFrame,
            interpolationPhase: intervalArray,
            destinationFrames: destinationFrames
        ) else {
            throw Fault.failedToCreateParameters
        }

        // Update previous for next call (before processing)
        previousFrame = (buffer: compatibleBuffer, timestamp: currentTimestamp)

        // Process — NO retries with startSession
        var outputs: [CVPixelBuffer] = []
        do {
            for try await readOnlyFrame in frameProcessor.process(parameters: parameters) {
                let processedBuffer = try readOnlyFrame.frame.withUnsafeBuffer { readOnlyPixelBuffer -> CVPixelBuffer in
                    let output = try Self.createPixelBuffer(from: pixelBufferPool)

                    var copySession: VTPixelTransferSession?
                    guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                      pixelTransferSessionOut: &copySession) == noErr,
                          let session = copySession
                    else {
                        throw Fault.failedToCreateOutputBuffer
                    }

                    let status = VTPixelTransferSessionTransferImage(session, from: readOnlyPixelBuffer, to: output)
                    VTPixelTransferSessionInvalidate(session)
                    guard status == noErr else {
                        throw Fault.failedToTransferImage
                    }
                    return output
                }
                outputs.append(processedBuffer)
            }

            if !outputs.isEmpty && !modelReady {
                modelReady = true
                print("   ✅ Frame interpolation model is now ready!")
                passthroughCount = 0
            }
        } catch {
            let ns = error as NSError
            if ns.domain == "com.apple.VideoProcessing" && ns.code == -12911 {
                passthroughCount += 1
                if firstFrameTime == nil { firstFrameTime = Date() }

                // Check timeout
                if let startTime = firstFrameTime,
                   Date().timeIntervalSince(startTime) > kModelLoadTimeoutSeconds {
                    modelFailed = true
                    print("   ❌ Model failed to load after \(Int(kModelLoadTimeoutSeconds))s — resolution unsupported on this device")
                    return [currentBuffer]
                }

                if passthroughCount <= 3 || passthroughCount % 60 == 0 {
                    print("   ℹ️ Frame processor model loading (frame \(passthroughCount)), passing through")
                }
                return [currentBuffer]
            }
            print("   ❌ Frame interpolation error: domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
            throw error
        }

        if outputs.isEmpty {
            return [currentBuffer]
        }
        return outputs
    }

    // MARK: - Source Buffer Preparation

    private func prepareSourceBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard let session = transferSession else { return pixelBuffer }

        let inputWidth = CVPixelBufferGetWidth(pixelBuffer)
        let inputHeight = CVPixelBufferGetHeight(pixelBuffer)
        let targetWidth = Int(processingDimensions.width)
        let targetHeight = Int(processingDimensions.height)

        let resolutionMismatch = inputWidth != targetWidth || inputHeight != targetHeight
        let attributeMismatch = checkAttributeMismatch(pixelBuffer)

        guard resolutionMismatch || attributeMismatch else {
            return pixelBuffer
        }

        guard let compatibleBuffer = try? Self.createPixelBuffer(from: sourcePixelBufferPool) else {
            return pixelBuffer
        }

        if VTPixelTransferSessionTransferImage(session, from: pixelBuffer, to: compatibleBuffer) == noErr {
            return compatibleBuffer
        }
        return pixelBuffer
    }

    private func checkAttributeMismatch(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let receivedAttributes = CVPixelBufferCopyCreationAttributes(pixelBuffer) as? [String: Any] else {
            return false
        }

        let criticalKeys = [
            kCVPixelBufferExtendedPixelsLeftKey as String,
            kCVPixelBufferExtendedPixelsTopKey as String,
            kCVPixelBufferExtendedPixelsRightKey as String,
            kCVPixelBufferExtendedPixelsBottomKey as String
        ]

        for key in criticalKeys {
            if let desiredValue = sourcePixelBufferAttributes[key] as? Int {
                let receivedValue = (receivedAttributes[key] as? Int) ?? 0
                if receivedValue != desiredValue {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func interpolationIntervals() -> [Double] {
        let step = 1.0 / (Double(numFrames) + 1)
        return Array(stride(from: step, through: 1.0, by: step).dropLast())
    }

    private func framesBetween(firstPTS: CMTime,
                               lastPTS: CMTime,
                               interpolationIntervals: [Double]) throws -> [VTFrameProcessorFrame] {
        let ptsRange = Double(CMTimeGetSeconds(lastPTS) - CMTimeGetSeconds(firstPTS))
        let ptsScale = lastPTS.timescale

        var frames: [VTFrameProcessorFrame] = []
        if spatialUpscaleEnabled {
            // In spatial mode VideoToolbox also writes an upscaled output for
            // the first frame in the pair. Without this destination, the stream
            // would mix scaled interpolated frames with unscaled original frames.
            let pts = CMTime(seconds: CMTimeGetSeconds(firstPTS), preferredTimescale: ptsScale)
            let pixelBuffer = try Self.createPixelBuffer(from: pixelBufferPool)
            guard let frame = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
                throw Fault.failedToCreateFrames
            }
            frames.append(frame)
        }

        for interval in interpolationIntervals {
            let ptsValue = ptsRange * interval
            let pts = CMTime(seconds: ptsValue + CMTimeGetSeconds(firstPTS), preferredTimescale: ptsScale)
            let pixelBuffer = try Self.createPixelBuffer(from: pixelBufferPool)
            guard let frame = VTFrameProcessorFrame(buffer: pixelBuffer, presentationTimeStamp: pts) else {
                throw Fault.failedToCreateFrames
            }
            frames.append(frame)
        }
        return frames
    }

    // MARK: - Diagnostic helpers

    /// Creates a black (zeroed) source buffer suitable for model warm-up / diagnostics.
    func createSyntheticSourceBuffer() throws -> CVPixelBuffer {
        return try Self.createPixelBuffer(from: sourcePixelBufferPool)
    }

    // MARK: - Static helpers

    private static func describeAttributes(_ attrs: [String: Any]) -> String {
        let width = attrs[kCVPixelBufferWidthKey as String] ?? "?"
        let height = attrs[kCVPixelBufferHeightKey as String] ?? "?"
        let format = attrs[kCVPixelBufferPixelFormatTypeKey as String] ?? "?"
        let extL = attrs[kCVPixelBufferExtendedPixelsLeftKey as String] ?? 0
        let extR = attrs[kCVPixelBufferExtendedPixelsRightKey as String] ?? 0
        let extT = attrs[kCVPixelBufferExtendedPixelsTopKey as String] ?? 0
        let extB = attrs[kCVPixelBufferExtendedPixelsBottomKey as String] ?? 0
        return "\(width)x\(height) fmt=\(format) ext=L\(extL)/R\(extR)/T\(extT)/B\(extB)"
    }

    private static func createPixelBufferPool(for attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as NSDictionary?,
                                             attributes as NSDictionary?,
                                             &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw Fault.failedToCreatePixelBufferPool
        }
        return pool
    }

    private static func createPixelBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw Fault.failedToCreatePixelBuffer
        }
        return buffer
    }
}

// MARK: - Errors

@available(macOS 14.0, *)
enum Fault: Error {
    case unsupportedProcessor
    case failedToCreateConfiguration
    case sessionNotStarted
    case failedToCreateFrames
    case failedToCreateParameters
    case failedToCreateOutputBuffer
    case failedToTransferImage
    case failedToCreatePixelBufferPool
    case failedToCreatePixelBuffer
}
