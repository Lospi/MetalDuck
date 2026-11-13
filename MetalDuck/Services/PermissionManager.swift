//
//  PermissionManager.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AVFoundation
import Foundation
import ScreenCaptureKit

class PermissionManager {
    static let shared = PermissionManager()
    
    private init() {}
    
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
