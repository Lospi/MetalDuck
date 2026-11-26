//
//  PermissionManager.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

@preconcurrency import ApplicationServices
import AVFoundation
import Foundation
import ScreenCaptureKit

class PermissionManager {
    static let shared = PermissionManager()

    nonisolated static let screenRecordingUnavailableMessage =
        "Screen recording is not available on this Mac. Check Screen Time or device management restrictions."

    private init() {}

    /// macOS 27 reports whether screen recording is supported and allowed on this Mac.
    /// Returns `nil` on older macOS versions where the OS cannot answer.
    static var screenRecordingAvailability: Bool? {
        guard #available(macOS 27.0, *) else { return nil }
        return SCContentSharingPicker.shared.isAvailable
    }

    /// False only when the OS explicitly reports that screen recording is unavailable.
    var isScreenRecordingAvailable: Bool {
        Self.screenRecordingAvailability ?? true
    }

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    func requestScreenRecordingPermission() async -> Bool {
        if hasScreenRecordingPermission {
            return true
        }
        
        return CGRequestScreenCaptureAccess()
    }
    
    var hasAccessibilityPermission: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
