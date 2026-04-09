//
//  DisplayManager.swift
//  DisplayBright
//
//  Created by Josh Phillips on 4/9/26.
//

import Foundation
@preconcurrency import CoreGraphics
import Combine
import SwiftUI
import IOKit

// MARK: - Display Discovery Result (Sendable for cross-isolation transfer)

private struct DisplayInfo: Sendable {
    let id: CGDirectDisplayID
    let name: String
    let ddcMax: UInt16
    let brightness: Double
    let ddcSupported: Bool
    let edrHeadroom: Float
}

// MARK: - External Display Model

/// Represents a single external display with its brightness state
@Observable
final class ExternalDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let ddcMaxBrightness: UInt16

    /// Brightness from 0.0 to 2.0 (0% to 200%)
    /// 0.0–1.0 = hardware brightness (DDC or gamma)
    /// 1.0–2.0 = EDR brightness boost (requires HDR enabled)
    var brightness: Double = 1.0

    /// Whether DDC communication is working for this display
    let ddcSupported: Bool

    /// Maximum EDR headroom (e.g. 2.0 means can go up to 200%)
    let edrHeadroom: Float

    /// Whether HDR/EDR is available for brightness upscaling
    var isHDRAvailable: Bool { edrHeadroom > 1.0 }

    /// Work item for debouncing DDC writes
    private var pendingWork: DispatchWorkItem?

    init(id: CGDirectDisplayID, name: String, ddcMaxBrightness: UInt16, currentBrightness: Double, ddcSupported: Bool, edrHeadroom: Float) {
        self.id = id
        self.name = name
        self.ddcMaxBrightness = ddcMaxBrightness
        self.ddcSupported = ddcSupported
        self.edrHeadroom = edrHeadroom
        self.brightness = max(0.0, min(2.0, currentBrightness))
    }

    /// The brightness percentage for the slider (0–150).
    /// 0–100 maps linearly to 0–100% actual brightness.
    /// 100–150 maps to 100–200% actual brightness (2x scaling in boost range).
    var brightnessPercent: Double {
        get {
            if brightness <= 1.0 {
                return brightness * 100.0
            } else {
                // brightness 1.0–2.0 → slider 100–150
                return 100.0 + (brightness - 1.0) * 50.0
            }
        }
        set {
            let actual: Double
            if newValue <= 100.0 {
                actual = max(0.0, newValue / 100.0)
            } else {
                // slider 100–150 → brightness 1.0–2.0
                actual = 1.0 + (min(newValue, 150.0) - 100.0) / 50.0
            }
            let clamped = max(0.0, min(2.0, actual))
            guard clamped != brightness else { return }
            brightness = clamped
            scheduleBrightnessUpdate()
        }
    }

    /// Set brightness programmatically (e.g. from preset buttons or reset)
    func setBrightness(_ value: Double) {
        let clamped = max(0.0, min(2.0, value))
        guard clamped != brightness else { return }
        brightness = clamped
        scheduleBrightnessUpdate()
    }

    /// Debounce brightness updates
    private func scheduleBrightnessUpdate() {
        // Apply EDR/gamma change immediately on main thread (fast)
        applyBrightnessVisual()

        // Debounce the DDC hardware write (slow I2C operation)
        pendingWork?.cancel()
        let currentBrightness = brightness
        let displayID = id
        let maxBrightness = ddcMaxBrightness
        let hasDDC = ddcSupported

        let work = DispatchWorkItem { @Sendable in
            guard hasDDC else { return }
            if currentBrightness <= 1.0 {
                let ddcValue = UInt16(currentBrightness * Double(maxBrightness))
                DDCControl.write(displayID: displayID, code: .brightness, value: ddcValue)
            } else {
                DDCControl.write(displayID: displayID, code: .brightness, value: maxBrightness)
            }
        }
        pendingWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Apply visual brightness change via gamma table
    private func applyBrightnessVisual() {
        // Use the gamma table approach for all brightness levels.
        // When HDR is enabled and brightness >1.0, the gamma table values >1.0
        // naturally drive the EDR pipeline to push brightness beyond SDR white.
        // When HDR is off, values >1.0 are clamped to SDR max (still allows dimming).
        EDRBrightnessControl.applyBrightness(Float(brightness), to: id)
    }

    /// Clean up — reset gamma to normal
    func tearDownOverlay() {
        EDRBrightnessControl.resetBrightness(for: id)
    }
}

// MARK: - Display Manager

/// Manages discovery and state of all external displays
@Observable
final class DisplayManager {
    var displays: [ExternalDisplay] = []
    var lastRefresh = Date()
    var isLoading = false

    init() {
        scheduleRefresh()
    }

    /// Public refresh — called from UI refresh button
    func refreshDisplays() {
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = DisplayManager.discoverExternalDisplays()
            DispatchQueue.main.async { [weak self] in
                self?.applyDiscoveryResults(results)
                self?.isLoading = false
            }
        }
    }

    /// Synchronous display discovery — runs on background thread only
    nonisolated private static func discoverExternalDisplays() -> [DisplayInfo] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let result = CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        guard result == .success else {
            print("[DisplayManager] Failed to get display list: \(result)")
            return []
        }

        var results: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]

            if CGDisplayIsBuiltin(displayID) != 0 {
                continue
            }

            let name = getDisplayName(for: displayID)

            // Check EDR headroom
            let edrHeadroom = EDRBrightnessControl.maxEDRHeadroom(for: displayID)
            print("[DisplayManager] EDR headroom for '\(name)': \(edrHeadroom)x")

            // Try to read current DDC brightness
            var ddcMax: UInt16 = 100
            var currentBrightness: Double = 1.0
            var ddcSupported = false

            if let ddcResult = DDCControl.read(displayID: displayID, code: .brightness) {
                ddcMax = ddcResult.maxValue > 0 ? ddcResult.maxValue : 100
                currentBrightness = Double(ddcResult.currentValue) / Double(ddcMax)
                ddcSupported = true
                print("[DisplayManager] DDC OK for '\(name)': \(ddcResult.currentValue)/\(ddcResult.maxValue)")
            } else {
                print("[DisplayManager] DDC not available for '\(name)'")
            }

            if edrHeadroom > 1.0 {
                print("[DisplayManager] ✅ HDR active for '\(name)' — EDR brightness upscaling available")
            } else {
                print("[DisplayManager] ⚠️ HDR not enabled for '\(name)' — enable HDR in System Settings → Displays")
            }

            results.append(DisplayInfo(id: displayID, name: name, ddcMax: ddcMax, brightness: currentBrightness, ddcSupported: ddcSupported, edrHeadroom: edrHeadroom))
        }

        return results
    }

    /// Apply discovery results on main thread
    private func applyDiscoveryResults(_ results: [DisplayInfo]) {
        var newDisplays: [ExternalDisplay] = []

        for r in results {
            if let existing = displays.first(where: { $0.id == r.id }) {
                newDisplays.append(existing)
            } else {
                let display = ExternalDisplay(
                    id: r.id,
                    name: r.name,
                    ddcMaxBrightness: r.ddcMax,
                    currentBrightness: r.brightness,
                    ddcSupported: r.ddcSupported,
                    edrHeadroom: r.edrHeadroom
                )
                newDisplays.append(display)
            }
        }

        displays = newDisplays
        lastRefresh = Date()
    }

    /// Get the human-readable name for a display
    nonisolated private static func getDisplayName(for displayID: CGDirectDisplayID) -> String {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return "External Display"
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {

                if let names = info[kDisplayProductName] as? [String: String],
                   let name = names.values.first {
                    return name
                }
            }
        }

        return "External Display"
    }

    /// Reset all displays to normal brightness (called on quit)
    func resetAll() {
        for display in displays {
            display.tearDownOverlay()
        }
    }
}
