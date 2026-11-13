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
    var captureSettings = CaptureSettings() {
        didSet {
            // Choosing a target in Preferences replaces whatever was picked in the system picker.
            if captureSettings.targetWindowID != oldValue.targetWindowID
                || captureSettings.targetDisplayID != oldValue.targetDisplayID {
                pickedFilter = nil
            }
        }
    }
    var upscaleSettings = UpscaleSettings()

    private var videoToolboxUpscaler: VideoToolboxUpscaler?
    private(set) var overlayManager: OverlayManager?
    private var captureManager: ScreenCaptureManager?
    private var contentPicker: ContentPickerController?
    /// Content chosen in the system picker. Used for every start until the Preferences target changes.
    private var pickedFilter: SCContentFilter?
    private var menuBarController: MenuBarController?
    private var captureTask: Task<Void, Never>?
    private let updaterDelegate = UpdaterDelegate()
    private var updaterController: SPUStandardUpdaterController?

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
    private var throughputMonitor = InterpolationThroughputMonitor()
    /// Set when this session lowered the resolution because interpolation was too slow.
    private var throughputStepDownNote: String?
    private var effectiveCaptureFrameRate = 60
    private var frameRateEstimator = FrameRateEstimator(initialFrameRate: 60)

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
        guard !appState.isCapturing, !appState.isStarting else { return }

        if !PermissionManager.shared.hasScreenRecordingPermission {
            let granted = await PermissionManager.shared.requestScreenRecordingPermission()
            if !granted {
                appState.setError("Screen recording permission is required")
                return
            }
        }

        ensureContentPicker()

        if let pickedFilter {
            await beginCapture(filter: pickedFilter)
        } else if captureSettings.hasTarget {
            await beginCapture(filter: nil)
        } else {
            // Nothing has been chosen yet: ask, and start once the user picks.
            presentPicker()
        }
    }

    /// Starts capturing `filter`, or the Preferences target when `filter` is nil.
    private func beginCapture(filter: SCContentFilter?) async {
        // Starting the stream suspends, so a second request could otherwise slip in before
        // `isCapturing` is set and start a second, orphaned stream.
        guard appState.beginStarting() else { return }

        guard let overlay = overlayManager else {
            appState.cancelStarting()
            appState.setError("Overlay not initialized")
            return
        }

        // Match capture resolution to window size before starting capture
        await matchCaptureResolutionToWindow()
        prepareCaptureFrameRateForStart()

        let manager = ScreenCaptureManager(settings: activeCaptureSettings)
        captureManager = manager

        do {
            let stream = try await manager.startCapture(filter: filter)
            appState.startCapture()

            interpolator = nil
            resetRuntimeFallbacks()

            createDisplayForCapture(overlay: overlay, usesPickedContent: filter != nil)

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
            appState.cancelStarting()
            // The picked content may no longer exist; ask again on the next start.
            if filter != nil { pickedFilter = nil }
            appState.setError("Failed to start capture: \(error.localizedDescription)")
        }
    }

    func stopCapture() async {
        guard appState.isCapturing else { return }

        // Mark as not capturing first to prevent re-entrant calls
        appState.stopCapture()

        let task = captureTask
        captureTask = nil
        task?.cancel()

        await captureManager?.stopCapture()
        captureManager = nil

        // Stop the interpolator's VTFrameProcessor session
        await interpolator?.stop()
        interpolator = nil

        overlayManager?.close()
        lastFrameTimestamp = nil
        didApplyContentWidthRatio = false
        resetRuntimeFallbacks()
        resetAutoFrameRateEstimator()
    }

    private func processFrame(_ frame: CapturedFrame) async {
        guard let overlay = overlayManager else { return }
        sourceFrameCount += 1
        await updateAutoFrameRateIfNeeded(for: frame)

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
        if upscaleSettings.mode == .frameInterpolation || upscaleSettings.frameInterpolationEnabled {
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
                    throughputMonitor.reset()
                }
                let processingStart = ContinuousClock.now
                if let outputs = try await interpolator?.process(
                    currentBuffer: frame.pixelBuffer,
                    currentTimestamp: currentPTS
                ).map(\.buffer) {
                    let processingTime = ContinuousClock.now - processingStart
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
                        appState.processingStatus = (spatialUpscaleEnabled
                            ? "Interpolating + 2x Upscale (\(totalPerInput) frames/input)"
                            : "Interpolating (\(totalPerInput) frames/input)")
                            + (throughputStepDownNote.map { " · \($0)" } ?? "")

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

                        await stepDownIfTooSlow(processingTime: processingTime, from: processingResolution)
                    } else if await interpolator?.modelFailed ?? false {
                        await advanceInterpolationFallback()
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
                guard !Task.isCancelled, appState.isCapturing else { return }
                print("   Frame interpolation failed: \(error.localizedDescription)")
                await advanceInterpolationFallback()
                overlay.displayBufferImmediate(frame.pixelBuffer)
                updateFPS()
                return
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
            if let interp = interpolator {
                let outDims = interp.outputDimensions
                processingRes = CGSize(width: CGFloat(outDims.width), height: CGFloat(outDims.height))
            }
            overlayManager?.updateDebugInfo(
                fps: fps,
                sourceFPS: currentSourceFPS,
                effectiveCaptureFPS: effectiveCaptureFrameRate,
                autoCaptureFPS: captureSettings.autoFrameRateEnabled,
                estimatedGameFPS: frameRateEstimator.estimatedFrameRate,
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
    private func createDisplayForCapture(overlay: OverlayManager, usesPickedContent: Bool) {
        // Picked content has no window ID to track, so it always gets the standalone window.
        if !usesPickedContent, let windowID = captureSettings.targetWindowID {
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

    private func advanceInterpolationFallback() async {
        let current = InterpolationFallback(
            resolution: activeProcessingResolution ?? upscaleSettings.processingResolution,
            spatialUpscaleEnabled: activeSpatialUpscaleEnabled ?? upscaleSettings.spatialUpscaleEnabled
        )
        let recommended = DeviceCapabilityDatabase.shared.recommendedFrameInterpolationResolution() ?? .p720
        let requested = upscaleSettings.processingResolution
        let plainResolution = requested.dimensions.width < recommended.dimensions.width ? requested : recommended
        let next = current.next(plainResolution: plainResolution)
        await interpolator?.stop()
        interpolator = nil
        guard !Task.isCancelled, appState.isCapturing else { return }
        if let next {
            activeProcessingResolution = next.resolution
            activeSpatialUpscaleEnabled = next.spatialUpscaleEnabled
            passthroughFrameCount = 0
            appState.processingStatus = current.spatialUpscaleEnabled && !next.spatialUpscaleEnabled
                ? "2x upscale unsupported, using plain interpolation"
                : "Trying interpolation at \(next.resolution.rawValue)"
        } else {
            interpolationUnsupported = true
            appState.processingStatus = "Interpolation unsupported on this device"
        }
    }

    /// Lowers the processing resolution for this session when interpolation cannot keep up with
    /// the capture rate. The resolution chosen in Preferences is left untouched.
    private func stepDownIfTooSlow(processingTime: Duration, from current: ProcessingResolution) async {
        guard upscaleSettings.autoStepDownEnabled else { return }

        // In auto capture mode the stream samples at a high ceiling, so judge against the detected
        // game rate once there is one.
        let targetFrameRate: Int
        if captureSettings.autoFrameRateEnabled {
            guard let estimated = frameRateEstimator.estimatedFrameRate else { return }
            targetFrameRate = estimated
        } else {
            targetFrameRate = effectiveCaptureFrameRate
        }

        let seconds = Double(processingTime.components.seconds) + Double(processingTime.components.attoseconds) / 1e18
        guard let median = throughputMonitor.observe(
            processingTime: seconds,
            frameInterval: 1.0 / Double(max(1, targetFrameRate))
        ), let lower = current.lowerResolution else { return }

        await interpolator?.stop()
        interpolator = nil
        guard !Task.isCancelled, appState.isCapturing else { return }

        activeProcessingResolution = lower
        passthroughFrameCount = 0
        throughputStepDownNote = "\(current.rawValue) too slow, using \(lower.rawValue)"
        print(String(
            format: "   🔽 %@ takes %.0f ms per frame, too slow for %d FPS capture — stepping down to %@",
            current.rawValue, median * 1000, targetFrameRate, lower.rawValue
        ))
    }

    private func resetRuntimeFallbacks() {
        throughputMonitor.reset()
        throughputStepDownNote = nil
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

    func updateCaptureSettings(_ newSettings: CaptureSettings) {
        let autoFrameRateChanged = captureSettings.autoFrameRateEnabled != newSettings.autoFrameRateEnabled
        captureSettings = newSettings

        if autoFrameRateChanged {
            resetAutoFrameRateEstimator()
        }
    }

    // MARK: - Picker

    func presentPicker() {
        ensureContentPicker()
        contentPicker?.present()
    }

    private func ensureContentPicker() {
        guard contentPicker == nil else { return }
        let picker = ContentPickerController()
        picker.onFilterSelected = { [weak self] filter in
            Task { @MainActor in
                await self?.handlePickedFilter(filter)
            }
        }
        picker.onStartFailed = { [weak self] message in
            self?.appState.setError("Content picker failed: \(message)")
        }
        contentPicker = picker
    }

    private func handlePickedFilter(_ filter: SCContentFilter) async {
        pickedFilter = filter
        if appState.isCapturing {
            await captureManager?.updateContentFilter(filter)
        } else {
            await beginCapture(filter: filter)
        }
    }

    private var activeCaptureSettings: CaptureSettings {
        var settings = captureSettings
        settings.frameRate = effectiveCaptureFrameRate
        return settings
    }

    private func prepareCaptureFrameRateForStart() {
        effectiveCaptureFrameRate = captureSettings.initialCaptureFrameRate
        resetAutoFrameRateEstimator()
        videoToolboxUpscaler?.updateSourceFrameRate(effectiveCaptureFrameRate)
    }

    private func resetAutoFrameRateEstimator() {
        frameRateEstimator.reset(initialFrameRate: effectiveCaptureFrameRate)
    }

    private func updateAutoFrameRateIfNeeded(for frame: CapturedFrame) async {
        guard captureSettings.autoFrameRateEnabled else { return }

        guard let recommendedFrameRate = frameRateEstimator.observe(
            timestamp: frame.frameRateTimestamp,
            changedAreaRatio: frame.changedAreaRatio
        ) else {
            return
        }

        guard recommendedFrameRate != effectiveCaptureFrameRate else { return }

        do {
            guard let captureManager else { return }
            try await captureManager.updateFrameRate(recommendedFrameRate)
            guard !Task.isCancelled, appState.isCapturing else { return }
            effectiveCaptureFrameRate = recommendedFrameRate
            videoToolboxUpscaler?.updateSourceFrameRate(recommendedFrameRate)
            appState.processingStatus = "Auto capture FPS: \(recommendedFrameRate)"
            print("   🎚️ Auto capture FPS adjusted to \(recommendedFrameRate)")
        } catch {
            resetAutoFrameRateEstimator()
            appState.processingStatus = "Auto capture FPS update failed"
            print("   ⚠️ Auto capture FPS update failed: \(error.localizedDescription)")
        }
    }
}
