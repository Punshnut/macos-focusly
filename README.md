# 🌙 Focusly - macOS Ambience & Focus Companion

> 🧪 **Alpha 0.1** – expect rapid iteration while the core experience settles.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Status](https://img.shields.io/badge/Stage-Alpha%200.1-yellow)

---

## ✨ Overview

**Focusly** is a lightweight menu bar companion for macOS. It softens each display with a glassy overlay, keeps distractions under control, and gives you per-monitor ambience controls without getting in the way.

Focusly tracks the active window (with your permission) so the foreground content stays sharp while the rest of the desktop calmly fades back. Presets, per-display overrides, and localizations live directly inside the Swift Package so contributors can tweak everything with familiar tooling.

---

## ⚡️ Feature Highlights

- 🎛️ **Status Bar Controls & Live Preferences** – toggle overlays, pick presets, switch icon styles, and jump into settings instantly.  
- 🖥️ **Per-Display Styling** – individual opacity, tint, and color treatment per monitor, with quick copy/sync tools.  
- 🪟 **Context-Aware Masks** – carve around the focused window plus menus, contextual panels, and popovers so interactions stay visible.  
- 🎨 **Preset Library** – Blur (Focus), Warm, Colorful, and Monochrome looks powered by `PresetLibrary` and `ProfileStore`.  
- ⌨️ **Global Shortcut** – Carbon-backed hotkey you can remap or disable from preferences or the menu bar.  
- 🚀 **Launch at Login Support** – available when running from the bundled `.app` via `SMAppService`.  
- 🧭 **Onboarding Flow** – guides first-run setup, including language selection and accessibility permission hints.  
- 🌐 **Localization Ready** – runtime language switching with translations for English, Spanish, Simplified Chinese, Ukrainian, and Russian.

---

## 💻 Requirements

- macOS **13 Ventura** or newer.  
- **Accessibility** permission (recommended) so Focusly can track window geometry. Without it, overlays stay active but lose contextual masks.  
- For source builds: **Xcode 15** / **Swift 5.9** or newer.

---

## 🚀 Run the Preview Build

Alpha binaries are included in this repository for quick trials:

1. Double-click `Focusly.dmg` and drag `Focusly.app` into `/Applications` (or open the checked-in `Focusly.app` bundle directly).  
2. Because the build is unsigned, Control-click the app, choose **Open**, and confirm the prompt under **System Settings › Privacy & Security**.  
3. When Focusly launches, grant Accessibility access when prompted: **System Settings › Privacy & Security › Accessibility** → enable **Focusly**.  
4. The menu bar item appears immediately—use **Enable Overlays** to bring the ambience online.

---

## 🧠 Build from Source

```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
swift build
```

- Open `Package.swift` in **Xcode 15+**, pick the `Focusly` scheme, and hit **⌘R** to run.  
- The CLI build outputs `.build/debug/Focusly`. Run it with `focusly` or bundle it via the scripts below.

---

## 📦 Bundle & Distribution Scripts

- `./build_app.sh` creates an unsigned `Focusly.app` using the latest SPM build output.  
- `./build_dmg.sh` rebuilds the app, stages the README alongside it, and produces `Focusly.dmg` ready for sharing.  
- Prefer `swift build -c release` before packaging if you need optimized binaries. The release `.app` lands in `.build/release/Focusly.app`.

---

## 🛠️ Development Notes

- **Accessibility:** Focusly falls back to CoreGraphics polling if Accessibility permission is denied, but contextual masking works best when permission is granted.  
- **Debug window:** Set `FOCUSLY_DEBUG_WINDOW=1` before launching to display the AX window tracker overlay for development.  
- **Launch at login:** Only available when running from an `.app` bundle (the menu explains this if you are in the CLI target).  
- **Localization:** Preferences expose language overrides via `LocalizationService`; translations live under `Sources/Focusly/Resources/*.lproj`.  
- **Onboarding:** Reset onboarding from the preferences window if you want to rerun the guided tour.

---

## 🧪 Tests

Run the current suite with:

```bash
swift test
```

Existing coverage focuses on `ProfileStore` persistence and preset override behavior. Expand the test target as more logic moves out of the UI layer.

---

## 🧱 Architecture Overview

| Component | Role |
|------------|------|
| **FocuslyAppCoordinator** | Central hub that wires overlays, status bar, onboarding, preferences, hotkeys, and localization together. |
| **OverlayService** | Creates an `OverlayWindow` per display and keeps frames/styles synchronized with `ProfileStore`. |
| **OverlayController** | Tracks the focused window and applies contextual masks using Accessibility/CoreGraphics data. |
| **ProfileStore** | Persists presets and per-display overrides in `UserDefaults`, powering the ambience presets. |
| **PreferencesWindowController / PreferencesViewModel** | SwiftUI configuration UI for presets, displays, hotkeys, login items, onboarding, and language. |
| **StatusBarController** | Draws the menu bar item, quick actions, preset menus, and login/hotkey toggles. |
| **HotkeyCenter** | Carbon wrapper that registers the global toggle shortcut and manages enable/disable state. |
| **LocalizationService** | Provides runtime language switching, localized strings, and language option metadata. |
| **LaunchAtLoginManager** | Bridges `SMAppService` to enroll/un-enroll Focusly as a login item when possible. |

---

## 🌐 Localization

In-app languages:

- 🇬🇧 English  
- 🇪🇸 Español  
- 🇨🇳 中文（简体）  
- 🇺🇦 Українська  
- 🇷🇺 Русский

Documentation folders live in `Documentation/<locale>` and include additional guides for Japanese (`ja`) and Korean (`ko`) readers.

---

## 📜 License

This project is released under the **MIT License**. See [LICENSE](./LICENSE) for the full text.

> ⚠️ Focusly is free to use during the alpha period. Future releases may introduce optional paid upgrades once the core experience stabilizes.

---

<details>
<summary>🇪🇸 <b>Leer en Español</b></summary>

### 🌙 Descripción general

**Focusly** es un compañero ligero para macOS. Atenúa el fondo de cada pantalla, resalta la ventana activa y pone los controles de enfoque al alcance directamente desde la barra de menús.

### ⚡️ Destacados
- Controles rápidos en la barra de estado con presets y estilo del icono.  
- Superposiciones por monitor con opacidad y color sincronizados en tiempo real.  
- Máscaras contextuales que respetan menús, ventanas emergentes y el contenido activo.  
- Biblioteca de presets (Blur, Warm, Colorful, Monochrome) con overrides guardados en `UserDefaults`.  
- Atajo global configurable y opción de iniciar con macOS (cuando se ejecuta desde `.app`).  
- Asistente inicial que orienta sobre permisos y preferencias de idioma.  
- Interfaz traducida a Inglés, Español, Chino simplificado, Ucraniano y Ruso.

### 💻 Requisitos
- macOS 13 Ventura o posterior.  
- Permiso de Accesibilidad para mejorar el recorte de la ventana activa.  
- Xcode 15 / Swift 5.9 (opcional para compilar desde el código).

### 🚀 Inicio rápido
1. Abre `Focusly.dmg` y copia `Focusly.app` a `/Applications`.  
2. Abre la app (Control + clic → **Abrir**) y aprueba el aviso de seguridad.  
3. Autoriza Accesibilidad en **Configuración del Sistema › Privacidad y seguridad › Accesibilidad**.

### 🧱 Arquitectura
| Componente | Descripción |
|-------------|-------------|
| `FocuslyAppCoordinator` | Coordina superposiciones, barra de estado, preferencias y hotkeys. |
| `OverlayService` | Mantiene una superposición por pantalla y aplica presets u overrides. |
| `OverlayController` | Gestiona el recorte de la ventana activa y menús auxiliares. |
| `ProfileStore` | Persiste presets y configuraciones por monitor en `UserDefaults`. |
| `StatusBarController` | Construye los menús y acciones rápidas en la barra de menús. |

### 📜 Licencia
Distribuido bajo licencia **MIT**. Úsalo, modifícalo y compártelo libremente.

</details>

---

**Made with ❤️ and SwiftUI for macOS users who value calm focus and performance.**
