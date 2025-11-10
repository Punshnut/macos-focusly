@testable import Focusly
import XCTest

@MainActor
final class ApplicationMaskingIgnoreListTests: XCTestCase {
    private func makeStore(
        builtInBundles: Set<String> = [],
        builtInFragments: Set<String> = ["alcove"]
    ) -> (store: ApplicationMaskingIgnoreList, defaults: UserDefaults, suiteName: String) {
        let suiteName = "FocuslyTests.MaskIgnore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ApplicationMaskingIgnoreList(
            userDefaults: defaults,
            defaultsKey: "FocuslyTests.MaskIgnore.Key",
            builtInBundleIdentifiers: builtInBundles,
            builtInProcessNameFragments: builtInFragments
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
        XCTAssertTrue(defaults.stringArray(forKey: "FocuslyTests.MaskIgnore.Key")?.contains("com.example.testapp") ?? false)

        store.setIgnored(false, bundleIdentifier: "com.example.TestApp")
        XCTAssertFalse(store.shouldIgnore(bundleIdentifier: "com.example.testapp", processName: nil))
        XCTAssertTrue(store.userDefinedBundleIdentifiers().isEmpty)
    }
}
