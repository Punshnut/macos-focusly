import XCTest
@testable import Focusly

final class ProfileStoreTests: XCTestCase {
    func testSelectPresetClearsOverrides() {
        let defaults = UserDefaults(suiteName: "FocuslyTests.ProfileStore")!
        defaults.removePersistentDomain(forName: "FocuslyTests.ProfileStore")
        defer { defaults.removePersistentDomain(forName: "FocuslyTests.ProfileStore") }
        let store = ProfileStore(defaults: defaults)
        let displayID: UInt32 = 1
        let override = FocusOverlayStyle(opacity: 0.5, blurRadius: 20, tint: .neutral, animationDuration: 0.3)
        store.updateStyle(override, forDisplayID: displayID)
        XCTAssertEqual(store.style(forDisplayID: displayID).opacity, 0.5, accuracy: 0.001)

        let preset = PresetLibrary.presets[1]
        store.selectPreset(preset)
        XCTAssertEqual(store.style(forDisplayID: displayID).opacity, preset.style.opacity, accuracy: 0.001)
    }

    func testOverridesPersistBetweenInstances() {
        let defaults = UserDefaults(suiteName: "FocuslyTests.ProfileStorePersistence")!
        defaults.removePersistentDomain(forName: "FocuslyTests.ProfileStorePersistence")
        defer { defaults.removePersistentDomain(forName: "FocuslyTests.ProfileStorePersistence") }

        var store: ProfileStore? = ProfileStore(defaults: defaults)
        let displayID: UInt32 = 9
        let override = FocusOverlayStyle(opacity: 0.61, blurRadius: 42, tint: .ember, animationDuration: 0.27)
        store?.updateStyle(override, forDisplayID: displayID)
        store = nil

        let newStore = ProfileStore(defaults: defaults)
        XCTAssertEqual(newStore.style(forDisplayID: displayID).opacity, 0.61, accuracy: 0.001)
    }
}
