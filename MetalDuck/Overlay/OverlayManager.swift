//
//  OverlayManager.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import Foundation
import AppKit
import AVFoundation
import CoreVideo
import CoreMedia
import QuartzCore

class OverlayManager {
    private var displayWindow: NSWindow?
    private var displayView: NSView?
    private var trackingTimer: Timer?
    private var trackedWindowID: CGWindowID?
    /// Content width / buffer width ratio — used to expand layer so black padding is clipped
    private var contentWidthRatio: CGFloat = 1.0

    // AVSampleBufferDisplayLayer for vsync'd, timed frame presentation
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    private var sampleBufferRenderer: AVSampleBufferVideoRenderer?
    private let enqueueQueue = DispatchQueue(label: "com.metalduck.enqueue")

    // Debug HUD
    private var debugTextField: NSTextField?
    var showDebugOverlay = true {
        didSet {
            if showDebugOverlay {
                if debugTextField == nil { setupDebugOverlay() }
            } else {
                debugTextField?.removeFromSuperview()
                debugTextField = nil
            }
        }
    }

    // MARK: - Overlay Mode (tracks a target window)

    func createOverlayOnWindow(windowID: CGWindowID) {
        close()
        trackedWindowID = windowID

        guard let frame = Self.windowFrame(for: windowID) else {
            print("   ❌ Could not find window \(windowID) to overlay")
            return
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true

        window.contentView = view
        self.displayWindow = window
        self.displayView = view

        setupSampleBufferLayer(in: view)
        setupDebugOverlay()
        startTrackingWindow()
    }

    // MARK: - Standalone Window Mode

    func createDisplayWindow(contentSize: CGSize) {
        close()
        trackedWindowID = nil

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "MetalDuck"
        window.backgroundColor = .black
        window.isOpaque = true
        window.minSize = NSSize(width: 320, height: 240)
        window.center()

        let view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        window.contentView = view
        self.displayWindow = window
        self.displayView = view

        setupSampleBufferLayer(in: view)
        setupDebugOverlay()
    }

    // MARK: - AVSampleBufferDisplayLayer Setup

    private func setupSampleBufferLayer(in view: NSView) {
        view.layer?.masksToBounds = true

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resize
        layer.frame = view.bounds

        // Create a timebase synced to the host clock at real-time rate
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }

        view.layer?.addSublayer(layer)
        self.sampleBufferLayer = layer
        self.sampleBufferRenderer = layer.sampleBufferRenderer
    }

    // MARK: - Display

    func show() {
        displayWindow?.orderFront(nil)
    }

    func hide() {
        stopTrackingWindow()
        displayWindow?.orderOut(nil)
    }

    /// Call once after the first frame to set the content-to-buffer width ratio.
    func setContentWidthRatio(_ ratio: CGFloat) {
        guard ratio > 0, ratio <= 1.0 else { return }
        contentWidthRatio = ratio
        updateSampleBufferLayerFrame()
    }

    /// Sizes the sample buffer layer so content fills the view and black padding overflows.
    private func updateSampleBufferLayerFrame() {
        guard let view = displayView, let layer = sampleBufferLayer else { return }
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        if contentWidthRatio < 1.0 {
            // Expand layer width so content pixels map exactly to the view width
            let expandedWidth = viewSize.width / contentWidthRatio
            layer.frame = CGRect(x: 0, y: 0, width: expandedWidth, height: viewSize.height)
        } else {
            layer.frame = CGRect(origin: .zero, size: viewSize)
        }
    }

    /// Current time on the display layer's timebase.
    private var currentTimebaseTime: CMTime {
        guard let timebase = sampleBufferLayer?.controlTimebase else {
            return CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        }
        return CMTimebaseGetTime(timebase)
    }

    /// Enqueue a CVPixelBuffer for timed presentation.
    /// `offset` is seconds from now when this frame should be displayed.
    func enqueueBuffer(_ pixelBuffer: CVPixelBuffer, offsetFromNow: Double) {
        guard let renderer = sampleBufferRenderer else { return }
        let pts = CMTimeAdd(currentTimebaseTime, CMTime(seconds: offsetFromNow, preferredTimescale: 600))
        guard let sampleBuffer = Self.createSampleBuffer(from: pixelBuffer, timestamp: pts) else { return }

        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }

    /// Flush pending frames and enqueue immediately (for passthrough / non-timed display).
    func displayBufferImmediate(_ pixelBuffer: CVPixelBuffer) {
        guard let renderer = sampleBufferRenderer else { return }
        renderer.flush()

        let pts = currentTimebaseTime
        guard let sampleBuffer = Self.createSampleBuffer(from: pixelBuffer, timestamp: pts) else { return }

        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }

    // MARK: - Debug HUD

    func updateDebugInfo(
        fps: Double,
        sourceFPS: Double,
        effectiveCaptureFPS: Int,
        autoCaptureFPS: Bool,
        estimatedGameFPS: Int?,
        status: String,
        captureRes: CGSize,
        processingRes: CGSize?,
        mode: String
    ) {
        guard showDebugOverlay, let debugTextField else { return }

        let captureLine: String
        if autoCaptureFPS {
            let estimate = estimatedGameFPS.map { "game ~\($0)" } ?? "estimating"
            captureLine = " Auto Capture: \(effectiveCaptureFPS) FPS (\(estimate)) "
        } else {
            captureLine = " Capture: \(effectiveCaptureFPS) FPS "
        }

        var lines = [
            captureLine,
            String(format: " Delivered: %.0f → Display: %.0f FPS ", sourceFPS, fps),
            " \(status) ",
            " Capture: \(Int(captureRes.width))x\(Int(captureRes.height)) ",
        ]
        if let proc = processingRes {
            lines.append(" Process: \(Int(proc.width))x\(Int(proc.height)) ")
        }
        lines.append(" \(mode) ")
        debugTextField.stringValue = lines.joined(separator: "\n")

        // Red text when resolution is unsupported
        let isError = status.contains("unsupported")
        debugTextField.textColor = isError ? .systemRed : .white
    }

    private func setupDebugOverlay() {
        guard showDebugOverlay, let view = displayView else { return }

        let hudView = NSTextField(labelWithString: "MetalDuck")
        hudView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        hudView.textColor = .white
        hudView.backgroundColor = NSColor(white: 0, alpha: 0.6)
        hudView.isBezeled = false
        hudView.isEditable = false
        hudView.drawsBackground = true
        hudView.maximumNumberOfLines = 6
        hudView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hudView)
        NSLayoutConstraint.activate([
            hudView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
        ])

        self.debugTextField = hudView
    }

    // MARK: - Cleanup

    func close() {
        stopTrackingWindow()
        sampleBufferRenderer?.flush()
        sampleBufferLayer?.removeFromSuperlayer()
        sampleBufferLayer = nil
        sampleBufferRenderer = nil
        debugTextField?.removeFromSuperview()
        debugTextField = nil
        displayWindow?.orderOut(nil)
        displayWindow = nil
        displayView = nil
        trackedWindowID = nil
        contentWidthRatio = 1.0
    }

    // MARK: - Window Tracking

    private func startTrackingWindow() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateOverlayPosition()
        }
    }

    private func stopTrackingWindow() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updateOverlayPosition() {
        guard let windowID = trackedWindowID,
              let frame = Self.windowFrame(for: windowID)
        else { return }

        if displayWindow?.frame != frame {
            displayWindow?.setFrame(frame, display: false)
            displayView?.frame = NSRect(origin: .zero, size: frame.size)
            updateSampleBufferLayerFrame()
        }
    }

    // MARK: - Helpers

    /// Creates a CMSampleBuffer wrapping a CVPixelBuffer with a presentation timestamp.
    private static func createSampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    static func windowFrame(for windowID: CGWindowID) -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]],
              let windowInfo = windowList.first,
              let boundsDict = windowInfo[kCGWindowBounds] as? [String: CGFloat]
        else { return nil }

        let x = boundsDict["X"] ?? 0
        let y = boundsDict["Y"] ?? 0
        let width = boundsDict["Width"] ?? 0
        let height = boundsDict["Height"] ?? 0

        let screenHeight = NSScreen.main?.frame.height ?? 0
        let appKitY = screenHeight - y - height

        return NSRect(x: x, y: appKitY, width: width, height: height)
    }
}
