import AppKit
import SwiftUI

enum PreferencesTab: Int, CaseIterable, Identifiable {
    case general
    case screen
    case about

    var id: Int { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .screen: return "sparkles.rectangle.stack"
        case .about: return "info.circle"
        }
    }

    var localizationKey: String {
        switch self {
        case .general: return "Preferences.Tab.General"
        case .screen: return "Preferences.Tab.Screen"
        case .about: return "Preferences.Tab.About"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .general: return "General"
        case .screen: return "Screen"
        case .about: return "About"
        }
    }
}

/// Modernized preferences scene with tabbed navigation and frosted styling.
final class PreferencesTabRelay {
    var handler: ((PreferencesTab) -> Void)?
    func notify(_ tab: PreferencesTab) {
        handler?(tab)
    }
}

/// Modernized preferences scene with tabbed navigation and frosted styling.
struct PreferencesView: View {
    @ObservedObject private var viewModel: PreferencesViewModel
    @EnvironmentObject private var localization: LocalizationService
    @State private var activeTab: PreferencesTab = .general
    @State private var selectedDisplayID: DisplayID?
    @Namespace private var tabSelectionNamespace
    @State private var hostingWindow: NSWindow?
    private let tabChangeRelay: PreferencesTabRelay?

    init(viewModel: PreferencesViewModel, tabChangeRelay: PreferencesTabRelay? = nil) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.tabChangeRelay = tabChangeRelay
    }

    var body: some View {
        VStack(spacing: 0) {
            topChromeSpacer
            tabBar
            Divider()
                .opacity(0.08)
                .overlay(Color.white.opacity(0.08))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    tabContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
        .frame(minWidth: 500)
        .background(
            FrostedBackgroundView(material: backgroundMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(borderStrokeColor, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(
            HostingWindowFinder { window in
                hostingWindow = window
                updateWindowChrome(for: window)
            }
            .allowsHitTesting(false)
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .padding(.top, 6)
        .overlay(alignment: .topLeading) {
            windowControls
                .padding(.top, topChromeControlInset)
                .padding(.leading, 22)
                .padding(.trailing, 22)
        }
        .background(outerBackgroundView)
        .onAppear {
            if selectedDisplayID == nil {
                selectedDisplayID = viewModel.displaySettings.first?.id
            }
            DispatchQueue.main.async {
                tabChangeRelay?.notify(activeTab)
            }
        }
        .onChange(of: viewModel.displaySettings.map(\.id)) { displayIDs in
            guard !displayIDs.isEmpty else {
                selectedDisplayID = nil
                tabChangeRelay?.notify(activeTab)
                return
            }
            guard let selectedDisplayID, displayIDs.contains(selectedDisplayID) else {
                selectedDisplayID = displayIDs.first
                tabChangeRelay?.notify(activeTab)
                return
            }
        }
        .onChange(of: activeTab) { tab in
            tabChangeRelay?.notify(tab)
        }
        .onChange(of: viewModel.preferencesWindowGlassy) { _ in
            updateWindowChrome(for: hostingWindow)
        }
    }

    private var topChromeSpacer: some View {
        Color.clear
            .frame(height: topChromeHeight)
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            ForEach(WindowControlKind.allCases) { control in
                WindowControlDot(kind: control) {
                    performWindowAction(for: control)
                }
            }
            Spacer()
        }
        .frame(height: 24, alignment: .leading)
    }

    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(PreferencesTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func tabButton(for tab: PreferencesTab) -> some View {
        let title = localized(tab.localizationKey, fallback: tab.fallbackTitle)
        let isSelected = activeTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                activeTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                            .matchedGeometryEffect(id: "tabSelection", in: tabSelectionNamespace)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 1.6 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .general:
            generalTab
        case .screen:
            screenTab
        case .about:
            aboutTab
        }
    }

    private var generalTab: some View {
        VStack(spacing: 16) {
            settingsPanel(
                icon: "power",
                titleKey: "Preferences.General.Launch",
                fallbackTitle: "Launch & Shortcuts",
                subtitleKey: "Preferences.General.Launch.Description",
                subtitleFallback: "Control startup behavior and your global shortcut."
            ) {
                VStack(spacing: 18) {
                    launchAtLoginControls
                    panelDivider
                    hotkeyControls
                }
            }

            settingsPanel(
                icon: "paintpalette",
                titleKey: "Preferences.General.Appearance",
                fallbackTitle: "Appearance",
                subtitleKey: "Preferences.General.Appearance.Description",
                subtitleFallback: "Adjust how the preferences window itself is styled."
            ) {
                appearanceControls
            }

            settingsPanel(
                icon: "menubar.rectangle",
                titleKey: "Preferences.General.MenuBar",
                fallbackTitle: "Menu Bar Presence",
                subtitleKey: "Preferences.General.MenuBar.Description",
                subtitleFallback: "Pick which Focusly icon appears in the menu bar."
            ) {
                statusIconControls
            }

            settingsPanel(
                icon: "globe",
                titleKey: "Preferences.General.Localized",
                fallbackTitle: "Language & Guidance",
                subtitleKey: "Preferences.General.Localized.Description",
                subtitleFallback: "Switch languages instantly or revisit the intro walkthrough."
            ) {
                VStack(spacing: 18) {
                    languageControls
                    panelDivider
                    onboardingControl
                }
            }
        }
    }

    private var screenTab: some View {
        VStack(spacing: 16) {
            settingsPanel(
                icon: "square.grid.2x2",
                titleKey: "Preferences.Interface.Presets",
                fallbackTitle: "Overlay Presets",
                subtitleKey: "Preferences.Interface.Presets.Description",
                subtitleFallback: "Quickly switch between saved looks."
            ) {
                VStack(spacing: 18) {
                    presetControls
                    panelDivider
                    trackingControls
                }
            }

            displayManagementPanel
        }
    }

    private var aboutTab: some View {
        settingsPanel(
            icon: "info.circle.fill",
            titleKey: "Preferences.About",
            fallbackTitle: "About Focusly",
            subtitleKey: "Preferences.About.Description",
            subtitleFallback: "Version details, credits, and useful links."
        ) {
            VStack(spacing: 22) {
                aboutHeader
                panelDivider
                aboutLinks
                panelDivider
                aboutActions
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - General Panels

    private var launchAtLoginControls: some View {
        launchAtLoginSection
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotkeyControls: some View {
        hotkeySection
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                isOn: Binding(
                    get: { viewModel.preferencesWindowGlassy },
                    set: { viewModel.setPreferencesWindowGlassy($0) }
                )
            ) {
                Text(localized("Preferences.General.Appearance.Toggle", fallback: "Keep the preferences window glassy"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .toggleStyle(.switch)

            Text(localized("Preferences.General.Appearance.Toggle.Description", fallback: "Enable to restore the original translucent styling."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIconControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Status Bar Icon", fallback: "Status Bar Icon"))
                .font(.subheadline)
                .fontWeight(.semibold)
            Picker(
                localized("Status Bar Icon", fallback: "Status Bar Icon"),
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

    private var languageControls: some View {
        languageSection
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onboardingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("Refresh the onboarding steps or review feature highlights."))
                .font(.caption)
                .foregroundColor(.secondary)
            onboardingSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screen Panels

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Overlay Preset"))
                .font(.subheadline)
                .fontWeight(.semibold)

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
        }
    }

    private var trackingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Window Tracking Performance"))
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker(
                localized("Window Tracking Performance"),
                selection: Binding(
                    get: { viewModel.trackingProfile },
                    set: { viewModel.updateTrackingProfile($0) }
                )
            ) {
                ForEach(viewModel.trackingProfileOptions, id: \.self) { profile in
                    Text(localized(profile.titleLocalizationKey, fallback: profile.titleFallback)).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            Text(localized("WindowTrackingProfile.Description.General", fallback: "Adjust how quickly Focusly tracks windows while you move or resize them."))
                .font(.caption)
                .foregroundColor(.secondary)

            Text(localized(viewModel.trackingProfile.descriptionLocalizationKey, fallback: viewModel.trackingProfile.descriptionFallback))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var displayManagementPanel: some View {
        settingsPanel(
            icon: "rectangle.3.group",
            titleKey: "Preferences.Interface.Displays",
            fallbackTitle: "Displays",
            subtitleKey: "Preferences.Interface.Displays.Description",
            subtitleFallback: "Fine-tune Focusly per monitor or sync styles instantly."
        ) {
            if viewModel.displaySettings.isEmpty {
                displayEmptyState
            } else {
                ResponsiveDisplayLayout(
                    selector: displayCollection,
                    inspector: displayInspector
                )
            }
        }
    }

    // MARK: - Reused Control Sections

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.hotkeysEnabled },
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

    private var onboardingSection: some View {
        Button {
            viewModel.showOnboarding()
        } label: {
            Text(localized("Revisit Introduction…"))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

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

    private var displayCollection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Connected Displays", fallback: "Connected Displays"))
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: displayColumns, spacing: 10) {
                ForEach(viewModel.displaySettings) { display in
                    Button {
                        selectedDisplayID = display.id
                    } label: {
                        DisplayCard(
                            display: display,
                            liveSettings: liveSettings(for: display.id),
                            isSelected: isSelected(displayID: display.id),
                            overlayOffLabel: localized("Overlay Off", fallback: "Overlay Off")
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.displaySettings.map(\.id))
        }
    }

    private var displayColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 10, alignment: .top)]
    }

    private var displayInspector: some View {
        Group {
            if let activeDisplay = selectedDisplay {
                monitorInspector(for: activeDisplay)
            } else {
                displayEmptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monitorInspector(for display: PreferencesViewModel.DisplaySettings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(display.name)
                    .font(.title3)
                    .fontWeight(.semibold)
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

            displayPreview(for: display)

            Toggle(isOn: exclusionBinding(for: display.id)) {
                Label(localized("Exclude This Display"), systemImage: "eye.slash")
            }
            .toggleStyle(.switch)

            if isDisplayExcluded(display.id) {
                Text(localized("Focusly leaves this display untouched while other screens stay blurred."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            blurControls(for: display)
                .disabled(isDisplayExcluded(display.id))

            colorControls(for: display)
                .disabled(isDisplayExcluded(display.id))

            actionControls(for: display)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.02))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func displayPreview(for display: PreferencesViewModel.DisplaySettings) -> some View {
        let settings = liveSettings(for: display.id)
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: settings.tint).opacity(settings.opacity))
            .frame(height: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay {
                if settings.isExcluded {
                    Text(localized("Excluded", fallback: "Excluded"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            .opacity(settings.isExcluded ? 0.35 : 1)
            .accessibilityLabel(Text(localized("Overlay preview")))
    }

    private func blurControls(for display: PreferencesViewModel.DisplaySettings) -> some View {
        let materialOptions = FocusOverlayMaterial.allCases
        let currentMaterial = liveSettings(for: display.id).blurMaterial
        let materialIndexBinding = Binding<Double>(
            get: {
                Double(materialOptions.firstIndex(of: currentMaterial) ?? 0)
            },
            set: { newValue in
                guard !materialOptions.isEmpty else { return }
                let clampedIndex = max(0, min(Int(round(newValue)), materialOptions.count - 1))
                let selectedMaterial = materialOptions[clampedIndex]
                viewModel.updateBlurMaterial(for: display.id, material: selectedMaterial)
            }
        )

        return VStack(alignment: .leading, spacing: 14) {
            Text(localized("Blur Style"))
                .font(.caption)
                .foregroundColor(.secondary)

            WindowDragSafeSlider(
                value: materialIndexBinding,
                range: 0...Double(max(materialOptions.count - 1, 1)),
                step: 1
            )
            .frame(height: 22)
            .accessibilityLabel(Text(localized("Blur Style")))
            .accessibilityValue(Text(currentMaterial.accessibilityDescription))

            if materialOptions.count > 1 {
                let selectedMaterialIndex = materialOptions.firstIndex(of: currentMaterial) ?? 0
                HStack(spacing: 4) {
                    ForEach(Array(materialOptions.enumerated()), id: \.offset) { index, _ in
                        Capsule()
                            .fill(index == selectedMaterialIndex ? Color.accentColor : Color.primary.opacity(0.18))
                            .frame(width: index == selectedMaterialIndex ? 16 : 10, height: 3)
                            .animation(.easeInOut(duration: 0.2), value: selectedMaterialIndex)
                            .accessibilityHidden(true)
                    }
                }
            }

            Text(localized("Sample different macOS blur materials to match your space."))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func colorControls(for display: PreferencesViewModel.DisplaySettings) -> some View {
        let opacityBinding = Binding(
            get: { liveSettings(for: display.id).opacity },
            set: { viewModel.updateOpacity(for: display.id, value: $0) }
        )

        let tintBinding = Binding(
            get: { Color(nsColor: liveSettings(for: display.id).tint) },
            set: { newColor in
                if let cgColor = newColor.cgColor,
                   let nsColor = NSColor(cgColor: cgColor) {
                    viewModel.updateTint(for: display.id, value: nsColor)
                } else {
                    viewModel.updateTint(for: display.id, value: display.tint)
                }
            }
        )

        let colorTreatmentBinding = Binding(
            get: { liveSettings(for: display.id).colorTreatment },
            set: { viewModel.updateColorTreatment(for: display.id, treatment: $0) }
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(localized("Overlay Strength"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(opacityLabel(for: opacityBinding.wrappedValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            WindowDragSafeSlider(
                value: opacityBinding,
                range: 0.35...1.0,
                step: 0.01
            )
            .frame(height: 22)
            .accessibilityLabel(Text(localized("Overlay Strength")))

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
                    .fill(Color(nsColor: liveSettings(for: display.id).tint).opacity(liveSettings(for: display.id).opacity))
                    .frame(height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.08))
                    )
                    .accessibilityHidden(true)
            }

            Picker(localized("Color Treatment"), selection: colorTreatmentBinding) {
                ForEach(FocusOverlayColorTreatment.allCases, id: \.self) { treatment in
                    Text(localized(treatment.displayName)).tag(treatment)
                }
            }
            .pickerStyle(.segmented)

            Text(localized("Dial in the color overlay or switch to monochrome window content."))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func actionControls(for display: PreferencesViewModel.DisplaySettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    viewModel.resetDisplay(display.id)
                } label: {
                    Label(localized("Reset to Preset"), systemImage: "arrow.counterclockwise")
                }

                Spacer()

                if viewModel.displaySettings.count > 1 {
                    Menu {
                        Button {
                            viewModel.syncDisplaySettings(from: display.id)
                        } label: {
                            Label(localized("Apply to Other Displays"), systemImage: "square.on.square")
                        }
                        ForEach(viewModel.displaySettings.filter { $0.id != display.id }) { otherDisplay in
                            Button {
                                viewModel.syncDisplaySettings(from: otherDisplay.id)
                            } label: {
                                Label(
                                    String(
                                        format: localized("Match %@", fallback: "Match %@"),
                                        otherDisplay.name
                                    ),
                                    systemImage: "rectangle.connected.to.line.below"
                                )
                            }
                        }
                    } label: {
                        Label(localized("Multi-Monitor Actions"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }

            Text(localized("Revert to the preset defaults or mirror these settings across every screen."))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - About Panel Helpers

    private var aboutHeader: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)

            Text(appDisplayName())
                .font(.title2)
                .fontWeight(.semibold)

            Text(developerSummary())
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(versionSummary())
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var aboutLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            aboutLinkRow(
                icon: "link",
                titleKey: "Preferences.About.Website",
                fallbackTitle: "Project Website",
                urlString: "https://github.com/Punshnut/macos-focusly"
            )

            aboutLinkRow(
                icon: "sparkle.magnifyingglass",
                titleKey: "Preferences.About.Issues",
                fallbackTitle: "Report an Issue",
                urlString: "https://github.com/Punshnut/macos-focusly/issues"
            )

            aboutLinkRow(
                icon: "envelope",
                titleKey: "Preferences.About.Support",
                fallbackTitle: "Support Email",
                urlString: "https://github.com/Punshnut/macos-focusly"
            )
        }
    }

    @ViewBuilder
    private func aboutLinkRow(icon: String, titleKey: String, fallbackTitle: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            let title = localized(titleKey, fallback: fallbackTitle)
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .frame(width: 20)
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutActions: some View {
        HStack(spacing: 14) {
            Button(action: openAboutPanel) {
                Label(localized("Standard About Panel", fallback: "macOS About Panel"), systemImage: "macwindow")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                if let url = URL(string: "https://github.com/Punshnut/macos-focusly") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(localized("View on GitHub", fallback: "View on GitHub"), systemImage: "chevron.right.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Display Helpers

    private func liveSettings(for displayID: DisplayID) -> PreferencesViewModel.DisplaySettings {
        viewModel.displaySettings.first(where: { $0.id == displayID }) ?? viewModel.displaySettings.first ?? PreferencesViewModel.DisplaySettings(
            id: displayID,
            name: "",
            opacity: 1,
            tint: .white,
            colorTreatment: .preserveColor,
            blurMaterial: .hudWindow,
            blurRadius: 0,
            isExcluded: false
        )
    }

    private func exclusionBinding(for displayID: DisplayID) -> Binding<Bool> {
        Binding(
            get: { isDisplayExcluded(displayID) },
            set: { viewModel.setDisplayExcluded(displayID, excluded: $0) }
        )
    }

    private func isDisplayExcluded(_ displayID: DisplayID) -> Bool {
        liveSettings(for: displayID).isExcluded
    }

    private var selectedDisplay: PreferencesViewModel.DisplaySettings? {
        guard let selectedDisplayID else {
            return viewModel.displaySettings.first
        }
        return liveSettings(for: selectedDisplayID)
    }

    private func isSelected(displayID: DisplayID) -> Bool {
        guard let activeID = selectedDisplay?.id ?? selectedDisplayID ?? viewModel.displaySettings.first?.id else { return false }
        return activeID == displayID
    }

    private var displayEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.2")
                .imageScale(.large)
                .foregroundColor(.secondary)
            Text(localized("No displays detected. Connect a monitor to adjust overlay styling."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Shared Helpers

    private var panelDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.vertical, 1)
    }

    private func settingsPanel<Content: View>(
        icon: String,
        titleKey: String,
        fallbackTitle: String,
        subtitleKey: String? = nil,
        subtitleFallback: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized(titleKey, fallback: fallbackTitle))
                        .font(.headline)
                    if let subtitleKey {
                        Text(localized(subtitleKey, fallback: subtitleFallback ?? ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func opacityLabel(for value: Double) -> String {
        let clamped = max(0, min(1, value))
        return String(format: "%.0f%%", clamped * 100)
    }

    private func performWindowAction(for kind: WindowControlKind) {
        guard let window = hostingWindow else { return }
        switch kind {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }

    private var backgroundMaterial: NSVisualEffectView.Material {
        .hudWindow
    }

    private var borderStrokeColor: Color {
        Color.white.opacity(viewModel.preferencesWindowGlassy ? 0.12 : 0.08)
    }

    private func updateWindowChrome(for window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private var topChromeHeight: CGFloat {
        34
    }

    private var topChromeControlInset: CGFloat {
        12
    }

    @ViewBuilder
    private var outerBackgroundView: some View {
        let cornerRadius: CGFloat = 32
        if viewModel.preferencesWindowGlassy {
            Color.clear
        } else {
            FrostedBackgroundView(material: .hudWindow)
                .overlay(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func localized(_ key: String, fallback: String? = nil) -> String {
        localization.localized(key, fallback: fallback ?? key)
    }

    private func appDisplayName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"
    }

    private func versionSummary() -> String {
        let format = localized("Version %@", fallback: "Version %@")
        return String(format: format, FocuslyBuildInfo.marketingVersion)
    }

    private func developerSummary() -> String {
        FocuslyBuildInfo.developerSummary
    }

    private func openAboutPanel() {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showAboutPanel(nil)
        } else {
            NSApp.orderFrontStandardAboutPanel(nil)
        }
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

    private func previewIcon(isActive: Bool) -> some View {
        Image(nsImage: StatusBarIconFactory.icon(style: style, isActive: isActive))
            .renderingMode(.template)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: 18, height: 18)
            .padding(.vertical, 4)
    }
}

/// Compact tile summarizing a display's overlay settings.
private struct DisplayCard: View {
    let display: PreferencesViewModel.DisplaySettings
    let liveSettings: PreferencesViewModel.DisplaySettings
    let isSelected: Bool
    let overlayOffLabel: String

    private var clampedOpacity: Double {
        max(0, min(1, liveSettings.opacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color(nsColor: liveSettings.tint).opacity(clampedOpacity))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .overlay {
                        if liveSettings.isExcluded {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(display.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    if liveSettings.isExcluded {
                        Label(overlayOffLabel, systemImage: "moon.zzz")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                            .foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Label {
                                Text(String(format: "%.0f%%", clampedOpacity * 100))
                            } icon: {
                                Image(systemName: "circle.lefthalf.filled")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)

                            Capsule()
                                .fill(Color(nsColor: liveSettings.tint).opacity(0.35))
                                .frame(width: 32, height: 6)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.4)
                                )
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: liveSettings.tint).opacity(0.38),
                            Color(nsColor: liveSettings.tint).opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.6)
                )
                .opacity(liveSettings.isExcluded ? 0.2 : 1)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : Color.white.opacity(0.04)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.08),
                    lineWidth: isSelected ? 1.6 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

/// Visual effect view used to mimic the macOS frosted window background.
private struct FrostedBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}

// MARK: - Window Controls

private enum WindowControlKind: CaseIterable, Identifiable {
    case close, minimize, zoom

    var id: String {
        switch self {
        case .close:
            return "close"
        case .minimize:
            return "minimize"
        case .zoom:
            return "zoom"
        }
    }

    var color: Color {
        switch self {
        case .close:
            return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .minimize:
            return Color(red: 1.0, green: 0.78, blue: 0.0)
        case .zoom:
            return Color(red: 0.19, green: 0.81, blue: 0.29)
        }
    }
}

private struct WindowControlDot: View {
    let kind: WindowControlKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(kind.color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(kind.id.capitalized) window button"))
    }
}

private struct HostingWindowFinder: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

/// Responsive split view that lays out the selector and inspector depending on available width.
private struct ResponsiveDisplayLayout<Selector: View, Inspector: View>: View {
    let selector: Selector
    let inspector: Inspector
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let width = availableWidth
        let shouldStack = width <= 0 || width < 640
        let selectorWidth = width > 0 ? min(width * 0.42, 320) : 320

        Group {
            if shouldStack {
                VStack(spacing: 16) {
                    selector
                        .frame(maxWidth: .infinity, alignment: .leading)
                    inspector
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    selector
                        .frame(maxWidth: selectorWidth, alignment: .leading)
                    inspector
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ResponsiveLayoutWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(ResponsiveLayoutWidthPreferenceKey.self) { width in
            if availableWidth != width {
                availableWidth = width
            }
        }
    }
}

private struct ResponsiveLayoutWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// NSSlider wrapper that keeps window dragging enabled elsewhere while allowing knob dragging.
private struct WindowDragSafeSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let isContinuous: Bool

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        isContinuous: Bool = true
    ) {
        _value = value
        self.range = range
        self.step = step
        self.isContinuous = isContinuous
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> DragSafeNSSlider {
        let slider = DragSafeNSSlider()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.isContinuous = isContinuous
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.allowsTickMarkValuesOnly = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }

    func updateNSView(_ nsView: DragSafeNSSlider, context: Context) {
        context.coordinator.parent = self
        if nsView.minValue != range.lowerBound {
            nsView.minValue = range.lowerBound
        }
        if nsView.maxValue != range.upperBound {
            nsView.maxValue = range.upperBound
        }
        nsView.isContinuous = isContinuous
        if abs(nsView.doubleValue - value) > .ulpOfOne {
            nsView.doubleValue = value
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: WindowDragSafeSlider

        init(parent: WindowDragSafeSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            var newValue = sender.doubleValue
            if let step = parent.step, step > 0 {
                let lower = parent.range.lowerBound
                let upper = parent.range.upperBound
                newValue = ((newValue - lower) / step).rounded() * step + lower
                newValue = min(max(newValue, lower), upper)
                if abs(newValue - sender.doubleValue) > .ulpOfOne {
                    sender.doubleValue = newValue
                }
            }

            if abs(parent.value - newValue) > .ulpOfOne {
                parent.value = newValue
            }
        }
    }
}

private final class DragSafeNSSlider: NSSlider {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}
