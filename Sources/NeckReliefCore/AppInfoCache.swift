import AppKit

/// pid → NSRunningApplication lookups, cached per operation. These queries hit
/// the process database; re-issuing them inside loops (once per CG window-list
/// row per window, as the old code did) adds up on Electron-heavy setups.
final class AppInfoCache {

    private var apps: [pid_t: NSRunningApplication] = [:]
    private var bundleIDs: [pid_t: String?] = [:]

    func app(_ pid: pid_t) -> NSRunningApplication? {
        if let cached = apps[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        apps[pid] = app
        return app
    }

    func bundleID(_ pid: pid_t) -> String? {
        if let cached = bundleIDs[pid] { return cached }
        let id = app(pid)?.bundleIdentifier
        bundleIDs[pid] = id
        return id
    }

    func isRegularApp(_ pid: pid_t) -> Bool {
        app(pid)?.activationPolicy == .regular
    }

    /// Localized name for logs and menu-bar feedback ("pid:1234" fallback).
    func name(_ pid: pid_t) -> String {
        app(pid)?.localizedName ?? "pid:\(pid)"
    }
}
