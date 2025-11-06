# 🌙 Focusly - macOS Ambience & Focus Companion

> 🧪 **Alpha 0.3** - building toward a refined and stable focus experience.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![Status](https://img.shields.io/badge/Stage-Alpha%200.3-yellow)

<p align="center">
<img src="Sources/Assets/Focusly_Logo.png" alt="Focusly logo" width="260">
</p>

---

## ✨ Overview

**Focusly** is a lightweight menu bar companion for macOS. It softens each display with a glassy overlay, keeps distractions under control, and gives you per-monitor ambience controls without getting in the way.

Focusly tracks the active window (with your permission) so the foreground content stays sharp while the rest of the desktop calmly fades back. Presets, per-display overrides, and localizations live directly inside the Swift Package so contributors can tweak everything with familiar tooling.

---

## ⚡️ Feature Highlights

- 🎛️ **Instant Menu Bar Control** - toggle overlays, switch presets, and update preferences in a click.  
- 🪟 **Context-Aware Focus Masking** - keeps the active window clear while softening the background.  
- 🎨 **Preset Library** - Focus, Warm, Colorful, and Monochrome looks 
- 🖥️ **Per-Display Ambience** - individual tint, opacity, and color for every monitor.  
- ⌨️ **Global Shortcut** - customizable Carbon-backed hotkey for instant control.  
- 🔒 **Local-First Privacy** - no telemetry, accounts, or network dependencies - everything runs on your Mac.  
- 🚀 **Launch at Login** - integrates with `SMAppService` when running as a bundled `.app`.  
- 🧭 **Guided Onboarding** - assists with setup, permissions, and language selection.  
- 🌐 **Localization Ready** - runtime language switching with support for English, Spanish, Spanish (Mexico), French, Italian, German, Portuguese (Portugal), Portuguese (Brazil), Arabic (Modern Standard), Swahili (Kiswahili), Hausa, Simplified Chinese, Ukrainian, Russian, Japanese, Korean, Thai, and Turkish.

---

## 🔐 Privacy & Security

- **Offline by design** - Focusly ships without networking code or telemetry hooks, so it operates the same way on air-gapped, corporate, or education Macs.  
- **No screen capture** - overlay masks are rendered from window metadata only; no pixel buffers or screenshots are stored or transmitted.  
- **Your data stays local** - preferences, presets, and onboarding state live in `UserDefaults` under your macOS account and can be purged at any time.  
- **Permission aware** - the Accessibility prompt is optional; declining simply falls back to less precise window tracking instead of breaking the app.  
- **Transparent build pipeline** - everything needed to audit and rebuild the app is in this repository, and distribution scripts produce unsigned artifacts so teams can apply their own certificates.  
- **Friendly for managed devices** - runs fully offline, plays nicely with Gatekeeper once signed, and respects standard macOS privacy controls, making it safe for home offices, media production bays, or regulated industries needing predictable behavior.

---

## ☀️ Upcoming Features

- **Overlay Performance** - higher refresh rates through gpu acceleration
- **Settings Menu** - rework of the settings window

---

## 💻 Requirements

- macOS **13 Ventura** or newer  
- **Accessibility permission** (recommended) for accurate window tracking  
- **Xcode 16 / Swift 6.2.1** or later for source builds  

---

## 🚀 Run the Alpha 0.2 Build

Precompiled alpha binaries are included for quick testing:

1. Mount `Focusly.dmg` and drag `Focusly.app` to `/Applications`.  
2. Control-click the app → **Open**, confirm under **System Settings › Privacy & Security**.  
3. Grant Accessibility permission: **System Settings › Privacy & Security › Accessibility** → enable **Focusly**.  
4. The menu bar icon appears — toggle **Enable Overlays** to begin.

> _If your workspace suddenly feels too cozy, that’s Focusly doing its job — or maybe you just need another café solo._

You can always grab the latest `.dmg` for **Alpha 0.2** from [GitHub Releases](https://github.com/your-user/macos-focusly/releases).

---

## 🧠 Build from Source (Alpha 0.3)

To build the latest alpha version directly from source using Xcode:

```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
xcodebuild -scheme Focusly -configuration Release
```

Or open the project manually:

1. Launch **Xcode 16+**  
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

## 🔐 Signing the App Bundle

The generated `Focusly.app` ships unsigned, so macOS Gatekeeper will flag it until you apply a signature.

**Quick option via Homebrew cask**

```bash
brew install --cask alienator88-sentinel
```
drop .app in Sentinel Window or

```bash
alienator88-sentinel sign Focusly.app \
  --identity "Developer ID Application: Your Name (TEAMID)"
```

- Replace the identity with your Developer ID certificate name (or use `--identity "-"` for ad-hoc signing while testing).  
- Run `spctl --assess --type exec Focusly.app` to confirm Gatekeeper now trusts the bundle.

Public releases posted to GitHub will ship pre-signed and notarized so Gatekeeper opens them without extra prompts.

---

## 🛠️ Development Notes

- **Window Tracking:** `WindowTracker` polls the Accessibility API; it automatically downgrades to CoreGraphics if permission is missing but overlays lose precision.  
- **Debug Overlay:** Launch with `FOCUSLY_DEBUG_WINDOW=1` or toggle the hidden preference key `FocuslyDebugWindow` to monitor tracked frames.  
- **Tracking Profiles:** Preferences expose `WindowTrackingProfile` presets (standard, responsive, etc.); polling cadence lives in `OverlayController`.  
- **Launch at Login:** `LaunchAtLoginManager` requires Focusly to run from a bundled, signed `.app`; CLI targets expose the control but surface a localized warning.  
- **Localization & Presets:** Translations live under `Sources/Resources/*.lproj`; overlay looks are defined in `PresetLibrary` so new presets can be added alongside localized names.

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

- **Application shell**  
  `Sources/Application/main.swift` boots the `AppDelegate`, which wires menus, permissions, and launches `FocuslyAppCoordinator`. The coordinator composes the `FocuslyEnvironment` dependency container and keeps long-lived services like overlays, status menus, hotkeys, and onboarding running.
- **Overlay engine**  
  `Sources/Features/Overlay/OverlayService.swift` maintains one `OverlayWindow` per `NSScreen`, while `Sources/Features/Overlay/OverlayController.swift` syncs mask geometry from `WindowTracker` snapshots and a `DisplayLinkDriver` for smooth updates. `PointerInteractionMonitor` handles cursor passthrough when overlays are active.
- **State & profiles**  
  `AppSettings`, `ProfileStore`, `PresetLibrary`, and `FocusProfileModels` coordinate persisted styles, per-display overrides, and `WindowTrackingProfile` cadence tweaks stored in `UserDefaults`, exposing Combine publishers to keep the UI and services in lockstep.
- **Interface surfaces**  
  `StatusBarController` renders the menu bar app and primary commands, `PreferencesWindowController` hosts the SwiftUI `PreferencesView`, and onboarding flows live in `OnboardingWindowController`/`OnboardingView`, all localized through `LocalizationService`.
- **System bridges**  
  `WindowTracker`, `WindowResolver`, `AXHelper`, and `DisplayID` abstract the Accessibility/CoreGraphics APIs; `HotkeyCenter` wraps Carbon for the global shortcut; `LaunchAtLoginManager` integrates with `SMAppService` so the app can opt into login items.

---

## 🌐 Localization

Available in:

- 🇬🇧 English  
- 🇩🇪 Deutsch  
- 🇪🇸 Español  
- 🇲🇽 Español (México)  
- 🇫🇷 Français  
- 🇮🇹 Italiano  
- 🇵🇹 Português (Portugal)  
- 🇧🇷 Português (Brasil)  
- 🇦🇪 العربية (الفصحى الحديثة)  
- 🇹🇿 Kiswahili  
- 🇳🇬 Hausa  
- 🇨🇳 中文（简体）  
- 🇺🇦 Українська  
- 🇷🇺 Русский  
- 🇯🇵 日本語  
- 🇰🇷 한국어 (대한민국)  
- 🇹🇭 ภาษาไทย  
- 🇹🇷 Türkçe  

Additional docs live under [`Documentation/`](Documentation/), including localized guides in all mentioned languages.

> _In Spanish, “enfocar” means “to focus” — and yes, Focusly is quite the “enfocador”._

---

## 📜 License

Released under the **MIT License**. See [LICENSE](./LICENSE) for full details.  

> ⚠️ Focusly is free to use during the alpha phase. Optional paid upgrades may come once stability is reached.

---

**Made with ❤️**
