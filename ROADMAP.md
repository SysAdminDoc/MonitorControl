# Roadmap

PowerShell/WPF utility for DDC/CI monitor control — brightness, contrast, color temp, input switching, RGB gain, gamma, VCP exploration. Roadmap prioritizes tray mode, hotkeys, and multi-GPU monitoring.

## Planned Features

### System Tray Mode
- Persistent tray icon with brightness slider popup (like Twinkle Tray)
- Per-monitor unison group / link mode
- Auto-hide main window to tray on minimize
- Tray-click cycling through saved profiles

### Hotkeys & Automation
- Global hotkey registration (RegisterHotKey WinAPI) — brightness up/down, input switch, profile cycle
- Per-application profile switching (monitor foreground window exe → apply profile)
- Scheduled profile switching (sunrise/sunset via SunCalc, or explicit times)
- Idle-dim on inactivity (GetLastInputInfo polling)

### Display Controls
- Extended VCP set: Gamma (0x72), OSD Language (0xCC), OSD Transparency, Power Indicator LED
- Dynamic contrast toggle (VCP 0xFC where supported)
- Picture mode presets (Cinema/Game/Web) via VCP 0xDC
- Dual-Input PiP/PbP control for ultrawide monitors that support it

### GPU Monitoring
- NVAPI integration for Digital Vibrance (stop being a placeholder)
- AMD ADL SDK for Radeon temperature/clock/fan
- Intel Arc / iGPU monitoring via IGCL
- CPU temperature via LibreHardwareMonitor/OpenHardwareMonitor lib
- Per-GPU FPS overlay (PresentMon integration)

### Laptop Support
- WMI fallback (`WmiMonitorBrightnessMethods`) for integrated laptop displays
- Ambient light sensor polling (`ILightSensor`) for auto-brightness
- Battery-aware profile: dim on battery, bright on AC

### Data & Profiles
- Profile JSON schema version + migration on load
- Export/import profile bundle (all profiles at once)
- Cloud-sync profiles via OneDrive/Dropbox folder pointer
- Profile scheduling UI (graphical timeline, not just trigger rules)

## Competitive Research
- **Twinkle Tray** — tray leader; borrow slider popup UX and time-based automation precision.
- **Monitorian** — clean WPF unison-mode implementation; reference for multi-monitor grouping.
- **ClickMonitorDDC** (discontinued) — classic feature density; fill that gap.
- **LightBulb (Tyrrrz)** — gamma-based color temp with smooth transitions; match the interpolation curve.

## Nice-to-Haves
- MQTT/Home Assistant integration (monitor-as-device with brightness entity)
- NUC/mini-PC HDMI-CEC remote control compatibility
- Stream Deck plugin (brightness/input as buttons)
- Per-monitor wallpaper switcher (stretches existing WPA work)
- OSD overlay rendered by the app itself (dxgi output duplication) when monitor lacks OSD
- VCP code crowdsource database (users share supported VCPs by monitor model)

## Open-Source Research (Round 2)

### Related OSS Projects
- https://github.com/emoacht/Monitorian — WPF/.NET, Microsoft Store + Winget, per-monitor range adjustment, WMI + DDC/CI
- https://github.com/xanderfrangos/twinkle-tray — Electron tray app, hotkey bindings, brightness normalization across monitors, VCP codes (`--VCP=0xD6:5`)
- https://github.com/hensm/ddccli — .NET CLI, scriptable brightness/contrast
- https://github.com/ddccontrol/ddccontrol — classic Linux DDC/CI stack, reference for VCP code tables
- https://github.com/unix755/displayController — Go Windows DDC/CI package, full VCP matrix (brightness/sharpness/contrast/RGB/input/power)
- https://github.com/Defozo/ddc-ci-control-bridge — MCP server + MQTT client for Home Assistant integration
- https://github.com/synle/display-dj — cross-platform (Win/macOS) Electron DDC/CI with hotkey adjust
- https://github.com/musqz/ddc-slider — ddcutil backend with per-monitor controls, state cache, tray variants

### Features to Borrow
- Brightness normalization across heterogeneous panels (twinkle-tray) — a 50% slider produces perceptually equal brightness on all monitors
- Global hotkey bindings for brightness +/- on specific or all displays (twinkle-tray)
- Arbitrary VCP code send (e.g. `0xD6` for power mode) instead of hardcoded brightness/contrast only (twinkle-tray `--VCP`)
- MCP server interface for AI/agent integration (ddc-ci-control-bridge) — let Claude/Copilot adjust monitors via prompt
- MQTT Home Assistant integration (ddc-ci-control-bridge) — ties monitor state into smart home scenes
- Per-monitor adjustable range (monitor X: 20-80%, monitor Y: 0-100%) so the slider maps to each display's usable range (Monitorian)
- Brightness state cache with disk persistence (musqz/ddc-slider) — restore last-used values on boot before DDC handshake
- Input-source switching via VCP 0x60 (displayController Go package) — one-click KVM-like monitor input switching

### Patterns & Architectures Worth Studying
- WMI path vs low-level DDC/CI path — Monitorian falls back between them because some docks only expose one; MonitorControl should probe both
- VCP capabilities string parsing (`0xF...`) — interrogate monitor for supported codes instead of hardcoding (ddccontrol, Monitorian)
- Scheduled/ambient brightness automation — sunrise/sunset curves driving VCP 0x10 (display-dj pattern)
- Tray-only minimal UI vs full control panel — Monitorian ships a tray popup, Twinkle Tray a richer overlay; MonitorControl can do both with a mode switch
- Cable/dock compatibility warnings — VGA/DVI and some HDMI adapters break DDC, surface a "DDC not detected" banner with docs link (Monitorian compatibility notes)
