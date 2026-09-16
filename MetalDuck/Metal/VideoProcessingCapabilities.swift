@preconcurrency import VideoToolbox

/// Keep the macOS 27 API boundary separate from the bounds policy and runtime fallback.
enum VideoProcessingCapabilities {
    nonisolated static func interpolation(spatialScaleFactor: Int) -> VideoProcessingCapability {
        guard #available(macOS 27.0, *) else { return .unavailable }
        return .reported(
            maximumDimension: VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: spatialScaleFactor),
            maximumPixelCount: VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: spatialScaleFactor)
        )
    }

    nonisolated static func superResolution(scaleFactor: Float) -> VideoProcessingCapability {
        guard #available(macOS 27.0, *) else { return .unavailable }
        return .reported(
            maximumDimension: VTLowLatencySuperResolutionScalerConfiguration.maximumDimension(forSpatialScaleFactor: scaleFactor),
            maximumPixelCount: VTLowLatencySuperResolutionScalerConfiguration.maximumPixelCount(forSpatialScaleFactor: scaleFactor)
        )
    }

    nonisolated static func superResolutionScaleFactors(width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0 else { return [] }
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: width, frameHeight: height
        ).filter { superResolution(scaleFactor: $0).allows(width: width, height: height) != false }
    }
}
