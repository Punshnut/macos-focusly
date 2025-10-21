import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

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
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Appearance", bundle: .module))
                .font(.headline)

            Picker(
                String(localized: "Status Bar Icon", bundle: .module),
                selection: Binding(
                    get: { viewModel.statusIconStyle },
                    set: { viewModel.updateStatusIconStyle($0) }
                )
            ) {
                ForEach(viewModel.availableIconStyles, id: \.self) { style in
                    HStack(spacing: 8) {
                        Image(nsImage: StatusBarIconFactory.previewIcon(for: style))
                            .renderingMode(.template)
                            .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Displays", bundle: .module))
                .font(.headline)

            ForEach(viewModel.displays) { display in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(display.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            viewModel.resetDisplay(display.id)
                        } label: {
                            Text(String(localized: "Reset", bundle: .module))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Opacity", bundle: .module))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { display.opacity },
                                set: { viewModel.updateOpacity(for: display.id, value: $0) }
                            ),
                            in: 0.35...1.0
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Blur Radius", bundle: .module))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { display.blurRadius },
                                set: { viewModel.updateBlur(for: display.id, value: $0) }
                            ),
                            in: 10...80
                        )
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
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
}
