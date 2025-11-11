import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PreferencesTab: Int, CaseIterable, Identifiable {
    case general
    case screen
    case apps
    case about

    var id: Int { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .screen: return "sparkles.rectangle.stack"
        case .apps: return "app.badge"
        case .about: return "info.circle"
        }
    }

    var localizationKey: String {
        switch self {
        case .general: return "Preferences.Tab.General"
        case .screen: return "Preferences.Tab.Screen"
        case .apps: return "Preferences.Tab.Apps"
        case .about: return "Preferences.Tab.About"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .general: return "General"
        case .screen: return "Screen"
        case .apps: return "Apps"
        case .about: return "About"
        }
    }
}

/// Modernized preferences scene with tabbed navigation and frosted styling.
final class PreferencesTabRelay {
    var handler: ((PreferencesTab) -> Void)?
    var selectionRequestHandler: ((PreferencesTab) -> Void)?

    func notify(_ tab: PreferencesTab) {
        handler?(tab)
    }

    func requestSelection(_ tab: PreferencesTab) {
        selectionRequestHandler?(tab)
    }
}

/// Modernized preferences scene with tabbed navigation and frosted styling.
struct PreferencesView: View {
    @ObservedObject private var viewModel: PreferencesViewModel
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeTab: PreferencesTab = .general
    @State private var selectedDisplayID: DisplayID?
    @State private var selectedApplicationIDs: Set<String> = []
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
            tabChangeRelay?.selectionRequestHandler = { tab in
                DispatchQueue.main.async {
                    guard activeTab != tab else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        activeTab = tab
                    }
                }
            }
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
        .onChange(of: viewModel.applicationExceptions.map(\.id)) { applicationIDs in
            selectedApplicationIDs = Set(selectedApplicationIDs.filter { applicationIDs.contains($0) })
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
            .overlay(alignment: .center) {
                topBarTitle
                    .padding(.top, 8)
                    .padding(.horizontal, 60)
            }
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

    private var topBarTitle: some View {
        let isDarkMode = colorScheme == .dark
        let titleColor = isDarkMode ? Color.white.opacity(0.95) : Color.black.opacity(0.82)
        let subtitleColor = isDarkMode ? Color.white.opacity(0.78) : Color.black.opacity(0.5)
        let highlightShadow = isDarkMode ? Color.black.opacity(0.6) : Color.black.opacity(0.12)
        let capsuleFill = LinearGradient(
            colors: isDarkMode
                ? [Color.black.opacity(0.65), Color.black.opacity(0.35)]
                : [
                    Color.white.opacity(viewModel.preferencesWindowGlassy ? 1.0 : 0.9),
                    Color.white.opacity(viewModel.preferencesWindowGlassy ? 0.9 : 0.82)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let capsuleHighlight = LinearGradient(
            colors: isDarkMode
                ? [Color.white.opacity(0.08), Color.clear]
                : [Color.white.opacity(0.35), Color.white.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let capsuleStroke = isDarkMode ? Color.white.opacity(0.28) : Color.black.opacity(0.08)
        let outerGlow = isDarkMode ? Color.white.opacity(0.12) : Color.white.opacity(0.4)
        let shadowColor = isDarkMode ? Color.black.opacity(0.65) : Color.black.opacity(0.15)

        return HStack(spacing: 8) {
            Text(appDisplayName())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundColor(titleColor)
                .shadow(color: highlightShadow, radius: isDarkMode ? 2.5 : 1.5, y: isDarkMode ? 2 : 1)
            Text(FocuslyBuildInfo.marketingVersion)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(subtitleColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(capsuleFill)
                Capsule(style: .continuous)
                    .fill(capsuleHighlight)
                    .blendMode(.screen)
                Capsule(style: .continuous)
                    .strokeBorder(capsuleStroke, lineWidth: 1)
                Capsule(style: .continuous)
                    .stroke(outerGlow, lineWidth: isDarkMode ? 0.6 : 0.8)
                    .blur(radius: isDarkMode ? 6 : 4)
                    .opacity(isDarkMode ? 0.6 : 0.35)
            }
        )
        .shadow(color: shadowColor, radius: isDarkMode ? 22 : 12, y: isDarkMode ? 12 : 6)
        .allowsHitTesting(false)
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
        case .apps:
            appsTab
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
                icon: "menubar.rectangle",
                titleKey: "Preferences.General.MenuBar",
                fallbackTitle: "Menu Bar Presence",
                subtitleKey: "Preferences.General.MenuBar.Description",
                subtitleFallback: "Pick which Focusly icon appears in the menu bar."
            ) {
                statusIconControls
            }

            settingsPanel(
                icon: "paintpalette",
                titleKey: "Preferences.General.Appearance",
                fallbackTitle: "Appearance",
                subtitleKey: "Preferences.General.Appearance.Description",
                subtitleFallback: "Switch between minimal and classic window chrome."
            ) {
                appearanceControls
            }

            settingsPanel(
                icon: "globe",
                titleKey: "Preferences.General.Localized",
                fallbackTitle: "Language & Guidance",
                subtitleKey: "Preferences.General.Localized.Description",
                subtitleFallback: "Switch languages instantly or revisit the intro walkthrough."
            ) {
                languageControls
            }
        }
    }

    private var screenTab: some View {
        VStack(spacing: 16) {
            settingsPanel(
                icon: "square.grid.2x2",
                titleKey: "Preferences.Interface.Presets",
                fallbackTitle: "Focus Presets",
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

            experimentalPanel
        }
    }

    private var appsTab: some View {
        settingsPanel(
            icon: "app.badge.checkmark",
            titleKey: "Preferences.Apps.Title",
            fallbackTitle: "Applications",
            subtitleKey: "Preferences.Apps.Description",
            subtitleFallback: "Choose which apps Focusly should ignore or keep masking their settings."
        ) {
            VStack(spacing: 14) {
                appExceptionsList
                panelDivider
                appListFooter
            }
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

    private var appExceptionsList: some View {
        VStack(spacing: 0) {
            appListHeader

            Divider()
                .overlay(Color.white.opacity(0.1))
                .blendMode(.softLight)

            if viewModel.applicationExceptions.isEmpty {
                appEmptyState
                    .frame(minHeight: 220)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            } else {
                appListContent
            }
        }
        .background(glassListBackground(highlight: true))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(LinearGradient(
                    colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1.1)
                .blendMode(.plusLighter)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 25, y: 20)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var appListHeader: some View {
        HStack {
            Text(localized("Preferences.Apps.Table.Application", fallback: "Application"))
            Spacer(minLength: 0)
            Text(localized("Preferences.Apps.Table.Behavior", fallback: "Behavior"))
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .textCase(.uppercase)
        .foregroundColor(Color.primary.opacity(0.65))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var appListContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.applicationExceptions) { exception in
                    appExceptionRow(for: exception, isSelected: selectedApplicationIDs.contains(exception.id))
                        .id(exception.id)
                        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: selectedApplicationIDs)
                        .onTapGesture {
                            toggleSelection(for: exception)
                        }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
        }
        .frame(minHeight: 220, maxHeight: 320)
        .glassListScrollBackground()
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func appExceptionRow(
        for exception: PreferencesViewModel.ApplicationException,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            applicationRow(for: exception)
                .frame(maxWidth: .infinity, alignment: .leading)

            preferencePicker(for: exception)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassListRowBackground(isSelected: isSelected))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func glassListBackground(cornerRadius: CGFloat = 22, highlight: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                LinearGradient(
                    colors: highlight
                        ? [Color.white.opacity(0.28), Color.white.opacity(0.05)]
                        : [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
    }

    private var appEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "app")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.secondary)
            Text(localized("Preferences.Apps.Empty", fallback: "No apps are excluded yet. Add one to stop Focusly from masking it."))
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var appListFooter: some View {
        let removableSelection = Array(selectedApplicationIDs)
        let canRemove = viewModel.canRemoveApplications(withIDs: removableSelection)
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    presentApplicationPicker()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(toolbarButtonBackground)
                .accessibilityLabel(Text(localized("Preferences.Apps.AddButton", fallback: "Add Application")))

                Button {
                    removeSelectedApplications()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(toolbarButtonBackground)
                .disabled(!canRemove)
                .opacity(canRemove ? 1 : 0.4)
                .accessibilityLabel(Text(localized("Preferences.Apps.RemoveButton", fallback: "Remove Application")))
            }

            Text(localized("Preferences.Apps.Footer", fallback: "Keep overlay helpers visible while still masking their Settings windows when you need to tweak them."))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var toolbarButtonBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            )
    }

    private func applicationRow(for exception: PreferencesViewModel.ApplicationException) -> some View {
        HStack(spacing: 10) {
            appIcon(for: exception)
            VStack(alignment: .leading, spacing: 2) {
                Text(exception.displayName)
                    .font(.body)
                Text(exception.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !exception.isUserDefined {
                Text(localized("Preferences.Apps.DefaultBadge", fallback: "Default"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.6))
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func appIcon(for exception: PreferencesViewModel.ApplicationException) -> some View {
        Group {
            if let icon = exception.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
    }

    private func preferencePicker(for exception: PreferencesViewModel.ApplicationException) -> some View {
        Picker(
            localized("Preferences.Apps.Preference.Label", fallback: "Masking Behavior"),
            selection: Binding(
                get: { exception.preference },
                set: { viewModel.updateApplicationPreference(for: exception.bundleIdentifier, preference: $0) }
            )
        ) {
            Text(localized("Preferences.Apps.Preference.Exclude", fallback: "Always blur entire app"))
                .tag(ApplicationMaskingIgnoreList.Preference.excludeCompletely)
            Text(localized("Preferences.Apps.Preference.SettingsOnly", fallback: "Always blur app except Settings menu"))
                .tag(ApplicationMaskingIgnoreList.Preference.excludeExceptSettingsWindow)
            Text(localized("Preferences.Apps.Preference.AlwaysMask", fallback: "Don't blur any window of this app"))
                .tag(ApplicationMaskingIgnoreList.Preference.alwaysMask)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, y: 4)
    }

    private func presentApplicationPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if #available(macOS 12, *) {
            panel.allowedContentTypes = [.applicationBundle]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.prompt = localized("Preferences.Apps.AddPrompt", fallback: "Add")
        panel.message = localized("Preferences.Apps.AddMessage", fallback: "Select an application to keep off the overlay.")

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.importApplication(at: url)
            if let identifier = Bundle(url: url)?.bundleIdentifier {
                let normalized = identifier.focuslyNormalizedToken() ?? identifier.lowercased()
                DispatchQueue.main.async {
                    selectedApplicationIDs = [normalized]
                }
            }
        }

        if let window = hostingWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func removeSelectedApplications() {
        let identifiers = Array(selectedApplicationIDs)
        guard viewModel.canRemoveApplications(withIDs: identifiers) else { return }
        viewModel.removeApplications(withIDs: identifiers)
        selectedApplicationIDs.removeAll()
    }

    private func toggleSelection(for exception: PreferencesViewModel.ApplicationException) {
        if selectedApplicationIDs.contains(exception.id) {
            selectedApplicationIDs.remove(exception.id)
        } else {
            selectedApplicationIDs.insert(exception.id)
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
                Text(localized("Preferences.General.Appearance.Toggle", fallback: "Make the settings window minimal"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .toggleStyle(.switch)

            Text(localized("Preferences.General.Appearance.Toggle.Description", fallback: "Remove the border and extra chrome from the settings window."))
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

    // MARK: - Screen Panels

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Focus Preset"))
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker(
                localized("Focus Preset"),
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
        VStack(alignment: .leading, spacing: 16) {
            ForEach(viewModel.hotkeyActions, id: \.self) { action in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { viewModel.isHotkeyEnabled(action) },
                        set: { viewModel.setHotkeyEnabled($0, for: action) }
                    )) {
                        Text(localized(action.preferenceTitleKey, fallback: action.preferenceTitleFallback))
                    }
                    .toggleStyle(.switch)

                    Text(localized(action.preferenceDescriptionKey, fallback: action.preferenceDescriptionFallback))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(localized("Shortcut"))
                                .foregroundColor(.secondary)
                            Text(viewModel.shortcutSummary(for: action))
                                .font(.body)
                            Spacer()
                            Button {
                                viewModel.beginShortcutCapture(for: action)
                            } label: {
                                Text(localized("Record"))
                            }
                            .disabled(viewModel.capturingHotkey == action)
                            Button {
                                viewModel.clearShortcut(for: action)
                            } label: {
                                Text(localized("Clear"))
                            }
                            .disabled(!viewModel.hasShortcut(for: action))
                        }

                        if viewModel.capturingHotkey == action {
                            Text(localized("Press a key combination…"))
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
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

    private var experimentalPanel: some View {
        settingsPanel(
            icon: "wand.and.stars",
            titleKey: "Preferences.Interface.DockReveal",
            fallbackTitle: "Dock & Stage Manager (Experimental)",
            subtitleKey: "Preferences.Interface.DockReveal.Description",
            subtitleFallback: "Early controls for how the Dock and Stage Manager clear the blur."
        ) {
            dockRevealControls
        }
    }

    private var dockRevealControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { viewModel.desktopPeripheralRevealEnabled },
                set: { viewModel.setDesktopPeripheralRevealEnabled($0) }
            )) {
                Text(localized(
                    "Preferences.Interface.DockReveal.Toggle",
                    fallback: "Reveal Dock & Stage Manager when desktop is focused"
                ))
            }
            .toggleStyle(.switch)

            Text(localized(
                "Preferences.Interface.DockReveal.Detail",
                fallback: "Automatically clear blur around the Dock and Stage Manager when every window is minimized or the desktop is active."
            ))
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
            Button {
                viewModel.showOnboarding()
            } label: {
                Label(localized("Revisit Introduction…"), systemImage: "sparkles")
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
}

/// Frosted pill background used for each app exception row.
private struct GlassListRowBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(rowGradient)
            .overlay(glossOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(borderGradient, lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(isSelected ? 0.45 : 0.25), radius: isSelected ? 26 : 12, y: isSelected ? 16 : 8)
    }

    private var rowGradient: LinearGradient {
        if isSelected {
            return LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.55),
                    Color.accentColor.opacity(0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color.white.opacity(0.12),
                Color.black.opacity(0.25)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var glossOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isSelected ? 0.18 : 0.08),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.softLight)
            .allowsHitTesting(false)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(isSelected ? 0.85 : 0.2),
                Color.white.opacity(isSelected ? 0.45 : 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

    var accessibilityLocalizationKey: String {
        switch self {
        case .close:
            return "WindowControls.Accessibility.Close"
        case .minimize:
            return "WindowControls.Accessibility.Minimize"
        case .zoom:
            return "WindowControls.Accessibility.Zoom"
        }
    }

    var accessibilityFallback: String {
        switch self {
        case .close:
            return "Close window button"
        case .minimize:
            return "Minimize window button"
        case .zoom:
            return "Zoom window button"
        }
    }
}

private struct WindowControlDot: View {
    let kind: WindowControlKind
    let action: () -> Void
    @EnvironmentObject private var localization: LocalizationService

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
        .accessibilityLabel(
            Text(localization.localized(kind.accessibilityLocalizationKey, fallback: kind.accessibilityFallback))
        )
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

private extension View {
    func glassListScrollBackground() -> some View {
        modifier(GlassListScrollBackgroundModifier())
    }

}

private struct GlassListScrollBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13, *) {
            content
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        } else {
            content
                .background(Color.clear)
        }
    }
}
