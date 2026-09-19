# Proposed roadmap

These are recommendations, not committed release dates. Reviewed against `0.10.0-beta.1` on GitHub.

## What is already working toward the product goal

- **Onboarding, a timed preview, and grayscale-only defaults** make the first activation less surprising.
- **Click-to-flip, temporary color, and schedule status** make everyday switching easier.
- **Installation handling, version visibility, and in-app updates** address the earlier confusion between app copies.
- **Focus sessions with color breaks** give users a repeatable study workflow. Keep ordinary grayscale use equally accessible.
- **Local goals and stats** provide feedback without an account. Their labels should distinguish elapsed timer time from actual attention.
- **Wildcat icons** add personality. Further cosmetic variants should wait behind reliability and usability work.

This is a review of the documented features and implementation, not a new round of device or usability testing.

## Priorities

| Priority | Improvement | Acceptance criteria |
|---|---|---|
| **P0** | Trusted installation and updates | Publish Developer ID-signed, notarized downloads. Verify the expected publisher when updating, beyond bundle ID, version, and signature validity. Confirm installation and upgrade on a clean Mac without removing quarantine. |
| **P0** | Focus pause and sleep behavior | Add Pause/Resume without losing the round. Define what happens on sleep and lock, and avoid silently crediting unattended sessions as work. Explain any catch-up choice on return. Test interactions with temporary color and schedules. |
| **P0** | Honest, controllable history | Explain what counts as a session and streak. Add export and reset with confirmation. Preserve lifetime totals separately or relabel “all time” to reflect retained history. Changing today's goal should not silently redefine past achievements. |
| **P1** | Choose a simple or study-oriented menu | Let users hide focus stats, streak nudges, and countdowns independently. Keep the mode toggle and temporary color prominent in both layouts. |
| **P1** | More flexible temporary color | Offer a few durations and an Extend action. Show when grayscale returns, including when a focus break or schedule change takes precedence. |
| **P1** | Better focus-round controls | Add a quick choice of one session or a saved round, plus an optional longer break between rounds. Preserve existing timing when preferences change mid-round. |
| **P2** | Color exceptions for chosen apps | Restore color while a selected app is foregrounded. Explain that this is a whole-display change, and define precedence with manual color, focus breaks, and scheduling. |
| **P2** | Custom shortcuts and automation | Add a shortcut recorder with conflict feedback and accessible actions for temporary color and focus controls. Keep menu alternatives available. |

## Why these come first

The updater currently checks the bundle identifier, version, and code-signature validity, but does not pin an expected signing identity (`Sources/EinkBar/Updater.swift`). The installer removes quarantine (`scripts/install.sh`). A straightforward, trusted download remains a release priority even though update convenience is now implemented.

Focus advances through elapsed phase boundaries and credits completed phases after sleep (`Sources/EinkCore/Controller.swift`). That is valid timer behavior, but it should be an explicit product decision before presenting the totals as study time.

History currently retains up to 800 recorded days, and “days goal met” uses the current goal for past records (`Sources/EinkCore/Focus.swift`). Clarify those semantics before adding more motivational statistics.

## Suggested sequence

1. **Trust and accuracy:** signing, update verification, focus pause/sleep semantics, and history labels/controls.
2. **Daily usability:** optional study UI, flexible color breaks, and quicker focus starts.
3. **Validate before expanding:** ask 10–15 outside testers to use the app for two weeks. Observe installation, starting/stopping a round, interrupting it, and restoring the display. Use interviews or voluntary feedback; no analytics service is required.
4. **Add integrations when requested repeatedly:** app exceptions and custom shortcuts, then reassess broader scope.

Defer Windows, cloud accounts, leaderboards, app blocking, and more themes until users return regularly and the core experience is dependable.
