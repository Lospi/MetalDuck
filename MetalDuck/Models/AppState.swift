//
//  AppState.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import Foundation
import SwiftUI

@MainActor
@Observable
class AppState {
    var isCapturing: Bool = false
    /// True from the moment a start request is accepted until the stream is running or the start fails.
    private(set) var isStarting: Bool = false
    var isUpscaling: Bool = false
    var isOverlayVisible: Bool = false
    var currentFPS: Double = 0.0
    var captureError: String?
    var processingStatus: String = "Idle"
    
    // Menu bar state
    var menuBarItem: NSStatusItem?
    
    /// Claims the right to start a capture. Returns false when one is already running or starting,
    /// so overlapping start requests collapse into one.
    func beginStarting() -> Bool {
        guard !isCapturing, !isStarting else { return false }
        isStarting = true
        return true
    }

    /// Releases the claim made by `beginStarting()` when the start did not go through.
    func cancelStarting() {
        isStarting = false
    }

    func startCapture() {
        isStarting = false
        isCapturing = true
        isOverlayVisible = true
    }
    
    func stopCapture() {
        isCapturing = false
        isUpscaling = false
        isOverlayVisible = false
    }
    
    func updateFPS(_ fps: Double) {
        currentFPS = fps
    }
    
    func setError(_ error: String?) {
        captureError = error
    }
}
