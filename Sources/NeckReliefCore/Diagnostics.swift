import AppKit
import CoreGraphics

/// Human-readable dump of everything the toggle sees. Copied to the clipboard
/// by the menu item; the fastest way to answer "why wasn't window X detected".
@MainActor
final class Diagnostics {

    private let displayManager: DisplayManager
    private let coordinates: CoordinateSystem
    private let discovery: WindowDiscovery

    init(displayManager: DisplayManager, coordinates: CoordinateSystem, discovery: WindowDiscovery) {
        self.displayManager = displayManager
        self.coordinates = coordinates
        self.discovery = discovery
    }

    func dump(memory: WindowMemory?) -> String {
        var lines: [String] = []
        lines.append("== Neck Relief diagnostics — \(Date()) ==")
        lines.append("CG→AX coordinates: \(coordinates.probeStateDescription)")

        let displays = displayManager.currentDisplays()
        lines.append("Displays (\(displays.count)):")
        for d in displays {
            let fullscreen = FullscreenGuard.spaceHasFullscreenWindow(on: d) ? " [fullscreen Space]" : ""
            lines.append("  \(d.isPrimary ? "primary" : "secondary"): \(d.name) id=\(d.displayID) frame=\(Format.rect(d.frame)) visible=\(Format.rect(d.visibleFrame))\(fullscreen)")
        }

        if let mem = memory {
            lines.append("Memory: away=\(Format.appName(mem.pid)) pid=\(mem.pid) cg=\(mem.cgWindowID.map(String.init) ?? "nil")")
            lines.append("  origin=\(Format.rect(mem.originFrame)) onDisplay=\(mem.originDisplayID) arrivedInBackground=\(mem.arrivedInBackground)")
            if let r = mem.revealed {
                lines.append("  revealed=\(Format.appName(r.pid)) pid=\(r.pid) frame=\(Format.rect(r.frame))")
            } else {
                lines.append("  revealed=nil")
            }
        } else {
            lines.append("Memory: none")
        }

        if let focused = discovery.focusedWindow() {
            lines.append("Focused (AX): \(Format.appName(focused.pid)) pid=\(focused.pid) frame=\(Format.rect(focused.frame)) cg=\(focused.cgWindowID.map(String.init) ?? "nil") minimized=\(focused.isMinimized)")
        } else {
            lines.append("Focused (AX): none")
        }

        let apps = AppInfoCache()
        let primaryFrame = displays.first?.frame ?? .zero
        lines.append("CG windows (on-screen, layer 0, ≥300x200, regular apps):")
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps).contentSized {
            let id = entry.id.map(String.init) ?? "?"
            let frame = coordinates.appKitRect(fromCG: entry.bounds, primaryFrame: primaryFrame)
            lines.append("  cg=\(id) \(apps.name(entry.ownerPID)) pid=\(entry.ownerPID) frame=\(Format.rect(frame))")
        }

        lines.append("AX windows per app:")
        var seen = Set<pid_t>()
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps) {
            guard !seen.contains(entry.ownerPID) else { continue }
            seen.insert(entry.ownerPID)
            let windows = discovery.windows(of: entry.ownerPID)
            guard !windows.isEmpty else { continue }
            lines.append("  \(apps.name(entry.ownerPID)) pid=\(entry.ownerPID):")
            for w in windows {
                lines.append("    frame=\(Format.rect(w.frame)) minimized=\(w.isMinimized) cg=\(w.cgWindowID.map(String.init) ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
