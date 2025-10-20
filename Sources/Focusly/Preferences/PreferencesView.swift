import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(String(localized: "Focusly Preferences", bundle: .module))
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Displays", bundle: .module))
                    .font(.headline)

                ForEach(viewModel.displays) { display in
                    VStack(alignment: .leading, spacing: 12) {
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

                        VStack(alignment: .leading, spacing: 8) {
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

                        VStack(alignment: .leading, spacing: 8) {
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
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { viewModel.hotkeysEnabled },
                    set: { viewModel.setHotkeysEnabled($0) }
                )) {
                    Text(String(localized: "Enable Focus Toggle Shortcut", bundle: .module))
                }
                .toggleStyle(.switch)

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

            Divider()

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

            Divider()

            Button {
                // Handy entry point for users who want to replay the onboarding copy later.
                viewModel.showOnboarding()
            } label: {
                Text(String(localized: "Revisit Introduction…", bundle: .module))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer()
        }
        .padding(24)
        .frame(width: 460)
    }
}
