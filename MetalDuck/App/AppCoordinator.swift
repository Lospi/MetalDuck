//
//  AppCoordinator.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Sparkle

@MainActor
@Observable
class AppCoordinator {
    static let shared = AppCoordinator()

    var appState = AppState()
    var captureSettings = CaptureSettings()
    var upscaleSettings = UpscaleSettings()

    private var videoToolboxUpscaler: VideoToolboxUpscaler?
    private(set) var overlayManager: OverlayManager?
    private var captureManager: ScreenCaptureManager?
    private var menuBarController: MenuBarController?
    private var captureTask: Task<Void, Never>?
    private let updaterDelegate = UpdaterDelegate()
    private var updaterController: SPUStandardUpdaterController?

    @available(macOS 14.0, *)
    private var interpolator: RealTimeFrameInterpolation?

    private var frameCount = 0
    private var lastFPSTime = Date()
    private var interpolatedFrameCount = 0
    private var passthroughFrameCount = 0
    private var sourceFrameCount = 0
    private var currentSourceFPS: Double = 0
    private var lastFrameTimestamp: CMTime?
    private var didApplyContentWidthRatio = false
    private var activeProcessingResolution: ProcessingResolution?
    private var activeSpatialUpscaleEnabled: Bool?
    private var interpolationUnsupported = false

    init() {
        setupComponents()
        setupNotifications()
    }

    private func setupComponents() {
        videoToolboxUpscaler = VideoToolboxUpscaler(settings: upscaleSettings)
        overlayManager = OverlayManager()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        updaterController = controller
        menuBarController = MenuBarController(appState: appState, updaterController: controller)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .startCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.startCapture()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .stopCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.stopCapture()
            }
        }
    }

    func startCapture() async {
        guard !appState.isCapturing else { return }

        if !PermissionManager.shared.hasScreenRecordingPermission {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            if !granted {
                appState.setError("Screen recording permission is required")
                return
            }
        }

        guard let overlay = overlayManager else {
            appState.setError("Overlay not initialized")
            return
        }

        if #available(macOS 12.3, *) {
            // Match capture resolution to window size before starting capture
            await matchCaptureResolutionToWindow()

            captureManager = ScreenCaptureManager(settings: captureSettings)

            do {
                let stream = try await captureManager!.startCapture()
                appState.startCapture()

                if #available(macOS 14.0, *) {
                    interpolator = nil
                }
                resetRuntimeFallbacks()

                createDisplayForCapture(overlay: overlay)

                captureTask = Task { [weak self] in
                    do {
                        for try await frame in stream {
                            await self?.processFrame(frame)
                        }
                    } catch {
                        await MainActor.run {
                            self?.appState.setError("Capture stream error: \(error.localizedDescription)")
                        }
                        await self?.stopCapture()
                    }
                }
            } catch {
                appState.setError("Failed to start capture: \(error.localizedDescription)")
            }
        } else {
            appState.setError("ScreenCaptureKit requires macOS 12.3 or later")
        }
    }

    func stopCapture() async {
        guard appState.isCapturing else { return }

        // Mark as not capturing first to prevent re-entrant calls
        appState.stopCapture()

        let task = captureTask
        captureTask = nil
        task?.cancel()

        if #available(macOS 12.3, *) {
            await captureManager?.stopCapture()
            captureManager = nil
        }

        // Stop the interpolator's VTFrameProcessor session
        if #available(macOS 14.0, *) {
            await interpolator?.stop()
            interpolator = nil
        }

        overlayManager?.close()
        lastFrameTimestamp = nil
        didApplyContentWidthRatio = false
        resetRuntimeFallbacks()
    }

    private func processFrame(_ frame: CapturedFrame) async {
        guard let overlay = overlayManager else { return }
        sourceFrameCount += 1

        let currentPTS = frame.presentationTimestamp
        let prevPTS = lastFrameTimestamp ?? currentPTS
        lastFrameTimestamp = currentPTS

        // On first frame, set content ratio so overlay clips the black padding
        if !didApplyContentWidthRatio {
            let bufferWidth = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
            let contentWidth = frame.contentRect.width * frame.scaleFactor
            if bufferWidth > 0 && contentWidth > 0 && contentWidth < bufferWidth {
                let ratio = contentWidth / bufferWidth
                overlay.setContentWidthRatio(ratio)
                print("   📐 Content width ratio: \(String(format: "%.3f", ratio)) (\(Int(contentWidth))/\(Int(bufferWidth)) px)")
            }
            didApplyContentWidthRatio = true
        }



        // If interpolation is enabled, run through interpolator
        if #available(macOS 14.0, *),
           upscaleSettings.mode == .frameInterpolation || upscaleSettings.frameInterpolationEnabled
        {
            if interpolationUnsupported {
                appState.processingStatus = "Interpolation unsupported on this device"
                overlay.displayBufferImmediate(frame.pixelBuffer)
                updateFPS()
                return
            }

            do {
                let spatialUpscaleEnabled = activeSpatialUpscaleEnabled ?? upscaleSettings.spatialUpscaleEnabled
                let processingResolution = activeProcessingResolution ?? upscaleSettings.processingResolution
                if interpolator == nil {
                    let width = Int32(CVPixelBufferGetWidth(frame.pixelBuffer))
                    let height = Int32(CVPixelBufferGetHeight(frame.pixelBuffer))
                    let dims = CMVideoDimensions(width: width, height: height)
                    let numBetween = spatialUpscaleEnabled ? 1 : max(1, min(3, upscaleSettings.interpolationMultiplier - 1))
                    let res = processingResolution.dimensions
                    interpolator = try RealTimeFrameInterpolation(
                        numFrames: numBetween,
                        inputDimensions: dims,
                        maxWidth: res.width,
                        maxHeight: res.height,
                        spatialUpscale: spatialUpscaleEnabled
                    )
                    try await interpolator?.start()
                }
                if let outputs = try await interpolator?.process(
                    currentBuffer: frame.pixelBuffer,
                    currentTimestamp: currentPTS
                ) {
                    let isModelReady = await interpolator?.modelReady ?? false

                    if isModelReady {
                        interpolatedFrameCount += spatialUpscaleEnabled ? max(0, outputs.count - 1) : outputs.count
                        if passthroughFrameCount > 0 {
                            if spatialUpscaleEnabled {
                                print("   ✅ Interpolation + 2x upscale active! \(outputs.count) processed frames per input")
                            } else {
                                print("   ✅ Interpolation active! \(outputs.count) interpolated + 1 original per input")
                            }
                            passthroughFrameCount = 0
                        }
                        let outputFrameCount = max(1, outputs.count)
                        let totalPerInput = spatialUpscaleEnabled ? outputFrameCount : outputFrameCount + 1
                        appState.processingStatus = spatialUpscaleEnabled
                            ? "Interpolating + 2x Upscale (\(totalPerInput) frames/input)"
                            : "Interpolating (\(totalPerInput) frames/input)"

                        // Calculate evenly spaced offsets for smooth frame pacing
                        let frameDuration = CMTimeGetSeconds(currentPTS) - CMTimeGetSeconds(prevPTS)
                        let step = frameDuration / Double(totalPerInput)

                        for (i, buffer) in outputs.enumerated() {
                            overlay.enqueueBuffer(buffer, offsetFromNow: step * Double(i))
                            updateFPS()
                        }
                        if !spatialUpscaleEnabled {
                            // Original frame at the end of the interval
                            overlay.enqueueBuffer(frame.pixelBuffer, offsetFromNow: step * Double(outputs.count))
                            updateFPS()
                        }
                    } else if await interpolator?.modelFailed ?? false {
                        // Model timed out — auto-fallback to lower resolution
                        let current = processingResolution
                        if let lower = current.lowerResolution {
                            print("   🔄 \(current.rawValue) unsupported, falling back to \(lower.rawValue)")
                            appState.processingStatus = "\(current.rawValue) unsupported, using \(lower.rawValue)"
                            activeProcessingResolution = lower
                            await interpolator?.stop()
                            interpolator = nil
                            // Next frame will recreate with lower resolution
                        } else if spatialUpscaleEnabled {
                            let fallbackResolution = DeviceCapabilityDatabase.shared.recommendedFrameInterpolationResolution()
                                ?? .p720
                            print("   🔄 2x upscale unsupported, falling back to plain interpolation at \(fallbackResolution.rawValue)")
                            appState.processingStatus = "2x upscale unsupported, using plain interpolation"
                            activeSpatialUpscaleEnabled = false
                            activeProcessingResolution = fallbackResolution
                            await interpolator?.stop()
                            interpolator = nil
                            passthroughFrameCount = 0
                        } else {
                            appState.processingStatus = "Interpolation unsupported on this device"
                            interpolationUnsupported = true
                            await interpolator?.stop()
                            interpolator = nil
                        }
                        overlay.displayBufferImmediate(frame.pixelBuffer)
                        updateFPS()
                    } else {
                        passthroughFrameCount += 1
                        appState.processingStatus = spatialUpscaleEnabled
                            ? "Loading model + 2x upscale (\(processingResolution.rawValue))..."
                            : "Loading model (\(processingResolution.rawValue))..."
                        overlay.displayBufferImmediate(frame.pixelBuffer)
                        updateFPS()
                    }
                    return
                }
            } catch {
                // Fallback to passthrough on error
            }
        }

        // Passthrough path
        appState.processingStatus = "Passthrough (\(upscaleSettings.mode.rawValue))"
        overlay.displayBufferImmediate(frame.pixelBuffer)
        updateFPS()
    }

    private func updateFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSTime)

        if elapsed >= 1.0 {
            let fps = Double(frameCount) / elapsed
            currentSourceFPS = Double(sourceFrameCount) / elapsed
            appState.updateFPS(fps)
            frameCount = 0
            sourceFrameCount = 0
            lastFPSTime = now

            var processingRes: CGSize? = nil
            if #available(macOS 14.0, *), let interp = interpolator {
                let outDims = interp.outputDimensions
                processingRes = CGSize(width: CGFloat(outDims.width), height: CGFloat(outDims.height))
            }
            overlayManager?.updateDebugInfo(
                fps: fps,
                sourceFPS: currentSourceFPS,
                status: appState.processingStatus,
                captureRes: captureSettings.captureResolution,
                processingRes: processingRes,
                mode: upscaleSettings.mode.rawValue
            )
        }
    }

    private func matchCaptureResolutionToWindow() async {
        // No-op: window ID may map to auxiliary windows with tiny dimensions.
        // Default 1920x1080 is reliable. The minor content padding (~3%) is acceptable.
    }

    /// Creates the appropriate display: overlay on target window, or standalone window.
    private func createDisplayForCapture(overlay: OverlayManager) {
        if let windowID = captureSettings.targetWindowID {
            overlay.createOverlayOnWindow(windowID: windowID)
            overlay.show()
            print("   🎯 Overlay mode: tracking window \(windowID)")
        } else {
            let captureSize = captureSettings.captureResolution
            overlay.createDisplayWindow(contentSize: captureSize)
            overlay.show()
            print("   🖥️ Standalone window mode")
        }
    }

    private func resetRuntimeFallbacks() {
        activeProcessingResolution = nil
        activeSpatialUpscaleEnabled = nil
        interpolationUnsupported = false
    }

    func setDebugOverlay(_ visible: Bool) {
        overlayManager?.showDebugOverlay = visible
    }

    func updateUpscaleSettings(_ newSettings: UpscaleSettings) {
        upscaleSettings = newSettings
        resetRuntimeFallbacks()
        videoToolboxUpscaler?.updateSettings(newSettings)
    }

    // MARK: - Picker

    @available(macOS 12.3, *)
    func presentPicker() {
        if captureManager == nil {
            captureManager = ScreenCaptureManager(settings: captureSettings)
            captureManager?.onPickerFilterSelected = { [weak self] filter in
                Task { @MainActor in
                    await self?.startCaptureWithFilter(filter)
                }
            }
        }
        captureManager?.presentPicker()
    }

    @available(macOS 12.3, *)
    private func startCaptureWithFilter(_ filter: SCContentFilter) async {
        // If already capturing, the filter was applied to the running session
        guard !appState.isCapturing else { return }

        guard let overlay = overlayManager else { return }

        do {
            let stream = try await captureManager!.startCapture()
            // Apply the picked filter to the new session
            await captureManager?.applyPickerFilter(filter)
            appState.startCapture()

            if #available(macOS 14.0, *) {
                interpolator = nil
            }
            resetRuntimeFallbacks()

            createDisplayForCapture(overlay: overlay)

            captureTask = Task { [weak self] in
                do {
                    for try await frame in stream {
                        await self?.processFrame(frame)
                    }
                } catch {
                    await MainActor.run {
                        self?.appState.setError("Capture stream error: \(error.localizedDescription)")
                    }
                    await self?.stopCapture()
                }
            }
        } catch {
            appState.setError("Failed to start capture: \(error.localizedDescription)")
        }
    }
}
