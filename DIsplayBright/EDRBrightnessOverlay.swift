//
//  EDRBrightnessOverlay.swift
//  DisplayBright
//
//  Created by Josh Phillips on 4/9/26.
//

import AppKit
import CoreGraphics

/// Manages brightness upscaling for external displays using CoreGraphics
/// gamma table manipulation. When HDR is enabled on the display, values >1.0
/// in the gamma transfer function actually drive the panel beyond SDR white
/// through the EDR (Extended Dynamic Range) pipeline.
///
/// This approach works by building a custom gamma lookup table that maps
/// input values to output values with proper gamma correction, preserving
/// color accuracy while boosting overall luminance.
enum EDRBrightnessControl {

    /// Apply a brightness multiplier to a display via gamma table.
    /// - Parameters:
    ///   - displayID: The target display
    ///   - multiplier: Brightness multiplier (0.0 to ~2.0). 1.0 = normal.
    ///                 Values >1.0 require HDR enabled on the display.
    static func applyBrightness(_ multiplier: Float, to displayID: CGDirectDisplayID) {
        if multiplier < 0.01 {
            // Near-black: just set min gamma
            CGSetDisplayTransferByFormula(
                displayID,
                0, 0.01, 1.0,
                0, 0.01, 1.0,
                0, 0.01, 1.0
            )
            return
        }

        // Build a custom gamma table with 256 entries per channel.
        // This gives us precise control over the transfer function.
        let tableSize = 256
        var redTable = [CGGammaValue](repeating: 0, count: tableSize)
        var greenTable = [CGGammaValue](repeating: 0, count: tableSize)
        var blueTable = [CGGammaValue](repeating: 0, count: tableSize)

        // Standard display gamma (sRGB-like)
        let displayGamma: Float = 2.2

        for i in 0..<tableSize {
            let normalized = Float(i) / Float(tableSize - 1)  // 0.0 to 1.0

            // Apply proper gamma-aware brightness scaling:
            // 1. Linearize the input (undo display gamma)
            // 2. Apply the brightness multiplier in linear space
            // 3. Re-apply display gamma for output
            //
            // This preserves color relationships and contrast,
            // unlike naive linear scaling which washes out the image.

            let linear = pow(normalized, displayGamma)         // Linearize
            let boosted = linear * multiplier                  // Scale in linear space
            let output = pow(boosted, 1.0 / displayGamma)     // Re-apply gamma

            // When HDR is enabled, the display pipeline accepts values >1.0
            // and maps them to brightness beyond SDR white point.
            // When HDR is not enabled, values >1.0 are clamped to 1.0.
            redTable[i] = CGGammaValue(output)
            greenTable[i] = CGGammaValue(output)
            blueTable[i] = CGGammaValue(output)
        }

        let result = CGSetDisplayTransferByTable(
            displayID,
            UInt32(tableSize),
            &redTable,
            &greenTable,
            &blueTable
        )

        if result != .success {
            print("[EDR] Failed to set gamma table: \(result)")
        }
    }

    /// Reset a display's gamma to identity (normal brightness)
    static func resetBrightness(for displayID: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(
            displayID,
            0, 1.0, 1.0,
            0, 1.0, 1.0,
            0, 1.0, 1.0
        )
    }

    /// Get the maximum EDR headroom for a display.
    /// Returns >1.0 when HDR is enabled and the display supports extended brightness.
    static func maxEDRHeadroom(for displayID: CGDirectDisplayID) -> Float {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return num == displayID
        }) else {
            return 1.0
        }

        return Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    /// Check if EDR/HDR is currently active for a display
    static func isEDRActive(for displayID: CGDirectDisplayID) -> Bool {
        return maxEDRHeadroom(for: displayID) > 1.0
    }
}
