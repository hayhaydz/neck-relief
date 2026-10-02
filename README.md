# Neck Relief

A menu-bar app for a two-monitor ergonomic workflow: move the focused window to your
other display and back, with one hotkey, so you never type with your neck turned.

## The loop it enables

1. Glance at Slack/Asana on the secondary display (fine for <20s).
2. Need to reply? Hit `⌘⌥→` — the window lands **on your primary, centered on your
   mouse, same size, on top**, with keyboard focus.
3. Type with a straight neck.
4. Hit `⌘⌥→` again — from anywhere — the window returns to its **exact remembered
   spot** on the secondary, and focus lands back on the window it had covered.

One key, one verb: the hotkey is a **chainable flip**. press → type in Slack →
press → type in your work app → press → Slack's back. Focus always follows.

## Install

```sh
make install   # builds release, wraps NeckRelief.app into ~/Applications
make open      # install + launch
```

On first launch, grant **Accessibility** (System Settings › Privacy & Security ›
Accessibility) when prompted. Enable **Launch at Login** from the menu-bar item.

## Behavior notes

- **Placement:** exact same size, centered on the mouse when the mouse is on the target
  display, otherwise same offset as it had on the source display; always kept inside the
  visible area.
- **Focus:** follow-the-window via the Accessibility API (plain `activate()` silently
  no-ops from background apps on macOS 14+). Sending a window home restores focus to
  the window it had covered on arrival.
- **Sticky toggle:** one window is "away" at a time. Pressing the hotkey while working
  (focused elsewhere) flips the away window home; clicking a *different* window on the
  away display and pressing the hotkey starts a new away-window instead.
- **Fullscreen:** macOS won't put a window above a native-fullscreen Space. If the
  landing display is fullscreen, Neck Relief switches that display to its desktop Space
  automatically (synthesized `⌃`-arrow) to reveal the window. If that fails, the
  menu-bar item shows a hint.
- **Permissions:** Accessibility only. No screen recording, no notifications.

## Develop

```sh
swift build     # debug build
swift test      # placement/geometry unit tests
make install    # real testing needs the .app bundle (AX trust is bundle-scoped)
```

Design doc: `.docs/plans/2026-10-02-neck-relief-mvp.md`
