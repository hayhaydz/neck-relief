import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "hotkey")

/// Global hotkey via Carbon — no extra permissions needed, and it's what the classic
/// window managers (Magnet et al.) use.
///
/// Single binding: ⌘⌥→. One key, one verb — the toggle. Press it to bring the focused
/// window over, press it again (from anywhere) to send it home.
final class HotKeyManager {

    var onHotKey: ((Direction) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let hotKeySignature = OSType(0x6E_72_6B_6C) // "nrkl"
    private static let toggleID: UInt32 = 2

    /// Installs the ⌘⌥→ binding. Returns false when registration fails — another
    /// app already owning the combination would otherwise leave this one silently
    /// deaf.
    @discardableResult
    func install() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onHotKey?(.right)
            }
            return noErr
        }

        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                callback,
                                                1,
                                                &spec,
                                                Unmanaged.passUnretained(self).toOpaque(),
                                                &handlerRef)
        guard installStatus == noErr else {
            log.error("InstallEventHandler failed: \(installStatus, privacy: .public)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.toggleID)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_RightArrow),
                                                 UInt32(cmdKey | optionKey),
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)
        guard registerStatus == noErr else {
            log.error("RegisterEventHotKey ⌘⌥→ failed (\(registerStatus, privacy: .public)) — combination taken by another app?")
            return false
        }
        return true
    }
}
