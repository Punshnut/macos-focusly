import AppKit
import Carbon

/// Manages Focusly's global keyboard shortcuts using Carbon hotkey APIs.
@MainActor
final class HotkeyCenter {
    private struct Registration {
        var shortcut: HotkeyShortcut?
        var isEnabled: Bool = false
        var handler: (() -> Void)?
        var token: EventHotKeyRef?
    }

    private var registrations: [HotkeyAction: Registration] = [:]
    /// Carbon event handler token allowing teardown during deinitialization.
    private var hotKeyHandlerReference: EventHandlerRef?

    init() {
        installHandler()
    }

    @MainActor
    deinit {
        for action in HotkeyAction.allCases {
            unregister(action: action)
        }
        if let hotKeyHandlerReference {
            RemoveEventHandler(hotKeyHandlerReference)
        }
    }

    /// Assigns or updates the closure executed when the supplied action fires.
    func setHandler(_ handler: (() -> Void)?, for action: HotkeyAction) {
        var registration = registrations[action] ?? Registration()
        registration.handler = handler
        registrations[action] = registration
    }

    /// Registers a new shortcut definition for the supplied action; pass nil to clear the binding.
    func updateShortcut(_ shortcut: HotkeyShortcut?, for action: HotkeyAction) {
        var registration = registrations[action] ?? Registration()
        registration.shortcut = shortcut
        registrations[action] = registration
        refreshRegistration(for: action)
    }

    /// Enables or disables the global hotkey for the supplied action without forgetting the shortcut.
    func setShortcutEnabled(_ enabled: Bool, for action: HotkeyAction) {
        var registration = registrations[action] ?? Registration()
        registration.isEnabled = enabled
        registrations[action] = registration
        refreshRegistration(for: action)
    }

    /// Returns the currently registered shortcut for the supplied action, if any.
    func currentShortcut(for action: HotkeyAction) -> HotkeyShortcut? {
        registrations[action]?.shortcut
    }

    /// Installs the Carbon event handler used to receive hotkey callbacks.
    private func installHandler() {
        var keyboardEventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, userData in
            guard
                let userData,
                let eventRef
            else { return OSStatus(eventNotHandledErr) }

            let instance = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            instance.handle(event: eventRef)
            return noErr
        }, 1, &keyboardEventSpec, selfPointer, &hotKeyHandlerReference)
    }

    /// Updates the registered hotkey whenever the shortcut or enabled state changes.
    private func refreshRegistration(for action: HotkeyAction) {
        var registration = registrations[action] ?? Registration()
        if let token = registration.token {
            UnregisterEventHotKey(token)
            registration.token = nil
        }

        guard registration.isEnabled, let shortcut = registration.shortcut else {
            registrations[action] = registration
            return
        }

        var hotKeyReference: EventHotKeyRef?
        let hotKeyIdentifier = EventHotKeyID(signature: fourCharCode("FCSH"), id: UInt32(action.rawValue))
        let registrationStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyIdentifier,
            GetEventDispatcherTarget(),
            0,
            &hotKeyReference
        )
        if registrationStatus == noErr {
            registration.token = hotKeyReference
        } else {
            registration.token = nil
        }
        registrations[action] = registration
    }

    /// Unregisters the previously registered hotkey for a specific action, if one exists.
    private func unregister(action: HotkeyAction) {
        if let token = registrations[action]?.token {
            UnregisterEventHotKey(token)
            registrations[action]?.token = nil
        }
    }

    /// Handles carbon callbacks, forwarding matched hotkey presses to the consumer.
    private func handle(event: EventRef) {
        var receivedHotKeyIdentifier = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedHotKeyIdentifier)
        guard
            let action = HotkeyAction(rawValue: Int(receivedHotKeyIdentifier.id)),
            let handler = registrations[action]?.handler
        else { return }
        Task { @MainActor in
            handler()
        }
    }
}

/// Helper that encodes a string into the four-character code format required by Carbon.
private func fourCharCode(_ string: String) -> OSType {
    var encodedValue: OSType = 0
    for character in string.utf16 {
        encodedValue = (encodedValue << 8) + OSType(character)
    }
    return encodedValue
}
