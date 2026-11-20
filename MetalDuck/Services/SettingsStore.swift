//
//  SettingsStore.swift
//  MetalDuck
//

import Foundation

/// Saves the user's settings between launches.
///
/// What is stored is decided by each settings type's `CodingKeys`. The capture target is
/// deliberately left out: a window ID does not survive its window closing, so a saved one would
/// make Start Capture fail instead of asking what to capture.
struct SettingsStore {
    private enum Key {
        static let capture = "captureSettings"
        static let upscale = "upscaleSettings"
        static let debugHUD = "showDebugHUD"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCaptureSettings() -> CaptureSettings {
        load(Key.capture) ?? CaptureSettings()
    }

    func loadUpscaleSettings() -> UpscaleSettings {
        load(Key.upscale) ?? UpscaleSettings()
    }

    func save(_ settings: CaptureSettings) {
        store(settings, Key.capture)
    }

    func save(_ settings: UpscaleSettings) {
        store(settings, Key.upscale)
    }

    var showDebugHUD: Bool {
        get { defaults.object(forKey: Key.debugHUD) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.debugHUD) }
    }

    private func load<Value: Decodable>(_ key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func store<Value: Encodable>(_ value: Value, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or holds something unreadable.
    /// Settings decode field by field with this, so one bad or new field never resets the rest.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
