# E-Ink Mode beta: tester guide

Thanks for trying [E-Ink Mode 0.10.0-beta.4](https://github.com/marcveihl/eink-mode/releases/tag/v0.10.0-beta.4)! Allow about **30 minutes**. Please don't read the README first. The point is to see whether the app explains itself.

**You need:** a Mac running macOS 13 Ventura or newer. An external monitor is a bonus.

**Safety net:** everything the app changes can be undone. If anything looks stuck, choose **Quit and Restore Display** from the E-Ink Mode menu (the ○ / ● icon in the menu bar). As a last resort, run this in Terminal:
`"/Applications/E-Ink Mode.app/Contents/MacOS/eink" off`

## 1. Install (≈2 min)

Open Terminal, paste, and press Return:

```sh
curl -fsSL https://github.com/marcveihl/eink-mode/releases/latest/download/install.sh | bash
```

This beta is not Developer ID signed or notarized. If macOS blocks it, attempt to open it, then choose **System Settings → Privacy & Security → Open Anyway**. Updates use the installer or ZIP download while signing is deferred.

*Note for yourself:* Was anything confusing? Did you find the ○ icon without help?

## 2. First minute (≈3 min)

Follow the welcome window.
- Before turning anything on, could you tell **what would change**?
- Try **Preview Grayscale for 10 Seconds**. Did it switch back on its own?
- Leave the optional extras off, or try them. Your choice.

## 3. Daily use (≈5 min)

- Turn E-Ink Mode **on and off** from the menu, then with **⌘⇧E**.
- Choose **Color for 5 Minutes**. Watch the countdown in the menu, then choose **Resume grayscale** early. Try it again, and let it expire on its own.
- Choose **Keep Display Awake** and leave your Mac alone for longer than it usually takes to sleep the screen. Did it stay on? Switch it off again.
- In **Settings → General → Behavior**, turn on **Click icon to toggle E-Ink Mode**. Click the icon a few times, then right-click it or hold for about a second. Leave **Appearance → Grayscale** on for normal grayscale switching.
- Does General fit comfortably? Expand **Tips and details** and try scrolling. Optionally enable **Hold to show color** and check that releasing the shortcut brings grayscale back.

## 4. Schedule (≈2 min)

- Open **Schedule** in the menu and choose **Evening**. Does the menu's *Schedule · …* line tell you what will happen next?
- Turn E-Ink Mode on or off by hand. Is it clear what the schedule will do now?

## 5. Focus sessions (≈12 min)

- In **Settings → Focus**, set focus to **5 minutes**, breaks to **1 minute**, and **2 sessions** per round, so you can see a whole round quickly.
- Leave **Use grayscale during focus** off (the default), turn E-Ink Mode off, then choose **Start Focus**. Does the countdown start without changing your display? Try Pause/Resume, then toggle E-Ink Mode on and off. Does the same timer keep running? Stop this round.
- Enable **Use grayscale during focus** and start a new round. When the break starts, does color come back? When the break ends, does grayscale return? Optionally try **Skip Break**.
- Open **Focus Stats…** after the round. Does it motivate you? What would you want to see there?
- Put your settings back (25 / 5 / 4) for real studying, and choose whether you want grayscale during future rounds.

## 6. Trust (≈3 min)

- Turn E-Ink Mode on (with dimming or Dock hiding if you enabled them), then choose **Quit and Restore Display**. Is everything back to normal?
- Optional: turn it on, put your Mac to sleep, and wake it. Unplug an external monitor while it's on, then turn it off.

## Tell Marc

Please answer these in a message (a sentence each is plenty):

1. Could you install and turn it on **without help**? Where did you hesitate?
2. Before turning it on, did you understand **what would change**?
3. Did **Color for 5 minutes** do what you expected, and did grayscale come back?
4. When you turned it off or quit, was your desktop **exactly** as before? Note anything that wasn't: brightness, Dock, colors.
5. Did timer-only focus and optional grayscale behave as expected? Would you use focus sessions for school? Were the stats motivating, and what's missing?
6. What would make you keep using it? What was annoying?
7. Your macOS version (Apple menu → About This Mac) and whether you used an external monitor.

If something went wrong, the version number helps: **Settings → General → Version**.

## Uninstall

Choose **Quit and Restore Display**, then drag **E-Ink Mode** from Applications to the Trash.
