# Command-line reference

The standalone release script can list displays, read or write VCP values, apply profiles, and collect diagnostics without creating the WPF window. Commands run in a bounded Windows PowerShell 5.1 worker. The default timeout is 10 seconds, and `-TimeoutSeconds` accepts values from 1 through 120.

## Find a monitor identity

```powershell
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 list
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 list -Json
```

Use the stable identity printed by `list` whenever more than one controllable display is connected.

## Read and write VCP values

```powershell
# Read brightness, VCP 0x10
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 get 0x10 `
  -Monitor "winrt:0123456789abcdef" -Json

# Write a raw MCCS value
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 set -Vcp 0x10 -Value 50 `
  -Monitor "winrt:0123456789abcdef" -IfNeeded

# Move relative to the current value
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 set -Vcp 0x10 -Delta -5 `
  -Monitor "winrt:0123456789abcdef"

# Move to the next declared value
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 set -Vcp 0xDC -Cycle "0,1,3,5" `
  -Monitor "winrt:0123456789abcdef"
```

`-IfNeeded` reads first and sends no write when the target already has the requested value. `-Delta` applies a signed change. `-Cycle` selects the value after the current one from a comma-separated list.

## Short aliases

Brightness aliases use percentages. Input aliases map to the standard MCCS values reported by the target.

```powershell
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 b 50 `
  -Monitor "winrt:0123456789abcdef"

powershell.exe -NoProfile -File .\MonitorControlPro.ps1 s hdmi1 `
  -Monitor "winrt:0123456789abcdef" -AllowRisky
```

Input names are `vga`, `dvi`, `dp1`, `dp2`, `hdmi1`, `hdmi2`, and `usbc`.

## Profiles and diagnostics

```powershell
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 profile "Work" -Json
powershell.exe -NoProfile -File .\MonitorControlPro.ps1 diagnostics -Json
```

Profile apply uses the same stable identity matching, support checks, snapshot, readback, and rollback path as the GUI.

## Risky commands

Power, input, reset, OSD, PiP/PbP, and arbitrary codes do not prompt in command-line mode. They require both of these signals:

- The display identity must already be unlocked under **System > Safety**.
- The command must include `-AllowRisky`.

The worker fails before writing when either signal is missing.

## JSON envelope

`-Json` emits one schema-v1 envelope:

```json
{"SchemaVersion":1,"Command":"get","Success":true,"ExitCode":0,"Data":{"Identity":"winrt:0123456789abcdef","Vcp":"0x10","Current":50,"Maximum":100,"Type":0},"Error":null}
```

The contract is stored in [`schemas/monitorcontrol-cli-v1.schema.json`](../schemas/monitorcontrol-cli-v1.schema.json) and ships in the release ZIP. Readers should check `SchemaVersion` and ignore unknown fields. Errors include a stable code and a readable message.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success, including an `-IfNeeded` no-op |
| `2` | Invalid command, option, code, value, cycle, or profile data |
| `3` | Monitor or profile not found, ambiguous monitor, or unsupported advertised value |
| `4` | Worker timed out and was terminated |
| `5` | Monitor read, write, verification, or profile transaction failed |
| `6` | Risky write denied by the shared per-identity policy |
| `10` | Unexpected startup or worker failure |

## Local bridge routes

The optional local bridge uses the same monitor selectors and percentage conversion as the CLI.

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/health` | Empty health check. This exact body-free route is the only unauthenticated request. |
| `GET` | `/api/monitors` | List connected displays and stable identities. |
| `GET` | `/api/profiles` | List saved profiles. |
| `GET` | `/api/brightness` | Read percentage, raw value, and reported maximum. |
| `POST` | `/api/brightness` | Set a percentage for an optional monitor selector. |
| `POST` | `/api/profile` | Apply a named profile. |

Authenticated routes accept the key through `X-MonitorControl-Key` or `Authorization: Bearer`. Query-string and JSON-body keys are rejected.
