# Human QA

## Scope

macOS MVP and the feature-note additions are included. Windows, custom palettes/dithering, app blocking, IDE themes, and other future PRD items remain outside this release, per the recommended implementation scope.

## Automated checks

`./scripts/test.sh` runs public core tests and real-process CLI integration using an isolated simulated OS. Coverage includes pre-existing grayscale, separate display brightness, idempotent activation, independent grayscale, settings persistence, absent capabilities, failures/rollback/retry, corrupt journals, restart recovery, schedule boundaries, DST, catch-up, overrides, and concurrent commands.

`./scripts/build.sh` compiles a release bundle and verifies its ad-hoc signature.

## On your Mac

1. Click the ◐ icon. Settings should be readable directly in the dropdown. The primary toggle stays first.
   - Enable **Click to flip**. Quick-click twice and verify mode toggles each time. Long press (half a second), right-click, and Control-click should open settings without toggling. Drag off the icon before releasing a quick press; it should do nothing. Relaunch and verify the preference persists; turn it off and confirm clicking opens settings again.
2. Enable E-Ink Mode. Verify with your eyes that colored content becomes grayscale; API readback alone does not prove pixels changed.
3. Turn Grayscale off while active. Confirm color returns while Dock/brightness settings stay active. Restore normal display and confirm the original state returns, including grayscale if it was already enabled before activation.
4. Adjust brightness on a supported display, toggle Dock hiding and reduced transparency. Restore and check their original values. Unsupported controls should be disabled and explained under System availability.
5. Press ⌘⇧E twice. Check the icon and display follow both toggles.
6. Set schedule times a few minutes ahead, enable it, and wait through both boundaries. Manually override within a scheduled period; polling must not undo your choice. Sleep across a boundary, wake, and check catch-up.
7. Enable Launch at login, approve in System Settings if macOS requests it, and test after your next login. Keep scheduling off to confirm launch itself does not activate the mode.
8. Quit while active; verify restoration. Relaunch with an unfinished session to exercise Restore/Resume. Reconnect disconnected monitors if restoration asks for them.
9. Change a setting with the CLI while the menu is open. It should appear within five seconds.

The schedule and launch-at-login are left off for the initial handoff. A real reboot, physical sleep, visible grayscale output, and external-monitor behavior require human QA.
