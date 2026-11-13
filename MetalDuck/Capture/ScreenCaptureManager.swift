//
//  ScreenCaptureManager.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

class ScreenCaptureManager {
    private var captureSession: CaptureSession?
    private let settings: CaptureSettings

    init(settings: CaptureSettings) {
        self.settings = settings
    }

    /// Starts capturing `filter`, or the target from the settings when no filter is given.
    func startCapture(filter: SCContentFilter? = nil) async throws -> AsyncThrowingStream<CapturedFrame, Error> {
        if !PermissionManager.shared.hasScreenRecordingPermission {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            guard granted else {
                throw CaptureError.permissionDenied
            }
        }

        captureSession = CaptureSession(settings: settings)
        return try await captureSession!.startCapture(filter: filter)
    }

    var isCapturing: Bool {
        captureSession != nil
    }

    func stopCapture() async {
        await captureSession?.stop()
        captureSession = nil
    }

    func updateFrameRate(_ frameRate: Int) async throws {
        try await captureSession?.updateFrameRate(frameRate)
    }

    /// Switches a running capture to different content.
    func updateContentFilter(_ filter: SCContentFilter) async {
        await captureSession?.updateContentFilter(filter)
    }

    static func getAvailableWindows() async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        return content.windows
    }

    static func getAvailableDisplays() async -> [SCDisplay] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return []
        }
        return content.displays
    }

    enum CaptureError: Error {
        case permissionDenied
        case sessionNotStarted
    }
}
