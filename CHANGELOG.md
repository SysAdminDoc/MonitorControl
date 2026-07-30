# Changelog

All notable changes to MonitorControl will be documented in this file.

## [Unreleased]

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
- Added: optional Authenticode signing when a local code-signing certificate is available.
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

## [v0.1.0] - %Y->- (HEAD -> main, origin/main, origin/HEAD)

- Added: Add screenshot to README
- docs: fix YOUR_USERNAME placeholder URLs
- Added: Add files via upload
- Added: Add files via upload
