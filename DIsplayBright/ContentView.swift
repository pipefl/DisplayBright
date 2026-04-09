//
//  ContentView.swift
//  DisplayBright
//
//  Created by Josh Phillips on 4/9/26.
//

import SwiftUI
import ServiceManagement

struct ContentView: View {
    @Environment(DisplayManager.self) private var displayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.yellow)
                Text("DisplayBright")
                    .font(.headline)
                Spacer()
                Button {
                    displayManager.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh displays")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if displayManager.displays.isEmpty {
                // No external displays found
                VStack(spacing: 8) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No External Displays")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Connect an external display to adjust its brightness.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                // Display list with brightness sliders
                ForEach(displayManager.displays) { display in
                    DisplayBrightnessRow(display: display)
                    if display.id != displayManager.displays.last?.id {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if !displayManager.displays.isEmpty {
                    Button("Reset All") {
                        for display in displayManager.displays {
                            display.setBrightness(1.0)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Quit") {
                    displayManager.resetAll()
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Launch at Login
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("[LaunchAtLogin] Error: \(error)")
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }
}

// MARK: - Display Brightness Row

struct DisplayBrightnessRow: View {
    @Bindable var display: ExternalDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Display name and status badges
            HStack {
                Image(systemName: "display")
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if display.isHDRAvailable {
                    Text("HDR")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("SDR")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Brightness slider
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $display.brightnessPercent, in: 0...150, step: 1)
                    .tint(display.brightnessPercent > 100 ? .orange : .accentColor)

                Image(systemName: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(display.brightnessPercent > 100 ? .orange : .secondary)
            }

            // Percentage label and status
            HStack {
                Text("\(Int(display.brightnessPercent))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(display.brightnessPercent > 100 ? .orange : .primary)

                if display.brightnessPercent > 100 {
                    if display.isHDRAvailable {
                        Text("EDR Boost")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Enable HDR")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                // Quick preset buttons
                HStack(spacing: 4) {
                    PresetButton(label: "50", percent: 50, display: display)
                    PresetButton(label: "100", percent: 100, display: display)
                    PresetButton(label: "150", percent: 150, display: display)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let label: String
    let percent: Double
    let display: ExternalDisplay

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                display.brightnessPercent = percent
            }
        } label: {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Int(display.brightnessPercent) == Int(percent)
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environment(DisplayManager())
}
