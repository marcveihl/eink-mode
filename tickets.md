# Tickets: E-Ink Mode research roadmap to 1.0

Build the trust, everyday controls, and focus features in the final dated roadmap from [26.9.23 EInk Research Features](<26.9.23 EInk Research Features.md>), followed by tester validation and a 1.0 decision. Breakdown approved September 24, 2026.

Work the **frontier**: any ticket whose blockers are all done. Tickets are listed in dependency order; numbers are stable references, not a requirement to work sequentially. Work one ticket at a time with `/implement`, clearing context between tickets.

Implementation checkpoint (September 24, 2026): tickets 2 and 4 are implemented with passing automated coverage. Ticket 24 is implemented, including the subsequently requested Fn/Globe option, with hold/release confirmed by the user; broader physical-key/sleep/lock QA remains pending. Ticket 1's code and offline rejection checks are implemented, but credentials, accepted notarization, and clean-Mac install/upgrade validation remain pending. No ticket is marked fully closed below. The combined suite passes 89 Swift tests plus CLI and release guard checks.

The 0.11 trust gate is an intentional product dependency for Phase 2. Phase 3 features remain provisional until the January scope decision. Dates in the source are planning targets, not substitutes for acceptance evidence. Tester studies, credential setup, hardware QA, and release decisions require human participation; do not mark them complete from automated checks alone.

Preserve local-first storage, the durable display-restoration guarantee, and existing settings/history when upgrading. Feature tickets include relevant behavior tests, accessible controls, and user-facing documentation. Extend existing notarization hooks, shortcut presets, and captured round timing. Screen-sharing detection, tint profiles, per-monitor control, and store distribution are outside this approved breakdown, as are the source roadmap's deferred features.

## 1. Trusted installation and publisher-verified updates

**What to build:** Users can download, install, and upgrade an authentic E-Ink Mode release without Gatekeeper workarounds or quarantine removal.

**Blocked by:** None — can start immediately. Developer Program enrollment and Developer ID credentials are external prerequisites for signed-release validation.

- [ ] Configure Developer ID signing, hardened runtime, notarization, and stapling using the existing release hooks; document credential setup without committing secrets.
- [ ] Distribution builds fail clearly when required signing or notarization fails; the delivered archive contains the stapled app.
- [ ] In-app updates and the installer verify the expected Team ID in addition to signature validity, application identity, and applicable version checks; wrong-publisher artifacts are rejected without replacing the installed app.
- [ ] Remove quarantine stripping and update installation/release guidance.
- [ ] Verify browser-download installation and a subsequent upgrade on a clean Mac without removing quarantine or using Open Anyway, including display restoration during update.

## 2. Pause and resume a focus round

**What to build:** Users can interrupt a focus round and resume the same phase and session without receiving credit for paused time.

**Blocked by:** None — can start immediately.

- [ ] Expose Pause/Resume through the menu and shared focus controls, with clear paused status and preserved remaining time, phase, and round position.
- [ ] Paused time never increases focused minutes or completed-session counts; stopping while paused credits only elapsed active focus time.
- [ ] Document and verify display behavior while paused and interactions with temporary color, schedule boundaries, stop, quit, and recovery.
- [ ] Existing persisted state remains readable, and repeated pause/resume calls cannot duplicate credit or lose progress.

## 3. Pause automatically on sleep and lock

**What to build:** A sleeping or locked Mac cannot silently finish focus sessions; users return to a paused round with an explicit resume choice.

**Blocked by:** Pause and resume a focus round.

- [ ] Sleep, lid closure that causes sleep, and screen locking pause the active round, including when the current phase is a break.
- [ ] Exclude the unattended gap by default; waking or unlocking does not automatically credit the gap or advance through missed phases.
- [ ] Show a clear resume choice on return and retain the original phase and remaining active time.
- [ ] Verify repeated or overlapping sleep/lock notifications, temporary color, schedules, and recovery without duplicate credit; include real-Mac sleep and lock checks.

## 4. Preserve historical goals and explain statistics

**What to build:** Users can understand their statistics and change today's goal without rewriting past achievements.

**Blocked by:** None — can start immediately.

- [ ] Persist the applicable daily goal with each recorded day and use it when calculating historical goal attainment.
- [ ] Explain completed sessions, stopped-session minutes, rounds, and streaks in the UI and guide; describe timer activity without claiming measured attention.
- [ ] Relabel retained-history totals to reflect the limit of 800 recorded days rather than claiming all-time coverage.
- [ ] Define and document a deterministic migration for legacy days whose original goals are unknown; do not present inferred goals as known historical facts.
- [ ] Verify goal changes, day boundaries, legacy records, and retention pruning leave past results consistent.

## 5. Export and reset focus history

**What to build:** Users can take their focus history with them or deliberately clear it from the app.

**Blocked by:** Preserve historical goals and explain statistics.

- [ ] Offer CSV and JSON export with documented fields, daily goals, and retained history matching the displayed statistics.
- [ ] Handle canceled exports and write failures without changing history.
- [ ] Require explicit confirmation before reset; refresh totals, streaks, charts, and nudges consistently afterward.
- [ ] Define and verify reset during an active or paused round so old credit cannot reappear unexpectedly and future activity is handled consistently.

## 6. Release 0.11 and pass the trust gate

**What to build:** Publish a trust beta that outside testers can install and use with reliable interruption handling and understandable history.

**Blocked by:** Trusted installation and publisher-verified updates; Pause automatically on sleep and lock; Export and reset focus history.

- [ ] Complete automated checks and real-Mac installation, upgrade, pause, sleep/lock, history, and display-restoration checks.
- [ ] Publish 0.11 beta with updated release notes and user guidance.
- [ ] Record the trust-gate evidence and decision; keep Phase 2 blocked if notarization is unresolved.

## 7. Run tester group 1 and summarize findings

**What to build:** Gather actionable evidence from the first outside cohort to guide the next scope decision.

**Blocked by:** Release 0.11 and pass the trust gate.

- [ ] Recruit 10–15 outside testers for two weeks of 0.11 use and record the tested version and participation window.
- [ ] Gather interviews or voluntary feedback about installation, focus use, interruptions, display restoration, and recurring unmet needs, without an analytics service.
- [ ] Summarize findings with supporting observations, severity, and priorities; distinguish observed problems from feature requests.
- [ ] Prepare recommendations for the January scope gate, including whether app exceptions or automation need more attention.

## 8. Restore color for selected foreground apps

**What to build:** Users choose applications that temporarily restore whole-screen color while foregrounded and automatically return to the appropriate display state afterward.

**Blocked by:** Release 0.11 and pass the trust gate.

- [ ] Provide an accessible app picker with persistent add/remove controls; explain that the change affects the whole screen, not just the selected window.
- [ ] Entering and leaving a selected foreground app updates color promptly without modifying the saved appearance profile or losing the restoration journal.
- [ ] Apply the roadmap priority of manual toggle over focus break over app exception over schedule, and explicitly define temporary-peek and active-focus interactions.
- [ ] Verify rapid app switching, unavailable or removed apps, pause/resume, schedule boundaries, manual off, and quit/recovery; the menu accurately explains effective display state.

## 9. Control E-Ink Mode through Shortcuts

**What to build:** Users can automate mode changes and focus sessions from native Shortcuts using the same behavior as the app's controls.

**Blocked by:** Release 0.11 and pass the trust gate.

- [ ] Expose Turn On, Turn Off, Color for N Minutes, Start Focus, Stop Focus, and Get Status actions.
- [ ] Validate inputs and report actionable errors; repeated invocations cannot start overlapping rounds or bypass recovery requirements.
- [ ] Verify actions against shared persisted state, including paused rounds and launch behavior, with compatibility handled for supported macOS versions.
- [ ] Document two runnable example Shortcuts and verify them on a real Mac.

## 10. Activate E-Ink Mode with a macOS Focus filter

**What to build:** Activating a chosen macOS Focus can enable grayscale and optionally start a focus round.

**Blocked by:** Control E-Ink Mode through Shortcuts.

- [ ] Let users configure grayscale activation and optional round start through the native Focus filter experience.
- [ ] Repeated activation does not duplicate a round or overwrite its timing.
- [ ] Define filter deactivation behavior and preserve manual choices made after activation; verify interaction with schedules and an already-running round.
- [ ] Verify activation/deactivation on a real Mac and document availability and setup.

## 11. Record a custom global shortcut

**What to build:** Users can choose a global toggle shortcut beyond the existing presets and understand when a combination cannot be registered.

**Blocked by:** Release 0.11 and pass the trust gate.

- [ ] Provide an accessible recorder, persisted custom choice, disable option, and a way to restore the default.
- [ ] Preserve existing preset selections during migration and show the active shortcut consistently in the menu and settings.
- [ ] Warn about invalid or unavailable combinations without claiming detection of every possible interception; a failed replacement leaves a usable control path.
- [ ] Verify recording, cancellation, registration failures, relaunch, and keyboard-only use; menu controls remain available.

## 12. Choose and extend temporary color

**What to build:** Users can take a short glance or longer color break and see when grayscale will actually return.

**Blocked by:** Restore color for selected foreground apps.

- [ ] Offer 1-, 5-, and 15-minute peeks plus Extend +5 Minutes and early return to grayscale.
- [ ] Show a return time and explain when a focus break, app exception, or schedule means grayscale will not return at peek expiry.
- [ ] Keep peek behavior consistent across app controls and automation without changing saved appearance settings.
- [ ] Verify expiry, repeated extension, paused focus, phase boundaries, manual off, and restoration without stale timers reactivating the mode.

## 13. Choose simple or study menus

**What to build:** Users can keep a compact switcher or show study features while retaining control of any running session.

**Blocked by:** Release 0.11 and pass the trust gate.

- [ ] Provide persistent Simple and Study presets with independent visibility settings for stats, nudges, and countdowns.
- [ ] Keep toggle, temporary color, schedule, and display restoration easy to reach in both layouts.
- [ ] Preserve access to pause/resume, stop, and other necessary active-session controls even when study information is hidden.
- [ ] Verify keyboard navigation, accessible labels, relaunch, and switching layouts during active and paused rounds.

## 24. Hold a key to peek in color

**What to build:** Users can hold a configurable shortcut to see color briefly, then release it to return to the display state required by their current mode, focus phase, app exception, and schedule.

**Blocked by:** None — can start immediately using the existing shortcut registration and timed-color controls.

**Scheduling:** Added and explicitly authorized for immediate implementation on September 24, 2026. The existing shortcut and temporary-color foundations are sufficient for this slice; full tickets 11 and 12 are not prerequisites. No release assignment yet. Stable ticket number retained.

- [ ] Provide an opt-in, configurable hold-to-peek key combination, defaulting to Control–Option–Command–C, with clear press-and-release instructions and conflict feedback; keep the normal toggle shortcut distinct.
- [ ] Show color only while held without changing saved settings, pausing focus, or replacing an existing timed peek; key repeat cannot create multiple peeks.
- [ ] On release, recompute the effective display state instead of blindly enabling grayscale. Preserve any remaining timed peek or active focus break; ensure future app exceptions use the same effective-state resolution.
- [ ] Handle interrupted key sequences, app deactivation, sleep/lock, shortcut changes, quit, and recovery so a missed key-up cannot leave an indefinite color override.
- [ ] Respect commitment-mode limits when that feature exists, including a documented rule for counting held peeks; retain display restoration and accessible menu alternatives.
- [ ] Verify press, hold, repeat, release, and interrupted-input paths on a real Mac, along with automated precedence and cleanup checks.

## 14. Release 0.12

**What to build:** Publish an everyday-controls beta whose app rules, automation, shortcuts, peeks, and menu choices work together.

**Blocked by:** Restore color for selected foreground apps; Activate E-Ink Mode with a macOS Focus filter; Record a custom global shortcut; Choose and extend temporary color; Choose simple or study menus.

- [ ] Run combined-state regression checks across app switching, manual actions, automation, peeks, focus phases, and scheduling.
- [ ] Verify upgrade from 0.11 retains settings, history, and restoration behavior.
- [ ] Publish 0.12 beta with updated release notes and user guidance.

## 15. Confirm Phase 3 scope at the January gate

**What to build:** Make a recorded, evidence-based decision about the next focus features before implementing them.

**Blocked by:** Run tester group 1 and summarize findings; Release 0.12.

- [ ] Review cohort findings and 0.12 behavior with the project owner.
- [ ] Explicitly retain, replace, or defer round controls, reflection, commitment mode, and Calendar logging; prioritize app exceptions or Shortcuts improvements if feedback warrants it.
- [ ] Update affected tickets and release dependencies to match the decision; do not treat silence as approval of provisional features.
- [ ] Defer Calendar logging first if capacity requires reducing scope, as directed by the roadmap.

## 16. Quick-start a session or saved round

**What to build:** Users can start one session or their saved round and optionally receive a longer color break after the fourth focus session.

**Blocked by:** Confirm Phase 3 scope at the January gate.

- [ ] Provide quick starts for one session and the saved round with clear duration and session-count labels.
- [ ] Offer an optional long-break duration after the fourth focus session; explicitly document whether and how the terminal break behaves when that session ends the round.
- [ ] Extend existing captured timing so preference changes never alter a running or paused round.
- [ ] Verify pause/resume, skip break, early stop, round completion, statistics, and schedule/display restoration for each supported round shape.

## 17. Save a reflection with each completed session

**What to build:** Users may record what they accomplished after a completed focus session and revisit that note locally.

**Blocked by:** Confirm Phase 3 scope at the January gate.

- [ ] Offer an optional, dismissible one-line reflection tied to the specific completed focus session, not just the day or round.
- [ ] Store sufficient session identity and timing to display the note with the correct completion, without interrupting the next phase or duplicating statistics.
- [ ] Provide local review of saved reflections and preserve existing aggregate history without inventing legacy session details.
- [ ] Include new session records and notes in history export and reset; verify skipped prompts, relaunch, and repeated completion handling.

## 18. Offer commitment mode for a round

**What to build:** Users can deliberately limit access to color during a chosen round while always retaining a safe way to restore their display.

**Blocked by:** Quick-start a session or saved round.

- [ ] Capture an opt-in per-round policy that disables color peeks or limits them to N, with visible allowance and consequences before starting.
- [ ] Define and enforce how extensions and app exceptions interact with that policy; menu, hotkey, CLI, and automation routes cannot accidentally bypass it.
- [ ] Require deliberate confirmation for ordinary early exit and persist that day's streak consequence, even if sessions were completed earlier that day.
- [ ] Preserve completed work and truthful statistics while representing the streak consequence explicitly.
- [ ] Emergency display restoration, crash recovery, and system termination remain safe; commitment restrictions never survive quitting the app. Verify these paths separately from voluntary early exit.

## 19. Log completed sessions to Apple Calendar

**What to build:** Users can optionally write completed focus sessions and their reflection notes to a selected Apple Calendar without an E-Ink account or service.

**Blocked by:** Save a reflection with each completed session.

- [ ] Request Calendar access only when the user enables logging and allow selection of a writable calendar; handle denied or revoked access clearly.
- [ ] Write only completed sessions with accurate timing and any reflection note; define how a note saved after event creation updates the event.
- [ ] Prevent duplicate events across retries and relaunch; logging errors never disrupt the focus timer or display restoration.
- [ ] Explain that the chosen calendar may sync through its provider, and define what disabling logging or resetting local history does to existing events.
- [ ] Verify permission failure, missing calendars, retries, and reflection updates. This feature may be deferred only through an explicit scope decision.

## 20. Complete accessibility review and release 0.13

**What to build:** Publish an accessible, documented feature-complete beta for the second tester cohort.

**Blocked by:** Offer commitment mode for a round; Log completed sessions to Apple Calendar. Explicitly deferred or replaced features must have their dependency changes recorded at the scope gate.

- [ ] Verify keyboard and VoiceOver use across new menus, settings, pause/resume, reflections, commitment confirmations, and Calendar setup; fix blocking issues.
- [ ] Run relevant automated checks and real-Mac restoration and upgrade regression checks across the retained Phase 3 scope.
- [ ] Update the user guide and release notes and publish 0.13 beta.
- [ ] Freeze new feature scope for validation; prepare the second cohort's five-flow study materials.

## 21. Run tester group 2 and assess release criteria

**What to build:** Determine whether the feature-complete beta is reliable and useful enough for 1.0 through observed use and interviews.

**Blocked by:** Complete accessibility review and release 0.13.

- [ ] Recruit 10–15 new testers for two weeks of 0.13 use, recording tested versions and participation windows.
- [ ] Observe installation, starting a round, interrupting it, using an app exception, and restoring the display.
- [ ] Interview participants without adding analytics; record install workarounds, restoration failures, and week-two continued use with a clear cohort denominator and treatment of missing responses.
- [ ] Prioritize findings and create individually scoped fix tickets with acceptance criteria and dependencies once the actual problems are known.
- [ ] Report evidence against each 1.0 gate without treating unverified or missing observations as successes.

## 22. Resolve tester blockers and release 1.0 RC

**What to build:** Deliver a release candidate with the prioritized cohort findings resolved and the final compatibility checks completed.

**Blocked by:** Run tester group 2 and assess release criteria; all release-blocking fix tickets identified from that study, whose titles must be added here before starting the release step.

- [ ] Resolve the agreed top issues through the scoped finding tickets and verify the affected user flows; record disposition of remaining nonblocking findings.
- [ ] Complete the final QA checklist on clean Intel and Apple silicon Macs, including installation, upgrade, interruptions, and display restoration.
- [ ] Retest supported macOS environments and record actual hardware/OS coverage and any unresolved gaps.
- [ ] Publish 1.0 RC with no unresolved release blockers and document the evidence for the final decision.

## 23. Make the 1.0 decision and release if qualified

**What to build:** Ship 1.0 only when the agreed trust and retention criteria are met, or record a concrete no-go decision and follow-up work.

**Blocked by:** Resolve tester blockers and release 1.0 RC.

- [ ] Confirm every tester installed without Gatekeeper workarounds.
- [ ] Confirm no display-restoration failures were reported; any prior failure and subsequent remediation must be explicitly addressed in the release decision rather than omitted.
- [ ] Confirm at least half of the second cohort were still using the app in week two, using the study's recorded denominator.
- [ ] Record the project owner's go/no-go decision and supporting evidence; unresolved or failed criteria produce follow-up tickets rather than an assumed pass.
- [ ] On go, publish the verified 1.0 artifact and final release documentation; on no-go, document the revised gate and schedule.
