# **Focusly - macOS Ambience & Focus Companion**

> 🔏 **Developer-signed build** - the latest DMG ships with my Developer ID cert; macOS still needs you to allow it once under **System Settings › Privacy & Security** because notarization is still in flight.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform macOS">
  <img src="https://img.shields.io/badge/Swift-6.2-orange" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/Stage-Alpha-yellow" alt="Stage Alpha">
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT">
</p>

<p align="center">
  <a href="https://github.com/Punshnut/macos-focusly/releases/latest">
    <img src="https://img.shields.io/badge/Download-Alpha%200.3-blueviolet?style=for-the-badge" alt="Download Alpha 0.3">
  </a>
  <a href="https://github.com/Punshnut/macos-focusly/issues/new/choose">
    <img src="https://img.shields.io/badge/Share%20feedback-Issue%20tracker-ff7f50?style=for-the-badge" alt="Share feedback">
  </a>
</p>

<p align="center">
  <strong>Quick tour:</strong> <a href="#-what-is-focusly">Overview</a> · <a href="#-built-for-every-desk">Localization</a> · <a href="#-menu-bar-superpowers">Features</a> · <a href="#-try-the-alpha-build-today">Install</a> · <a href="#-roadmap-to-public-launch">Roadmap</a> · <a href="#-build-or-customize">Build</a>
</p>

<p align="center">
  <img src="Focusly/Resources/Media/Focusly_Logo.png" alt="Focusly logo" width="260">
</p>


<div align="center">
  <details>
    <summary>🇺🇦 · 🇷🇺 · 🇨🇳 · 🇯🇵 · 🇰🇷 · 🇹🇭 · 🇹🇷 · 🇩🇪 · 🇫🇷 · 🇮🇹 · 🇪🇸 - Europe & Asia (11)</summary>
    <p>🇺🇦 Українська<br>🇷🇺 Русский<br>🇨🇳 中文（简体）<br>🇯🇵 日本語<br>🇰🇷 한국어<br>🇹🇭 ภาษาไทย<br>🇹🇷 Türkçe<br>🇩🇪 Deutsch<br>🇫🇷 Français<br>🇮🇹 Italiano<br>🇪🇸 Español (España)</p>
  </details>
  <details>
    <summary>🇦🇪 · 🇹🇿 · 🇳🇬 - Africa & Middle East (3)</summary>
    <p>🇦🇪 العربية (الفصحى)<br>🇹🇿 Kiswahili<br>🇳🇬 Hausa</p>
  </details>
  <details>
    <summary>🇧🇷 · 🇲🇽 · 🇵🇹 · 🇺🇸 - Americas (4)</summary>
    <p>🇧🇷 Português (Brasil)<br>🇲🇽 Español (LatAm)<br>🇵🇹 Português (Portugal)<br>🇺🇸 English</p>
  </details>
</div>
<p align="center">
  <sub>Spanish ships in both 🇲🇽 LatAm and 🇪🇸 Spain variants - the Americas card highlights LatAm while Europe & Asia lists the Iberian pack.</sub>
</p>


## **About Focusly**

**Focusly** is a lightweight menu bar companion that softens the edges of every display, keeps the active window crisp, and lets you dial in ambience without touching your creative tools.

It’s built to feel like a **native macOS control** - fast, glassy, localized, and respectful of your privacy.

---

## **Privacy & Trust**

Focusly is built on the principle that privacy isn’t an afterthought - it’s the architecture.

- **Offline by design** - zero networking code, no telemetry, no analytics SDKs.
- **No screen capture** - overlays rely on Accessibility metadata, never on screenshots.
- **Data stays local** - presets, onboarding state, and preferences live in your macOS account’s `UserDefaults`.
- **Permission aware** - decline Accessibility and the app gracefully downgrades instead of quitting.
- **Transparent pipeline** - every script required to audit, sign, and ship the app sits in this repo.

---

## **Quiet Power in Your Menu Bar**

<details open>
<summary>Tap to preview the menu bar tricks</summary>

- **Context-aware masking** keeps the foreground app clear while gently blurring everything else so your brain stays in flow.
- **Preset Library** ships with Smart Blur, Warm, Dark, White, Paper, Moss, and Ocean looks plus per-display tint + opacity overrides.
- **Per-monitor ambience** lets you tune multi-display setups individually - brighten the reference monitor, dim the chat screen.
- **Shift-click focus** lets you flip between masking only the focused window or every window from the same app, per display, without opening Preferences.
- **Dual hotkeys** give you one shortcut to toggle overlays and another to cycle the masking mode, so you can keep hands on the keyboard.
- **Instant control** from the status bar: toggle overlays, swap presets, and edit preferences in a couple of clicks or via customizable global hotkeys.
- **Guided onboarding** walks first-time users through permissions, color picks, and localization so the app feels ready on launch.

</details>

---

## **Made for Every Desk, Everywhere**

Being a minimalist, productivity-first app means - at least to me as the developer, Jan - that every surface should feel intentional, and that includes shipping as much localization as humanly possible instead of treating it as a stretch goal.

- **18 languages shipping today** (English, German, Spanish EU + MX, French, Italian, Portuguese EU + BR, Arabic MSA, Kiswahili, Hausa, Simplified Chinese, Ukrainian, Russian, Japanese, Korean, Thai, Turkish) so teammates worldwide see Focusly in their native voice the moment it launches.
- **Right-to-left + Latin scripts** are tested against the same onboarding stories and menus, keeping cultural nuances intact.
- **Locale-aware presets** let each translation bundle tweak color names and descriptions without touching code.
- **Community glossary** lives in `Focusly/Resources/Localization/*.lproj`, making it easy for translators to submit improvements with context screenshots.
- **Native speaker call**: I need native speakers to keep shaping their languages, but please hold PRs/issues until Alpha 0.5 lands-major localization changes are planned through that release and strings are still moving.

<p align="center">
  <meter min="0" max="20" value="18">18</meter><br>
  <sub>18 / 18 launch languages locked in for Alpha</sub>
</p>

> Focusly is designed for hybrid teams spread across time zones - the app never phones home, so the experience in Nairobi or Nagoya is identical to New York.

---

## **Upcoming Features**

<details open>
<summary>Alpha flight checklist</summary>

- [ ] **Overlay Performance** - higher refresh via smarter blur scheduling *(feature-complete locally; validating on diverse GPUs before calling it done)*.
- [ ] **Settings Refresh** - enhancing the usability of the app settings window
- [ ] **Full notarization** - finish Apple's notary review so Gatekeeper skips the **Open Anyway** dance (current DMG is already Developer ID signed).

</details>

---

## **Try the newest Alpha Release Today**

<details open>
<summary>Tap for install steps</summary>

1. Mount `Focusly.dmg` and drag `Focusly.app` into `/Applications`.
2. Launch `Focusly.app` once. macOS will block it because the build is Developer ID–signed but not notarized yet-open **System Settings › Privacy & Security**, click **Open Anyway** next to Focusly, confirm the prompt, and relaunch.
3. Approve **Accessibility** under **System Settings › Privacy & Security › Accessibility** to unlock precise window tracking.
4. Tap the menu bar icon and toggle **Enable Overlays**.

Latest alpha DMG lives on [GitHub Releases](https://github.com/Punshnut/macos-focusly/releases).

> 🛡️ First launch is the only time macOS will block the app-after you click **Open Anyway** in **System Settings › Privacy & Security**, the system remembers the approval.

> Need to roll your own build? Jump to **Build or Customize** below for the one-liner.

</details>

---

## **Build or Customize**

```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
xcodebuild -scheme Focusly -configuration Release
open .build/Release/Focusly.app
```

### Repository Layout

- `Focusly/App` — entry point, app delegate, and coordinator wiring for the menu bar lifecycle.
- `Focusly/Features/*` — surface-level features including overlays, hotkeys, onboarding, preferences, and status bar UI.
- `Focusly/Infrastructure` — shared services such as localization, app settings, login helpers, and bundle utilities.
- `Focusly/Domain` — focus profile models, preset catalogs, and persistence.
- `Focusly/Platform` — low-level AppKit + Accessibility integrations (window tracker, display link driver, AX helpers).
- `Focusly/Resources/Localization` — `.lproj` bundles that power every shipped language.
- `Focusly/Resources/Media` — packaged artwork (centered logo, menu icons) while brand-only files stay excluded from the build.
- `Resources/` — Info.plist + app icon that get baked into the signed `.app` via the shell scripts.
- `Scripts/` + root `.sh` helpers — release automation, signing, notarization, and localization checks.

---

<details>
<summary>Distribution & Dev Notes</summary>

### Bundle & Distribution

- `./build_app.sh` → builds an optimized unsigned `Focusly.app` straight from the Swift build artifacts.
- `./build_dmg.sh` → wraps the app + docs into a tester-friendly `.dmg`.
- Prefer `swift build -c release` (or `xcodebuild -configuration Release`) before packaging for the crispest overlays.

### Signing & Notarization Prep

```bash
brew install --cask alienator88-sentinel
alienator88-sentinel sign Focusly.app \
  --identity "Developer ID Application: Your Name (TEAMID)"
spctl --assess --type exec Focusly.app
```

- Swap the identity for your Developer ID certificate (or use `--identity "-"` for ad-hoc testing).
- The latest public DMG is Developer ID signed; until notarization lands, testers must allow it once via **System Settings › Privacy & Security › Open Anyway**.
- `Resources/Info.plist` now ships with marketing + build versions, the Productivity category, a human-readable copyright,
  and the automation usage blurb Gatekeeper surfaces alongside Accessibility prompts.
- `Focusly.entitlements` is a tracked hardened-runtime manifest; the signing/notarization scripts pick it up automatically so any added capabilities are visible in code review.

### Developer Notebook

- **Window tracking**: `WindowTracker` polls the Accessibility API and gracefully falls back to CoreGraphics when permission is denied.
- **Debug overlay**: toggle `FOCUSLY_DEBUG_WINDOW=1` (or the `FocuslyDebugWindow` preference) to visualize tracked frames.
- **Tracking profiles**: `WindowTrackingProfile` presets define cadence + responsiveness inside `OverlayController`.
- **Launch at login**: `LaunchAtLoginManager` piggybacks on `SMAppService` - Focusly must run from a bundled, signed `.app` before the toggle appears.
- **Localization & presets**: everything lives beside the code in `Focusly/Resources/Localization/*.lproj` so translators + designers stay in sync.

</details>

---

<details>
<summary>For contributors & QA</summary>

### Tests

```bash
swift test
```

Current coverage focuses on `ProfileStore` persistence and preset override logic; more UI-independent pieces move under test as they stabilize.

### Architecture postcard

- `main.swift` boots the `AppDelegate`, which composes the `FocuslyAppCoordinator` and long-lived services such as overlays, hotkeys, and onboarding.
- `OverlayService` hosts one `OverlayWindow` per screen, driven by `WindowTracker` snapshots and a lightweight display link driver for smooth animation.
- Preferences and profiles live in `ProfileStore`, `PresetLibrary`, and `AppSettings`, broadcasting via Combine to keep UI + services synced.
- System bridges (`WindowTracker`, `AXHelper`, `HotkeyCenter`, `LaunchAtLoginManager`) wrap Accessibility, Carbon, and `SMAppService` APIs so the app stays sandbox-friendly.

</details>

---

## **License**

Released under the **MIT License** - see [LICENSE](./LICENSE) for details.

> Focusly remains free during the alpha cycle; optional paid tiers may appear once the notarized launch ships.

---

**Made with ❤️**
