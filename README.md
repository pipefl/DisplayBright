# DisplayBright ☀️

A lightweight macOS menu bar app for controlling external display brightness — no extra drivers, no bloat.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What It Does

DisplayBright sits in your menu bar and gives you a simple slider to control the brightness of external monitors. It works via **DDC/CI** (the same protocol your monitor's physical buttons use) and supports **EDR brightness boost** on HDR-capable displays for up to 150% brightness.

## Features

- **Menu bar app** — always accessible, never in the way
- **DDC/CI hardware control** — adjusts actual monitor backlight, not a software overlay
- **EDR brightness boost** — push beyond 100% on HDR displays using macOS Extended Dynamic Range
- **Multi-monitor support** — control each external display independently
- **Quick presets** — one-click buttons for 50%, 100%, and 150%
- **Launch at Login** — optional auto-start via macOS `ServiceManagement`
- **Universal binary** — runs natively on both Apple Silicon and Intel Macs
- **Zero dependencies** — pure Swift/SwiftUI, no third-party libraries

## Screenshot

After launching, click the ☀️ icon in your menu bar:

| Slider Control | HDR Badge | Presets |
|---|---|---|
| Drag to adjust brightness 0–150% | Shows HDR/SDR capability per display | Quick-set to 50%, 100%, or 150% |

## Requirements

- macOS 14 Sonoma or later
- External display connected via HDMI, DisplayPort, or USB-C
- For EDR boost (>100%): HDR must be enabled in System Settings → Displays

## Installation

### Download

Grab the latest `DisplayBright.app` from [Releases](../../releases).

> **Note:** The app is not notarized. On first launch, right-click → **Open** to bypass Gatekeeper.

### Build from Source

```bash
git clone https://github.com/pipefl/DisplayBright.git
cd DisplayBright
xcodebuild archive \
  -project DisplayBright.xcodeproj \
  -scheme "DIsplayBright" \
  -configuration Release \
  -archivePath build/DisplayBright.xcarchive
cp -R build/DisplayBright.xcarchive/Products/Applications/DisplayBright.app /Applications/
```

Or just open `DisplayBright.xcodeproj` in Xcode and hit **⌘R**.

## How It Works

| Range | Method | Details |
|---|---|---|
| **0–100%** | DDC/CI | Sends VCP brightness commands over I2C to the monitor's firmware |
| **100–150%** | EDR gamma boost | Builds a custom gamma lookup table that drives the panel beyond SDR white via macOS EDR pipeline |

The DDC/CI implementation communicates directly with monitor hardware through IOKit's I2C interface — the same channel the monitor's own OSD buttons use. The EDR boost applies gamma-corrected brightness scaling in linear space to preserve color accuracy.

## Known Limitations

- **Sleep/wake resets brightness** — after the monitor sleeps, you'll need to re-adjust the slider. The monitor's firmware resets DDC values on power cycle. (Auto-restore on wake is planned.)
- **Some monitors have limited DDC support** — a few displays (especially older ones or those connected through certain docks/adapters) may not respond to DDC commands.
- **EDR boost requires HDR enabled** — the >100% range only works if HDR is turned on in System Settings for that display.

## Project Structure

```
DisplayBright/
├── DisplayBrightApp.swift      # Menu bar app entry point
├── ContentView.swift           # SwiftUI popover UI
├── DisplayManager.swift        # Display discovery & brightness state
├── DDCControl.swift            # DDC/CI protocol over I2C (IOKit)
├── EDRBrightnessOverlay.swift  # EDR gamma table brightness boost
└── Assets.xcassets/            # App icon (sun icon)
```

## License

MIT — do whatever you want with it.
