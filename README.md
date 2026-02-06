![Preview](preview.png)

# NotchMac

A Dynamic Island-style notch replacement for MacBooks with notch displays. Transforms the black notch area into an interactive, functional space with beautiful animations and useful indicators.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

### Volume & Brightness HUD
Replace the default macOS volume and brightness overlays with a sleek notch-integrated HUD.

**Three display modes:**
- **Minimal** — Icon on left, percentage on right, no expansion
- **Progress Bar** — Classic style with animated progress bar
- **Notched** — Premium segmented design inspired by iOS

### Now Playing
Automatically detects music playback and shows animated audio visualizer.

**Supported apps:**
- Apple Music
- Spotify
- TIDAL
- Deezer
- Amazon Music
- Safari, Chrome, Firefox, Arc (browser media)

### Battery Monitoring
- Animated charging indicator when plugged in
- Unplug notification with battery status
- Sound effects for plug/unplug events

### Lock Screen Integration
- Lock indicator when screen is locked
- Unlock animation with haptic feedback
- Works on the lock screen using SkyLight framework

### Calendar Widget
Expanded view shows:
- Current date with calendar icon
- Day of week
- Week progress indicator
- Current time

## Installation

1. Clone the repository
2. Open `MyDynamicIsland.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Grant Accessibility permissions when prompted

## Requirements

- macOS 14.0 or later
- MacBook with notch display (M1 Pro/Max/Ultra, M2, M3 series)
- Accessibility permissions for media key interception

## Settings

Right-click on the notch to access Settings.

### General
- Launch at Login
- Hide from Dock
- Expand on Hover
- Haptic Feedback
- Auto Collapse Delay
- Lock/Unlock Indicators

### Appearance
- HUD Display Mode (Minimal / Progress Bar / Notched)

### Volume & Brightness
- Enable/Disable HUD replacement
- Show/Hide percentage

### Battery
- Charging indicator toggle
- Sound effects toggle

### Music
- Now Playing indicator
- Audio visualizer animation

## Architecture

```
MyDynamicIsland/
├── MyDynamicIslandApp.swift    # App entry point
├── DynamicIsland.swift         # Core controller
│   ├── LockScreenWindowManager # SkyLight integration
│   ├── NotchPanel              # Custom NSPanel
│   ├── NotchState              # Observable state
│   └── DynamicIsland           # Main controller
├── MediaKeyManager.swift       # Volume/brightness keys
│   └── BrightnessHelper        # DisplayServices integration
└── IslandView.swift            # SwiftUI views
    ├── NotchView               # Main notch view
    ├── HUD Views               # Volume/Brightness HUDs
    ├── Indicator Views         # Lock, Battery, Music
    └── Settings Views          # Settings panel
```

## Frameworks Used

- **SwiftUI** — User interface
- **AppKit** — Window management
- **Combine** — Reactive updates
- **IOKit** — Battery monitoring
- **CoreAudio** — Volume control
- **SkyLight** (Private) — Lock screen visibility
- **MediaRemote** (Private) — Now Playing detection
- **DisplayServices** (Private) — Brightness control

## Privacy

NotchMac requires the following permissions:
- **Accessibility** — To intercept media keys (volume/brightness)

The app does not collect any data and works entirely offline.

## Author

Mark Kozhydlo

---

*NotchMac is not affiliated with Apple Inc. Dynamic Island is a trademark of Apple Inc.*
