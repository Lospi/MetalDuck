//
//  UpscaleSettings.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import Foundation
import VideoToolbox

enum ProcessingResolution: String, Codable, CaseIterable {
    case p360 = "360p"
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .p360:  return (640, 360)
        case .p720:  return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        }
    }

    /// Returns the next lower resolution, or nil if already at minimum.
    var lowerResolution: ProcessingResolution? {
        switch self {
        case .p1440: return .p1080
        case .p1080: return .p720
        case .p720:  return .p360
        case .p360:  return nil
        }
    }
}

enum UpscaleMode: String, Codable, CaseIterable {
    case temporal = "Temporal"
    case quality = "Quality"
    case spatial = "Spatial"
    case superResolution = "Super Resolution"
    case frameInterpolation = "Frame Interpolation"
    
    var description: String {
        switch self {
        case .temporal:
            return "Temporal (Lower latency, good quality)"
        case .quality:
            return "Quality (Higher latency, best quality)"
        case .spatial:
            return "Spatial (Fast, basic upscaling)"
        case .superResolution:
            return "Super Resolution (AI-powered upscaling)"
        case .frameInterpolation:
            return "Frame Interpolation (Increase frame rate)"
        }
    }
}

struct UpscaleSettings: Codable {
    var mode: UpscaleMode
    var targetResolution: CGSize
    var sourceResolution: CGSize
    var sharpness: Float
    
    // Super Resolution parameters
    var superResolutionEnabled: Bool = false
    var superResolutionQuality: Float = 0.5 // 0.0 to 1.0
    
    // Frame Interpolation parameters
    var frameInterpolationEnabled: Bool = false
    var interpolationMultiplier: Int = 2
    var processingResolution: ProcessingResolution = .p720
    var spatialUpscaleEnabled: Bool = false
    
    init() {
        self.mode = .temporal
        self.targetResolution = CGSize(width: 3840, height: 2160)
        self.sourceResolution = CGSize(width: 1920, height: 1080)
        self.sharpness = 0.5
        self.superResolutionEnabled = false
        self.superResolutionQuality = 0.5
        self.frameInterpolationEnabled = false
        self.interpolationMultiplier = 2
    }
    
    /// Calculates the target frame rate based on source frame rate and multiplier
    func targetFrameRate(sourceFrameRate: Int) -> Int {
        if spatialUpscaleEnabled {
            return sourceFrameRate * 2
        }
        return sourceFrameRate * interpolationMultiplier
    }
    
    var scaleFactor: Float {
        let widthScale = Float(targetResolution.width / sourceResolution.width)
        let heightScale = Float(targetResolution.height / sourceResolution.height)
        return min(widthScale, heightScale)
    }
}
