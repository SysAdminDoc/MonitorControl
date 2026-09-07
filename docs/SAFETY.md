# Safety and DDC behavior

DDC/CI gives software direct access to a monitor's firmware controls. Brightness and contrast are widely supported. Other commands vary, and some panels report incomplete or incorrect capability data.

MonitorControl Pro treats monitor firmware as an unreliable hardware boundary.

## Capability discovery

Full capability strings are useful because they list supported VCP codes and legal values. They are also one of the least reliable parts of the DDC standard on Windows.

On first launch, MonitorControl asks whether it may request them. If you allow discovery:

- A crash sentinel is written before every native request and cleared only after it returns.
- A successful result is cached by stable monitor identity.
- An interrupted request disables discovery on the next launch and excludes that display.
- Shipped emergency blocks and the versioned compatibility database are checked before a request.

Maximum compatibility mode skips all capability-string requests. You can also exclude one monitor and leave discovery enabled for the rest.

## Risky writes

Brightness, contrast, RGB gain, volume, and sharpness use the routine write path. Power, input, reset, color presets, picture modes, OSD settings, PiP/PbP, and arbitrary VCP codes use the protected path.

A protected write requires a saved unlock for the monitor's stable identity. The GUI then shows the exact code and value before each direct action. Automation needs its own consent as well. Command-line use needs `-AllowRisky`.

Unlocking one display does not unlock another.

## Verification and rollback

Before a protected transaction, MonitorControl reads every value that can be read safely. Writes are issued in a stable order and read back after the monitor's calibrated delay.

The result is reported as verified, mismatched, unavailable, or unreliable. A mismatch rolls readable settings back in reverse order. If a monitor accepts a write but cannot provide trustworthy readback, the app says so instead of claiming verification.

## Timing and recovery

Some displays answer in a few milliseconds. Others need longer waits, especially after sleep or an input change. Timing is stored per identity, and automatic calibration does not change another monitor's delay.

A read-only liveness probe checks one inexpensive supported code every 60 seconds while the DDC pipeline is idle. If one monitor stops answering while others remain healthy, stale physical handles are released and reacquired once for that recovery generation.

## Writes that do not persist

Some panels accept a setting and then revert after power loss. **Save settings to the monitor after a write** sends VCP `0xB0` only after a transaction has fully succeeded. It is disabled by default and rate limited to one save per display every ten seconds.

Do not enable it as a general fix. The command can write to limited-endurance monitor storage.

## Connection limits

The following paths often have no usable DDC channel:

- DisplayLink and other indirect display drivers
- Remote desktop and virtual displays
- KVMs, docks, or adapters that do not forward DDC
- DisplayPort cables or monitor inputs with incomplete DDC wiring
- A monitor with DDC/CI disabled in its on-screen menu

Connect the display directly to a GPU with a known-good cable before assuming the application is at fault.

## Support bundles

The Diagnostics page previews a text report and can package it with structured JSON plus a checksum manifest. Monitor identities and local names are pseudonymized by default. Paths, Windows user and machine names, email addresses, network addresses, and credential-like values are always redacted.

Review the preview before posting it to an issue.
