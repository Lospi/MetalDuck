//
//  CaptureSettings.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import CoreMedia
import Foundation
import ScreenCaptureKit

enum DynamicRangePreset: String, Codable, CaseIterable {
    case localDisplayHDR = "Local Display HDR"
    case canonicalDisplayHDR = "Canonical Display HDR"
    
    @available(macOS 15.0, *)
    var scDynamicRangePreset: SCStreamConfiguration.Preset? {
        switch self {
        case .localDisplayHDR:
            return SCStreamConfiguration.Preset.captureHDRStreamLocalDisplay
        case .canonicalDisplayHDR:
            return SCStreamConfiguration.Preset.captureHDRStreamCanonicalDisplay
        }
    }
}

struct CaptureSettings: Codable {
    var targetWindowID: CGWindowID?
    var targetDisplayID: CGDirectDisplayID?
    var captureResolution: CGSize
    var frameRate: Int
    var autoFrameRateEnabled: Bool
    var useVirtualDisplay: Bool
    var selectedDynamicRangePreset: DynamicRangePreset?

    static let autoFrameRateSamplingCeiling = 120
    
    init() {
        self.captureResolution = CGSize(width: 1920, height: 1080)
        self.frameRate = 60
        self.autoFrameRateEnabled = false
        self.useVirtualDisplay = false
        self.selectedDynamicRangePreset = nil
    }

    static func frameInterval(for frameRate: Int) -> CMTime {
        let clampedFrameRate = max(1, frameRate)
        return CMTime(value: 1, timescale: CMTimeScale(clampedFrameRate))
    }
    
    @available(macOS 12.3, *)
    func contentFilter() async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        
        if let windowID = targetWindowID {
            // Find window from shareable content
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let displayID = targetDisplayID {
            // Find display from shareable content
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }
        
        // Default: capture main display
        if let mainDisplay = content.displays.first {
            return SCContentFilter(display: mainDisplay, excludingWindows: [])
        }
        
        return nil
    }
}
