# Focusly Settings & First-Run Guide

Focusly’s latest alpha ships with a tabbed, glassy Preferences window and a refreshed onboarding tour that mirrors what is described in the README. Use this guide to stay aligned with the current build.

## Installation Check-In
- Signed + notarized DMGs launch immediately after you drag Focusly into `/Applications`.
- I call out any unsigned/dev drops in the release notes - only those require visiting **System Settings › Privacy & Security › Open Anyway** once before continuing.

## Opening Preferences
- Launch Focusly, click its status bar icon (Standard, Halo, or Equalizer), and choose `Preferences…`, or press `⌘,`.
- The window now uses four tabs-**General**, **Screen**, **Applications**, and **About**-so you can jump straight to the area you need.
- Preferences inherits the frosted chrome from the onboarding flow; use the scroll gesture or the left-hand tabs to traverse sections quickly.

## General Tab
### Launch & Shortcuts
- **Launch Focusly at login** keeps overlays consistent across restarts; the toggle only appears once macOS trusts the signed `.app`.
- Two global hotkeys ship by default: `Toggle overlays` and `Cycle masking mode`. Each row has enable/disable switches plus Record/Clear buttons so you can manage shortcuts independently.
- Tooltips inline with the controls reiterate what each action touches, matching the README’s emphasis on dual hotkeys.

### Menu Bar Presence
- Pick the menu bar icon that matches your setup: Standard, Halo, or Equalizer. The picker previews both idle and active states so you can see contrast at a glance.
- Icon changes apply immediately to the status item and to the quick menu referenced throughout onboarding.

### Appearance
- Toggle **Make the settings window minimal** to collapse the extra border/chrome and keep only the glassy content view. This mirrors the macOS-style aesthetic highlighted in the project overview.

### Language & Guidance
- Override the system language via **App Language** if you want to preview one of the 18 bundled localizations. “Follow macOS Language (Default)” keeps Focusly synced with System Settings.
- Use **Revisit Introduction…** to reopen onboarding without restarting the app; the same command is available from the status bar (`Show Introduction…`).

## Screen Tab
### Focus Presets
- Switch between the current preset library: **Smart Blur, Warm, Dark, White, Paper, Moss, and Ocean**. Selecting a preset updates every display instantly and matches the quick menu preset list.

### Window Tracking Performance
- Choose **Energy Saving (30 Hz)**, **Standard (60 Hz)**, or **High Performance (90 Hz)** to control how often the Accessibility tracker runs.
- Explanations under the segmented control describe the responsiveness vs. battery trade-off so new testers know when to bump the cadence (e.g., rapid window management).

### Displays Panel
- Every connected monitor appears as a tile under **Connected Displays**. Selecting one opens a detailed inspector with:
  - **Preview & Exclusion**: A live tint preview and an `Exclude This Display` switch that leaves certain monitors untouched.
  - **Blur Style slider**: Browse built-in macOS materials (HUD Window → Window Background) so overlays can inherit the correct texture.
  - **Overlay Strength & Tint**: A 35–100% slider plus a Color Picker with opacity support; use `Preserve Color` or `Monochrome` via the segmented control to keep reference content accurate.
  - **Actions**: `Reset to Preset`, `Multi-Monitor Actions`, and `Apply to Other Displays` buttons make it easy to clone a tuned look across the entire desk.
- Tips under each block suggest practical defaults (e.g., keep secondary displays lighter to avoid hiding chat/reference apps).

### Dock & Stage Manager (Experimental)
- A dedicated panel toggles **Reveal Dock & Stage Manager when desktop is focused**. When enabled, Focusly automatically clears the blur around the Dock or Stage Manager strip if every window is minimized or you click the desktop, matching the experimental behavior described in the status updates.

## Applications Tab
- Use **Add Application…** to import any `.app` bundle and tell Focusly how to treat its windows.
- Each row supports three behaviors that map to the current `ApplicationMaskingIgnoreList` options:
  1. **Always blur entire app** (`excludeCompletely`)
  2. **Always blur app except Settings menu** (`excludeExceptSettingsWindow`) - perfect for tools like Alcove.
  3. **Don’t blur any window of this app** (`alwaysMask`)
- Select one or more apps, adjust their masking policy, or remove them entirely. Suggested entries appear automatically when Focusly detects known utilities.

## About Tab
- Shows version/build info, credits, and quick links (privacy details, help center, GitHub repository).
- Includes the same **Revisit Introduction…** action as the General tab plus a prominent link to the project’s GitHub page so testers can file issues right away.

## Onboarding Walkthrough
Focusly displays a five-card onboarding flow on first launch (or whenever you choose **Show Introduction…**):
1. **Welcome to Focusly** – Explains the difference between the status bar menu and the glassy Preferences window; advancing opens Preferences beside the onboarding card.
2. **Switch overlays on** – Guides you to toggle overlays per display from the status bar.
3. **Shift-click for focus** – Teaches the Shift-click gesture that flips between “focused window only” and “all windows from the active app,” with each display remembering its own mode.
4. **Pick a filter** – Prompts you to use the Screen tab to adjust opacity, tint, and presets (Smart Blur, Warm, Dark, White, Paper, Moss, Ocean).
5. **Set your controls** – Encourages binding hotkeys and enabling Launch at Login under the General tab so Focusly is available immediately after boot.

The onboarding window mirrors the Preferences chrome, includes Back/Next navigation, and automatically focuses the relevant Preferences tab on steps 3 and 4 so testers can follow along without hunting.

## First-Run Tips
1. **Allow Accessibility access** when macOS prompts you; Focusly relies on it for masking without capturing the screen.
2. **Toggle overlays per display** from the status bar, then dial in blur strength inside Preferences to match each workspace.
3. **Use Shift-click muscle memory** to promote tool palettes or entire apps without opening Preferences.
4. **Capture both hotkeys**-one shortcut for overlay power and another for masking mode-to stay keyboard-driven.
5. **Tune the Applications tab** for creative suites or streaming apps whose UIs you never want blurred.
6. **Reopen onboarding after hardware changes** so the app can automatically anchor Preferences beside the welcome flow and remind you of the new tabs.
