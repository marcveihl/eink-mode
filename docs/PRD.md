Product Requirements Document

Working Name: E-Ink Mode

Status: Concept / MVP Definition  
Platforms: macOS, Windows  
Primary Use Case: Late-night coding, writing, terminal work, and focused AI-assisted development

  

1. Product Summary

E-Ink Mode is a lightweight desktop utility that transforms a standard computer display into a low-stimulation, monochrome workspace inspired by E-ink devices.

With one keyboard shortcut or tray/menu-bar toggle, the user’s computer switches from a normal colorful desktop into a focused work environment with:

- Monochrome rendering
- Reduced brightness
- Paper-like tones
- Reduced animations
- Reduced visual clutter
- Notification suppression
- Optional distraction blocking

The product is designed primarily for coding, writing, terminal work, documentation, and AI-assisted development at night.

The product does not attempt to perfectly simulate the limitations of physical E-ink hardware. Instead, it borrows the visual and behavioral qualities that make E-ink devices feel calm and distraction-resistant.

  

2. Problem

Modern desktop operating systems are optimized for rich media.

That means:

- Bright colors
- High contrast notifications
- Animated UI elements
- Badges
- Video
- Social media
- Colorful syntax highlighting
- Constant visual stimulation

This environment can feel especially distracting during late-night coding or focused work.

Users can manually enable grayscale, reduce brightness, change themes, enable Do Not Disturb, hide the taskbar, and close distracting applications.

But these settings are scattered across the operating system and must be managed independently.

Existing solutions generally fall into three categories:

1. Grayscale accessibility settings
2. Website/app blockers
3. Focus timers

None provide a unified “turn my computer into a calm E-ink workstation” experience.

  

3. Product Vision

Turn any laptop or monitor into a calm monochrome workstation with one action.

The experience should feel like changing the computer into a different device rather than simply enabling grayscale.

Normal mode:

General-purpose computer.

E-Ink Mode:

Focused reading, writing, coding, and thinking machine.

  

4. Product Principle

Borrow E-ink’s strengths, not its weaknesses.

The product should emulate:

- Monochrome visuals
- Limited palette
- Paper-like backgrounds
- Reduced visual noise
- Low brightness
- Static interfaces
- Intentional interaction

It should not emulate:

- Slow refresh rates
- Input latency
- Severe ghosting
- Poor scrolling
- Limited responsiveness

Coding should still feel instantaneous.

  

5. Target Users

Primary User

Developers who frequently work at night and want a calmer environment for:

- VS Code
- Cursor
- Terminal
- Claude Code
- Codex
- Documentation
- Browsing technical references
- Writing
- Markdown
- Git workflows

Secondary Users

- Writers
- Students
- Researchers
- Knowledge workers
- Designers doing documentation-heavy work
- Users intentionally reducing digital stimulation

  

6. Core Jobs To Be Done

Focus

When I want to work without getting distracted, I want my computer to visually simplify itself so I can stay focused on the task.

Late-night work

When I’m coding at night, I want my display to feel calmer and less stimulating without sacrificing readability.

Context switching

When I’m done working, I want one action to restore my computer exactly to its previous state.

Distraction resistance

When I enter focus mode, I want distracting apps and notifications to become less visually appealing or inaccessible.

  

7. Core Experience

The primary interaction should be extremely simple.

Enter E-Ink Mode

User presses:

⌘ + Shift + E

or on Windows:

Ctrl + Shift + E

The system transitions into E-Ink Mode.

Example state:

- Display becomes monochrome
- Brightness drops to 35%
- Colors collapse into four grayscale tones
- Wallpaper becomes neutral
- Dock/taskbar hides
- Notifications are suppressed
- UI animations reduce
- Allowed work applications remain accessible
- Distracting applications optionally become blocked or heavily desaturated

A small temporary indicator appears:

E-INK MODE ENABLED

After ~2 seconds it disappears.

  

8. Mode Architecture

E-Ink Mode should function as a configurable system profile.

Example:

profile: eink

  

display:

  grayscale: true

  brightness: 35

  palette: 4-level

  temperature: warm

  contrast: high

  

system:

  reduce_motion: true

  reduce_transparency: true

  notifications: off

  wallpaper: paper

  taskbar: hidden

  

focus:

  enabled: true

  

allowed_apps:

  - VS Code

  - Terminal

  - Cursor

  - Claude

  - Browser

  

blocked_apps:

  - Discord

  - Steam

  - Reddit

  - YouTube

This profile architecture allows future modes to be added.

Examples:

- Reading Mode
- Deep Work Mode
- Night Writing Mode
- Coding Mode

  

9. MVP Requirements

P0 — Required

9.1 Global Toggle

Users must be able to enable or disable E-Ink Mode using:

- Menu bar / system tray
- Global keyboard shortcut

The transition should take less than approximately one second where technically possible.

  

9.2 Full-Screen Grayscale

The system should render the desktop in monochrome.

Initial implementation should use native OS capabilities whenever possible.

macOS:

- Accessibility Color Filters

Windows:

- Accessibility Color Filters

The system must restore the user’s previous setting when E-Ink Mode is disabled.

  

9.3 Brightness Control

Users can define an E-Ink Mode brightness level.

Example:

Normal:

80%

E-Ink:

35%

When exiting E-Ink Mode, previous brightness should be restored.

  

9.4 Paper Tone

Users should optionally be able to replace pure white with a warmer off-white tone.

Example target palette:

Paper       #F4F1E8

Light Gray  #A7A59F

Dark Gray   #575752

Ink         #181817

The MVP may implement this using:

- Native display settings
- Overlay
- Color transform

Exact implementation may vary by OS.

  

9.5 State Restoration

The application must capture relevant system settings before entering E-Ink Mode.

When exiting, the previous state must be restored.

Examples:

- Brightness
- Grayscale state
- Notification mode
- Dock/taskbar behavior

This is a critical requirement.

The user should never have to manually undo E-Ink Mode.

  

9.6 Startup Behavior

Users can optionally:

- Launch app at login
- Remember last configuration

The app should not automatically enter E-Ink Mode by default.

  

10. P1 Features

10.1 Notification Suppression

Entering E-Ink Mode can optionally enable:

macOS:

Focus / Do Not Disturb

Windows:

Do Not Disturb

Previous notification state must be restored on exit.

  

10.2 Reduced Motion

Enable operating-system accessibility settings where possible.

Examples:

- Reduce motion
- Reduce transparency
- Disable unnecessary animations

This reinforces the static E-ink feel.

  

10.3 Taskbar / Dock Reduction

Optional setting:

Minimal Desktop

When enabled:

- macOS Dock autohides
- Windows taskbar autohides

  

10.4 Application Allowlist

Users can identify applications associated with focused work.

Example:

VS Code

Terminal

Cursor

Claude

Chrome

Obsidian

These applications remain normally accessible.

  

10.5 Application Blocklist

Optional distraction mode.

Example:

Steam

Discord

Spotify

Reddit

YouTube

X

Potential behaviors:

Soft block

Show:

E-Ink Mode is active. Open anyway?

Hard block

Prevent launching until E-Ink Mode is disabled.

MVP should begin with soft blocking.

  

11. P2 Features

11.1 Limited Grayscale Palettes

Instead of continuous grayscale, users can choose:

- 2-tone
- 4-tone
- 8-tone
- 16-tone
- Standard grayscale

This would create a stronger E-ink visual identity.

  

11.2 Dithering

Use ordered or error-diffusion dithering to represent intermediate shades.

Potential methods:

- Bayer dithering
- Floyd-Steinberg
- GPU shader-based dithering

Example:

Original image

      ↓

Grayscale

      ↓

4-level quantization

      ↓

Dithering

      ↓

E-ink-like output

  

12. Coding-Specific Features

One area where the product can differentiate from generic digital wellness software is support for developer workflows.

IDE Theme Integration

E-Ink Mode could ship with compatible themes for:

- VS Code
- Cursor
- JetBrains
- Terminal
- iTerm2
- Windows Terminal

Example theme:

Background: paper

Text: ink

Comments: gray

Keywords: dark gray

Strings: medium gray

Errors: underline/bold instead of red

Color meaning is replaced by:

- Weight
- Underlining
- Italics
- Brightness
- Contrast

This makes syntax readable without relying heavily on color.

  

13. AI Coding Mode

A future mode could specifically target AI-assisted development.

Example:

Vibe Coding Mode

Launching it could automatically open:

VS Code

Terminal

Claude Code

Local development server

Browser

while suppressing everything else.

The user effectively turns the machine into an AI development appliance.

Example launcher:

┌─────────────────────────────┐

│ E-INK MODE                  │

│                             │

│ ● VS Code                   │

│ ● Terminal                  │

│ ● Claude Code               │

│ ● localhost:3000            │

│                             │

│ Focus Session      01:47:32 │

└─────────────────────────────┘

  

14. Scheduling

Users can optionally schedule E-Ink Mode.

Example:

Enable:   10:00 PM

Disable:   2:00 AM

Days:      Sun–Thu

Alternative trigger:

Enable after sunset

This could use system location or local sunset data.

  

15. User Interface

The app should remain extremely small.

macOS

Menu bar icon:

◐

Click:

E-Ink Mode

  

○ Off

● On

  

Brightness          35%

Palette             4-Level

Paper Tone          Warm

  

Focus Mode          ✓

Hide Dock           ✓

Reduce Motion       ✓

  

──────────────

  

Schedule

Apps

Preferences

  

Windows

Equivalent UI in the system tray.

The experience should remain consistent across platforms.

  

16. First-Run Setup

Initial onboarding should take less than one minute.

Screen 1

Turn your display into an E-ink workspace.

[Continue]

  

Screen 2

Choose brightness:

20% ─────●───── 100%

  

Screen 3

Choose style:

○ Standard Grayscale

  

● Paper

  

○ High Contrast

  

○ 4-Level E-Ink

  

Screen 4

Optional:

Reduce distractions while E-Ink Mode is active?

☑ Silence notifications

☑ Hide Dock / taskbar

☑ Reduce animations

☐ Block distracting apps

  

Screen 5

Shortcut:

⌘ ⇧ E

Try E-Ink Mode

  

17. Technical Architecture

The application should use a shared abstraction layer with operating-system-specific implementations.

                 ┌─────────────────────┐

                 │     E-Ink Core      │

                 │                     │

                 │ Profile Manager     │

                 │ State Manager       │

                 │ Settings            │

                 │ Scheduler           │

                 └─────────┬───────────┘

                           │

             ┌─────────────┴─────────────┐

             │                           │

      macOS Adapter                Windows Adapter

             │                           │

       Accessibility                Color Filters

       Brightness APIs              Brightness APIs

       Focus APIs                   DND APIs

       Dock controls                Taskbar controls

       Metal                        DirectX

The core profile schema should remain platform independent.

  

18. Technology Options

macOS

Likely technologies:

- Swift
- SwiftUI
- AppKit
- Core Graphics
- Core Image
- Metal

Initial implementation should prioritize native system controls.

Metal should only be introduced if advanced rendering requires it.

  

Windows

Likely technologies:

- C#
- .NET
- WinUI
- Windows APIs
- DirectX / DirectComposition

Again, initial versions should rely on native accessibility and display functionality whenever possible.

  

19. Cross-Platform Strategy

The biggest technical risk is display manipulation.

Therefore development should proceed in layers.

Layer 1 — System Controls

Use operating-system functionality.

Examples:

- Grayscale
- Brightness
- Notifications
- Taskbar
- Motion

Lowest technical risk.

  

Layer 2 — Overlay

Add an always-on-top transparent display overlay.

Supports:

- Warm tint
- Contrast
- Paper tone

Moderate technical risk.

  

Layer 3 — Rendering Layer

GPU post-processing.

Supports:

- Grayscale quantization
- Dithering
- E-ink simulation
- Per-monitor rendering

Highest technical complexity.

The MVP should stop at Layer 1 or Layer 2 unless testing proves the advanced rendering is necessary.

  

20. Multi-Monitor Behavior

Users may have multiple monitors.

MVP options:

Global

E-Ink Mode applies to every display.

Later

Allow per-monitor configuration.

Example:

MacBook Display        E-Ink

Dell 27"               E-Ink

TV                      Normal

Per-monitor support should be considered P2.

  

21. Accessibility

The product must not interfere with existing accessibility settings.

If grayscale or reduced motion were already enabled before activation, those settings must remain enabled after exiting.

State transitions must therefore be based on:

Capture

↓

Modify

↓

Restore

rather than:

Enable

↓

Disable

This distinction is important.

  

22. Performance Requirements

E-Ink Mode should feel invisible to system performance.

Targets:

- <1% CPU usage while idle
- Minimal memory footprint
- No noticeable typing latency
- No meaningful GPU usage during basic mode
- Mode switch <1 second where OS APIs permit
- No significant battery penalty

The application should not continuously process the framebuffer unless advanced visual modes are enabled.

  

23. Privacy

The application should not need to capture screen contents.

MVP should avoid:

- Screen recording
- Screenshot access
- Browser history collection
- Keystroke monitoring
- Content analysis

The app should only modify system state.

This provides a strong privacy posture and simplifies permissions.

  

24. Failure Handling

The application must recover cleanly from:

- Crash
- Forced quit
- Reboot while E-Ink Mode is active
- Display disconnect
- Sleep/wake
- User changing settings manually

Persist the captured system state locally.

On restart:

E-Ink Mode was active when the app closed.

  

[Restore Normal Display]

  

[Resume E-Ink Mode]

  

25. Success Metrics

Activation

Percentage of users who successfully enable E-Ink Mode during onboarding.

Target:

>80%

Repeat usage

Users activating E-Ink Mode on three or more different days per week.

Session duration

Median E-Ink Mode session length.

Expected:

30–180 minutes

Retention

Weekly active users after:

- 1 week
- 4 weeks
- 12 weeks

Most important qualitative metric

Users report:

“When I turn this on, I naturally stop messing around and start working.”

  

26. MVP Scope

Build

- macOS menu bar app
- Windows tray app
- Global shortcut
- Native grayscale toggle
- Brightness profile
- Notification suppression
- Reduce motion where supported
- Dock/taskbar autohide
- Reliable state capture and restoration
- Launch at startup
- Basic configuration

Do Not Build Yet

- Custom framebuffer rendering
- AI features
- Complex website blocking
- Browser extension
- Per-window grayscale
- Cloud accounts
- Cross-device sync
- Productivity analytics
- Pomodoro system
- Mobile app
- Perfect E-ink refresh simulation

  

27. MVP Validation

Before building advanced rendering, test whether the simple combination of:

grayscale

+

low brightness

+

paper tone

+

reduced motion

+

notifications off

+

minimal desktop

already creates the desired psychological effect.

The first prototype can be crude.

A useful validation test:

Normal Desktop

Code for 30 minutes.

Measure:

- App switching
- Phone checking
- Browser tab switching
- Subjective distraction

E-Ink Desktop

Repeat the same task.

Ask:

- Did the computer feel calmer?
- Did color become less tempting?
- Was code still readable?
- Did the mode encourage staying in the current task?
- Would the user voluntarily enable it again?

  

28. Prototype Milestones

Prototype 0 — Manual Validation

Use built-in OS settings manually.

Create a combination of:

- Grayscale
- Low brightness
- Minimal IDE theme
- Do Not Disturb
- Hidden Dock/taskbar

Use it personally for several late-night coding sessions.

Goal:

Validate the behavior before writing software.

  

Prototype 1 — One Button

Build:

Enable E-Ink

Disable E-Ink

Nothing else.

Prove state management works reliably.

  

Prototype 2 — Profile

Add:

- Brightness
- Notifications
- Reduced motion
- Dock/taskbar
- Settings persistence

  

Prototype 3 — Visual Identity

Add:

- Paper tones
- 4-level grayscale
- Dithering experiments
- Developer-focused IDE themes

  

Prototype 4 — Focus Environment

Add:

- App allowlist
- App soft-blocking
- Scheduling
- Focus sessions

  

29. Key Product Risks

OS Restrictions

Some system settings may not expose stable public APIs.

Mitigation:

Prefer supported APIs and treat unsupported features as optional.

  

Rendering Complexity

True system-wide E-ink rendering may require graphics techniques that introduce:

- GPU overhead
- compatibility issues
- multiple-display complexity

Mitigation:

Treat custom rendering as an enhancement rather than an MVP requirement.

  

Accessibility Conflicts

Users may already depend on grayscale or accessibility features.

Mitigation:

Always snapshot and restore state.

  

Gimmick Risk

Users may like the aesthetic but not change their actual behavior.

Mitigation:

Validate repeat usage before investing in advanced E-ink simulation.

  

30. Differentiation

The product should not position itself as another productivity timer.

The differentiation is the transformation of the computer itself.

Existing mental model:

“I turned on Focus Mode.”

Desired mental model:

“I turned my laptop into my E-ink coding machine.”

That psychological device switch is the core concept.

  

31. Potential Naming Directions

Functional:

- E-Ink Mode
- Mono Mode
- Paper Mode
- Ink Mode

Developer-oriented:

- MonoDev
- InkTerm
- PaperCode
- NightCode

More playful:

- Ghost
- Slate
- Parchment
- Carbon
- Monk

Working name should remain E-Ink Mode until product validation establishes the final identity.

  

32. Long-Term Vision

E-Ink Mode could eventually become a general-purpose computer environment switcher.

Instead of changing individual settings, users switch entire computing environments.

Example:

WORK

VS Code + Slack + Browser

  

DEEP WORK

VS Code + Terminal + Docs

  

E-INK

Monochrome + Quiet + Minimal

  

GAMING

Full Color + Discord + Steam

  

NORMAL

Everything restored

At that point, E-Ink Mode becomes the first strong use case for a broader desktop profile system.

But the initial product should remain focused:

One click turns your normal computer into a calm monochrome workstation for coding and focused work.