//
//  SettingsStoreTests.swift
//  MetalDuckTests
//
//  Tests settings persistence against a throwaway UserDefaults suite.
//

import Foundation
import Testing
@testable import MetalDuck

@MainActor
struct SettingsStoreTests {
    private let suiteName = "MetalDuckTests.\(UUID().uuidString)"

    /// A store backed by its own empty suite, plus that suite for writing raw data.
    private func makeStore() throws -> (store: SettingsStore, defaults: UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (SettingsStore(defaults: defaults), defaults)
    }

    private func write(_ json: String, forKey key: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: - Defaults

    @Test("An empty store returns the default settings", .tags(.settings))
    func emptyStoreReturnsDefaults() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let capture = store.loadCaptureSettings()
        let upscale = store.loadUpscaleSettings()

        #expect(capture.frameRate == 60)
        #expect(capture.autoFrameRateEnabled == false)
        #expect(upscale.mode == .temporal)
        #expect(upscale.processingResolution == .p720)
        #expect(upscale.autoStepDownEnabled)
        #expect(store.showDebugHUD, "The debug HUD is on until the user turns it off.")
    }

    // MARK: - Round trips

    @Test("Processing settings survive a save and load", .tags(.settings))
    func upscaleSettingsRoundTrip() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = UpscaleSettings()
        settings.mode = .frameInterpolation
        settings.processingResolution = .p1080
        settings.interpolationMultiplier = 3
        settings.autoStepDownEnabled = false
        store.save(settings)

        let loaded = SettingsStore(defaults: defaults).loadUpscaleSettings()
        #expect(loaded.mode == .frameInterpolation)
        #expect(loaded.processingResolution == .p1080)
        #expect(loaded.interpolationMultiplier == 3)
        #expect(loaded.spatialUpscaleEnabled == false)
        #expect(loaded.autoStepDownEnabled == false)
    }

    @Test("Capture settings survive a save and load", .tags(.settings))
    func captureSettingsRoundTrip() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = CaptureSettings()
        settings.frameRate = 90
        settings.autoFrameRateEnabled = true
        settings.selectedDynamicRangePreset = .localDisplayHDR
        store.save(settings)

        let loaded = SettingsStore(defaults: defaults).loadCaptureSettings()
        #expect(loaded.frameRate == 90)
        #expect(loaded.autoFrameRateEnabled)
        #expect(loaded.selectedDynamicRangePreset == .localDisplayHDR)
    }

    @Test("The debug HUD choice survives a save and load", .tags(.settings))
    func debugHUDRoundTrip() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.showDebugHUD = false
        #expect(SettingsStore(defaults: defaults).showDebugHUD == false)
    }

    // MARK: - What is deliberately not stored

    @Test("The capture target is not stored", .tags(.settings, .capture))
    func captureTargetIsSessionOnly() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = CaptureSettings()
        settings.targetWindowID = 42
        settings.targetDisplayID = 7
        store.save(settings)

        let loaded = store.loadCaptureSettings()
        #expect(loaded.targetWindowID == nil)
        #expect(loaded.targetDisplayID == nil)
        #expect(!loaded.hasTarget, "A restored target would make Start Capture fail instead of prompting.")
    }

    @Test("The capture resolution stays fixed whatever was stored", .tags(.settings, .capture))
    func captureResolutionIsNotRestored() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(#"{"frameRate": 60, "captureResolution": [640, 360]}"#, forKey: "captureSettings", to: defaults)

        #expect(store.loadCaptureSettings().captureResolution == CGSize(width: 1920, height: 1080))
    }

    // MARK: - Tolerant decoding

    @Test("Settings saved before a field existed keep that field's default", .tags(.settings))
    func missingFieldsKeepDefaults() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(#"{"mode": "Frame Interpolation", "processingResolution": "360p"}"#, forKey: "upscaleSettings", to: defaults)

        let loaded = store.loadUpscaleSettings()
        #expect(loaded.mode == .frameInterpolation)
        #expect(loaded.processingResolution == .p360)
        #expect(loaded.interpolationMultiplier == 2)
        #expect(loaded.autoStepDownEnabled)
    }

    @Test("One unreadable field does not reset the others", .tags(.settings))
    func unreadableFieldFallsBackAlone() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(
            #"{"mode": "Frame Interpolation", "processingResolution": "8K", "interpolationMultiplier": "three", "autoStepDownEnabled": false}"#,
            forKey: "upscaleSettings", to: defaults
        )

        let loaded = store.loadUpscaleSettings()
        #expect(loaded.mode == .frameInterpolation)
        #expect(loaded.processingResolution == .p720, "An unknown resolution falls back to the default.")
        #expect(loaded.interpolationMultiplier == 2)
        #expect(loaded.autoStepDownEnabled == false)
    }

    @Test("Corrupt data falls back to the defaults", .tags(.settings))
    func corruptDataFallsBackToDefaults() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write("not json", forKey: "upscaleSettings", to: defaults)
        write("[1, 2, 3]", forKey: "captureSettings", to: defaults)

        #expect(store.loadUpscaleSettings().processingResolution == .p720)
        #expect(store.loadCaptureSettings().frameRate == 60)
    }

    // MARK: - Out-of-range values

    @Test("A stored capture rate is brought back to one Preferences can show", .tags(.settings), arguments: [
        (0, 30), (29, 30), (45, 60), (60, 60), (100, 90), (120, 120), (500, 120), (-10, 30)
    ])
    func captureRateIsValidated(stored: Int, expected: Int) throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(#"{"frameRate": \#(stored)}"#, forKey: "captureSettings", to: defaults)

        #expect(store.loadCaptureSettings().frameRate == expected)
    }

    @Test("A stored multiplier is clamped to the supported range", .tags(.settings, .upscaling), arguments: [
        (0, 2), (2, 2), (4, 4), (9, 4)
    ])
    func multiplierIsClamped(stored: Int, expected: Int) throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(#"{"interpolationMultiplier": \#(stored)}"#, forKey: "upscaleSettings", to: defaults)

        #expect(store.loadUpscaleSettings().interpolationMultiplier == expected)
    }

    @Test("2x upscale always restores with a 2x multiplier", .tags(.settings, .upscaling))
    func spatialUpscaleFixesMultiplier() throws {
        let (store, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        write(#"{"spatialUpscaleEnabled": true, "interpolationMultiplier": 4}"#, forKey: "upscaleSettings", to: defaults)

        let loaded = store.loadUpscaleSettings()
        #expect(loaded.spatialUpscaleEnabled)
        #expect(loaded.interpolationMultiplier == 2)
    }
}
