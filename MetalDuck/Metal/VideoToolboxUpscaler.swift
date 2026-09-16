//
//  VideoToolboxUpscaler.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AVFoundation
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

class VideoToolboxUpscaler {
    private var transferSession: VTPixelTransferSession?
    private var settings: UpscaleSettings

    // Super-resolution scaler
    @available(macOS 14.0, *)
    private var superResolutionFrameProcessor: VTFrameProcessor?

    @available(macOS 14.0, *)
    private var superResolutionConfiguration: VTLowLatencySuperResolutionScalerConfiguration?

    @available(macOS 14.0, *)
    private var superResolutionPixelBufferPool: CVPixelBufferPool?

    @available(macOS 14.0, *)
    private var superResolutionSessionStarted = false

    // Source frame rate (default to 30fps, can be updated)
    private var sourceFrameRate: Int = 30

    init(settings: UpscaleSettings) {
        self.settings = settings
        setupTransferSession()
        if #available(macOS 14.0, *) {
            setupAdvancedFeatures()
        }
    }

    private func setupTransferSession() {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)

        guard status == noErr, let transferSession = session else {
            print("Failed to create VTPixelTransferSession: \(status)")
            return
        }

        self.transferSession = transferSession
    }

    @available(macOS 14.0, *)
    private func setupAdvancedFeatures() {
        guard settings.superResolutionEnabled || settings.mode == .superResolution else {
            return
        }

        print("🎬 VideoToolboxUpscaler: Setting up Super Resolution")
        print("   Source Resolution: \(Int(settings.sourceResolution.width))x\(Int(settings.sourceResolution.height))")
        print("   Target Resolution: \(Int(settings.targetResolution.width))x\(Int(settings.targetResolution.height))")
        setupSuperResolutionScaler()
    }

    @available(macOS 14.0, *)
    private func setupSuperResolutionScaler() {
        print("🔧 Setting up Super Resolution Scaler...")

        if superResolutionSessionStarted, let processor = superResolutionFrameProcessor {
            processor.endSession()
            superResolutionSessionStarted = false
        }

        superResolutionConfiguration = nil
        superResolutionPixelBufferPool = nil
        superResolutionFrameProcessor = nil

        let sourceWidth = Int(settings.sourceResolution.width)
        let sourceHeight = Int(settings.sourceResolution.height)
        let targetWidth = Int(settings.targetResolution.width)
        let targetHeight = Int(settings.targetResolution.height)

        print("   Source: \(sourceWidth)x\(sourceHeight)")
        print("   Target: \(targetWidth)x\(targetHeight)")
        print("   Quality: \(settings.superResolutionQuality)")

        let result = VideoToolboxAdvanced.createSuperResolutionScaler(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            quality: settings.superResolutionQuality
        )

        if let config = result.configuration, let pool = result.pixelBufferPool {
            print("   ✅ Super Resolution Scaler configured successfully")
            superResolutionConfiguration = config
            superResolutionPixelBufferPool = pool
            superResolutionFrameProcessor = VTFrameProcessor()
        } else {
            print("   ❌ Failed to configure Super Resolution Scaler")
        }
    }

    func updateSettings(_ newSettings: UpscaleSettings) {
        let oldSourceResolution = settings.sourceResolution
        let oldTargetResolution = settings.targetResolution
        settings = newSettings

        print("🔄 VideoToolboxUpscaler: Settings updated → Mode: \(settings.mode)")

        let sourceResolutionChanged = oldSourceResolution != settings.sourceResolution
        let targetResolutionChanged = oldTargetResolution != settings.targetResolution

        if #available(macOS 14.0, *) {
            if settings.superResolutionEnabled || settings.mode == .superResolution {
                if sourceResolutionChanged || targetResolutionChanged {
                    print("   ✅ Reconfiguring Super Resolution (resolution changed)")
                }
                setupSuperResolutionScaler()
            }
        }
    }

    func updateSourceFrameRate(_ frameRate: Int) {
        let oldFrameRate = sourceFrameRate
        sourceFrameRate = frameRate
        if oldFrameRate != frameRate {
            print("🔄 VideoToolboxUpscaler: Source frame rate updated: \(oldFrameRate) fps → \(frameRate) fps")
        }
    }

    func updateSourceResolution(from pixelBuffer: CVPixelBuffer) {
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        let currentWidth = Int(settings.sourceResolution.width)
        let currentHeight = Int(settings.sourceResolution.height)

        if actualWidth != currentWidth || actualHeight != currentHeight {
            print("🔄 VideoToolboxUpscaler: Source resolution updated: \(currentWidth)x\(currentHeight) → \(actualWidth)x\(actualHeight)")
            settings.sourceResolution = CGSize(width: actualWidth, height: actualHeight)

            if #available(macOS 14.0, *) {
                if settings.superResolutionEnabled || settings.mode == .superResolution {
                    setupSuperResolutionScaler()
                }
            }
        }
    }

    private var frameCount: Int = 0
    private var lastLogTime: Date = .init()

    /// Upscales the given pixel buffer. Returns the processed buffer, or the original on passthrough.
    func upscale(pixelBuffer: CVPixelBuffer) async -> CVPixelBuffer? {
        frameCount += 1

        if frameCount == 1 || frameCount % 100 == 0 {
            updateSourceResolution(from: pixelBuffer)
        }

        switch settings.mode {
        case .superResolution:
            if #available(macOS 14.0, *) {
                return await upscaleWithSuperResolution(pixelBuffer: pixelBuffer)
            } else {
                return fallbackUpscale(pixelBuffer: pixelBuffer)
            }
        case .frameInterpolation:
            // Interpolation handled upstream; passthrough here
            return pixelBuffer
        case .temporal, .quality, .spatial:
            if #available(macOS 14.0, *), settings.superResolutionEnabled {
                return await upscaleWithSuperResolution(pixelBuffer: pixelBuffer)
            } else {
                return fallbackUpscale(pixelBuffer: pixelBuffer)
            }
        }
    }

    @available(macOS 14.0, *)
    private func upscaleWithSuperResolution(pixelBuffer: CVPixelBuffer) async -> CVPixelBuffer? {
        guard let processor = superResolutionFrameProcessor,
              let configuration = superResolutionConfiguration,
              let pixelBufferPool = superResolutionPixelBufferPool
        else {
            return fallbackUpscale(pixelBuffer: pixelBuffer)
        }

        // Verify source dimensions match
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let configWidth = Int(configuration.frameWidth)
        let configHeight = Int(configuration.frameHeight)

        if sourceWidth != configWidth || sourceHeight != configHeight {
            if superResolutionSessionStarted {
                processor.endSession()
                superResolutionSessionStarted = false
            }
            settings.sourceResolution = CGSize(width: sourceWidth, height: sourceHeight)
            setupSuperResolutionScaler()
            return await upscaleWithSuperResolution(pixelBuffer: pixelBuffer)
        }

        // Verify and convert source buffer to match sourcePixelBufferAttributes
        var processedPixelBuffer = pixelBuffer
        let sourcePixelBufferAttributes = configuration.sourcePixelBufferAttributes

        if let receivedAttributes = CVPixelBufferCopyCreationAttributes(pixelBuffer) as? [String: Any] {
            let criticalKeys = [
                kCVPixelBufferExtendedPixelsLeftKey as String,
                kCVPixelBufferExtendedPixelsTopKey as String,
                kCVPixelBufferExtendedPixelsRightKey as String,
                kCVPixelBufferExtendedPixelsBottomKey as String
            ]

            var needsConversion = false
            for criticalKey in criticalKeys {
                if let desiredValue = sourcePixelBufferAttributes[criticalKey] as? Int {
                    let receivedValue = (receivedAttributes[criticalKey] as? Int) ?? 0
                    if receivedValue != desiredValue {
                        needsConversion = true
                        break
                    }
                }
            }

            if needsConversion {
                var session: VTPixelTransferSession?
                if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                pixelTransferSessionOut: &session) == noErr,
                    let session = session
                {
                    var pool: CVPixelBufferPool?
                    let poolAttributes: [String: Any] = [
                        kCVPixelBufferPoolMinimumBufferCountKey as String: 1
                    ]
                    if CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               poolAttributes as NSDictionary?,
                                               sourcePixelBufferAttributes as NSDictionary?,
                                               &pool) == kCVReturnSuccess,
                        let pool = pool
                    {
                        var convertedBuffer: CVPixelBuffer?
                        if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &convertedBuffer) == kCVReturnSuccess,
                           let converted = convertedBuffer
                        {
                            if VTPixelTransferSessionTransferImage(session, from: pixelBuffer, to: converted) == noErr {
                                processedPixelBuffer = converted
                            }
                        }
                    }
                    VTPixelTransferSessionInvalidate(session)
                }
            }
        }

        // Start session if needed
        if !superResolutionSessionStarted {
            do {
                try processor.startSession(configuration: configuration)
                superResolutionSessionStarted = true
                print("   ✅ Super Resolution session started")
            } catch {
                print("   ❌ Failed to start super-resolution session: \(error)")
                return fallbackUpscale(pixelBuffer: pixelBuffer)
            }
        }

        let timestamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)

        guard let sourceFrame = VTFrameProcessorFrame(buffer: processedPixelBuffer, presentationTimeStamp: timestamp) else {
            return fallbackUpscale(pixelBuffer: pixelBuffer)
        }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outputBuffer)
        guard let output = outputBuffer else {
            return fallbackUpscale(pixelBuffer: pixelBuffer)
        }

        processedPixelBuffer.propagateAttachments(to: output)

        guard let destinationFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: timestamp) else {
            return fallbackUpscale(pixelBuffer: pixelBuffer)
        }

        let parameters = VTLowLatencySuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame
        )

        do {
            try await processor.process(parameters: parameters)
            processedPixelBuffer.propagateAttachments(to: output)
            // CALayer handles YUV→RGB conversion natively, no format conversion needed
            return output
        } catch {
            print("   ❌ Super-resolution processing failed: \(error.localizedDescription)")
            return fallbackUpscale(pixelBuffer: pixelBuffer)
        }
    }

    private var fallbackCount: Int = 0

    private func fallbackUpscale(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        fallbackCount += 1

        guard let output = createOutputBuffer() else {
            return nil
        }

        if let session = transferSession {
            let status = VTPixelTransferSessionTransferImage(session, from: pixelBuffer, to: output)
            if status == noErr {
                return output
            }
        }

        // If transfer session fails, return original — CALayer can display it directly
        return pixelBuffer
    }

    private func createOutputBuffer() -> CVPixelBuffer? {
        var outputBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(settings.targetResolution.width),
            kCVPixelBufferHeightKey: Int(settings.targetResolution.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(settings.targetResolution.width),
            Int(settings.targetResolution.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &outputBuffer
        )

        return (status == kCVReturnSuccess) ? outputBuffer : nil
    }

    deinit {
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
        }

        if #available(macOS 14.0, *) {
            if superResolutionSessionStarted, let processor = superResolutionFrameProcessor {
                processor.endSession()
            }
            superResolutionFrameProcessor = nil
            superResolutionConfiguration = nil
            superResolutionPixelBufferPool = nil
        }
    }
}
