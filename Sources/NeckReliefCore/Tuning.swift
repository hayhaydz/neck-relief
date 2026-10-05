import Foundation
import CoreGraphics

/// Hand-tuned thresholds and timings, all in one place.
enum Tuning {

    /// Windows smaller than this are treated as panels/strays — never the
    /// focused window, the revealed window, or a probe candidate.
    static let minContentWidth: CGFloat = 300
    static let minContentHeight: CGFloat = 200

    /// How close a CG window's center must sit to an AX frame for the two to
    /// count as the same window (CG ids are unreliable for Electron).
    static let cgMatchTolerance: CGFloat = 50

    /// Deadline for a fullscreen exit animation before moving anyway.
    static let fullscreenExitTimeout: TimeInterval = 1.5

    /// Poll interval while waiting for a fullscreen exit to settle.
    static let settlePollInterval: TimeInterval = 0.1

    /// Delay after a move before checking the window is actually on-screen.
    static let hiddenHintDelay: TimeInterval = 0.25

    /// How long menu-bar flash feedback stays up.
    static let flashDuration: TimeInterval = 2.5

    /// Poll interval while waiting for the Accessibility grant after the
    /// first-launch prompt.
    static let trustPollInterval: TimeInterval = 2
}
