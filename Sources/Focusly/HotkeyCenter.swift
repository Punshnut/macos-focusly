import AppKit
import Carbon

/// Manages a single global keyboard shortcut using Carbon hotkey APIs.
@MainActor
final class HotkeyCenter {
    var onActivation: (() -> Void)?

    /// Last requested shortcut definition used to manage Carbon registration.
    private var registeredShortcut: HotkeyShortcut? {
        didSet { refreshRegistration() }
    }

    /// Controls whether the registered shortcut should currently be active.
    private var isEnabled = false {
        didSet { refreshRegistration() }
    }

    /// Carbon hotkey token returned during registration.
    private var registeredHotKeyReference: EventHotKeyRef?
    /// Carbon event handler token allowing teardown during deinitialization.
    private var hotKeyHandlerReference: EventHandlerRef?

    init() {
        installHandler()
    }

    @MainActor
    deinit {
        unregister()
        if let hotKeyHandlerReference {
            RemoveEventHandler(hotKeyHandlerReference)
        }
    }

    /// Registers a new shortcut definition; pass nil to clear the binding.
    func updateShortcut(_ shortcut: HotkeyShortcut?) {
        self.registeredShortcut = shortcut
    }

    /// Enables or disables the global hotkey without forgetting the shortcut.
    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
    }

    /// Returns the currently registered shortcut, if any.
    func currentShortcut() -> HotkeyShortcut? {
        registeredShortcut
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
    private func refreshRegistration() {
        unregister()
        guard isEnabled, let registeredShortcut else { return }

        // Register the single global hotkey each time modifiers or enabled state changes.
        let hotKeyIdentifier = EventHotKeyID(signature: fourCharCode("FCS1"), id: 1)
        let registrationStatus = RegisterEventHotKey(
            UInt32(registeredShortcut.keyCode),
            registeredShortcut.carbonModifiers,
            hotKeyIdentifier,
            GetEventDispatcherTarget(),
            0,
            &registeredHotKeyReference
        )
        if registrationStatus != noErr {
            registeredHotKeyReference = nil
        }
    }

    /// Unregisters the previously registered hotkey, if one exists.
    private func unregister() {
        if let registeredHotKeyReference {
            UnregisterEventHotKey(registeredHotKeyReference)
            self.registeredHotKeyReference = nil
        }
    }

    /// Handles carbon callbacks, forwarding matched hotkey presses to the consumer.
    private func handle(event: EventRef) {
        var receivedHotKeyIdentifier = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedHotKeyIdentifier)
        guard receivedHotKeyIdentifier.id == 1 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onActivation?()
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
