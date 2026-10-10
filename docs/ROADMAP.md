# Proposed roadmap

These are recommendations, not committed release dates. Reviewed against [0.10.0-beta.4](https://github.com/marcveihl/eink-mode/releases/tag/v0.10.0-beta.4).

## What is already working toward the product goal

- **Onboarding, a timed preview, and grayscale-only defaults** make the first activation less surprising.
- **Click-to-flip, temporary color, and schedule status** make everyday switching easier.
- **Installation handling, version visibility, and update checks** address the earlier confusion between app copies. Unsigned betas install manually; publisher verification is ready for signed releases.
- **Optional grayscale focus, pause/resume, and independent timers** support study rounds without requiring a display change. Manual display changes leave the timer running.
- **Local goals and stats** preserve historical goals and label retained totals. They describe elapsed timer activity, not measured attention.
- **Compact General settings, held color shortcuts, and Keep Display Awake** improve everyday controls.
- **A separate Windows beta** provides grayscale, temporary color, schedules, and display restoration; focus and updates remain Mac-only.
- **Wildcat icons** add personality. Further cosmetic variants should wait behind reliability and usability work.

This is a review of the documented features and implementation, not a new round of device or usability testing.

## Priorities

| Priority | Improvement | Acceptance criteria |
|---|---|---|
| **P0** | Trusted installation and updates | Configure Developer ID credentials and publish notarized downloads using the existing publisher checks. Confirm installation and upgrade on a clean Mac without removing quarantine. |
| **P0** | Automatic focus pause and sleep behavior | Define what happens on sleep and lock beyond the existing manual Pause/Resume controls. Explain catch-up on return and test interactions with temporary color and schedules. |
| **P0** | Controllable history | Add export and reset with confirmation. Decide whether to preserve lifetime totals beyond the 800-day retention limit. Keep saved daily goals and the existing retained-total labels. |
| **P1** | Choose a simple or study-oriented menu | Let users hide focus stats and streak nudges independently, alongside the existing countdown preference. Keep the mode toggle and temporary color prominent. |
| **P1** | More flexible temporary color | Offer a few durations and an Extend action. Show when grayscale returns, including when a focus break or schedule change takes precedence. |
| **P1** | Better focus-round controls | Add a quick menu choice of one session or a saved round, plus an optional longer break between rounds. Existing rounds already retain their timing when preferences change. |
| **P2** | Color exceptions for chosen apps | Restore color while a selected app is foregrounded. Explain that this is a whole-display change, and define precedence with manual color, focus breaks, and scheduling. |
| **P2** | Custom shortcuts and automation | Add a shortcut recorder with conflict feedback and accessible actions for temporary color and focus controls. Keep menu alternatives available. |

## Why these come first

The updater and signed installer already verify the expected Developer ID publisher, bundle identity, signature, and macOS acceptance. Neither removes quarantine. Beta.4 is ad hoc signed and unnotarized; its installer instead pins the exact archive checksum and version. Publishing a Gatekeeper-clean release still requires signing credentials and clean-Mac validation.

Focus advances through elapsed phase boundaries and credits completed phases after sleep (`Sources/EinkCore/Controller.swift`). That is valid timer behavior, but it should be an explicit product decision before presenting the totals as study time.

History retains up to 800 recorded days and saves each day's goal. Legacy days with unknown goals are excluded from historical goal attainment. Export, reset, and optional lifetime totals remain useful additions before more motivational statistics.

## Suggested sequence

1. **Trust and accuracy:** signed distribution, automatic sleep/lock semantics, and history controls.
2. **Daily usability:** optional study UI, flexible color breaks, and quicker focus starts.
3. **Validate before expanding:** ask 10–15 outside testers to use the app for two weeks. Observe installation, starting/stopping a round, interrupting it, and restoring the display. Use interviews or voluntary feedback; no analytics service is required.
4. **Add integrations when requested repeatedly:** app exceptions and custom shortcuts, then reassess broader scope.

Defer further Windows feature parity, cloud accounts, leaderboards, app blocking, and more themes until users return regularly and the core experience is dependable.
