# E-Ink Mode implementation scope

Approved working scope: macOS MVP plus inline settings, independent grayscale, and nightly scheduling. Preserve prototype0. Windows, custom rendering/palettes/dithering, IDE themes, and app blocking are deferred. Warmth remains owned by f.lux. Notification suppression is unavailable unless prior state can be reliably captured and restored.

Deliver menu bar settings, primary toggle, Command-Shift-E, grayscale, optional brightness, Dock autohide, reduced motion/transparency where supported, login startup, persisted configuration, crash recovery and CLI parity. Schedule defaults to disabled, 21:00–07:00 daily local time, catches up on wake/start, and respects manual mode overrides until the next boundary. Launch alone never activates an unscheduled profile.

Tests exercise public mode/configuration/schedule commands with a simulated system adapter and real temporary persistence: capture/restore including pre-existing accessibility settings, per-display brightness, repeated and concurrent operations, partial failures, recovery, independent settings, input validation, midnight/DST/wake/manual override behavior. Real system mutation and visual grayscale verification are a separate human QA gate.

New app and CLI share a Swift core and atomic JSON state. Read legacy config as data, never execute shell. Keep a durable restoration journal before any system changes. A process lock serializes menu, CLI, and scheduler. Failed restoration retains the journal for retry. Unsupported controls are reported explicitly. Legacy active state must be restored using the prototype before using the new app; never invent missing invert or display state.

Beta 0.9 (see CHANGELOG): defaults are grayscale-only; brightness and Dock are opt-in via first-run setup. Temporary color is runtime state (`colorUntil`) that never edits the saved profile. Status menu follows the agreed hierarchy; settings moved to a window. App exceptions and a free-form shortcut recorder are deferred until beta feedback.
