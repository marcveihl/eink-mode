# E-Ink Mode beta: tester guide

Thanks for trying E-Ink Mode! This takes about **20 minutes**. Please don't read the README first. The point is to see whether the app explains itself.

**You need:** a Mac running macOS 13 Ventura or newer. An external monitor is a bonus.

**Safety net:** everything the app changes can be undone. If anything looks stuck, choose **Quit and Restore Display** from the ◐ menu. As a last resort, run this in Terminal:
`"/Applications/E-Ink Mode.app/Contents/MacOS/eink" off`

## 1. Install (≈2 min)

Open Terminal, paste, and press Return:

```sh
curl -fsSL https://github.com/marcveihl/eink-mode/releases/latest/download/install.sh | bash
```

*Note for yourself:* Was anything confusing? Did you find the ◐ icon without help?

## 2. First minute (≈3 min)

Follow the welcome window.
- Before turning anything on, could you tell **what would change**?
- Try **Preview Grayscale for 10 Seconds**. Did it switch back on its own?
- Leave the optional extras off, or try them. Your choice.

## 3. Daily use (≈5 min)

- Turn E-Ink Mode **on and off** from the menu, then with **⌘⇧E**.
- Choose **Color for 5 Minutes**. Watch the countdown in the menu, then choose **Resume grayscale** early. Try it again, and let it expire on its own.
- In **Settings → General**, turn on **Click the icon to switch**. Click ◐ a few times, then right-click it.

## 4. Schedule (≈2 min)

- Open **Schedule** in the menu and choose **Evening**. Does the menu's *Schedule · …* line tell you what will happen next?
- Turn E-Ink Mode on or off by hand. Is it clear what the schedule will do now?

## 5. Focus sessions (≈4 min)

- In **Settings → Focus**, set focus to **5 minutes**, breaks to **1 minute**, and **2 sessions** per round, so you can see a whole round quickly.
- Choose **Start Focus** in the menu. Watch the countdown in the menu bar. When the break starts, does color come back? When the break ends, does grayscale return?
- Open **Focus Stats…** after the round. Does it motivate you? What would you want to see there?
- Put your settings back (25 / 5 / 4) for real studying.

## 6. Trust (≈3 min)

- Turn E-Ink Mode on (with dimming or Dock hiding if you enabled them), then choose **Quit and Restore Display**. Is everything back to normal?
- Optional: turn it on, put your Mac to sleep, and wake it. Unplug an external monitor while it's on, then turn it off.

## Tell Marc

Please answer these in a message (a sentence each is plenty):

1. Could you install and turn it on **without help**? Where did you hesitate?
2. Before turning it on, did you understand **what would change**?
3. Did **Color for 5 minutes** do what you expected, and did grayscale come back?
4. When you turned it off or quit, was your desktop **exactly** as before? Note anything that wasn't: brightness, Dock, colors.
5. Would you use focus sessions for school? Were the stats motivating, and what's missing?
6. What would make you keep using it? What was annoying?
7. Your macOS version (Apple menu → About This Mac) and whether you used an external monitor.

If something went wrong, the version number helps: **Settings → General → Version**.

## Uninstall

Choose **Quit and Restore Display**, then drag **E-Ink Mode** from Applications to the Trash.
