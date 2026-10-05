import AppKit
import CoreGraphics

/// One parsed row of the CG on-screen window list. `bounds` are in raw CG
/// coordinates — convert through the coordinate system before comparing with
/// AX frames.
struct CGWindowEntry {
    let id: CGWindowID?
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect
}

/// Fetches and parses the on-screen window list. One call replaces the
/// layer/pid/policy/bounds dictionary guard cascade that used to be duplicated
/// at every call site.
enum CGWindowList {

    /// Front-to-back snapshot (z-order preserved) of on-screen windows,
    /// desktop elements excluded. Rows that can't be parsed are skipped.
    static func onScreen() -> [CGWindowEntry] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return CGWindowEntry(id: (entry[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
                                 ownerPID: owner,
                                 layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                                 bounds: bounds)
        }
    }
}

extension [CGWindowEntry] {

    /// Layer-0 windows — normal document windows; panels, menus and overlays
    /// live on other layers.
    var layerZero: [CGWindowEntry] {
        filter { $0.layer == 0 }
    }

    /// Windows of real, user-facing apps; system processes, helpers and this
    /// app itself excluded.
    func fromRegularApps(_ apps: AppInfoCache) -> [CGWindowEntry] {
        filter { $0.ownerPID != getpid() && apps.isRegularApp($0.ownerPID) }
    }

    /// Windows big enough to be real content — filters stray floating
    /// mini-windows.
    var contentSized: [CGWindowEntry] {
        filter { $0.bounds.width >= 300 && $0.bounds.height >= 200 }
    }
}
