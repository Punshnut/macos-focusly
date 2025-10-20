import AppKit
import Carbon

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

    func updateShortcut(_ shortcut: HotkeyShortcut?) {
        self.shortcut = shortcut
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    func currentShortcut() -> HotkeyShortcut? {
        shortcut
    }

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

    private func refreshRegistration() {
        unregister()
        guard enabled, let shortcut else { return }

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

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func handle(event: EventRef) {
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard hotKeyID.id == 1 else { return }
        onActivation?()
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var value: OSType = 0
    for character in string.utf16 {
        value = (value << 8) + OSType(character)
    }
    return value
}
