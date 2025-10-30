import AppKit
import SwiftUI

/// Hosts the SwiftUI preferences UI for overlays, hotkeys, onboarding, and localization.
struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @EnvironmentObject private var localization: LocalizationService
    @State private var selectedDisplayID: DisplayID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(localized("Focusly Preferences"))
                    .font(.title2)
                    .fontWeight(.semibold)

                appearanceSection

                Divider()

                displaysSection

                Divider()

                hotkeySection

                Divider()

                launchAtLoginSection

                Divider()

                onboardingSection

                Divider()

                languageSection
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420)
        .onAppear {
            if selectedDisplayID == nil {
                selectedDisplayID = viewModel.displaySettings.first?.id
            }
        }
    }

    /// Preset and status icon controls.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Appearance"))
                .font(.headline)

            Picker(
                localized("Overlay Preset"),
                selection: Binding(
                    get: { viewModel.selectedPresetIdentifier },
                    set: { viewModel.selectPreset(id: $0) }
                )
            ) {
                ForEach(viewModel.presetOptions) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.segmented)

            Text(localized("Switch between saved overlay looks instantly."))
                .font(.caption)
                .foregroundColor(.secondary)

            Picker(
                localized("Status Bar Icon"),
                selection: Binding(
                    get: { viewModel.statusIconStyle },
                    set: { viewModel.updateStatusIconStyle($0) }
                )
            ) {
                ForEach(viewModel.iconStyleOptions, id: \.self) { style in
                    HStack(spacing: 8) {
                        StatusBarIconStyleMenuPreview(style: style)
                        Text(style.localizedName)
                    }
                    .tag(style)
                }
            }
            .pickerStyle(.menu)

            Text(localized("Choose how Focusly appears in the menu bar."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Per-display overlay customization UI.
    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Displays"))
                    .font(.headline)
                if viewModel.displaySettings.count > 1 {
                    Text(localized("Pick a screen to fine-tune or copy its look to every monitor."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(localized("Dial in how Focusly feels on this display."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.displaySettings.isEmpty {
                Text(localized("No displays detected. Connect a monitor to adjust overlay styling."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                displayChooser

                if let activeDisplay = selectedDisplay {
                    displayDetail(for: activeDisplay)
                }
            }
        }
    }

    @ViewBuilder
    /// Horizontal selector showing all detected displays.
    private var displayChooser: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.displaySettings) { display in
                    Button {
                        selectedDisplayID = display.id
                    } label: {
                        DisplayChip(
                            display: display,
                            isSelected: isSelected(displayID: display.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(display.name)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Detailed controls for adjusting opacity and tint on the selected display.
    private func displayDetail(for display: PreferencesViewModel.DisplaySettings) -> some View {
        let liveOpacity = viewModel.displaySettings.first(where: { $0.id == display.id })?.opacity ?? display.opacity
        let liveTint = viewModel.displaySettings.first(where: { $0.id == display.id })?.tint ?? display.tint

        let opacityBinding = Binding(
            get: { viewModel.displaySettings.first(where: { $0.id == display.id })?.opacity ?? display.opacity },
            set: { viewModel.updateOpacity(for: display.id, value: $0) }
        )

        let tintBinding = Binding(
            get: { Color(nsColor: viewModel.displaySettings.first(where: { $0.id == display.id })?.tint ?? display.tint) },
            set: { newColor in
                if let cgColor = newColor.cgColor,
                   let nsColor = NSColor(cgColor: cgColor) {
                    viewModel.updateTint(for: display.id, value: nsColor)
                } else {
                    viewModel.updateTint(for: display.id, value: display.tint)
                }
            }
        )

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(localized("Adjust how the overlay looks on this screen."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Menu {
                    Button(localized("Reset This Display")) {
                        viewModel.resetDisplay(display.id)
                    }
                    if viewModel.displaySettings.count > 1 {
                        Button(localized("Copy settings to other displays")) {
                            viewModel.syncDisplaySettings(from: display.id)
                        }
                    }
                } label: {
                    Label(localized("Options"), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .imageScale(.large)
                        .padding(6)
                }
                .menuStyle(.borderlessButton)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: liveTint).opacity(liveOpacity))
                .frame(height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityLabel(Text(localized("Overlay preview")))

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(localized("Color Filter"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(opacityLabel(for: liveOpacity))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: opacityBinding, in: 0.35...1.0, step: 0.01)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Tint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ColorPicker(
                        localized("Overlay Tint"),
                        selection: tintBinding,
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: liveTint).opacity(liveOpacity))
                        .frame(height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.08))
                        )
                        .accessibilityHidden(true)
                    Text(localized("Adjust the tint and transparency until it matches your space."))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    /// Currently focused display entry, defaulting to the first available.
    private var selectedDisplay: PreferencesViewModel.DisplaySettings? {
        if let id = selectedDisplayID,
           let match = viewModel.displaySettings.first(where: { $0.id == id }) {
            return match
        }
        return viewModel.displaySettings.first
    }

    /// Checks whether the supplied display ID matches the highlighted tile.
    private func isSelected(displayID: DisplayID) -> Bool {
        guard let activeID = selectedDisplay?.id ?? selectedDisplayID ?? viewModel.displaySettings.first?.id else { return false }
        return activeID == displayID
    }

    /// Shortcut enablement and capture controls.
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { viewModel.areHotkeysEnabled },
                set: { viewModel.setHotkeysEnabled($0) }
            )) {
                Text(localized("Enable Focus Toggle Shortcut"))
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized("Shortcut"))
                        .foregroundColor(.secondary)
                    Text(viewModel.shortcutSummary)
                        .font(.body)
                    Spacer()
                    Button {
                        viewModel.beginShortcutCapture()
                    } label: {
                        Text(localized("Record"))
                    }
                    .disabled(viewModel.isCapturingShortcut)
                    Button {
                        viewModel.clearShortcut()
                    } label: {
                        Text(localized("Clear"))
                    }
                }

                if viewModel.isCapturingShortcut {
                    Text(localized("Press a key combination…"))
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// Launch-at-login toggle with status messaging.
    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.isLaunchAtLoginEnabled },
                set: { viewModel.setLaunchAtLoginEnabled($0) }
            )) {
                Text(localized("Launch Focusly at login"))
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.isLaunchAtLoginAvailable)

            if let message = viewModel.launchAtLoginStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Button to reopen the onboarding walkthrough.
    private var onboardingSection: some View {
        Button {
            viewModel.showOnboarding()
        } label: {
            Text(localized("Revisit Introduction…"))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    /// Language picker that leverages the localization service overrides.
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("App Language"))
                .font(.headline)

            Picker(
                localized("App Language"),
                selection: Binding(
                    get: { localization.selectedLanguageID },
                    set: { viewModel.setLanguage(id: $0) }
                )
            ) {
                ForEach(localization.languageOptions) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            Text(localized("Choose which language Focusly uses. Switch instantly to test translations."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Formats an opacity value as a percentage string.
    private func opacityLabel(for value: Double) -> String {
        let clamped = max(0, min(1, value))
        return String(format: "%.0f%%", clamped * 100)
    }

    /// Convenience wrapper so the view reads from the localization service.
    private func localized(_ key: String) -> String {
        localization.localized(key, fallback: key)
    }

}

/// Menu row preview for status bar icon styles.
private struct StatusBarIconStyleMenuPreview: View {
    let style: StatusBarIconStyle

    var body: some View {
        HStack(spacing: 6) {
            previewIcon(isActive: false)
            previewIcon(isActive: true)
        }
        .accessibilityHidden(true)
    }

    /// Renders either the active or inactive variant of the icon.
    private func previewIcon(isActive: Bool) -> some View {
        Image(nsImage: StatusBarIconFactory.icon(style: style, isActive: isActive))
            .renderingMode(.template)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: 18, height: 18)
            .padding(.vertical, 4)
    }
}

/// Compact tile summarizing a display's overlay settings.
private struct DisplayChip: View {
    let display: PreferencesViewModel.DisplaySettings
    let isSelected: Bool

    /// Bounds the provided opacity before rendering or displaying it.
    private var clampedOpacity: Double {
        max(0, min(1, display.opacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .imageScale(.medium)
                    .foregroundColor(.secondary)
                Text(display.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: display.tint).opacity(clampedOpacity))
                .frame(height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", clampedOpacity * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.6 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
