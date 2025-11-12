@testable import Focusly
import XCTest

@MainActor
final class ApplicationMaskingIgnoreListTests: XCTestCase {
    private func makeStore(
        builtInBundles: [String: ApplicationMaskingIgnoreList.Preference] = [:],
        builtInFragments: [String: ApplicationMaskingIgnoreList.Preference] = ["alcove": .excludeExceptSettingsWindow]
    ) -> (store: ApplicationMaskingIgnoreList, defaults: UserDefaults, suiteName: String) {
        let suiteName = "FocuslyTests.MaskIgnore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ApplicationMaskingIgnoreList(
            userDefaults: defaults,
            defaultsKey: "FocuslyTests.MaskIgnore.Key",
            builtInBundleEntries: builtInBundles,
            builtInProcessNameFragmentPreferences: builtInFragments
        )
        return (store, defaults, suiteName)
    }

    func testProcessNameFragmentsIgnoreAlcove() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(store.shouldIgnore(bundleIdentifier: nil, processName: "Alcove"))
        XCTAssertTrue(store.shouldIgnore(bundleIdentifier: nil, processName: "alcove helper"))
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: nil, processName: "Preview"))
    }

    func testPersistedBundleIdentifiersRoundTrip() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setIgnored(true, bundleIdentifier: "com.example.TestApp")
        XCTAssertTrue(store.shouldIgnore(bundleIdentifier: "com.example.testapp", processName: nil))
        XCTAssertEqual(store.userDefinedBundleIdentifiers(), ["com.example.testapp"])
        let entry = store.userEntries().first(where: { $0.bundleIdentifier == "com.example.TestApp" })
        XCTAssertEqual(entry?.preference, .excludeCompletely)
        XCTAssertTrue(defaults.stringArray(forKey: "FocuslyTests.MaskIgnore.Key")?.contains("com.example.testapp") ?? false)

        store.setIgnored(false, bundleIdentifier: "com.example.TestApp")
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.testapp", processName: nil))
        XCTAssertTrue(store.userDefinedBundleIdentifiers().isEmpty)
    }

    func testSettingsWindowBypassesIgnoreWhenPreferenceAllows() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setPreference(.excludeExceptSettingsWindow, bundleIdentifier: "com.example.SettingsApp")
        XCTAssertTrue(store.shouldIgnore(bundleIdentifier: "com.example.settingsapp", processName: nil, windowName: "Main Overlay"))
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.settingsapp", processName: nil, windowName: "Settings"))
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.settingsapp", processName: nil, windowName: "Preferences"))
    }

    func testBuiltInProcessFragmentAllowsSettingsWindowWhenPartial() {
        let (store, defaults, suiteName) = makeStore(
            builtInFragments: ["alcove": .excludeExceptSettingsWindow]
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(store.shouldIgnore(bundleIdentifier: nil, processName: "Alcove Helper", windowName: "Main"))
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: nil, processName: "Alcove Helper", windowName: "Settings"))
    }

    func testAlwaysMaskPreferenceForcesMasking() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setPreference(.alwaysMask, bundleIdentifier: "com.example.FocusApp")
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.focusapp", processName: nil))
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.focusapp", processName: nil, windowName: "Settings"))
    }
}
