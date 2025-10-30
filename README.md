# 🌙 Focusly - macOS Ambience & Focus Companion

> 🧪 **Alpha Release** - expect frequent updates and refinements before the stable version.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Status](https://img.shields.io/badge/Stage-Alpha%200.1-yellow)

---

## ✨ Overview

**Focusly** is a lightweight macOS companion that softens your desktop, adapts ambience per monitor, and keeps distraction-cutting tools just a click away in your menu bar.

> Current build: **Prerelease Alpha 0.1**

---

## ⚡️ Highlights

- 🎛️ **Status Bar Control** - quick toggles, presets, and auto-launch management.  
- 🖥️ **Per-Display Overlays** - smooth animations, adjustable opacity, blur, and tint.  
- 🎨 **Ambience Filters** - *Blur (Focus)*, *Warm*, *Colorful*, *Monochrome*, customizable per monitor.  
- 🧭 **Custom Icons** - choose from *Dot*, *Halo*, or *Equalizer* styles.  
- ⌨️ **Global Shortcuts** - configurable Carbon-powered hotkeys.  
- 🪟 **SwiftUI Preferences** - live updates synced with `UserDefaults`.  
- 🚀 **Auto-Start Integration** - via `SMAppService`.  
- 🧩 **Modern Swift Architecture** - async-safe patterns with `@MainActor`, `Task`, and `ObservableObject`.

---

## 💻 Requirements

- macOS **13 Ventura** or newer  
- Optional (for source builds): **Xcode 15 / Swift 5.9** or newer

---

## 🚀 Quick Start

1. **Download** the latest Alpha build from [GitHub Releases](../../releases).  
2. **Install:** drag `Focusly.app` to `/Applications`.  
3. **Launch:** approve unsigned builds in  
   **System Settings → Privacy & Security** if prompted.

---

## 🧠 Build from Source

```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
open Package.swift
```

Then open the workspace in **Xcode 15+**, select the `focusly` scheme, and press **⌘R**.  
Or build via CLI:

```bash
swift build
```

---

## 📦 Packaging

Focusly uses **Swift Package Manager** only.

To build a release bundle:

```bash
swift build -c release
```

Resulting `.app` will appear in:

```
.build/release/focusly.app
```

Wrap it into a DMG or ZIP using `create-dmg`, `ditto`, or custom scripts.  
Legacy helper script: `_old/scripts/package_app.sh`

---

## 🧪 Tests

Run all tests:

```bash
swift test
```

Current coverage:
- Persistence layer (per-display overrides)
- Preset selection logic

Extend the suite as you add new features.

---

## 🧱 Architecture Overview

| Component | Role |
|------------|------|
| **FocuslyAppCoordinator** | Connects status bar, overlays, hotkeys, persistence, and preferences. |
| **OverlayService** | Manages one overlay per display; reacts to screen/space changes. |
| **ProfileStore** | Serializes presets and overrides into `UserDefaults`. |
| **PreferencesWindowController** | SwiftUI-based editor for displays, shortcuts, and startup settings. |
| **HotkeyCenter** | Wraps Carbon APIs for global shortcuts and toggle events. |

---

## 🌐 Localization

Focusly supports multiple languages for both UI and documentation.

### Available Languages
- 🇬🇧 English  
- 🇪🇸 Español (Spanish)  
- 🇨🇳 中文 (Simplified Chinese)  
- 🇺🇦 Українська (Ukrainian)  
- 🇷🇺 Русский (Russian)

Localized setup guides live in:
```
Documentation/en
Documentation/es
Documentation/zh-Hans
Documentation/uk
Documentation/ru
```

---

## 📜 License

This project is released under the **MIT License**.

You’re free to **use, modify, and distribute** Focusly under these terms.  
See [LICENSE](./LICENSE) for the full text.

> ⚠️ *Focusly is currently in Alpha. All core features are free during development.  
Future versions may include optional paid upgrades (e.g., a Pro version).*

---

<details>
<summary>🇪🇸 <b>Leer en Español</b></summary>

### 🌙 Descripción general

**Focusly** es un compañero ligero para macOS que suaviza tu escritorio, adapta el ambiente por monitor y mantiene los controles de enfoque accesibles desde la barra de menús.

> 🧪 Compilación actual: **Alpha 0.1**

### ⚡️ Destacados
- Control rápido en la barra de estado  
- Superposiciones por pantalla  
- Filtros de ambiente personalizables  
- Iconos ajustables  
- Atajos globales  
- Preferencias en tiempo real  
- Inicio automático  
- Arquitectura moderna con SwiftUI y `ObservableObject`

### 💻 Requisitos
- macOS 13 (Ventura) o posterior  
- Xcode 15 / Swift 5.9 (opcional para compilar)

### 🚀 Inicio rápido
1. Descarga la versión más reciente de `Focusly.app`.  
2. Mueve la app a `/Applications` y ábrela.  
3. Si macOS te avisa, apruébala en **Privacidad y seguridad**.

### 🧱 Arquitectura
| Componente | Descripción |
|-------------|-------------|
| `FocuslyAppCoordinator` | Conecta todos los servicios principales |
| `OverlayService` | Gestiona superposiciones por pantalla |
| `ProfileStore` | Guarda presets y configuraciones |
| `PreferencesWindowController` | Editor SwiftUI de opciones |
| `HotkeyCenter` | Gestiona atajos globales |

### 📜 Licencia
Bajo licencia **MIT**. Libre para uso, modificación y distribución.  

</details>

---

**Made with ❤️ and SwiftUI for macOS users who value calm focus and performance.**
