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

    /// Whether a window or display has been chosen in Preferences.
    var hasTarget: Bool {
        targetWindowID != nil || targetDisplayID != nil
    }

    var initialCaptureFrameRate: Int {
        autoFrameRateEnabled ? Self.autoFrameRateSamplingCeiling : frameRate
    }

    static func frameInterval(for frameRate: Int) -> CMTime {
        let clampedFrameRate = max(1, frameRate)
        return CMTime(value: 1, timescale: CMTimeScale(clampedFrameRate))
    }
    
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

// MARK: - Persistence

extension CaptureSettings {
    /// The settings saved between launches. The capture target is session-only, and the capture
    /// resolution is fixed, so neither is stored.
    enum CodingKeys: String, CodingKey {
        case frameRate
        case autoFrameRateEnabled
        case useVirtualDisplay
        case selectedDynamicRangePreset
    }

    /// Manual capture rates offered in Preferences.
    static let frameRateRange = 30...120
    static let frameRateStep = 30

    /// The nearest capture rate Preferences can show.
    static func validFrameRate(_ frameRate: Int) -> Int {
        let clamped = min(max(frameRate, frameRateRange.lowerBound), frameRateRange.upperBound)
        let steps = (Double(clamped) / Double(frameRateStep)).rounded()
        return Int(steps) * frameRateStep
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = Self.validFrameRate(values.value(.frameRate, default: frameRate))
        autoFrameRateEnabled = values.value(.autoFrameRateEnabled, default: autoFrameRateEnabled)
        useVirtualDisplay = values.value(.useVirtualDisplay, default: useVirtualDisplay)
        selectedDynamicRangePreset = values.value(.selectedDynamicRangePreset, default: selectedDynamicRangePreset)
    }
}
