# Research - MonitorControl Pro

## Executive Summary
MonitorControl Pro is a standalone Windows PowerShell 5.1/WPF utility for DDC/CI monitor control, profile automation, tray brightness, VCP exploration, and NVIDIA telemetry. Its strongest shape is the single-file, no-install "power user control panel" niche: it already exposes more raw VCP surface than basic tray-brightness tools, while staying simpler than Electron/.NET competitors. Highest-value direction: make hardware communication trustworthy before adding more surface area. Top opportunities are: move DDC calls off the UI thread, add Win32 error diagnostics and retry policy, parse capabilities into safe per-monitor controls, harden profile storage, add stable monitor identity, add accessibility/localization scaffolding, ship a signed distributable, then add optional automation bridges.

## Product Map
- Core workflows: detect DDC/CI monitors; adjust brightness/contrast/RGB/volume/sharpness; switch inputs and power states; save/load profiles; run app/profile/schedule/idle automation; inspect and set VCP codes.
- User personas: Windows multi-monitor desk users; IT/power users replacing monitor OSD button workflows; streamers/gamers switching inputs or picture modes; laptop users needing a WMI fallback; monitor troubleshooting users who need raw VCP diagnostics.
- Platforms and distribution: Windows 10/11, PowerShell 5.1+, direct `.ps1` download today; no package manifest, installer, signature, or Winget/MS Store style channel yet.
- Key integrations and data flows: Win32 `dxva2.dll`, `user32.dll`, `gdi32.dll`; monitor profile/rule JSON in `%APPDATA%\MonitorControlPro`; optional `nvidia-smi.exe`; display settings/color management shell launches.

## Competitive Landscape
- Twinkle Tray: best Windows tray brightness baseline with normalization, idle/time automation, command-line monitor targeting, arbitrary VCP sends, localization, and package-manager installs. Learn its coalesced tray-first UX and install/update channels; avoid its heavier Electron footprint.
- Monitorian: best lightweight Windows desktop reference for WPF/.NET-style multi-monitor brightness, unison control, per-monitor adjustable ranges, ambient light display, localization, Microsoft Store/Winget distribution, and long compatibility history. Learn its range/identity/localization discipline; avoid narrowing MonitorControl to brightness-only.
- ControlMyMonitor: best raw VCP troubleshooting reference with GUI plus command-line, config export/load, selectable VCP loading modes, retry-on-failure, status error codes, and monitor identifiers. Learn its diagnostics, retry, and export model; avoid exposing every write-only code without safer context.
- ddcutil: strongest DDC/CI architecture reference for capabilities-driven VCP handling, monitor calibration/profile workflows, Linux/USB edge cases, and extensive troubleshooting. Learn its capabilities-first model and troubleshooting docs; avoid cross-platform scope until Windows reliability is solid.
- Lunar and DisplayBuddy: strongest commercial automation references, especially hardware DDC over software overlay, gamma fallback, sunrise/sunset schedules, sensor modes, input switching, presets, and display-connected/charger triggers. Learn their fallback and automation model; avoid macOS-only assumptions and paid-feature sprawl.
- BetterDisplay: strongest advanced display-control reference for DDC auto-configuration, EDID export, nits-based synchronization, display groups, HDR/SDR color-profile switching, and integration endpoints. Learn auto-configuration and stable display metadata; avoid virtual-screen scope that does not match this repo.
- Dell Display Manager: strongest vendor-suite reference for KVM/PBP/PIP, OSD settings import/export, monitor asset/usage reporting, input manager, and command-line fleet controls. Learn monitor-model-specific OSD cloning and diagnostic reports; avoid becoming a Dell-only fleet manager.
- ddc-ci-control-bridge: useful adjacent reference for a local server plus MQTT/Home Assistant style automation. Learn optional automation boundaries and API-key defaults; avoid network services enabled by default.

## Security, Privacy, and Reliability
- Verified: `MonitorControlPro.ps1:1483-1489`, `1510-1515`, and `1527-1540` perform synchronous `GetVCPFeatureAndVCPFeatureReply`/`SetVCPFeature` work on WPF event handlers; Microsoft documents roughly 40 ms per get and 50 ms per set, so slider drags and scans can stall the UI.
- Verified: `MonitorControlPro.ps1:244-264` returns only Boolean success/current/max and drops `Marshal.GetLastWin32Error()`, while many callers also ignore failed writes. ControlMyMonitor's error-code surface and retry options show this is table-stakes for DDC/CI hardware.
- Verified: `MonitorControlPro.ps1:1533-1540` scans a fixed preset table instead of parsing the capabilities string into supported values and write safety; this risks false negatives/positives on monitors with partial MCCS support.
- Verified: `MonitorControlPro.ps1:1543-1546`, `892-898`, `1036-1041`, and `1111-1118` write JSON directly with user-derived names and no temp-file/rename path, schema marker, or corrupted-file quarantine. A crash or invalid filename can lose settings or confuse automation.
- Verified: `MonitorControlPro.ps1:1514` exposes factory reset through a modal confirmation. The project rules prefer immediate action plus status/toast patterns; destructive monitor writes should still be gated through an in-app safety pattern that does not block automation.
- Verified: `MonitorControlPro.ps1:330-715` has dense WPF controls but no `AutomationProperties`, resource dictionaries, or localized strings; Monitorian's localization breadth shows Windows display utilities get real non-English use.
- Verified: `MonitorControlPro.ps1:1715-1717` destroys physical monitor handles on close, but `Refresh-Monitors` recreates handles without first destroying previous handles. Repeated refreshes can leak handles until exit.
- Missing guardrails: no release signature, no hash, no installer/portable ZIP, no `PSScriptAnalyzer`/Pester harness, no structured log, no crash log, no DDC compatibility report, no safe-mode launch after profile corruption.

## Architecture Assessment
- `MonitorControlPro.ps1` needs a small hardware boundary: wrap DDC get/set/scan in queued worker functions with coalescing, retry policy, last-error capture, and UI dispatcher updates.
- `Get-Monitors`/`Refresh-Monitors` should own monitor-handle lifecycle and stable identity (`DeviceName`, EDID/manufacturer/model/serial where available), so profiles can target monitors instead of the current array index.
- The VCP Explorer should be capabilities-driven: parse `(vcp(...))`, record possible values, and disable or warn on unsupported/write-only codes.
- Profile/rule/schedule/idle JSON should share schema, validation, atomic write, backup, migration, and quarantine helpers instead of four direct `ConvertTo/From-Json` paths.
- The UI should split strings/styles from behavior enough to support accessibility names, high-contrast checks, and later localization without rewriting the single-file app.
- Test gaps: no parser/lint gate, no unit tests for schedule rollover, idle wraparound, profile migration, VCP parsing, or filename sanitization; no manual smoke checklist for no-DDC, one monitor, many monitors, dock/KVM, laptop panel, and AMD driver failure.
- Documentation gaps: README explains DDC basics, but not a diagnostic report, error-code meanings, backup/restore of profiles, package verification, or known driver regressions.

## Rejected Ideas
- Global hotkeys from Twinkle Tray/Lunar/DisplayBuddy: rejected for this repo until owner policy changes; `Roadmap_Blocked.md` already records keyboard shortcuts as blocked.
- Virtual displays, HiDPI scaling, and display streaming from BetterDisplay: rejected because MonitorControl is a monitor-control utility, not a display-server replacement.
- Window tiling/Easy Arrange from Dell Display Manager: rejected because Windows already owns this workflow and it dilutes the DDC/CI control focus.
- Smart TV Wi-Fi control from DisplayBuddy/BetterDisplay: rejected for now because it adds vendor network protocols and credentials before local DDC reliability is solved.
- Fleet remote management from Dell Display Manager: rejected for now because the repo is a local end-user utility with no auth, policy, inventory, or remote trust model.
- Cloud profile sync as a default path: rejected as a default because monitor profiles can encode hardware identity and desk setup; keep any sync opt-in and local-folder based.

## Sources
OSS:
- https://github.com/xanderfrangos/twinkle-tray
- https://github.com/emoacht/Monitorian
- https://github.com/rockowitz/ddcutil
- https://www.nirsoft.net/utils/control_my_monitor.html
- https://github.com/Defozo/ddc-ci-control-bridge
- https://github.com/MonitorControl/MonitorControl
- https://github.com/MartinGC94/MonitorConfig

Commercial:
- https://lunar.fyi/
- https://displaybuddy.app/
- https://betterdisplay.pro/
- https://www.dell.com/support/kbdoc/en-us/000060112/what-is-dell-display-manager

Platform and standards:
- https://learn.microsoft.com/en-us/windows/win32/monitor/monitor-configuration
- https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-getvcpfeatureandvcpfeaturereply
- https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature
- https://learn.microsoft.com/en-us/windows/win32/api/physicalmonitorenumerationapi/nf-physicalmonitorenumerationapi-destroyphysicalmonitor
- https://learn.microsoft.com/en-us/windows/win32/wmicoreprov/wmimonitorbrightnessmethods
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-authenticodesignature
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing

Adjacent implementation:
- https://www.home-assistant.io/integrations/light.mqtt/
- https://docs.elgato.com/streamdeck/sdk/introduction/getting-started/
- https://github.com/GameTechDev/PresentMon
- https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
- https://github.com/PowerShell/PSScriptAnalyzer
- https://github.com/pester/Pester

## Open Questions
- Which code-signing certificate, if any, should be used for a signed release artifact?
- Which monitor models should be the validation matrix for destructive VCP writes, input switching, PBP/PIP, and factory reset?
