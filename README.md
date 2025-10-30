# 🌙 Focusly — macOS Ambience & Focus Companion

> 🧪 **Alpha 0.2** - building toward a refined and stable focus experience.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Status](https://img.shields.io/badge/Stage-Alpha%200.2-yellow)

---

## ✨ Overview

**Focusly** is a lightweight menu bar companion for macOS. It softens each display with a glassy overlay, keeps distractions under control, and gives you per-monitor ambience controls without getting in the way.

Focusly tracks the active window (with your permission) so the foreground content stays sharp while the rest of the desktop calmly fades back. Presets, per-display overrides, and localizations live directly inside the Swift Package so contributors can tweak everything with familiar tooling.

---

## ⚡️ Feature Highlights

- 🎛️ **Instant Menu Bar Control** - toggle overlays, switch presets, and update preferences in a click.  
- 🖥️ **Per-Display Ambience** - individual tint, opacity, and color for every monitor.  
- 🪟 **Context-Aware Focus Masking** - keeps the active window clear while softening the background.  
- 🎨 **Preset Library** - Focus, Warm, Colorful, and Monochrome looks, powered by `PresetLibrary` and `ProfileStore`.  
- ⌨️ **Global Shortcut** - customizable Carbon-backed hotkey for instant control.  
- 🚀 **Launch at Login** - integrates with `SMAppService` when running as a bundled `.app`.  
- 🧭 **Guided Onboarding** - assists with setup, permissions, and language selection.  
- 🌐 **Localization Ready** - runtime language switching with support for English, Spanish, Simplified Chinese, Ukrainian, and Russian.

---

## 💻 Requirements

- macOS **13 Ventura** or newer  
- **Accessibility permission** (recommended) for accurate window tracking  
- **Xcode 15 / Swift 5.9** or later for source builds  

---

## 🚀 Run the Alpha 0.2 Build

Precompiled alpha binaries are included for quick testing:

1. Mount `Focusly.dmg` and drag `Focusly.app` to `/Applications`.  
2. Control-click the app → **Open**, confirm under **System Settings › Privacy & Security**.  
3. Grant Accessibility permission: **System Settings › Privacy & Security › Accessibility** → enable **Focusly**.  
4. The menu bar icon appears — toggle **Enable Overlays** to begin.

> _If your workspace suddenly feels too cozy, that’s Focusly doing its job — or maybe you just need another café solo._

---

## 🧠 Build from Source (Alpha 0.2)

To build the latest alpha version directly from source using Xcode:

```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
xcodebuild -scheme Focusly -configuration Release
```

Or open the project manually:

1. Launch **Xcode 15+**  
2. Open `Package.swift`  
3. Select the **Focusly** scheme  
4. Hit **⌘R** to build and run  

The built `.app` will appear under:  
```
.build/release/Focusly.app
```

---

## 📦 Bundle & Distribution

- `./build_app.sh` → Builds an unsigned `Focusly.app` from the latest Swift build.  
- `./build_dmg.sh` → Packages `Focusly.app` and documentation into a shareable `.dmg`.  
- Prefer `swift build -c release` before packaging for optimized binaries.

---

## 🛠️ Development Notes

- **Accessibility:** Falls back to CoreGraphics polling if permission is denied (masking quality reduced).  
- **Debug Overlay:** Enable with `FOCUSLY_DEBUG_WINDOW=1` to visualize the window tracker.  
- **Launch at Login:** Available only when running from a bundled `.app`.  
- **Localization:** Preferences allow runtime language overrides; translation files live in `Sources/Focusly/Resources/*.lproj`.  
- **Onboarding:** Reset onboarding in Preferences to rerun the guided setup.

---

## 🧪 Tests

```bash
swift test
```

The suite currently covers:
- `ProfileStore` persistence  
- Preset override behavior  

Further tests will be added as more logic moves outside the UI layer.

---

## 🧱 Architecture Overview

| Component | Description |
|------------|--------------|
| **FocuslyAppCoordinator** | Coordinates overlays, status bar, preferences, hotkeys, and localization. |
| **OverlayService** | Manages one `OverlayWindow` per display, syncing frames and styles. |
| **OverlayController** | Tracks the focused window and applies contextual masks. |
| **ProfileStore** | Persists presets and per-display overrides in `UserDefaults`. |
| **PreferencesWindowController** | SwiftUI interface for presets, displays, hotkeys, onboarding, and language. |
| **StatusBarController** | Builds the menu bar item, actions, and preset menu. |
| **HotkeyCenter** | Handles Carbon-based global shortcut registration. |
| **LocalizationService** | Provides runtime language switching and localized string management. |
| **LaunchAtLoginManager** | Integrates `SMAppService` for login item registration. |

---

## 🌐 Localization

Available in:

- 🇬🇧 English  
- 🇪🇸 Español  
- 🇨🇳 中文（简体）  
- 🇺🇦 Українська  
- 🇷🇺 Русский  

Additional community docs under `Documentation/<locale>`, including Japanese (`ja`) and Korean (`ko`).

> _In Spanish, “enfocar” means “to focus” — and yes, Focusly is quite the “enfocador”._

---

## 📜 License

Released under the **MIT License**. See [LICENSE](./LICENSE) for full details.  

> ⚠️ Focusly is free to use during the alpha phase. Optional paid upgrades may come once stability is reached.

---

**Made with ❤️ and SwiftUI — for Mac users who believe calm focus is a feature, not a setting.**
