import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var selectedDisplayID: DisplayID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "Focusly Preferences", bundle: .module))
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
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420)
        .onAppear {
            if selectedDisplayID == nil {
                selectedDisplayID = viewModel.displays.first?.id
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Appearance", bundle: .module))
                .font(.headline)

            Picker(
                String(localized: "Overlay Preset", bundle: .module),
                selection: Binding(
                    get: { viewModel.selectedPresetID },
                    set: { viewModel.selectPreset(id: $0) }
                )
            ) {
                ForEach(viewModel.availablePresets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.segmented)

            Text(String(localized: "Switch between saved overlay looks instantly.", bundle: .module))
                .font(.caption)
                .foregroundColor(.secondary)

            Picker(
                String(localized: "Status Bar Icon", bundle: .module),
                selection: Binding(
                    get: { viewModel.statusIconStyle },
                    set: { viewModel.updateStatusIconStyle($0) }
                )
            ) {
                ForEach(viewModel.availableIconStyles, id: \.self) { style in
                    HStack(spacing: 8) {
                        StatusBarIconStyleMenuPreview(style: style)
                        Text(style.localizedName)
                    }
                    .tag(style)
                }
            }
            .pickerStyle(.menu)

            Text(String(localized: "Choose how Focusly appears in the menu bar.", bundle: .module))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Displays", bundle: .module))
                    .font(.headline)
                if viewModel.displays.count > 1 {
                    Text(String(localized: "Pick a screen to fine-tune or copy its look to every monitor.", bundle: .module))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(String(localized: "Dial in how Focusly feels on this display.", bundle: .module))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.displays.isEmpty {
                Text(String(localized: "No displays detected. Connect a monitor to adjust overlay styling.", bundle: .module))
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
    private var displayChooser: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.displays) { display in
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

    private func displayDetail(for display: PreferencesViewModel.DisplaySettings) -> some View {
        let liveOpacity = viewModel.displays.first(where: { $0.id == display.id })?.opacity ?? display.opacity
        let liveBlur = viewModel.displays.first(where: { $0.id == display.id })?.blurRadius ?? display.blurRadius
        let liveTint = viewModel.displays.first(where: { $0.id == display.id })?.tint ?? display.tint

        let opacityBinding = Binding(
            get: { viewModel.displays.first(where: { $0.id == display.id })?.opacity ?? display.opacity },
            set: { viewModel.updateOpacity(for: display.id, value: $0) }
        )

        let blurBinding = Binding(
            get: { viewModel.displays.first(where: { $0.id == display.id })?.blurRadius ?? display.blurRadius },
            set: { viewModel.updateBlur(for: display.id, value: $0) }
        )

        let tintBinding = Binding(
            get: { Color(nsColor: viewModel.displays.first(where: { $0.id == display.id })?.tint ?? display.tint) },
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
                    Text(String(localized: "Adjust how the overlay looks on this screen.", bundle: .module))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Menu {
                    Button(String(localized: "Reset This Display", bundle: .module)) {
                        viewModel.resetDisplay(display.id)
                    }
                    if viewModel.displays.count > 1 {
                        Button(String(localized: "Copy settings to other displays", bundle: .module)) {
                            viewModel.syncDisplaySettings(from: display.id)
                        }
                    }
                } label: {
                    Label(String(localized: "Options", bundle: .module), systemImage: "ellipsis.circle")
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
                .accessibilityLabel(Text(String(localized: "Overlay preview", bundle: .module)))

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Color Filter", bundle: .module))
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

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Blur Radius", bundle: .module))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(blurLabel(for: liveBlur))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: blurBinding, in: 10...80, step: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Tint", bundle: .module))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ColorPicker(
                        String(localized: "Overlay Tint", bundle: .module),
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
                    Text(String(localized: "Adjust the tint, blur, and transparency until it matches your space.", bundle: .module))
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

    private var selectedDisplay: PreferencesViewModel.DisplaySettings? {
        if let id = selectedDisplayID,
           let match = viewModel.displays.first(where: { $0.id == id }) {
            return match
        }
        return viewModel.displays.first
    }

    private func isSelected(displayID: DisplayID) -> Bool {
        guard let activeID = selectedDisplay?.id ?? selectedDisplayID ?? viewModel.displays.first?.id else { return false }
        return activeID == displayID
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { viewModel.hotkeysEnabled },
                set: { viewModel.setHotkeysEnabled($0) }
            )) {
                Text(String(localized: "Enable Focus Toggle Shortcut", bundle: .module))
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "Shortcut", bundle: .module))
                        .foregroundColor(.secondary)
                    Text(viewModel.shortcutDescription)
                        .font(.body)
                    Spacer()
                    Button {
                        viewModel.beginShortcutCapture()
                    } label: {
                        Text(String(localized: "Record", bundle: .module))
                    }
                    .disabled(viewModel.capturingShortcut)
                    Button {
                        viewModel.clearShortcut()
                    } label: {
                        Text(String(localized: "Clear", bundle: .module))
                    }
                }

                if viewModel.capturingShortcut {
                    Text(String(localized: "Press a key combination…", bundle: .module))
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.launchAtLoginEnabled },
                set: { viewModel.setLaunchAtLoginEnabled($0) }
            )) {
                Text(String(localized: "Launch Focusly at login", bundle: .module))
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.launchAtLoginAvailable)

            if let message = viewModel.launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var onboardingSection: some View {
        Button {
            viewModel.showOnboarding()
        } label: {
            Text(String(localized: "Revisit Introduction…", bundle: .module))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private func opacityLabel(for value: Double) -> String {
        let clamped = max(0, min(1, value))
        return String(format: "%.0f%%", clamped * 100)
    }

    private func blurLabel(for value: Double) -> String {
        String(format: "%.0f px", value)
    }
}

private struct StatusBarIconStyleMenuPreview: View {
    let style: StatusBarIconStyle

    var body: some View {
        HStack(spacing: 6) {
            previewIcon(isActive: false)
            previewIcon(isActive: true)
        }
        .accessibilityHidden(true)
    }

    private func previewIcon(isActive: Bool) -> some View {
        Image(nsImage: StatusBarIconFactory.icon(style: style, isActive: isActive))
            .renderingMode(.template)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: 18, height: 18)
            .padding(.vertical, 4)
    }
}

private struct DisplayChip: View {
    let display: PreferencesViewModel.DisplaySettings
    let isSelected: Bool

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
                HStack(spacing: 4) {
                    Image(systemName: "drop")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f px", display.blurRadius))
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
