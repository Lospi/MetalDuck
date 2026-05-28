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

@available(macOS 12.3, *)
class ScreenCaptureManager: NSObject {
    private var captureSession: CaptureSession?
    private let settings: CaptureSettings

    /// Called when the user picks content from the sharing picker.
    var onPickerFilterSelected: ((SCContentFilter) -> Void)?

    init(settings: CaptureSettings) {
        self.settings = settings
        super.init()
        SCContentSharingPicker.shared.add(self)
        SCContentSharingPicker.shared.isActive = true
    }

    func startCapture() async throws -> AsyncThrowingStream<CapturedFrame, Error> {
        if !PermissionManager.shared.hasScreenRecordingPermission {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            guard granted else {
                throw CaptureError.permissionDenied
            }
        }

        captureSession = CaptureSession(settings: settings)
        return try await captureSession!.startCapture()
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

    // MARK: - Content Picker

    func presentPicker() {
        SCContentSharingPicker.shared.present()
    }

    func applyPickerFilter(_ filter: SCContentFilter) async {
        if captureSession != nil {
            await captureSession?.updateContentFilter(filter)
        } else {
            // Capture not running — notify coordinator to start with this filter
            onPickerFilterSelected?(filter)
        }
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

@available(macOS 12.3, *)
extension ScreenCaptureManager: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // no-op
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { [weak self] in
            await self?.applyPickerFilter(filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        // no-op
    }
}
