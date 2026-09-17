# E-Ink Mode

One click turns a Mac into a calm monochrome workstation. Click again and
everything goes back exactly as it was.

Grayscale, dimmed, Dock hidden — for late-night coding, writing and terminal
work. Think "iPhone grayscale mode, but a first-class focus mode for the desktop."

<p align="center">
  <img src="docs/img/icon-off.png" alt="Menu bar icon, mode off" height="34">
  &nbsp;&nbsp;→&nbsp;&nbsp;
  <img src="docs/img/icon-on.png" alt="Menu bar icon, mode on" height="34">
</p>

The menu bar icon is the whole interface: **◐ off**, **● on**. Left-click
toggles, right-click opens a menu.

## Status

Working prototype. It does what it says on one Mac (macOS 15.7, Apple Silicon)
and has not been tested anywhere else. It is not signed or notarised.

## Install

```sh
git clone <this repo> && cd eink-mode
./build.sh
open EinkBar.app
```

Requires the Xcode command line tools for `swiftc`. To keep it running across
reboots, add `EinkBar.app` to System Settings → General → Login Items.

## Use

| | |
|---|---|
| Left-click the icon | toggle |
| Right-click the icon | menu — enable/restore, edit config, quit |
| `./eink on` / `off` / `toggle` | same thing from the shell |
| `./eink status` | what is active and what will be restored |

The CLI and the menu bar share one state file, so they never disagree. Toggling
from the terminal updates the icon within ~2s.

### Config

`~/.config/eink/config`, sourced as shell:

```sh
EINK_BRIGHTNESS=0.35   # 0.0-1.0, or empty to leave brightness alone
EINK_HIDE_DOCK=yes
```

## What it changes

| Setting | Mechanism | Restored |
|---|---|---|
| Grayscale | `UAGrayscaleSetEnabled` (UniversalAccess) | yes |
| Brightness | `DisplayServicesSetBrightness` | yes, to the exact prior value |
| Dock autohide | `com.apple.dock autohide` | yes |

Everything is captured **before** it is changed and restored from that capture,
so a setting you already had on stays on after a round trip. If you were already
running grayscale, exiting E-Ink Mode leaves it enabled.

Colour temperature is deliberately not managed — f.lux and Night Shift own that,
and both stack with grayscale rather than fighting it.

## If you get stuck in grey

Grayscale persists across reboot, so if something wedges, it will still be grey
when you come back. Any of these clears it:

```sh
./einkctl gray off
./eink off
```

Or System Settings → Accessibility → Display → Color Filters.

Quitting the app turns the mode off first, so you can't quit your way into a
grey screen with no UI left to fix it.

## Notes for anyone building something similar

**`CGDisplayForceToGray` is a no-op on macOS 15 / Apple Silicon.** It stores a
flag that `CGDisplayUsesForceToGray` reads straight back, so it round-trips
perfectly in tests while changing nothing on screen. This project was built on it
first and every automated check passed against a display that was still in full
colour. Verify with your eyes.

**`UAWhiteOnBlackSetEnabled` is similarly dead.** The working invert symbol is
`UAInvertColorsUserInitiatedSetEnabled`, found by enumerating the framework's
exports with `dyld_info -exports` rather than guessing names.

**`defaults` cannot write `com.apple.universalaccess`** (TCC), and SIP blocks
`launchctl kickstart` of `universalaccessd`. The UA* APIs go through the daemon
with an entitlement `defaults` lacks. `defaults read` also lags the API by a
second or two, so it is not a reliable way to check current state.

**Screenshots cannot capture the grayscale filter.** `screencapture` grabs the
pre-filter framebuffer — a capture taken during E-Ink Mode is pixel-identical to
one taken outside it. That is why there are no before/after display shots in this
README: an honest one is not possible, and a post-processed one would be a
drawing, not a screenshot.

## Not built

Smart Invert is tabled. It works (`UAInvertColorsUserInitiatedSetEnabled`), but
it and grayscale want opposite things: Smart Invert exists to spare images so
photos stay usable, grayscale exists to flatten everything. Stack them and
grayscale wins on images, making the exemption invisible. They are two modes, not
two features to combine.

Also not built: global hotkey, Do Not Disturb (macOS 15 no longer exposes prior
Focus state without Full Disk Access), app blocking, scheduling, multi-monitor
config, palette quantization, dithering, Windows.

## Background

The original product spec is in [docs/PRD.md](docs/PRD.md) — product vision,
prioritised requirements and the prototype milestones this repo is step one of.
Worth reading §27 and §29: the open question was never whether this could be
built, but whether monochrome-on-demand actually changes how you work.

## License

MIT
