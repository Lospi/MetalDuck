//
//  ContentView.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 07/11/25.
//

import SwiftUI

struct ContentView: View {
    @Bindable private var coordinator = AppCoordinator.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .imageScale(.large)
                .foregroundStyle(.tint)
            
            Text("MetalDuck")
                .font(.title)
            
            if coordinator.appState.isCapturing {
                VStack(spacing: 4) {
                    Text("Capturing...")
                        .foregroundColor(.green)
                    Text("FPS: \(coordinator.appState.currentFPS, specifier: "%.1f")")
                        .font(.caption)
                    Text(coordinator.appState.processingStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ready to capture")
                    .foregroundColor(.secondary)
            }
            
            if let error = coordinator.appState.captureError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding()
            }
            
            if coordinator.appState.isCapturing {
                Button("Stop Capture") {
                    Task {
                        await coordinator.stopCapture()
                    }
                }
            } else {
                Button("Start Capture") {
                    Task {
                        await coordinator.startCapture()
                    }
                }
            }
        }
        .padding()
        .frame(width: 300, height: 200)
    }
}

#Preview {
    ContentView()
}
