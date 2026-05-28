//
//  PreferencesView.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import ScreenCaptureKit
import SwiftUI
@preconcurrency import VideoToolbox

struct PreferencesView: View {
    @Binding var captureSettings: CaptureSettings
    @Binding var upscaleSettings: UpscaleSettings
    @State private var targetType: String = "Display"
    @State private var availableWindows: [(id: CGWindowID, title: String)] = []
    @State private var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    @State private var selectedWindowID: CGWindowID?
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var isLoading: Bool = false
    @State private var showDebugHUD: Bool = true
    @State private var showDiagnostics = false

    private let verticalLabelSpacing: CGFloat = 8

    var body: some View {
        Form {
            // MARK: - Capture

            Section {
                Picker("Capture Type", selection: $targetType) {
                    Text("Display").tag("Display")
                    Text("Window").tag("Window")
                }
                .onChange(of: targetType) { _, newValue in
                    if newValue == "Window" {
                        captureSettings.targetDisplayID = nil
                    } else {
                        captureSettings.targetWindowID = nil
                    }
                    loadAvailableTargets()
                }

                if targetType == "Window" {
                    if isLoading {
                        Text("Loading windows...")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Window", selection: Binding(
                            get: { selectedWindowID },
                            set: { newValue in
                                selectedWindowID = newValue
                                captureSettings.targetWindowID = newValue
                                captureSettings.targetDisplayID = nil
                            }
                        )) {
                            Text("Select a window...").tag(nil as CGWindowID?)
                            ForEach(availableWindows, id: \.id) { window in
                                Text(window.title)
                                    .tag(window.id as CGWindowID?)
                            }
                        }
                    }
                } else {
                    if isLoading {
                        Text("Loading displays...")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Display", selection: Binding(
                            get: { selectedDisplayID },
                            set: { newValue in
                                selectedDisplayID = newValue
                                captureSettings.targetDisplayID = newValue
                                captureSettings.targetWindowID = nil
                            }
                        )) {
                            Text("Select a display...").tag(nil as CGDirectDisplayID?)
                            ForEach(availableDisplays, id: \.id) { display in
                                Text(display.name)
                                    .tag(display.id as CGDirectDisplayID?)
                            }
                        }
                    }
                }

                Toggle("Auto Capture FPS", isOn: $captureSettings.autoFrameRateEnabled)

                Stepper("Capture FPS: \(captureSettings.frameRate)",
                        value: $captureSettings.frameRate,
                        in: 30...120, step: 30)
                    .disabled(captureSettings.autoFrameRateEnabled)

                if captureSettings.autoFrameRateEnabled {
                    Label(
                        "Auto mode samples up to 120 FPS, then adjusts capture to the detected game rate.",
                        systemImage: "gauge.with.dots.needle.50percent"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                HStack {
                    Button("Refresh") {
                        loadAvailableTargets()
                    }
                    Button("Content Picker") {
                        if #available(macOS 12.3, *) {
                            AppCoordinator.shared.presentPicker()
                        }
                    }
                }
            } header: {
                HeaderView("Capture")
            }

            // MARK: - Processing

            Section {
                Picker("Mode", selection: $upscaleSettings.mode) {
                    Text("Passthrough").tag(UpscaleMode.temporal)
                    Text("Frame Interpolation").tag(UpscaleMode.frameInterpolation)
                }

                if upscaleSettings.mode == .frameInterpolation {
                    Picker("Processing Resolution", selection: $upscaleSettings.processingResolution) {
                        ForEach(ProcessingResolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }

                    resolutionWarning

                    Stepper("Multiplier: \(upscaleSettings.interpolationMultiplier)x",
                            value: $upscaleSettings.interpolationMultiplier,
                            in: 2...4, step: 1)

                    if upscaleSettings.interpolationMultiplier > 2 {
                        Label(
                            "Multipliers above 2x may cause worse performance, quality, or latency. 2x is recommended.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundColor(.orange)
                    }

                    Text("\(captureSettings.frameRate) fps capture → \(upscaleSettings.targetFrameRate(sourceFrameRate: captureSettings.frameRate)) fps output")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            } header: {
                HeaderView("Processing")
            }

            // MARK: - Debug

            Section {
                Toggle("Show Debug HUD", isOn: $showDebugHUD)
                    .onChange(of: showDebugHUD) { _, newValue in
                        AppCoordinator.shared.setDebugOverlay(newValue)
                    }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("Run Device Diagnostics...") {
                        showDiagnostics = true
                    }
                    Text("Help us improve the app")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                HeaderView("Debug")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: upscaleSettings.mode) { _, _ in
            AppCoordinator.shared.updateUpscaleSettings(upscaleSettings)
            restartCaptureIfNeeded()
        }
        .onChange(of: upscaleSettings.interpolationMultiplier) { _, _ in
            AppCoordinator.shared.updateUpscaleSettings(upscaleSettings)
            restartCaptureIfNeeded()
        }
        .onChange(of: upscaleSettings.processingResolution) { _, _ in
            AppCoordinator.shared.updateUpscaleSettings(upscaleSettings)
            restartCaptureIfNeeded()
        }
        .onChange(of: captureSettings.frameRate) { _, _ in
            AppCoordinator.shared.updateCaptureSettings(captureSettings)
            guard !captureSettings.autoFrameRateEnabled else { return }
            restartCaptureIfNeeded()
        }
        .onChange(of: captureSettings.autoFrameRateEnabled) { _, newValue in
            if newValue {
                captureSettings.frameRate = CaptureSettings.autoFrameRateSamplingCeiling
            }
            AppCoordinator.shared.updateCaptureSettings(captureSettings)
            restartCaptureIfNeeded()
        }
        .sheet(isPresented: $showDiagnostics) {
            if #available(macOS 14.0, *) {
                DiagnosticsView()
            }
        }
        .onAppear {
            if captureSettings.targetWindowID != nil {
                targetType = "Window"
                selectedWindowID = captureSettings.targetWindowID
            } else if captureSettings.targetDisplayID != nil {
                targetType = "Display"
                selectedDisplayID = captureSettings.targetDisplayID
            } else {
                targetType = "Display"
            }
            showDebugHUD = AppCoordinator.shared.overlayManager?.showDebugOverlay ?? true
            loadAvailableTargets()
        }
    }

    // MARK: - Resolution Warning

    @ViewBuilder
    private var resolutionWarning: some View {
        let db = DeviceCapabilityDatabase.shared
        let support = db.frameInterpolationSupport(for: upscaleSettings.processingResolution)
        let recommended = db.recommendedFrameInterpolationResolution()

        switch support {
        case .knownUnsupported:
            Label(
                "Not supported on this device — a lower resolution will be set automatically.",
                systemImage: "xmark.circle"
            )
            .font(.caption)
            .foregroundColor(.red)

        case .unknown:
            Label(
                "Support is unknown for this device. A lower resolution will be set automatically if it fails.",
                systemImage: "questionmark.circle"
            )
            .font(.caption)
            .foregroundColor(.orange)

        case .noData:
            Label(
                "No data for this device yet. Run Diagnostics to contribute.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundColor(.secondary)

        case .knownSupported:
            if let rec = recommended, rec != upscaleSettings.processingResolution {
                Label(
                    "Recommended for this device: \(rec.rawValue)",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private func restartCaptureIfNeeded() {
        guard AppCoordinator.shared.appState.isCapturing else { return }
        Task {
            await AppCoordinator.shared.stopCapture()
            await AppCoordinator.shared.startCapture()
        }
    }

    @available(macOS 12.3, *)
    private func loadAvailableTargets() {
        isLoading = true

        Task {
            if targetType == "Window" {
                let windows = await ScreenCaptureManager.getAvailableWindows()
                await MainActor.run {
                    availableWindows = windows.compactMap { window in
                        guard window.isOnScreen,
                              window.frame.width > 100,
                              window.frame.height > 100
                        else { return nil }

                        let appName = window.owningApplication?.applicationName
                        let title = window.title?.isEmpty == false ? window.title! : nil
                        let displayName: String
                        if let title, let appName {
                            displayName = "\(appName) — \(title)"
                        } else if let appName {
                            displayName = appName
                        } else {
                            return nil
                        }

                        return (id: window.windowID, title: displayName)
                    }
                    isLoading = false
                }
            } else {
                let displays = await ScreenCaptureManager.getAvailableDisplays()
                await MainActor.run {
                    availableDisplays = displays.map { display in
                        let displayID = display.displayID
                        let width = Int(display.width)
                        let height = Int(display.height)
                        let name = "Display \(displayID) (\(width)x\(height))"
                        return (id: displayID, name: name)
                    }
                    isLoading = false
                }
            }
        }
    }
}
