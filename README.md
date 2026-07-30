# MonitorControl Pro

<p align="center">
  <img src="https://img.shields.io/badge/Version-v3.34.0-brightgreen" alt="Version v3.34.0">
  <img src="https://img.shields.io/badge/PowerShell-5.1+-blue?logo=powershell" alt="PowerShell 5.1+">
  <img src="https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows" alt="Windows 10/11">
  <img src="https://img.shields.io/badge/DDC%2FCI-Supported-green" alt="DDC/CI">
  <img src="https://img.shields.io/badge/License-MIT-yellow" alt="MIT License">
</p>

A comprehensive Windows GUI utility for controlling monitor settings via DDC/CI protocol. Adjust brightness, contrast, color temperature, input sources, and more — all without touching your monitor's physical buttons.

<p align="center">
  <img src="screenshot.png" alt="MonitorControl Pro display dashboard" width="900">
</p>

## Features

### Display Controls
- **Modern Control Center** — Persistent sidebar navigation, selected-display context, high-contrast control cards, and DPI-aware layouts for a clearer Windows 10/11 experience
- **Brightness & Contrast** — Real-time adjustment via DDC/CI
- **RGB Gain Control** — Fine-tune red, green, and blue channels independently
- **Color Temperature Presets** — Quick access to Warm (5000K), 6500K (D65), Cool (9300K), and sRGB
- **Sharpness Control** — Adjust display sharpness if supported
- **Dynamic Contrast** — Switch display mode between standard (`0x00`) and dynamic contrast (`0xF0`) through VCP `0xDC` on monitors that expose it
- **Picture Mode Presets** — Apply Web/Productivity (`0x01`), Cinema/Movie (`0x03`), or Game (`0x05`) display modes through VCP `0xDC`

### Monitor Management
- **Visual Monitor Layout** — Click-to-select interface matching Windows Display Settings
- **Input Source Switching** — Switch between HDMI, DisplayPort, USB-C, DVI, VGA
- **Power Control** — Turn monitors On, Standby, or Off via software
- **PiP / PbP Controls** — Toggle vendor-defined PiP/PbP modes and secondary input routing for ultrawide monitors that expose those DDC/CI controls
- **Apply to All Monitors** — Sync settings across all connected displays
- **Monitor Identification** — On-screen overlays showing monitor numbers
- **Laptop Brightness Fallback** — Uses `WmiMonitorBrightnessMethods` for integrated displays when DDC/CI handles are unavailable
- **Safe Monitor Refresh** — Re-enumeration and app close destroy stale physical-monitor handles once before replacing the monitor list

### Automation
- **System Tray Mode** - Persistent notification-area icon with a brightness popup, linked-monitor toggle, and profile cycling
- **Per-Application Profiles** - Watch the foreground app and automatically apply a saved profile when its executable matches a rule
- **Scheduled Profiles** - Apply saved profiles automatically from explicit `HH:mm` daily schedule rules with a 24-hour timeline view
- **Idle Dim** - Poll Windows idle time and dim all monitors after inactivity, with optional brightness restore on activity
- **Ambient Light Mode** - Poll Windows `LightSensor` readings and map lux to monitor brightness automatically when a sensor is available
- **Battery Profile** - Apply separate brightness targets when Windows switches between AC power and battery
- **Local Automation Bridge** - Disabled-by-default localhost HTTP bridge for list/read brightness, set brightness, and profile load commands
- **Auto Mode** - Automatic brightness and color temperature based on time of day:
  - Day (7 AM - 6 PM): 80% brightness, neutral colors
  - Evening (6 PM - 9 PM): 60% brightness, slightly warm
  - Night (9 PM - 7 AM): 40% brightness, warm/reduced blue light
- **Profile System** — Save and load custom configurations
- **Hardened Profile Storage** — Profile and automation JSON writes use atomic replacement, valid backups, corrupt-file quarantine, and filename validation
- **Command-line Support** — Launch minimized or with a specific profile

### Advanced Features
- **VCP Explorer** — Query and set any VCP code for advanced users
- **VCP Code Scanner** — Discover which DDC/CI features your monitor supports, including extended MCCS codes for gamma, OSD controls, indicators, auxiliary power, and display modes
- **Capabilities-Aware Controls** — Parses monitor `vcp(...)` capabilities, disables controls that are known unsupported, and can scan either reported capabilities or the full probe table
- **Crash-Safe Capability Discovery** — Requires explicit consent, persists a per-probe crash sentinel, automatically excludes an interrupted monitor identity, and offers a maximum-compatibility mode that never requests capability strings
- **Stable Monitor Identity** — Stores EDID/device-path backed monitor identities, supports custom display labels, and targets saved profiles by identity after reordering
- **System-Aware Accessibility** — Follows Windows high contrast live, supports 100–200% text scaling with independently scrollable content and navigation, exposes visible keyboard focus and UI Automation names, and raises native live-region events for inline errors
- **Portable Release ZIP** — Local release builds package the script, icon, README, LICENSE, signature status, and SHA256 checksums
- **Verified Risky Writes** — Power, input, reset, PiP/PbP, and arbitrary commands require a per-monitor identity unlock plus an exact code/value confirmation; readback reports verified, mismatched, or unavailable outcomes
- **Async Capabilities Reads** — Monitor `vcp(...)` capabilities load from a background worker after enumeration, keeping refresh responsive
- **DDC Compatibility Report** — Builds a copyable diagnostics report with monitor identities, capability status, common VCP probe results, OS/GPU driver data, and recent DDC errors
- **No-Hardware Regression Tests** — Pester tests cover schedule rollover, idle tick wraparound, profile transactions, hostile bundles, capability safety, risky-write rollback, bridge framing/auth, and VCP input parsing
- **Async VCP Reads** — VCP Explorer query and scan operations run in a background worker with live scan progress
- **Async Monitor Refresh** — Monitor brightness, contrast, color gain, volume, and sharpness reads refresh from a background worker
- **Coalesced Routine Writes** — Sliders, presets, and brightness automation queue on a background worker so rapid routine changes do not block the WPF thread
- **Recoverable Profile Apply** — Profile loads snapshot every readable hardware value, verify writes, and restore readable prior values in reverse order after a failure or mismatch
- **DDC/CI Diagnostics** — Failed reads and writes include monitor name, VCP code, attempted value, Win32 error, and retry count in a copyable VCP Explorer summary
- **DDC/CI Capabilities Viewer** — View raw capabilities string from monitor
- **Software Gamma Control** — Independent RGB gamma curves via Windows API
- **Factory Reset** — Reset monitor to factory defaults (colors only or full reset)

### GPU Monitoring (NVIDIA / AMD)
- Real-time temperature, utilization, and clock speed
- Memory usage and fan speed
- Power draw monitoring
- Digital vibrance slider using NVAPI DVC where supported
- AMD Radeon temperature, utilization, engine/memory clocks, and fan percent via ADL where supported by the installed driver
- CPU package/core temperature via LibreHardwareMonitorLib or OpenHardwareMonitorLib when either library is installed or placed next to the script
- PresentMon-powered FPS overlay when `PresentMon.exe` or `PresentMon64.exe` is installed or placed next to the script

## Requirements

- **Windows 10/11**
- **PowerShell 5.1+** (included with Windows)
- **DDC/CI Compatible Monitor** — Most modern monitors support this; ensure it's enabled in your monitor's OSD settings
- **NVIDIA or AMD GPU** (optional) — For GPU monitoring tab
- **LibreHardwareMonitorLib.dll or OpenHardwareMonitorLib.dll** (optional) — For CPU temperature on the hardware tab
- **PresentMon.exe** (optional) — For FPS overlay capture on the hardware tab

## Installation

### Option 1: Portable Release ZIP
1. Download `MonitorControlPro-vX.Y.Z.zip` from the GitHub release.
2. Extract the ZIP to a writable folder.
3. Verify `SHA256SUMS`, then run `MonitorControlPro.ps1`.

### Option 2: From PowerShell
```powershell
irm https://raw.githubusercontent.com/SysAdminDoc/MonitorControl/main/MonitorControlPro.ps1 -OutFile MonitorControlPro.ps1
.\MonitorControlPro.ps1
```

### Option 3: Create a Shortcut
```powershell
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\MonitorControl Pro.lnk")
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PWD\MonitorControlPro.ps1`""
$Shortcut.IconLocation = "imageres.dll,109"
$Shortcut.Save()
```

### Build a Release ZIP
```powershell
.\tools\build-release.ps1
```

The release builder writes an unsigned `dist\MonitorControlPro-vX.Y.Z.zip` and includes `SIGNING.txt` plus `SHA256SUMS` in the ZIP.

### Run No-Hardware Tests
```powershell
.\tools\run-tests.ps1
```

The deterministic suite requires Pester 5.8.0 and imports only selected function definitions from `MonitorControlPro.ps1`, so it does not enumerate displays, open the WPF app, or require DDC/CI hardware.

### Run the Full Windows Verification Lane
```powershell
# Run from Windows PowerShell 5.1
Install-Module Pester -RequiredVersion 5.8.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
.\tools\verify.ps1
```

This is the same pinned lane used by CI. It gates static-analysis errors, deterministic protocol/persistence/concurrency tests, isolated standard and high-contrast/200%-text UI Automation smokes, native accessibility-event delivery, and an unsigned portable ZIP build. The WPF smoke tests redirect `APPDATA` and `LOCALAPPDATA` to disposable directories and verify that the real `%APPDATA%\MonitorControlPro` tree is unchanged.

## Usage

### Basic Usage
```powershell
.\MonitorControlPro.ps1
```

### Command-Line Parameters
```powershell
# Start minimized (useful for startup)
.\MonitorControlPro.ps1 -StartMinimized

# Load a specific profile on launch
.\MonitorControlPro.ps1 -LoadProfile "Gaming"

# Combined
.\MonitorControlPro.ps1 -StartMinimized -LoadProfile "Night Mode"

# Force an accessibility theme or text scale for validation
.\MonitorControlPro.ps1 -Theme HighContrast -TextScalePercent 200
```

`-Theme System` (the default) follows live Windows high-contrast changes. `-Theme Dark` and `-Theme HighContrast` are explicit overrides. `-TextScalePercent 0` (the default) follows the Windows text-size setting; values from 100 through 200 override it.

### Tray Mode
- Minimize the window to keep MonitorControl running from the notification area
- Click the tray icon to open the compact brightness popup
- Double-click the tray icon or use **Next Profile** in the tray menu to cycle saved profiles
- Use **Link Monitors** in the tray popup or menu to apply brightness changes to every detected monitor

### Per-Application Profiles
- Create or load a saved monitor profile
- Open the **Profiles** tab, enable **Per-application profiles**, and map an executable name such as `photoshop.exe` to a profile
- Use **Capture** to grab the foreground executable after a short delay, or type the executable name directly
- Leave **Risky writes** off unless that exact application rule should be allowed to use risky profile values; enabling it shows a separate rule-level warning and does not bypass the per-monitor unlock
- Rules are saved in `%APPDATA%\MonitorControlPro\app-profile-rules.json`

### Scheduled Profiles
- Create or load a saved monitor profile
- Open the **Schedule** tab, enable **Scheduled profiles**, and add `HH:mm` rules that map times to profiles
- Leave **Risky writes** off unless that exact schedule rule should be allowed to use risky profile values; the target monitor identity must still be unlocked separately
- The timeline plots rules against a 24-hour axis so timing gaps are visible before saving more rules
- The watcher applies the latest due rule once per schedule boundary, including the current effective rule when scheduling is enabled
- Rules are saved in `%APPDATA%\MonitorControlPro\profile-schedules.json`

### Idle Dim
- Open the **Schedule** tab and enable **Idle dim**
- Set the idle threshold in minutes, target brightness, and whether activity should restore the previous brightness
- Settings are saved in `%APPDATA%\MonitorControlPro\idle-dim.json`

### Local Automation Bridge
- Open the **System** tab and enable **Local Automation Bridge** only when needed
- Default bind is `127.0.0.1:34291`; enabling a non-loopback address requires an explicit network-exposure warning because the bridge uses unencrypted HTTP
- Only an exact, body-free `GET /api/health` is unauthenticated; every other request requires the generated key through `X-MonitorControl-Key` or `Authorization: Bearer <key>`
- Query-string and JSON-body API keys are rejected, and the saved key is encrypted for the current Windows user with DPAPI
- The listener enforces request-line, header-count, header-size, body-size, response-size, concurrency, and socket-deadline limits; malformed framing receives a deterministic 4xx response
- Supported endpoints are `GET /api/health`, `GET /api/monitors`, `GET /api/profiles`, `GET /api/brightness`, `POST /api/brightness`, and `POST /api/profile`
- MQTT/Home Assistant integration remains disabled; use the bridge as the local foundation before enabling network integrations

### Capability Discovery Safety
- On first launch, choose whether MonitorControl Pro may request full DDC/CI capability strings from monitor firmware
- Choose **No** or enable **Maximum compatibility** in **System** to prevent all capability-string requests
- Before each enabled request, the app persists the selected monitor identity in a crash sentinel and clears it only after the native call returns
- If the app or Windows exits during a request, discovery is disabled on the next launch and that monitor identity is excluded
- Use **Exclude selected** or **Clear exclusions** in **System** to manage the per-monitor exclusion list

### Risky VCP Write Safety
- Risky controls start disabled. Select a display, open **System**, and explicitly enable risky VCP writes for that stable monitor identity
- The unlock covers power, input, reset, PiP/PbP, and arbitrary VCP writes; identities without a stable key cannot be unlocked
- Every direct command shows the exact VCP code, value, and target before writing. Canceling makes no hardware change
- The app reads each supported value back and distinguishes **verified**, **mismatched**, and **readback unavailable** outcomes
- Profile loads snapshot every readable prior DDC/WMI value and restore those values in reverse order when a write fails or reads back incorrectly
- Automatic compatibility reports omit risky VCP codes; VCP Explorer reads remain explicitly user initiated

### Navigation
- Click on monitor rectangles to select different displays
- Use Tab and Shift+Tab to navigate every interactive control; focus has a visible system-aware outline
- Use Alt+D/M/H/V/P/A/S to open Display, Monitor, Hardware, VCP Explorer, Profiles, Automation, or System
- Use Ctrl+R to refresh displays and Escape to dismiss an inline alert
- Slider values update in real-time

## VCP Code Reference

The VCP Explorer tab allows you to query and set any DDC/CI VCP code. Common codes:

| Code | Name | Range | Description |
|------|------|-------|-------------|
| `0x10` | Brightness | 0-100 | Display brightness level |
| `0x12` | Contrast | 0-100 | Display contrast level |
| `0x14` | Color Preset | varies | Color temperature preset |
| `0x16` | Red Gain | 0-100 | Red channel gain |
| `0x18` | Green Gain | 0-100 | Green channel gain |
| `0x1A` | Blue Gain | 0-100 | Blue channel gain |
| `0x60` | Input Source | varies | Active input selection |
| `0x62` | Volume | 0-100 | Speaker volume (if available) |
| `0x72` | Gamma | varies | Hardware gamma control when exposed by the monitor |
| `0x87` | Sharpness | 0-100 | Image sharpness |
| `0x8D` | Audio Mute | 1/2 | Mute speakers |
| `0xC0` | Display Usage Time | read-only | Panel usage counter |
| `0xC6` | Application Enable Key | varies | Vendor/application enable key |
| `0xCA` | OSD/Button Control | varies | Monitor OSD and button behavior |
| `0xCC` | OSD Language | varies | Monitor on-screen display language |
| `0xCD` | Status Indicators / LED | varies | Status indicator and power LED behavior when supported |
| `0xD6` | Power Mode | 1-5 | Power state control |
| `0xD7` | Aux Power Output | varies | Auxiliary power output control when supported |
| `0xDC` | Display Mode | varies | Preset picture/display modes |
| `0xDF` | VCP Version | read-only | Monitor VCP/MCCS version |
| `0xE8` | Secondary Input Source | vendor-defined | Secondary PiP/PbP input on some Dell-style ultrawides |
| `0xE9` | PiP/PbP Mode | vendor-defined | PiP/PbP mode on some Dell-style ultrawides |
| `0x04` | Factory Reset | 1 | Reset all settings |
| `0x08` | Color Reset | 1 | Reset color settings only |

### Input Source Values
| Value | Input |
|-------|-------|
| `0x01` | VGA |
| `0x03` | DVI |
| `0x0F` | DisplayPort 1 |
| `0x10` | DisplayPort 2 |
| `0x11` | HDMI 1 |
| `0x12` | HDMI 2 |
| `0x13` | USB-C |

### PiP / PbP Vendor Values
| Code | Value | Meaning |
|------|-------|---------|
| `0xE9` | `0x00` | PiP/PbP off |
| `0xE9` | `0x21` | PiP upper-right |
| `0xE9` | `0x23` | PbP split |
| `0xE8` | `0x21` | Secondary DisplayPort |
| `0xE8` | `0x11` | Secondary HDMI 1 |
| `0xE8` | `0x12` | Secondary HDMI 2 |

### Power Mode Values
| Value | State |
|-------|-------|
| `0x01` | On |
| `0x02` | Standby |
| `0x04` | Off |

### Display Mode Values
| Value | Mode |
|-------|------|
| `0x00` | Standard / default |
| `0x01` | Productivity / Web |
| `0x03` | Movie / Cinema |
| `0x05` | Games |
| `0xF0` | Dynamic Contrast |

## Profiles

Profiles are saved as JSON files in `%APPDATA%\MonitorControlPro\`

### Profile Contents
```json
{
  "SchemaVersion": 3,
  "Name": "Gaming",
  "MonitorIdentityKey": "edid:0123456789abcdef",
  "MonitorLabel": "Desk Left",
  "MonitorName": "Generic PnP Monitor",
  "MonitorDevicePath": "MONITOR\\ABC1234\\...",
  "MonitorSettings": [
    {
      "IdentityKey": "edid:0123456789abcdef",
      "MonitorLabel": "Desk Left",
      "Brightness": 80,
      "Contrast": 70,
      "Red": 50,
      "Green": 50,
      "Blue": 50,
      "Gamma": 100,
      "GammaRed": 100,
      "GammaGreen": 100,
      "GammaBlue": 100
    }
  ],
  "Brightness": 80,
  "Contrast": 70,
  "Red": 50,
  "Green": 50,
  "Blue": 50,
  "Gamma": 100,
  "GammaRed": 100,
  "GammaGreen": 100,
  "GammaBlue": 100,
  "UpdatedAt": "2026-06-28T10:30:00.0000000-04:00"
}
```

Profiles without `SchemaVersion` are treated as v1 and migrated to the current schema on load.

Use **Export Bundle** on the Profiles tab to create a manifest-declared, SHA-256 checksummed ZIP in `%APPDATA%\MonitorControlPro\exports`.
Use **Import Bundle** to preview creates, replacements, and skipped conflicts before writing. Imports reject unsafe paths, undeclared or duplicate entries, unsupported schemas, invalid values, oversized content, and suspicious compression ratios.
Accepted profiles are staged on the profile volume and committed as one transaction; a write failure restores every prior profile byte-for-byte and removes newly created destinations.
Use **Sync Folder** to point profile storage at a OneDrive or Dropbox folder. The pointer is stored in `%APPDATA%\MonitorControlPro\profile-storage.json`; **Use Local** switches back to `%APPDATA%\MonitorControlPro`.

### Example Profiles

**Night Mode** — Reduced brightness and blue light
```json
{
  "Name": "Night Mode",
  "Brightness": 35,
  "Contrast": 50,
  "Red": 50,
  "Green": 48,
  "Blue": 40,
  "Gamma": 100,
  "GammaRed": 100,
  "GammaGreen": 95,
  "GammaBlue": 80
}
```

**Photography** — Accurate colors for editing
```json
{
  "Name": "Photography",
  "Brightness": 50,
  "Contrast": 50,
  "Red": 50,
  "Green": 50,
  "Blue": 50,
  "Gamma": 100,
  "GammaRed": 100,
  "GammaGreen": 100,
  "GammaBlue": 100
}
```

## Troubleshooting

### Monitor Not Detected
1. **Enable DDC/CI** — Check your monitor's OSD settings for DDC/CI option and ensure it's enabled
2. **Check Cable** — DDC/CI works best over DisplayPort and HDMI; some adapters don't pass through DDC/CI signals
3. **Try Different Port** — Some monitor ports may have DDC/CI disabled

### Settings Not Applying
- Some monitors have a delay (~50ms per command)
- Certain VCP codes may not be supported by your specific monitor
- Use the VCP Scanner to discover which features your monitor actually supports
- Open **System** and build the **DDC Compatibility Report** before troubleshooting docks, adapters, GPU drivers, KVMs, or firmware quirks
- Failed DDC/CI reads and writes are retried automatically and surfaced in the status bar; open **VCP Explorer** to copy the latest diagnostic summary with monitor name, VCP code, attempted value, Win32 error, and retry count

### Laptop Display Not Working
Laptop integrated displays typically don't support DDC/CI. Use Windows brightness controls or WMI-based tools instead.

### "No DDC/CI Monitor" Message
Your monitor either:
- Doesn't support DDC/CI
- Has DDC/CI disabled in OSD
- Is connected through an incompatible adapter/dock

## Technical Details

### APIs Used
- **dxva2.dll** — Windows DDC/CI implementation
  - `GetPhysicalMonitorsFromHMONITOR`
  - `GetVCPFeatureAndVCPFeatureReply`
  - `SetVCPFeature`
  - `CapabilitiesRequestAndCapabilitiesReply`
- **gdi32.dll** — Software gamma control
  - `SetDeviceGammaRamp`
- **user32.dll** — Monitor enumeration
  - `EnumDisplayMonitors`
  - `GetMonitorInfo`

### Data Storage
- Profiles: `%APPDATA%\MonitorControlPro\*.json`
- Automation bridge settings: `%APPDATA%\MonitorControlPro\automation-bridge.json` (API key protected with current-user DPAPI)
- Automation bridge write log: `%APPDATA%\MonitorControlPro\automation-bridge-writes.jsonl` (redacted and size-rotated)
- Risky VCP identity unlocks: `%APPDATA%\MonitorControlPro\vcp-write-safety.json`
- No registry modifications
- No admin rights required

## Inspiration & Credits

This project was inspired by and incorporates concepts from these excellent open-source projects:

- **[Twinkle Tray](https://github.com/xanderfrangos/twinkle-tray)** — System tray brightness control, time-based automation
- **[Monitorian](https://github.com/emoacht/Monitorian)** — Clean WPF implementation, unison mode concept
- **[ControlMyMonitor](https://www.nirsoft.net/utils/control_my_monitor.html)** — Comprehensive VCP exploration
- **[MonitorConfig](https://github.com/MartinGC94/MonitorConfig)** — PowerShell DDC/CI module
- **[LightBulb](https://github.com/Tyrrrz/LightBulb)** — Gamma-based color temperature
- **[display-switch](https://github.com/haimgel/display-switch)** — Input source switching concepts

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup
1. Clone the repository
2. Edit `MonitorControlPro.ps1` in your preferred editor (VS Code with PowerShell extension recommended)
3. Test changes by running the script directly

### Areas for Improvement
- [ ] Multi-monitor profile linking
- [ ] WMI fallback for laptop displays

## License

MIT License — see [LICENSE](LICENSE) for details.

## Disclaimer

This software interacts with monitor hardware via DDC/CI protocol. While DDC/CI is a standard protocol and this software uses official Windows APIs, use at your own risk. The author is not responsible for any damage to monitors or other hardware.

---

<p align="center">
  Made with PowerShell and WPF<br>
  <a href="https://github.com/SysAdminDoc/MonitorControl/issues">Report Bug</a> ·
  <a href="https://github.com/SysAdminDoc/MonitorControl/issues">Request Feature</a>
</p>
