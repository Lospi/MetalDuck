//
//  DiagnosticsView.swift
//  MetalDuck
//
//  Created by Roberto Camargo on 25/03/26.
//
//  Shows device capability tests for frame interpolation and super-resolution.
//  The generated report can be copied and pasted into a GitHub issue.
//

import SwiftUI

@available(macOS 14.0, *)
struct DiagnosticsView: View {
    @State private var runner = DiagnosticsRunner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider()

            ScrollView {
                if runner.isRunning {
                    runningView
                } else if !runner.reportText.isEmpty {
                    completedView
                } else {
                    idleView
                }
            }
        }
        .frame(width: 580)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundColor(.accentColor)
            Text("Device Diagnostics")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            VStack(spacing: 6) {
                Text("Device Capability Test")
                    .font(.title3.bold())
                Text("Tests which processing resolutions your device supports for\nFrame Interpolation, 2x Upscale, and Super Resolution.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
            Button("Run Diagnostics") {
                Task { await runner.run() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(runner.currentStep)
                    .foregroundColor(.secondary)
                    .font(.callout)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            resultsTable
                .padding(.horizontal, 20)

            spatialResultsTable
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Completed

    private var completedView: some View {
        VStack(alignment: .leading, spacing: 16) {
            resultsTable
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Divider()
                .padding(.horizontal, 20)

            spatialResultsTable
                .padding(.horizontal, 20)

            Divider()
                .padding(.horizontal, 20)

            superResTable
                .padding(.horizontal, 20)

            actionBar
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Frame Interpolation Results

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Frame Interpolation", systemImage: "film.stack")
                .font(.subheadline.bold())

            if !runner.frameInterpIsSupported {
                unsupportedBadge("Not supported on this hardware")
            } else {
                VStack(spacing: 0) {
                    tableHeader(["Resolution", "Dimensions", "Status", "Load Time"])
                    ForEach(runner.frameInterpolationResults) { result in
                        Divider()
                        resultRow(result)
                    }
                }
                .background(Color(.textBackgroundColor).opacity(0.4))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }

    private func resultRow(_ result: DiagnosticsRunner.FrameInterpolationResult) -> some View {
        let dims = result.resolution.dimensions
        return HStack(spacing: 0) {
            cell(result.resolution.rawValue, width: 70, alignment: .leading)
            cell("\(dims.width)×\(dims.height)", width: 110, alignment: .leading)
            statusCell(result.status)
            loadTimeCell(result.status)
        }
        .frame(height: 30)
    }

    private func loadTimeCell(_ status: DiagnosticsRunner.TestStatus) -> some View {
        let text: String
        let color: Color
        switch status {
        case .supported(let t):
            text = String(format: "%.1f s", t)
            color = .secondary
        default:
            text = "—"
            color = .secondary
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundColor(color)
            .frame(width: 80, alignment: .trailing)
            .padding(.horizontal, 10)
    }

    // MARK: - Frame Interpolation + Upscale Results

    private var spatialResultsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Frame Interpolation + 2x Upscale", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.bold())

            if !runner.frameInterpIsSupported {
                unsupportedBadge("Not supported on this hardware")
            } else {
                VStack(spacing: 0) {
                    tableHeader(["Resolution", "Input", "Output", "Status", "Load Time"])
                    ForEach(runner.spatialFrameInterpolationResults) { result in
                        Divider()
                        spatialResultRow(result)
                    }
                }
                .background(Color(.textBackgroundColor).opacity(0.4))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }

    private func spatialResultRow(_ result: DiagnosticsRunner.FrameInterpolationResult) -> some View {
        let dims = result.resolution.dimensions
        return HStack(spacing: 0) {
            cell(result.resolution.rawValue, width: 70, alignment: .leading)
            cell("\(dims.width)×\(dims.height)", width: 90, alignment: .leading)
            cell("\(dims.width * 2)×\(dims.height * 2)", width: 110, alignment: .leading)
            statusCell(result.status)
            loadTimeCell(result.status)
        }
        .frame(height: 30)
    }

    // MARK: - Super Resolution Results

    private var superResTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Super Resolution", systemImage: "sparkles")
                .font(.subheadline.bold())

            if !runner.superResIsSupported {
                unsupportedBadge("Not supported on this hardware")
            } else if runner.superResolutionEntries.isEmpty {
                Text("No results")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 0) {
                    tableHeader(["Input", "Supported", "Scale Factors"])
                    ForEach(runner.superResolutionEntries) { entry in
                        Divider()
                        HStack(spacing: 0) {
                            cell(entry.inputLabel, width: 180, alignment: .leading)
                            cell(
                                entry.isSupported ? "✅" : "❌",
                                width: 90,
                                alignment: .center
                            )
                            let factors = entry.isSupported
                                ? entry.supportedScaleFactors.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
                                : "—"
                            Text(factors)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                        }
                        .frame(height: 28)
                    }
                }
                .background(Color(.textBackgroundColor).opacity(0.4))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.reportText, forType: .string)
                }
                .buttonStyle(.borderedProminent)

                if let url = githubIssueURL {
                    Button("Submit to GitHub") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Run Again") {
                    Task { await runner.run() }
                }
                .buttonStyle(.bordered)
            }

            Text("Submit opens a pre-filled GitHub issue with your diagnostics report.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var githubIssueURL: URL? {
        guard !runner.reportText.isEmpty else { return nil }
        let chip = runner.deviceInfo?.chip ?? "Unknown Device"
        var components = URLComponents(string: "https://github.com/lospi/metalduck/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Device Diagnostics: \(chip)"),
            URLQueryItem(name: "labels", value: "diagnostics"),
            URLQueryItem(name: "body", value: runner.reportText),
        ]
        return components?.url
    }

    // MARK: - Shared Helpers

    private func tableHeader(_ titles: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .frame(maxWidth: title == titles.first ? 70 : .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }

    private func cell(_ text: String, width: CGFloat? = nil, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.caption)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func statusCell(_ status: DiagnosticsRunner.TestStatus) -> some View {
        HStack(spacing: 4) {
            statusIcon(status)
            Text(statusLabel(status))
                .font(.caption)
        }
        .frame(width: 120, alignment: .leading)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func statusIcon(_ status: DiagnosticsRunner.TestStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .supported:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .unsupported:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .hardwareUnsupported:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }

    private func statusLabel(_ status: DiagnosticsRunner.TestStatus) -> String {
        switch status {
        case .pending:              return "Pending"
        case .running:              return "Testing..."
        case .supported:            return "Supported"
        case .unsupported:          return "Unsupported"
        case .hardwareUnsupported:  return "N/A"
        case .failed:               return "Error"
        }
    }

    private func unsupportedBadge(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }
}
