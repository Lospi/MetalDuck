//
//  MenuBarController.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import AppKit
import Foundation
import Sparkle
import SwiftUI

@Observable
class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var preferencesWindow: NSWindow?
    var appState: AppState
    private weak var updaterController: SPUStandardUpdaterController?

    init(appState: AppState, updaterController: SPUStandardUpdaterController) {
        self.appState = appState
        self.updaterController = updaterController
        super.init()
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "MetalDuck")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        let startItem = NSMenuItem(title: "Start Capture", action: #selector(startCapture), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop Capture", action: #selector(stopCapture), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        self.startItem = startItem
        self.stopItem = stopItem
        updateCaptureItems()

        menu.addItem(NSMenuItem.separator())

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MetalDuck", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        appState.menuBarItem = statusItem
    }
    
    /// Only the action that applies right now is shown.
    private func updateCaptureItems() {
        startItem?.isHidden = appState.isCapturing
        stopItem?.isHidden = !appState.isCapturing
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateCaptureItems()
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func startCapture() {
        NotificationCenter.default.post(name: .startCapture, object: nil)
    }
    
    @objc private func stopCapture() {
        NotificationCenter.default.post(name: .stopCapture, object: nil)
    }
    
    @objc private func showPreferences() {
        if preferencesWindow == nil {
            let contentView = PreferencesView(
                captureSettings: Binding(
                    get: { AppCoordinator.shared.captureSettings },
                    set: { AppCoordinator.shared.captureSettings = $0 }
                ),
                upscaleSettings: Binding(
                    get: { AppCoordinator.shared.upscaleSettings },
                    set: { AppCoordinator.shared.upscaleSettings = $0 }
                )
            )
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.title = "MetalDuck Preferences"
            window.isReleasedWhenClosed = false
            
            preferencesWindow = window
        }
        
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    static let startCapture = Notification.Name("startCapture")
    static let stopCapture = Notification.Name("stopCapture")
}
