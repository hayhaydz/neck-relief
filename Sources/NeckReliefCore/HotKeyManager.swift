import Carbon.HIToolbox

/// Global hotkey via Carbon — no extra permissions needed, and it's what the classic
/// window managers (Magnet et al.) use.
///
/// Single binding: ⌘⌥→. One key, one verb — the toggle. Press it to bring the focused
/// window over, press it again (from anywhere) to send it home.
final class HotKeyManager {

    var onHotKey: ((Direction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    private static let hotKeySignature = OSType(0x6E_72_6B_6C) // "nrkl"
    private static let toggleID: UInt32 = 2

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onHotKey?(.right)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &handlerRef)

        register(id: Self.toggleID, keyCode: UInt32(kVK_RightArrow))
    }

    private func register(id: UInt32, keyCode: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode,
                            UInt32(cmdKey | optionKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &ref)
        hotKeyRefs.append(ref)
    }
}
