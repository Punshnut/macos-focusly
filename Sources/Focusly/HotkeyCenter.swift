import AppKit
import Carbon

/// Manages a single global keyboard shortcut using Carbon hotkey APIs.
@MainActor
final class HotkeyCenter {
    var onActivation: (() -> Void)?

    private var shortcut: HotkeyShortcut? {
        didSet { refreshRegistration() }
    }

    private var enabled = false {
        didSet { refreshRegistration() }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        installHandler()
    }

    @MainActor
    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Registers a new shortcut definition; pass nil to clear the binding.
    func updateShortcut(_ shortcut: HotkeyShortcut?) {
        self.shortcut = shortcut
    }

    /// Enables or disables the global hotkey without forgetting the shortcut.
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    /// Returns the currently registered shortcut, if any.
    func currentShortcut() -> HotkeyShortcut? {
        shortcut
    }

    /// Installs the Carbon event handler used to receive hotkey callbacks.
    private func installHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, userData in
            guard
                let userData,
                let eventRef
            else { return OSStatus(eventNotHandledErr) }

            let instance = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            instance.handle(event: eventRef)
            return noErr
        }, 1, &eventSpec, pointer, &handlerRef)
    }

    /// Updates the registered hotkey whenever the shortcut or enabled state changes.
    private func refreshRegistration() {
        unregister()
        guard enabled, let shortcut else { return }

        // Register the single global hotkey each time modifiers or enabled state changes.
        let hotKeyID = EventHotKeyID(signature: fourCharCode("FCS1"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            hotKeyRef = nil
        }
    }

    /// Unregisters the previously registered hotkey, if one exists.
    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// Handles carbon callbacks, forwarding matched hotkey presses to the consumer.
    private func handle(event: EventRef) {
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard hotKeyID.id == 1 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onActivation?()
        }
    }
}

/// Helper that encodes a string into the four-character code format required by Carbon.
private func fourCharCode(_ string: String) -> OSType {
    var value: OSType = 0
    for character in string.utf16 {
        value = (value << 8) + OSType(character)
    }
    return value
}
