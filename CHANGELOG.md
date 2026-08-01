# Changelog

- Added: DDC diagnostics now export a ZIP support bundle containing the previewed text report, a schema-versioned JSON report, and a checksummed manifest; the diagnostics history keeps only the newest ten bundles within a 20 MiB budget.
- Changed: support exports pseudonymize monitor identifiers and local names by default, offer separate one-build opt-ins for each raw category, and always redact local paths, Windows user and machine names, email/IP/MAC addresses, and credential-like tokens.
- Changed: application name and version metadata now come from one canonical data file, and the launcher, UI, diagnostics, profile exports, release filenames, and artifact manifest consume that value.
- Changed: portable releases are pinned to Windows PowerShell 5.1 and use an ordinal ZIP entry order plus `SOURCE_DATE_EPOCH` timestamps for byte-identical rebuilds; release output cleanup is restricted to validated exact targets.
- Changed: the support matrix now distinguishes current Windows 11 releases from Windows 10 ESU and LTSC compatibility lanes.

All notable changes to MonitorControl will be documented in this file.

## [Unreleased]

- Added: VCP Explorer now renders a monitor-advertised discrete value list as a constrained, labelled picker with known MCCS names, and continuous codes as sliders bounded by the reported maximum. Free entry appears only while capabilities are unknown; known codes with no advertised legal values cannot be written speculatively.
- Added: System > Automation now has a **Run at login** toggle backed by one per-user Startup-folder shortcut. The shortcut launches the current portable script with `-StartMinimized`, its exact command is verified on every launch, and disabling the option removes it without writing the registry.
- Security: automation bridge keys now use a once-generated 32-byte per-install entropy file separate from the DPAPI blob. Existing `dpapi:v1` keys migrate transparently to `dpapi:v2`, and an AST regression guard traces every `XamlReader.Load` call back to a literal, non-interpolated here-string.
- Fixed: startup now treats the inline native C# block as an explicit dependency: compiler diagnostics identify that block immediately, a missing `MonitorAPI` type fails at the call site, and neither failure can be hidden until a later consumer crashes.
- Fixed: malformed capability-list values can no longer escape into the advertised VCP code set; unregistered native monitor handles are destroyed during topology races; stale selected-monitor indexes no longer throw; NVIDIA helper discovery keeps the first valid path; brightness controls update their monitor-specific range before the raw value; and bridge route timeouts atomically retire their response slot so late dispatcher work cannot leak entries.
- Fixed: profile application, manual VCP commands, and display-state restore now share a generation-checked background runspace instead of performing native reads, writes, retry waits, and rollback on the WPF dispatcher. Multi-monitor applies stream progress to a responsive footer with a Cancel action; cancellation is cooperative and completes reverse-order rollback or explicitly reports a partial restore. The worker waits for the coalesced write queue off-thread and discards stale completion after display re-enumeration.
- Fixed: verified DDC writes now wait according to each monitor's calibrated timing instead of a fixed 75 ms. DDC timing schema v3 stores a per-monitor Strict, Lenient, or Off readback policy exposed in System; Lenient requires a second mismatch after a longer delay before rollback, and values above the monitor's reported maximum are classified as unreliable readback without undoing a successful write. Compatibility reports include the effective policy and both delays.
- Fixed: after the first healthy DDC read, each monitor is probed once with impossible VCP code `0x00` to distinguish an explicit unsupported reply from a persistent Null reply. The classification date and error are stored in DDC timing schema v2 and shown in compatibility reports. A panel proven to use Null for unsupported features stops retrying that reply and learns the affected code immediately; explicit-unsupported, inconclusive, and mixed behavior keep the existing per-code convergence path.
- Changed: monitor identity now prefers the Windows `DisplayManager` device-interface path and reads EDID, connector type, and peak luminance through WinRT without registry access when that API is available. The assembly-qualified WinRT type is loaded once under Windows PowerShell 5.1, every call is guarded, and the existing EDID/device-path implementation remains the fallback. Labels, risky-write unlocks, capability exclusions and cache entries, DDC timing, brightness restore state, and profile targets migrate from the legacy key; compatibility reports include connector and luminance metadata.
- Fixed: a read-only liveness worker now queries one inexpensive supported VCP code per monitor every 60 seconds when the DDC pipeline is idle. If one display fails while another succeeds, the app cancels stale workers, destroys the old physical-monitor handles, and re-enumerates once for that recovery generation; a global outage remains on the existing retry path. Compatibility reports include each monitor's last probe attempt and last successful probe, and the regression suite proves the worker contains no write operation.
- Changed: the 11,000-line monolith is now maintained as Core, Storage, DDC, Automation, Bridge, and WPF application source components. The development launcher preserves every existing switch, tests compose a disposable standalone script, and release builds still ship one PowerShell 5.1-compatible file with no runtime module dependency. Composition rejects syntax errors and duplicate function definitions, while regression tests keep WPF globals out of the testable modules and preserve injectable native read/write adapters.
- Changed: all seven workspaces now share a denser midnight control-center shell with page subtitles, bento-style cards, clearer metrics, consistent rounded controls, and an accessible blue accent. System settings now use named Overview, Display & DDC, Safety, Automation, Diagnostics, and Integrations categories instead of one ten-card scrolling column.
- Changed: the WPF smoke lane navigates the new System categories, verifies that the persistent header never scrolls away, and can export every visible workspace through app-native WPF rendering for pixel-accurate review without capturing the desktop.
- Fixed: the per-monitor capability retry budget and calibrated retry delay now reach the capability worker, and VCP Explorer Query/Scan use the same effective per-monitor read timing. Retries remain off the WPF dispatcher and report their actual attempt count.
- Fixed: profile deletion now confirms the profile file is gone before removing application rules or schedules. Locked and otherwise undeletable profiles leave all state untouched with an explicit error, while a dependent metadata-save failure restores the original profile and automation state.
- Fixed: monitor refresh and shutdown now cancel queued DDC writes, reject new queue entries during teardown, and wait for any in-flight native call to release its handle before destruction. A timeout aborts destruction with an explicit error instead of passing a freed physical-monitor handle to the background worker.
- Fixed: DDC value observations now expire after five minutes so panel OSD changes, other DDC tools, and self-reverting monitors cannot suppress a needed write indefinitely. Direct control changes always bypass suppression, repeating automation retains write-wear protection with a read-before-write after expiry, and System now offers a selected-monitor **Re-read values** action.
- Fixed: risky-write UI state is now refreshed with the selected monitor. The System checkbox and status name the active display, VCP Explorer's arbitrary Set button is disabled with guidance when that identity is locked, and all-monitor standby remains unavailable until every connected DDC/CI identity is unlocked.
- Fixed: monitor-identification overlays and delayed post-reset refreshes now close over their function-local state before the dispatcher invokes them. Identify overlays stop and close after two seconds, reset refreshes reach the selected monitor, and an AST regression test rejects future deferred timer handlers that capture function locals without `GetNewClosure()`.

## [v3.37.0] - 2026-07-31

- Added: DDC timing is now learned and stored per stable monitor identity instead of being three global constants. Adaptive mode calibrates a sleep multiplier from the first successful handshake with each monitor and persists it; manual mode uses the default delay verbatim so an operator value is never modified by calibration. The two are mutually exclusive and the card states that returning to adaptive discards the stored calibration. Read, write, and capability retry budgets are set separately per monitor.
- Added: a VCP code that fails every retry on a monitor that is answering other codes is recorded as null-signalled-unsupported and skipped from then on, and forgotten again as soon as it answers. Some monitors use the DDC Null Message to mean "not supported" rather than "not ready", which is the usual cause of a scan that appears to hang. Effective timing, calibration state, and skipped codes appear in the DDC Compatibility Report.
- Fixed: ambient brightness used a five-step hard-threshold ladder polled every 30 seconds, so a lux reading oscillating around a boundary rewrote brightness on every tick. Levels now use overlapping lux buckets with hysteresis, following Microsoft's adaptive-brightness guidance: a level is entered at one threshold and left only at a lower one, so a reading bouncing across a boundary produces no writes at all. Changes are rate-limited and ramped rather than stepped, and the darkest level is floored so the screen never becomes unreadable.
- Removed: the `AutomationBridgeMqttEnabled` setting. It was serialized to disk, force-reset to false whenever settings were read from the UI, and consumed only by a status label - there was no client, broker configuration, topic, or transport, so the bridge could report a capability that did not exist. Settings files that still carry the field load normally and drop it on the next save.
- Fixed: `EnumDisplayDevices` was called with a bare `$null` device name, which PowerShell marshals into a `[string]` parameter as an empty string rather than as NULL, so the call always failed and the adapter enumeration never ran. Monitor naming now has its display-device fallback back, and display-path classification depends on the same enumeration.
- Added: when DDC/CI control is missing, the app now names the cause instead of showing a monitor called "No DDC/CI Monitor". Every enumeration cross-checks the display count against the DDC-capable count and reports both. DisplayLink, indirect/virtual displays, remote-session displays, and the Microsoft Basic Display Adapter are identified as paths that terminate DDC/CI by design rather than as failures, each with what to try instead. A table of GPU driver releases with confirmed DDC/CI regressions is checked against the installed vendor branding version and names the release that fixed it. Anything left unexplained is reported as an unidentified path with hub, adapter, KVM, cable, and OSD guidance. The alert banner carries the headline and the DDC Compatibility Report gains an availability breakdown and a per-display path listing.

## [v3.36.0] - 2026-07-31

- Security: monitor capability strings are cached per stable monitor identity and replayed on later launches, so the one native call Microsoft documents as able to fault the Windows kernel now runs once per monitor instead of on every refresh. A shipped list of EDID model ids known to trigger that fault is consulted before any probe, and those monitors are skipped and reported rather than asked. **Clear cache** in System forces a re-read.

## [v3.35.0] - 2026-07-31

- Added: an opt-in "Restore brightness at launch and after resume" setting in System. Monitors commonly reset themselves to full brightness after a power or sleep cycle; when enabled, the last brightness set for each stable monitor identity is written back once per detected display change through the verified write path. Displays without a stable identity, without a DDC/CI handle, or that do not report brightness are skipped with a stated reason.
- Changed: the verification lane now refuses any PowerShell source containing a byte above 0x7F, enforces PSScriptAnalyzer warnings as well as errors against a committed `PSScriptAnalyzerSettings.psd1`, and pins Pester 5.9.0 on a windows-2025 runner. Every remaining analyzer finding was either fixed or excluded with a documented reason.
- Fixed: locals named `$profile` shadowed the automatic `$PROFILE` variable.
- Added: cancellation and teardown coverage for all four background workers.
- Changed: `main` is protected with admin enforcement, and force pushes and deletions are blocked. A required status check is deliberately not configured because it would block the direct-to-main workflow this repository uses.
- Fixed: the tray popup, monitor identify overlays, FPS overlay, and schedule timeline markers now draw from the shared theme instead of hardcoded colours, so they follow Windows high contrast like the main window. Detached windows receive the resolved brushes when created and again whenever the theme changes.
- Fixed: the tray popup "Link monitors" label no longer renders below the minimum supported text size.
- Added: a regression test fails the build if the static XAML brush dictionary drifts from the palette function, or if a hardcoded colour reappears in the tray popup or overlays.
- Fixed: a manual VCP write that fails or reads back mismatched now restores the readable prior value, matching what profile and automation writes already did. The status line reports whether the restore was complete or partial.
- Security: color preset (`0x14`), OSD/button control (`0xCA`), OSD language (`0xCC`), and auxiliary power (`0xD7`) now require the same per-identity unlock and exact-value confirmation as power and input. Color preset can persist after the app closes and need a factory reset to undo; OSD/button control can disable the monitor's own buttons. Each confirmation now names the specific consequence for the code being written, and the color temperature presets route through the verified write path.
- Security: optional hardware helpers are off by default and nothing is loaded or executed until they are explicitly enabled. The CPU temperature library used to be loaded from the script directory on every launch, and PresentMon was resolved from PATH first. Enabling a helper now requires confirmation, records the resolved path, source category, file and product version, and SHA-256, refuses versions below the supported minimum or with no version resource, prefers well-known install locations over PATH, and bounds PresentMon by time and output size. Turning a helper off removes the integration without affecting monitor control.
- Fixed: a DDC/CI value that already matches the panel is no longer written again. Successful reads and writes record the current value per monitor and code, so ambient mode, idle dim, battery targets, schedules, and slider drags stop re-pushing an unchanged number to hardware that stores it in limited-endurance EEPROM. The count of suppressed writes appears in the DDC compatibility report, and the cache is dropped whenever monitor handles are released.
- Fixed: brightness, contrast, RGB gain, volume, and sharpness now honour each monitor's own reported VCP maximum. Profiles, schedules, idle dim, battery targets, ambient mode, presets, the tray popup, and the automation bridge exchange percentages and convert to each display's raw range at the write boundary, so a linked change no longer writes one raw number to panels that report different ranges.
- Changed: profile schema v4 stores scaled DDC values as percentages; profiles written before v4 are clamped into 0-100 on load.
- Changed: `GET /api/brightness` returns a percentage plus the raw value and reported maximum, and `GET /api/monitors` reports `BrightnessMaximum` per display.

- Added: live Windows high-contrast colors, text-only scaling through 200%, per-monitor DPI awareness, reflowed headers, and independently scrollable navigation and tab content.
- Added: visible keyboard focus, access-key navigation, keyboard-invokable monitor tiles, complete UI Automation names, and inline dismissible error banners.
- Added: assertive WPF live regions with a native UI Automation provider fallback, plus an out-of-process accessibility-event smoke assertion.
- Added: automated WCAG 2.2 AA palette contrast checks and standard/high-contrast minimum-window visual smoke coverage.
- Added: pinned Windows PowerShell 5.1 verification with Pester 5.8.0, PSScriptAnalyzer 1.25.0, an isolated WPF UI Automation smoke test, and an unsigned release build.
- Added: regression coverage for every legacy profile schema, deterministic same-time schedule precedence, unique native-handle cleanup, and future-schema rejection.
- Added: one debounced display recovery pipeline for display, device, resume, and WMI brightness events, with per-identity fresh, stale, retrying, and offline status.
- Changed: monitor settings, capability, VCP Explorer, and DDC report workers now reject obsolete generations and mismatched stable identities before publishing results.
- Added: per-monitor DDC failure backoff, adaptive read retries, last-success diagnostics, and no-hardware reconnect regression coverage.
- Added: previewed copy-or-merge profile-storage migration with staged commits, named conflict copies, atomic pointer cutover, and byte-for-byte rollback.
- Changed: unavailable synchronized storage now exposes a red offline state and the last available library read-only instead of presenting an empty profile list.

## [v3.34.0] - 2026-06-30

- Added: no-hardware Pester suite for schedule rollover, idle tick wraparound, profile JSON quarantine/replacement, profile filename validation, capabilities parsing, and VCP parser helpers.
- Added: local `tools/run-tests.ps1` runner that enforces Pester 5+ and exits nonzero on failures.
- Changed: VCP Explorer query/set input parsing now uses shared validated helper functions.

## [v3.33.0] - 2026-06-30

- Added: disabled-by-default local automation bridge with `127.0.0.1:34291` default binding, generated API key, and MQTT disabled.
- Added: JSON endpoints for health, monitor list, profile list, brightness read, brightness write, and profile load.
- Added: write authorization and JSONL write logging for bridge brightness/profile commands.

## [v3.32.0] - 2026-06-30

- Added: System-tab DDC compatibility report with monitor identities, capability status and length, GPU driver names, OS version, recent DDC errors, and common VCP probe results.
- Added: report generation runs DDC probes on a background worker, copies the completed report to the clipboard, and saves a local diagnostics text file.
- Changed: monitor refresh and app close now cancel any active report worker before handles are replaced or destroyed.

## [v3.31.0] - 2026-06-30

- Changed: monitor enumeration no longer calls `CapabilitiesRequestAndCapabilitiesReply` on the WPF event thread.
- Added: background capabilities worker that fills raw capabilities, parsed VCP codes, and capability-aware control state after refresh.
- Changed: capabilities panel now reports pending reads while the background worker is active.

## [v3.30.0] - 2026-06-30

- Changed: VCP Explorer Set now uses the coalesced background DDC write queue instead of synchronous `SetVCPFeature`.
- Changed: color reset and factory reset actions queue DDC writes and use timer-delayed refresh instead of sleeping on the WPF event thread.
- Removed: factory reset confirmation dialog in favor of immediate queued action and status feedback.

## [v3.29.0] - 2026-06-30

- Added: local `tools/build-release.ps1` portable ZIP builder with staged script, icon, README, LICENSE, signing status, and SHA256SUMS.
- Added: an explicit unsigned-release contract recorded in SIGNING.txt.
- Changed: README install docs now prefer the portable release ZIP and document the release build command.

## [v3.28.0] - 2026-06-30

- Added: English UI string baseline for localized tab, title, and action text.
- Added: explicit automation names for core sliders, text boxes, lists, status fields, and VCP/profile/schedule controls.
- Changed: major interactive controls now get deterministic tab ordering during startup initialization.

## [v3.27.0] - 2026-06-30

- Added: EDID/device-path backed monitor identity records with persisted per-monitor labels.
- Added: Monitor tab label save/reset controls and tray/header labels that use the saved display name.
- Changed: schema v3 profiles store the selected monitor identity and target that monitor on load after display order changes.

## [v3.26.0] - 2026-06-30

- Added: MCCS `vcp(...)` capabilities parsing with per-monitor supported-code and supported-value maps.
- Changed: fixed DDC controls and VCP presets now disable or mark items that parsed capabilities say are unsupported.
- Added: VCP Scanner can switch between capabilities-only scans and full known-code probes.

## [v3.25.0] - 2026-06-30

- Added: shared safe JSON read/write helpers with temp-file replacement, valid `.bak` retention, and corrupt-file quarantine.
- Changed: profile, app-rule, schedule, idle dim, battery profile, and profile-storage JSON now use hardened persistence.
- Changed: profile save/load/delete/import/startup load now reject unsafe Windows filenames before touching disk.

## [v3.24.0] - 2026-06-30

- Added: reusable physical-monitor handle cleanup before refresh re-enumerates displays.
- Changed: refresh and close now wait briefly for queued DDC writes, destroy each stale non-zero handle once, and zero old handle objects before replacing the monitor list.

## [v3.23.0] - 2026-06-30

- Added: DDC/CI read and write diagnostics with monitor name, VCP code, attempted value, Win32 error, and retry count.
- Changed: queued DDC/CI writes now surface failures in the status bar and copyable VCP Explorer diagnostics summary.
- Changed: time-based brightness writes now route through the coalesced background write queue.

## [v3.22.0] - 2026-06-30

- Added: background monitor-settings read worker for brightness, contrast, RGB gain, volume, and sharpness refreshes.
- Changed: monitor selection and refresh no longer perform the standard DDC/CI read batch on the WPF event thread.

## [v3.21.0] - 2026-06-30

- Added: background VCP Explorer worker for query and scan reads.
- Changed: VCP scan now reports timer-driven progress without blocking the WPF event loop with `DoEvents`.

## [v3.20.0] - 2026-06-30

- Added: coalesced native DDC/CI write queue backed by a ThreadPool worker.
- Changed: slider, profile, preset, and all-monitor writes now enqueue without sleeping on the WPF event thread.

## [v3.19.0] - 2026-06-28

- Added: 24-hour schedule timeline with ticks, rule markers, and rule tooltips in the Schedule tab.
- Changed: scheduled profile controls now redraw the timeline after load, add, remove, toggle, and resize events.

## [v3.18.0] - 2026-06-28

- Added: profile storage folder pointer for OneDrive/Dropbox sync folders.
- Added: Profiles tab storage status plus Sync Folder and Use Local actions.

## [v3.17.0] - 2026-06-28

- Added: profile bundle export to timestamped ZIP files under `%APPDATA%\MonitorControlPro\exports`.
- Added: profile bundle import with schema migration and corrupt-entry skipping.

## [v3.16.0] - 2026-06-28

- Added: profile schema version `2` with normalized save/load helpers.
- Added: v1 profile migration on load and filtering for internal automation JSON files.

## [v3.15.0] - 2026-06-28

- Added: battery-aware brightness profile with separate AC and battery brightness targets.
- Added: persisted battery profile settings and power-line status watcher in the Schedule tab.

## [v3.14.0] - 2026-06-28

- Added: ambient light auto-brightness mode using Windows `LightSensor` WinRT readings.
- Changed: time-based Auto and Ambient modes now disable each other before applying brightness.

## [v3.13.0] - 2026-06-28

- Added: WMI brightness fallback for integrated laptop displays with no DDC/CI handle.
- Changed: brightness sync and time-based presets now also apply through WMI when laptop brightness methods are available.

## [v3.12.0] - 2026-06-28

- Added: optional PresentMon FPS overlay with a topmost mini-window and GPU-tab status controls.
- Added: PresentMon stdout CSV parser for short capture windows when `PresentMon.exe` is available.

## [v3.11.0] - 2026-06-28

- Added: optional CPU temperature monitoring through LibreHardwareMonitorLib or OpenHardwareMonitorLib.
- Changed: hardware tab remains available when only CPU temperature sensors are available.

## [v3.10.0] - 2026-06-28

- Added: AMD ADL telemetry path for Radeon temperature, utilization, engine/memory clocks, and fan percent.
- Changed: GPU tab visibility now supports NVIDIA or AMD devices instead of hiding on non-NVIDIA systems.

## [v3.9.0] - 2026-06-28

- Added: NVAPI digital vibrance setter wired to the GPU tab slider.
- Changed: Digital Vibrance now reports NVAPI availability and set errors through the status bar instead of remaining a placeholder.

## [v3.8.0] - 2026-06-28

- Added: vendor-defined PiP/PbP mode controls for Dell-style ultrawides using VCP `0xE9`.
- Added: secondary input routing buttons for VCP `0xE8` with DisplayPort, HDMI 1, and HDMI 2 values.

## [v3.7.0] - 2026-06-28

- Added: picture mode buttons for Web/Productivity, Cinema/Movie, and Game using Display Mode VCP `0xDC`.
- Changed: documented the standard MCCS Display Mode values used by the new presets.

## [v3.6.0] - 2026-06-28

- Added: dynamic contrast controls that set Display Mode VCP `0xDC` to standard (`0x00`) or dynamic contrast (`0xF0`) where supported.
- Changed: corrected the roadmap's dynamic contrast reference from non-standard `0xFC` to Display Mode `0xDC`.

## [v3.5.0] - 2026-06-28

- Added: extended VCP presets for gamma, OSD/button control, OSD language, status indicators, auxiliary power, and display modes.
- Changed: VCP scanner now uses the shared preset table so new VCP codes are scanned automatically.

## [v3.4.0] - 2026-06-27

- Added: idle-dim automation using `GetLastInputInfo` polling.
- Added: persisted idle threshold, dim brightness, and restore-on-activity settings in the Schedule tab.

## [v3.3.0] - 2026-06-27

- Added: scheduled profile rules with a Schedule tab, explicit `HH:mm` daily triggers, and persisted schedule JSON.
- Added: schedule watcher that applies the latest due saved profile once per schedule boundary.

## [v3.2.0] - 2026-06-27

- Added: per-application profile rules that watch the foreground executable and apply matching saved profiles.
- Added: Profiles-tab rule editor with delayed foreground-app capture, add/remove controls, and persisted rules JSON.

## [v3.1.0] - 2026-06-27

- Added: notification-area tray icon with a compact brightness popup.
- Added: minimize-to-tray behavior for persistent background operation.
- Added: tray link-monitor toggle and profile cycling from the tray surface.
- Changed: moved global hotkey work to blocked because current project rules disallow keyboard shortcuts.
