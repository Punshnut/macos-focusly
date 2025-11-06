import XCTest
@testable import Focusly

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testSelectPresetClearsOverrides() {
        let userDefaults = UserDefaults(suiteName: "FocuslyTests.ProfileStore")!
        userDefaults.removePersistentDomain(forName: "FocuslyTests.ProfileStore")
        defer { userDefaults.removePersistentDomain(forName: "FocuslyTests.ProfileStore") }
        let store = ProfileStore(userDefaults: userDefaults)
        let displayID: UInt32 = 1
        let override = FocusOverlayStyle(opacity: 0.5, tint: .neutral, animationDuration: 0.3)
        store.updateStyle(override, forDisplayID: displayID)
        XCTAssertEqual(store.style(forDisplayID: displayID).opacity, 0.5, accuracy: 0.001)

        let preset = PresetLibrary.presets[1]
        store.selectPreset(preset)
        XCTAssertEqual(store.style(forDisplayID: displayID).opacity, preset.style.opacity, accuracy: 0.001)
    }

    func testOverridesPersistBetweenInstances() {
        let userDefaults = UserDefaults(suiteName: "FocuslyTests.ProfileStorePersistence")!
        userDefaults.removePersistentDomain(forName: "FocuslyTests.ProfileStorePersistence")
        defer { userDefaults.removePersistentDomain(forName: "FocuslyTests.ProfileStorePersistence") }

        var store: ProfileStore? = ProfileStore(userDefaults: userDefaults)
        let displayID: UInt32 = 9
        let override = FocusOverlayStyle(
            opacity: 0.61,
            tint: .ember,
            animationDuration: 0.27,
            colorTreatment: .dark,
            blurMaterial: .menu,
            blurRadius: 18
        )
        store?.updateStyle(override, forDisplayID: displayID)
        store = nil

        let newStore = ProfileStore(userDefaults: userDefaults)
        XCTAssertEqual(newStore.style(forDisplayID: displayID).opacity, 0.61, accuracy: 0.001)
        XCTAssertEqual(newStore.style(forDisplayID: displayID).colorTreatment, .dark)
        XCTAssertEqual(newStore.style(forDisplayID: displayID).blurRadius, 18, accuracy: 0.001)
        XCTAssertEqual(newStore.style(forDisplayID: displayID).blurMaterial, .menu)
    }

    func testDisplayExclusionPersistsBetweenInstances() {
        let suite = "FocuslyTests.ProfileStoreExclusion"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)
        defer { userDefaults.removePersistentDomain(forName: suite) }

        var store: ProfileStore? = ProfileStore(userDefaults: userDefaults)
        let displayID: UInt32 = 27
        store?.setDisplay(displayID, excluded: true)
        XCTAssertEqual(store?.isDisplayExcluded(displayID), true)
        store = nil

        let restoredStore = ProfileStore(userDefaults: userDefaults)
        XCTAssertTrue(restoredStore.isDisplayExcluded(displayID))
    }

    func testRemovingInvalidDisplaysClearsExclusions() {
        let suite = "FocuslyTests.ProfileStoreExclusionCleanup"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let store = ProfileStore(userDefaults: userDefaults)
        let displayID: UInt32 = 81
        store.setDisplay(displayID, excluded: true)
        XCTAssertTrue(store.isDisplayExcluded(displayID))

        store.removeInvalidOverrides(validDisplayIDs: [])
        XCTAssertFalse(store.isDisplayExcluded(displayID))
    }
}
