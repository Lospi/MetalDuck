//
//  VideoToolboxAdvanced.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//
//  This file provides wrappers and helpers for advanced VideoToolbox APIs:
//  - VTLowLatencySuperResolutionScalerConfiguration
//  - VTLowLatencySuperResolutionScalerParameters
//  - VTLowLatencyFrameInterpolationConfiguration
//  - VTLowLatencyFrameInterpolationParameters
//

import AVFoundation
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

@available(macOS 14.0, *)
class VideoToolboxAdvanced {
    // MARK: - Super Resolution Scaler
    
    /// Creates a low-latency super-resolution scaler configuration
    static func createSuperResolutionScaler(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        quality: Float
    ) -> (configuration: VTLowLatencySuperResolutionScalerConfiguration?, pixelBufferPool: CVPixelBufferPool?) {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            print("VTLowLatencySuperResolutionScalerConfiguration is not supported")
            return (nil, nil)
        }
        
        guard sourceWidth > 0, sourceHeight > 0 else { return (nil, nil) }

        // Retain legacy bounds on macOS 26; macOS 27 uses scale-specific limits below.
        if #unavailable(macOS 27.0),
           let maximumDimensions = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions {
            guard sourceWidth <= Int(maximumDimensions.width),
                  sourceHeight <= Int(maximumDimensions.height) else {
                return (nil, nil)
            }
        }

        if let minimumDimensions = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions {
            guard Int32(sourceWidth) >= minimumDimensions.width,
                  Int32(sourceHeight) >= minimumDimensions.height
            else {
                print("Input dimensions are below minimum supported dimensions")
                return (nil, nil)
            }
        }
        
        // Calculate scale factor
        let scaleFactor = Float(targetWidth) / Float(sourceWidth)
        let heightScaleFactor = Float(targetHeight) / Float(sourceHeight)
        
        // Use the minimum scale factor to maintain aspect ratio
        let actualScaleFactor = min(scaleFactor, heightScaleFactor)
        
        // Get supported scale factors
        let supportedScaleFactors = VideoProcessingCapabilities.superResolutionScaleFactors(
            width: sourceWidth, height: sourceHeight
        )
        
        // Find the closest supported scale factor
        guard let closestScaleFactor = supportedScaleFactors.min(by: { abs($0 - actualScaleFactor) < abs($1 - actualScaleFactor) }) else {
            print("No supported scale factor found")
            return (nil, nil)
        }
        
        // Create configuration
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: sourceWidth,
            frameHeight: sourceHeight,
            scaleFactor: closestScaleFactor
        )
        
        print("   📐 Super Resolution Configuration:")
        print("      Scale Factor: \(String(format: "%.2f", closestScaleFactor))x")
        print("      Supported Scale Factors: \(supportedScaleFactors.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
        
        // Create pixel buffer pool (exactly as Apple example)
        let destinationPixelBufferAttributes = configuration.destinationPixelBufferAttributes
        var pixelBufferPool: CVPixelBufferPool?
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 2 // Apple uses 2, not 3
        ]
        
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as NSDictionary?,
            destinationPixelBufferAttributes as NSDictionary?,
            &pixelBufferPool
        )
        
        guard let pool = pixelBufferPool else {
            print("   ❌ Failed to create pixel buffer pool for super-resolution scaler")
            return (configuration, nil)
        }
        
        print("   ✅ Pixel buffer pool created successfully")
        return (configuration, pool)
    }
    
    // MARK: - Frame Interpolation
    
    /// Creates a low-latency frame interpolation configuration
    static func createFrameInterpolation(
        sourceWidth: Int,
        sourceHeight: Int,
        targetFrameRate: Int,
        sourceFrameRate: Int
    ) -> (configuration: VTLowLatencyFrameInterpolationConfiguration?, pixelBufferPool: CVPixelBufferPool?) {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            print("VTLowLatencyFrameInterpolationConfiguration is not supported")
            return (nil, nil)
        }
        
        // Calculate number of interpolated frames needed (exactly as Apple example)
        // Apple uses: scalar = 1 for interpolation only, and limits numFrames to min(3, numFrames)
        // For example, if source is 30fps and target is 60fps, we need 1 interpolated frame between each pair
        let frameRateRatio = Float(targetFrameRate) / Float(sourceFrameRate)
        let requestedFrames = max(1, Int(ceil(frameRateRatio)) - 1)
        // Apple limits to max 3 frames for interpolation only (scalar = 1)
        let numFrames = min(3, requestedFrames)
        
        print("   📐 Frame Interpolation Configuration:")
        print("      Requested frames: \(requestedFrames)")
        print("      Number of interpolated frames (limited to 3): \(numFrames)")
        print("      Frame rate ratio: \(String(format: "%.2f", frameRateRatio))")
        print("      Source FPS: \(sourceFrameRate) → Target FPS: \(targetFrameRate)")
        
        // Create configuration for interpolation only (scalar = 1, exactly as Apple example)
        // If you want to also scale, use spatialScaleFactor: 2 instead
        guard let config = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: sourceWidth,
            frameHeight: sourceHeight,
            numberOfInterpolatedFrames: numFrames
        ) else {
            print("   ❌ Failed to create VTLowLatencyFrameInterpolationConfiguration")
            return (nil, nil)
        }
        
        // Create pixel buffer pool
        // Get destination pixel buffer attributes from the configuration
        let destinationPixelBufferAttributes = config.destinationPixelBufferAttributes
        var pixelBufferPool: CVPixelBufferPool?
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as NSDictionary?,
            destinationPixelBufferAttributes as NSDictionary?,
            &pixelBufferPool
        )
        
        guard status == kCVReturnSuccess, let pool = pixelBufferPool else {
            print("   ❌ Failed to create pixel buffer pool for frame interpolation (status: \(status))")
            return (nil, nil)
        }
        
        print("   ✅ Pixel buffer pool created successfully")
        // Return configuration as optional to match return type
        return (config, pool)
    }
}

// MARK: - Helper Extensions

extension CVPixelBuffer {
    /// Propagates attachments from source to destination pixel buffer
    /// Note: Apple's example uses CMSampleBuffer.propagateAttachments(to:) which is built-in.
    /// Apple propagates from CMSampleBuffer to CVPixelBuffer, not CVPixelBuffer to CVPixelBuffer.
    /// Since we work with CVPixelBuffer directly (not CMSampleBuffer), this is a no-op.
    func propagateAttachments(to destination: CVPixelBuffer) {
        // Apple's implementation uses CMSampleBuffer.propagateAttachments(to: CVPixelBuffer)
        // which is a built-in method. Since we don't have CMSampleBuffer, we can't use that.
        // Attachments are typically not critical for pixel buffers in this context.
    }
    
    /// Propagates attachments from source to destination sample buffer
    func propagateAttachments(to destination: CMSampleBuffer) {
        // Get all attachments from the pixel buffer
        // CVBufferGetAttachments requires a CVAttachmentMode parameter
        // CVAttachmentMode is a typealias for UInt32, so we can use 0 to get all attachments
        guard let attachmentMode = CVAttachmentMode(rawValue: 0) else {
            return
        }
        guard let attachmentsDict = CVBufferGetAttachments(self, attachmentMode) as? [CFString: Any] else {
            return
        }
        
        for (key, value) in attachmentsDict {
            // CMSetAttachment expects CFString for key and CFTypeRef for value
            // value needs to be a class type (CFTypeRef), so we cast it
            guard let cfValue = value as? CFTypeRef else {
                continue
            }
            CMSetAttachment(destination, key: key, value: cfValue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
    }
}
