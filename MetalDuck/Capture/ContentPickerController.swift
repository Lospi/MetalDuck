//
//  ContentPickerController.swift
//  MetalDuck
//

import ScreenCaptureKit

/// The app's single observer of the system content picker.
///
/// Registered once and kept for the app's lifetime. The picker walks its observer list on a
/// background queue while delivering a selection, so registering another observer at that moment
/// (as a per-capture observer would) crashes with "collection was mutated while being enumerated".
final class ContentPickerController: NSObject {
    var onFilterSelected: ((SCContentFilter) -> Void)?
    var onStartFailed: ((String) -> Void)?

    override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
        SCContentSharingPicker.shared.isActive = true
    }

    func present() {
        SCContentSharingPicker.shared.present()
    }
}

extension ContentPickerController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // no-op
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // SCContentFilter is not Sendable. The picker hands it over and never touches it again,
        // so transferring it to the main actor is safe.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor [weak self] in
            self?.onFilterSelected?(filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onStartFailed?(message)
        }
    }
}
