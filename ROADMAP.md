# Roadmap

PowerShell/WPF utility for DDC/CI monitor control â€” brightness, contrast, color temp, input switching, RGB gain, gamma, VCP exploration. Roadmap prioritizes tray mode, hotkeys, and multi-GPU monitoring.

## Planned Features

## Competitive Research
- **Twinkle Tray** â€” tray leader; borrow slider popup UX and time-based automation precision.
- **Monitorian** â€” clean WPF unison-mode implementation; reference for multi-monitor grouping.
- **ClickMonitorDDC** (discontinued) â€” classic feature density; fill that gap.
- **LightBulb (Tyrrrz)** â€” gamma-based color temp with smooth transitions; match the interpolation curve.

## Nice-to-Haves
- MQTT/Home Assistant integration (monitor-as-device with brightness entity)
- NUC/mini-PC HDMI-CEC remote control compatibility
- Stream Deck plugin (brightness/input as buttons)
- Per-monitor wallpaper switcher (stretches existing WPA work)
- OSD overlay rendered by the app itself (dxgi output duplication) when monitor lacks OSD
- VCP code crowdsource database (users share supported VCPs by monitor model)

## Open-Source Research (Round 2)

### Related OSS Projects
- https://github.com/emoacht/Monitorian â€” WPF/.NET, Microsoft Store + Winget, per-monitor range adjustment, WMI + DDC/CI
- https://github.com/xanderfrangos/twinkle-tray â€” Electron tray app, hotkey bindings, brightness normalization across monitors, VCP codes (`--VCP=0xD6:5`)
- https://github.com/hensm/ddccli â€” .NET CLI, scriptable brightness/contrast
- https://github.com/ddccontrol/ddccontrol â€” classic Linux DDC/CI stack, reference for VCP code tables
- https://github.com/unix755/displayController â€” Go Windows DDC/CI package, full VCP matrix (brightness/sharpness/contrast/RGB/input/power)
- https://github.com/Defozo/ddc-ci-control-bridge â€” MCP server + MQTT client for Home Assistant integration
- https://github.com/synle/display-dj â€” cross-platform (Win/macOS) Electron DDC/CI with hotkey adjust
- https://github.com/musqz/ddc-slider â€” ddcutil backend with per-monitor controls, state cache, tray variants

### Features to Borrow
- Brightness normalization across heterogeneous panels (twinkle-tray) â€” a 50% slider produces perceptually equal brightness on all monitors
- Global hotkey bindings for brightness +/- on specific or all displays (twinkle-tray)
- Arbitrary VCP code send (e.g. `0xD6` for power mode) instead of hardcoded brightness/contrast only (twinkle-tray `--VCP`)
- MCP server interface for local automation clients (ddc-ci-control-bridge) â€” let external tools adjust monitors through a prompt or structured command
- MQTT Home Assistant integration (ddc-ci-control-bridge) â€” ties monitor state into smart home scenes
- Per-monitor adjustable range (monitor X: 20-80%, monitor Y: 0-100%) so the slider maps to each display's usable range (Monitorian)
- Brightness state cache with disk persistence (musqz/ddc-slider) â€” restore last-used values on boot before DDC handshake
- Input-source switching via VCP 0x60 (displayController Go package) â€” one-click KVM-like monitor input switching

### Patterns & Architectures Worth Studying
- WMI path vs low-level DDC/CI path â€” Monitorian falls back between them because some docks only expose one; MonitorControl should probe both
- VCP capabilities string parsing (`0xF...`) â€” interrogate monitor for supported codes instead of hardcoding (ddccontrol, Monitorian)
- Scheduled/ambient brightness automation â€” sunrise/sunset curves driving VCP 0x10 (display-dj pattern)
- Tray-only minimal UI vs full control panel â€” Monitorian ships a tray popup, Twinkle Tray a richer overlay; MonitorControl can do both with a mode switch
- Cable/dock compatibility warnings â€” VGA/DVI and some HDMI adapters break DDC, surface a "DDC not detected" banner with docs link (Monitorian compatibility notes)

## Research-Driven Additions

### P0
- [ ] P0 - Move DDC/CI calls off the WPF event thread
  Why: Slider changes, scans, profile loads, and all-monitor writes call slow monitor APIs directly from UI handlers, so a multi-monitor setup can freeze the app.
  Evidence: `MonitorControlPro.ps1:1483`, `MonitorControlPro.ps1:1533`; Microsoft documents roughly 40 ms for VCP reads and 50 ms for VCP writes.
  Touches: `MonitorControlPro.ps1` hardware wrappers, slider handlers, VCP scan, profile/app/schedule/idle apply paths.
  Acceptance: Rapid slider dragging remains responsive, writes are coalesced per monitor/code, VCP scan shows progress without `DoEvents`, and failed writes surface in status/log.
  Progress: v3.20.0 adds coalesced background writes for slider, profile, preset, and all-monitor set paths; v3.21.0 moves VCP Explorer query/scan reads to a background worker with timer-based progress; v3.22.0 moves monitor setting refresh reads to a background worker; v3.23.0 routes time-based writes through the queued path and surfaces DDC retry diagnostics for read/write failures.
  Complexity: M

### P1
### P2
- [ ] P2 - Add a copyable DDC compatibility report
  Why: DDC failures are often cable, dock, driver, GPU, or monitor-firmware issues; users need a concise report before troubleshooting.
  Evidence: ControlMyMonitor documents driver/cable/KVM error cases and a January 2026 AMD DDC/CI regression; Twinkle Tray documents dock/VGA/DVI/DDC behavior caveats.
  Touches: monitor enumeration, capabilities read, VCP read/write probes, README troubleshooting.
  Acceptance: A Diagnostics action exports monitor identities, capabilities length/status, tested VCP results, driver/GPU names, OS version, and recent DDC errors with no private user paths.
  Complexity: M

- [ ] P2 - Add optional local automation bridge with network-off default
  Why: Existing roadmap mentions MQTT/Home Assistant and local protocol control, but the safe foundation is a disabled-by-default localhost bridge with explicit API key and command allowlist.
  Evidence: ddc-ci-control-bridge provides MCP/MQTT patterns; Home Assistant MQTT Light defines brightness/state integration conventions.
  Touches: optional listener module, config JSON, tray/status indicator, README security notes.
  Acceptance: Bridge is off by default, binds only to localhost unless changed, requires an API key for writes, supports list/read/set brightness/profile, logs all writes, and MQTT/Home Assistant remains opt-in.
  Complexity: L

- [ ] P2 - Add no-hardware parser and storage tests
  Why: The repo has no test harness despite growing schedule/profile/VCP parsing logic; many failures can be caught without monitor hardware.
  Evidence: PowerShell Parser check passes today, but there are no Pester tests; PSScriptAnalyzer and Pester are standard PowerShell quality tools.
  Touches: `tests/`, extracted pure functions or dot-source-safe test harness, local test command docs.
  Acceptance: Local tests cover schedule rollover, idle tick wraparound, profile migration/quarantine, filename validation, capabilities parsing, and VCP value parsing without needing DDC hardware.
  Complexity: M
