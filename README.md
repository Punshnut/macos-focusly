# Focusly

> 🧪 This is an alpha release — expect updates and improvements before the stable version.

## English

Focusly is a lightweight macOS companion that softens your desktop, adapts ambience to your workspace, and keeps distraction-cutting controls a click away in the status bar.

> Current build: Prerelease Alpha 0.1

### Highlights
- Status bar control with primary and context menus, including quick toggles, presets, and launch-at-login management.
- Per-display overlays rendered above desktop icons with smooth animations, configurable opacity, blur, and tint.
- Four built-in ambience filters - Blur (Focus), Warm, Colorful, Monochrome - each tweakable per monitor without losing the defaults.
- Three status bar icon styles (Dot, Halo, Equalizer) so you can match Focusly to the rest of your menu bar.
- Customisable global shortcut powered by Carbon hotkeys; capture any modifier combination directly from Preferences.
- Preferences window built with SwiftUI that updates overlays in real time and keeps settings in sync with UserDefaults.
- Login item integration through `SMAppService` so Focusly can light up automatically after you sign in.
- Modern Swift patterns keep things tidy: `@MainActor` coordination, lightweight `Task` usage, and `ObservableObject` view models ensure responsive, thread-safe UI updates.
- Feature-focused folders plus a dependency-injected environment make services swappable and ready for testing.

### Requirements
- macOS 13 (Ventura) or newer
- Xcode 15 / Swift 5.9 or newer

### Quick Start
```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
open Package.swift
```
Open the generated workspace in Xcode 15 or newer, select the `focusly` scheme, and press `⌘R` to launch the Prerelease Alpha 0.1 build. To build from the command line:
```bash
swift build
```

Prefer a ready-to-run build? Download the Focusly.app Alpha from the GitHub releases or grab the bundled `Focusly.app` in this repository's root.

### Packaging
The project ships with a Swift Package Manager manifest only. You can reuse the `_old/scripts/package_app.sh` flow as a starting point, or create a fresh bundle with:
```bash
swift build -c release
```
The resulting `.app` sits under `.build/release/focusly.app`. Wrap it in a DMG or ZIP with your preferred tooling (e.g. `create-dmg`, `ditto`, or custom workflows).

### Tests
```bash
swift test
```
Current tests cover the persistence layer that stores per-display overrides and preset selection. Extend the suite when you add new services.

### Architecture at a Glance
- `FocuslyAppCoordinator` wires together the status item, overlay service, hotkey centre, persistence, and preferences window.
- `OverlayService` owns one `OverlayWindow` per display and reacts to space or screen changes.
- `ProfileStore` serialises the selected preset plus overrides into a single `UserDefaults` payload.
- `PreferencesWindowController` hosts a SwiftUI-driven editor for displays, hotkeys, and login options.
- `HotkeyCenter` wraps Carbon APIs for modifier-aware shortcuts and emits toggle events back to the coordinator.

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

This project is currently in **Alpha stage** and released under the **MIT License**.

All core features are available for free during development.  
Future versions may include additional functionality that could be offered as a **low-cost Pro or upgrade version**.

You are free to use, modify, and distribute this version of the software under the terms of the MIT License.  
See the [LICENSE](./LICENSE) file for more information.

---

## Español

Focusly es un compañero ligero para macOS que suaviza tu escritorio, permite que cada monitor tenga su propio ambiente y mantiene los controles de enfoque accesibles desde la barra de menús.

> Compilación actual: Prerelease Alpha 0.1

### Destacados
- Control en la barra de estado con menús principal y contextual, atajos rápidos, presets y manejo de inicio automático.
- Superposiciones por pantalla situadas sobre los iconos del escritorio, con animaciones fluidas y ajustes de opacidad, desenfoque y tinte.
- Cuatro filtros integrados - Blur (Focus), Cálido, Colorido, Monocromo - personalizables por monitor sin perder el ajuste original.
- Tres estilos para el icono de la barra de menús (Punto, Halo, Ecualizador) para que Focusly combine con tu menú.
- Atajo global configurable usando hotkeys de Carbon; grábalo directamente desde Preferencias con cualquier combinación de modificadores.
- Ventana de preferencias creada con SwiftUI que actualiza las superposiciones en tiempo real y sincroniza ajustes en `UserDefaults`.
- Integración con `SMAppService` para iniciar Focusly automáticamente cuando inicies sesión.
- Patrones modernos de Swift: coordinación `@MainActor`, uso sencillo de `Task` y view models `ObservableObject` para actualizaciones reactivas y seguras en la interfaz.
- Carpetas orientadas a funcionalidades y un entorno inyectado mantienen las dependencias explícitas y listas para pruebas.

### Requisitos
- macOS 13 (Ventura) o posterior
- Xcode 15 / Swift 5.9 o posterior

### Inicio rápido
```bash
git clone https://github.com/your-user/macos-focusly.git
cd macos-focusly
open Package.swift
```
Abre el workspace generado en Xcode 15 o posterior, selecciona el esquema `focusly` y pulsa `⌘R` para iniciar la compilación Prerelease Alpha 0.1. Para compilar desde la línea de comandos:
```bash
swift build
```

¿Prefieres una compilación lista para usar? Descarga el Focusly.app Alpha desde los lanzamientos de GitHub o utiliza el `Focusly.app` incluido en la raíz del repositorio.

### Empaquetado
El proyecto utiliza únicamente Swift Package Manager. Puedes reutilizar `_old/scripts/package_app.sh` como referencia o crear un nuevo paquete con:
```bash
swift build -c release
```
La aplicación (`focusly.app`) queda en `.build/release/`. Empácalo en DMG o ZIP con tu herramienta preferida (`create-dmg`, `ditto`, flujos personalizados, etc.).

### Pruebas
```bash
swift test
```
Las pruebas actuales validan la capa de persistencia que almacena overrides por pantalla y la selección de presets. Añade más pruebas conforme amplíes el proyecto.

### Arquitectura en resumen
- `FocuslyAppCoordinator` conecta la barra de estado, el servicio de superposición, los atajos, la persistencia y la ventana de preferencias.
- `OverlayService` administra una `OverlayWindow` por pantalla y responde a cambios de espacios o monitores.
- `ProfileStore` serializa el preset seleccionado y los overrides en un solo payload dentro de `UserDefaults`.
- `PreferencesWindowController` hospeda un editor basado en SwiftUI para pantallas, atajos y opciones de arranque.
- `HotkeyCenter` encapsula las APIs de Carbon y envía eventos de alternancia de vuelta al coordinador.

## Licencia

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Este proyecto se encuentra actualmente en **fase alfa** y se publica bajo la **licencia MIT**.

Todas las funciones principales están disponibles de forma gratuita durante el desarrollo.  
Las versiones futuras pueden incluir funciones adicionales que podrían ofrecerse como una **versión Pro o de pago a bajo costo**.

Eres libre de usar, modificar y distribuir esta versión del software según los términos de la licencia MIT.  
Consulta el archivo [LICENSE](./LICENSE) para más información.
