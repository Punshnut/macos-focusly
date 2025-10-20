import AppKit
import Carbon

/// Describes a user defined shortcut that can be registered with the Carbon hot key API.
/// Caches Carbon compatible modifier bits to avoid recomputing them during hot key registration.
struct HotkeyShortcut: Codable, Equatable {
    // MARK: - Stored Properties

    /// Hardware level key code as reported by `NSEvent`.
    var keyCode: UInt32
    /// AppKit modifier flags that define the shortcut, kept normalized for consistency.
    var modifiers: NSEvent.ModifierFlags {
        didSet {
            let normalized = HotkeyShortcut.normalize(modifiers)
            if normalized != modifiers {
                modifiers = normalized
                return
            }
            cachedCarbonModifiers = HotkeyShortcut.carbonModifiers(for: normalized)
        }
    }

    /// Cached Carbon modifier bitmask used when registering the shortcut with the legacy API.
    private var cachedCarbonModifiers: UInt32

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    // MARK: - Lifecycle

    /// Creates a new shortcut definition with the supplied key code and modifiers.
    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        let normalized = HotkeyShortcut.normalize(modifiers)
        self.modifiers = normalized
        self.cachedCarbonModifiers = HotkeyShortcut.carbonModifiers(for: normalized)
    }

    // MARK: - Codable

    /// Decodes the struct while keeping Carbon modifier bits in sync.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let raw = try container.decode(UInt.self, forKey: .modifiers)
        let decodedModifiers = NSEvent.ModifierFlags(rawValue: raw)
        let normalized = HotkeyShortcut.normalize(decodedModifiers)
        modifiers = normalized
        cachedCarbonModifiers = HotkeyShortcut.carbonModifiers(for: normalized)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }

    // MARK: - Carbon Bridge

    /// Cached Carbon compatible modifier mask.
    var carbonModifiers: UInt32 {
        cachedCarbonModifiers
    }
}

private extension HotkeyShortcut {
    private static let carbonModifierMap: [(modifier: NSEvent.ModifierFlags, mask: UInt32)] = [
        (.command, UInt32(cmdKey)),
        (.option, UInt32(optionKey)),
        (.control, UInt32(controlKey)),
        (.shift, UInt32(shiftKey))
    ]

    /// Filters out device specific bits so the shortcut behaves consistently on macOS 26.
    /// Normalizing in one place guarantees the cached Carbon modifiers remain valid.
    static func normalize(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask)
    }

    /// Maps AppKit modifier flags to the Carbon bit mask used by the hot key APIs.
    static func carbonModifiers(for modifiers: NSEvent.ModifierFlags) -> UInt32 {
        carbonModifierMap.reduce(into: UInt32(0)) { result, mapping in
            if modifiers.contains(mapping.modifier) {
                result |= mapping.mask
            }
        }
    }
}
