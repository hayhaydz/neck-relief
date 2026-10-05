# Neck Relief

A menu-bar app for a two-monitor ergonomic workflow: move the focused window to your
other display and back, with one hotkey, so you never type with your neck turned.

## The loop it enables

1. Glance at Slack/Asana on the secondary display (fine for <20s).
2. Need to reply? Hit `⌘⌥→` — the window glides to your **primary, at the same
   position it had on the other monitor, same size, on top**, with keyboard focus.
3. Type with a straight neck.
4. Hit `⌘⌥→` again — from anywhere — the window glides back to its **exact remembered
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

- **Placement (round 3):** same position, other monitor — the window's offset from
  its display's origin is preserved exactly (size unchanged, proportional downscale
  only when it can't fit), always clamped inside the visible area. Deterministic:
  repeated flips land pixel-identical. (Cursor-relative placement was removed —
  landings depended on where the mouse happened to sit.)
- **Animation & reliability:** moves glide ~200 ms with ease-in-out easing (instant
  when Reduce Motion is on). Landings are *verified* — the frame is read back and
  re-asserted while the app drifts it (Electron…); a stubborn app is reported via
  the menu bar. Rapid presses cancel the in-flight glide and re-target from
  wherever the window is.
- **Focus:** follow-the-window via the Accessibility API (plain `activate()` silently
  no-ops from background apps on macOS 14+), applied on arrival. Sending a window
  home restores focus to the window it had covered on arrival.
- **Sticky toggle:** one window is "away" at a time. Pressing the hotkey while working
  (focused elsewhere) flips the away window home; clicking a *different* window on the
  away display and pressing the hotkey starts a new away-window instead.
- **Fullscreen:** never touches your Spaces. If the landing display's active Space is
  fullscreen, the window is moved **in the background** — it parks on that display's
  desktop Space, the fullscreen window and your focus stay untouched; reach it later
  manually (`⌃→` or exit fullscreen). A fullscreen *focused* window exits fullscreen
  first, then moves as a normal window (sending it home never re-fullscreens it).
- **Permissions:** Accessibility only. No screen recording, no notifications.

## Develop

```sh
swift build     # debug build
swift test      # placement/geometry unit tests
make install    # real testing needs the .app bundle (AX trust is bundle-scoped)
```

Design doc: `.docs/plans/2026-10-02-neck-relief-mvp.md`
