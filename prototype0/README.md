# E-Ink Mode — Prototype 0

Validation prototype for `../0.E-Ink Mode.md`. Purpose is to answer one question:
**does monochrome-on-demand actually change how I work at night?** Not to be an app.

```
./build.sh
./eink on      # or: toggle / off / status
```

## What it touches

| Setting | Mechanism | Restored on exit |
|---|---|---|
| Grayscale | `UAGrayscaleSetEnabled` (UniversalAccess) | yes |
| Invert colours | `UAWhiteOnBlackSetEnabled` — off by default | yes |
| Brightness | `DisplayServicesSetBrightness` | yes, to the exact prior float |
| Dock autohide | `com.apple.dock autohide` | yes |

Colour temperature is **not** managed — f.lux owns that. f.lux works on gamma
ramps and grayscale works at the compositing level, so they stack rather than
fight. (Night Shift would also stack: Apple documents Grayscale as the one colour
filter Night Shift tolerates. Irrelevant if you're on f.lux.)

## Grayscale: the API that actually works

**`CGDisplayForceToGray` is a no-op on macOS 15 / Apple Silicon.** It stores a
flag that `CGDisplayUsesForceToGray` reads straight back, so it round-trips
perfectly in tests while changing nothing on screen. This prototype was built on
it first and every automated check passed against a display that was still in
full colour. Verify grayscale with your eyes; never with that pair.

`UAGrayscaleSetEnabled` / `UAGrayscaleIsEnabled` is what System Settings drives
and it does affect real pixels. Consequences:

- It **does** write `com.apple.universalaccess grayscale`, so it is the same
  switch as System Settings → Accessibility → Display → Color Filters → Grayscale.
- It therefore **persists across reboot**. PRD §24 crash recovery is *not* free:
  if the script dies between capture and restore, you stay grey. Escape hatch
  below.
- `defaults read` lags behind the API by a second or two (cfprefsd caching), so
  the pref is not a reliable way to check current state. `einkctl gray` is.
- If you had grayscale on *before* entering, it is still on after you exit —
  PRD §21's capture→modify→restore rather than enable→disable.

## If you get stuck in grey

Any of these, no rebuild needed:

```sh
./einkctl gray off          # fastest
./eink off                  # full restore
```

Or System Settings → Accessibility → Display → Color Filters, and switch it off.

## Smart vs Classic invert

`invert` is off by default. If you turn it on, whether you get Smart (leaves
images and video alone) or Classic follows the mode selected in System Settings →
Accessibility → Display → Invert colours. The toggle respects that choice; it
doesn't set it. Pick Smart there once, then use `EINK_INVERT=on`.

Worth trying grayscale alone first. Grayscale + Smart Invert is a much heavier
change and confounds the thing you're measuring.

## Config

`~/.config/eink/config`, sourced as shell:

```sh
EINK_BRIGHTNESS=0.35   # empty to leave brightness alone
EINK_INVERT=off
EINK_HIDE_DOCK=yes
```

## Hotkey

No global-hotkey daemon here — that's Prototype 1. For now, a Quick Action:

1. Automator → New → **Quick Action**
2. "Workflow receives" → **no input**, in **any application**
3. Add **Run Shell Script**, paste the absolute path:
   `/Users/marc/VibeCoding/eink/prototype0/eink toggle`
4. Save as `E-Ink Mode`
5. System Settings → Keyboard → Keyboard Shortcuts → Services → General →
   bind it to ⌘⇧E

Raycast/Alfred/skhd will also just run `eink toggle`.

## State

Captured state lives at `~/.local/state/eink/saved-state`. Its presence is what
"mode is active" means. If it's missing, `eink off` still forces colour back
rather than trusting the file.

## What this deliberately doesn't do

No menu-bar app, no Focus/DND (macOS 15 no longer exposes prior Focus state
without Full Disk Access — see the PRD discussion), no app blocking, no
scheduling, no palette quantization or dithering. Layer 1 only.

## The actual experiment

Run it for several late-night sessions, then answer PRD §27:

- Did the machine feel calmer?
- Did colour become less tempting?
- Was code still readable?
- **Did you reach to turn it on again without being prompted?**

That last one is the signal. If it's no, the menu-bar app in §26 is wasted work
no matter how good the dithering gets.
