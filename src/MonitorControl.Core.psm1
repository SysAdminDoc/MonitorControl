# MonitorControl Pro Core source module.

# Dot-sourced by the development launcher and composed into the portable release.



function Get-HexTokens {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @([regex]::Matches($Text, '(?i)\b(?:0x)?[0-9a-f]{1,2}\b') | ForEach-Object {
        $token = $_.Value
        if ($token.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) { $token = $token.Substring(2) }
        [Convert]::ToInt32($token, 16)
    })
}

function Get-StableHash {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Test-DisplayWorkerResultCurrent {
    param($Result, [int]$CurrentGeneration, [object[]]$Monitors)
    if ($null -eq $Result) { return $false }
    $properties = @($Result.PSObject.Properties.Name)
    if ($properties -notcontains "Generation" -or [int]$Result.Generation -ne $CurrentGeneration) { return $false }
    if ($properties -notcontains "MonitorIndex") { return $false }
    $monitorIndex = [int]$Result.MonitorIndex
    if ($monitorIndex -lt 0 -or $monitorIndex -ge @($Monitors).Count) { return $false }
    $monitor = @($Monitors)[$monitorIndex]
    if ($null -eq $monitor -or $properties -notcontains "IdentityKey") { return $false }
    $resultIdentity = [string]$Result.IdentityKey
    if ([string]::IsNullOrWhiteSpace($resultIdentity) -or $resultIdentity -ne [string]$monitor.IdentityKey) { return $false }
    if ($properties -contains "HandleValue") {
        if ($monitor.PSObject.Properties.Name -notcontains "Handle") { return $false }
        if ([int64]$Result.HandleValue -ne [int64]$monitor.Handle.ToInt64()) { return $false }
    }
    return $true
}

function Get-WcagRelativeLuminance {
    param([string]$Color)
    if ($Color -notmatch '^#[0-9A-Fa-f]{6}$') { throw "Color must use #RRGGBB format" }
    $channels = @()
    for ($offset = 1; $offset -le 5; $offset += 2) {
        $channel = [Convert]::ToInt32($Color.Substring($offset, 2), 16) / 255.0
        $channels += if ($channel -le 0.04045) {
            $channel / 12.92
        } else {
            [Math]::Pow((($channel + 0.055) / 1.055), 2.4)
        }
    }
    return (0.2126 * $channels[0]) + (0.7152 * $channels[1]) + (0.0722 * $channels[2])
}

function Get-WcagContrastRatio {
    param([string]$Foreground, [string]$Background)
    $foregroundLuminance = Get-WcagRelativeLuminance -Color $Foreground
    $backgroundLuminance = Get-WcagRelativeLuminance -Color $Background
    $lighter = [Math]::Max($foregroundLuminance, $backgroundLuminance)
    $darker = [Math]::Min($foregroundLuminance, $backgroundLuminance)
    return ($lighter + 0.05) / ($darker + 0.05)
}

function Resolve-TextScaleFactor {
    param(
        [int]$SystemPercent = 100,
        [int]$OverridePercent = 0
    )
    $percent = if ($OverridePercent -gt 0) { $OverridePercent } else { $SystemPercent }
    $percent = [Math]::Max(100, [Math]::Min(200, $percent))
    return [Math]::Round(($percent / 100.0), 2)
}

function Get-SystemTextScalePercent {
    try {
        $settings = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Accessibility" -Name "TextScaleFactor" -ErrorAction Stop
        return [int]$settings.TextScaleFactor
    } catch {
        return 100
    }
}

function Get-StatusMessageSeverity {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return "Info" }
    if ($Message -match '(?i)\b(fail(?:ed|ure)?|error|invalid|denied|blocked|offline|corrupt|mismatch(?:ed)?|newer than|not found|unavailable|could not|no (?:DDC/CI )?(?:write )?target)\b') {
        return "Error"
    }
    if ($Message -match '(?i)\b(warn(?:ing)?|cancel(?:ed|led)?|busy|waiting|unsupported|stale|retry(?:ing)?|disabled|partly|partial(?:ly)?)\b') {
        return "Warning"
    }
    return "Info"
}

function Get-NavigationShortcutTarget {
    param([string]$Key)
    switch ($Key.ToUpperInvariant()) {
        "D" { return "Display" }
        "M" { return "Monitor" }
        "H" { return "Hardware" }
        "V" { return "VCP Explorer" }
        "P" { return "Profiles" }
        "A" { return "Automation" }
        "S" { return "System" }
        default { return "" }
    }
}

function Get-UiString {
    param([string]$Key)
    if ($script:UiStrings.ContainsKey($Key)) { return [string]$script:UiStrings[$Key] }
    return $Key
}

function Get-CapabilityProbeDecision {
    param($Monitor)
    if ($null -eq $Monitor -or $Monitor.Handle -eq [IntPtr]::Zero) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "no DDC/CI handle" }
    }
    if (-not $script:CapabilitiesDiscoveryEnabled) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "discovery disabled" }
    }
    if ($script:CapabilitiesMaximumCompatibility) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "maximum compatibility" }
    }
    $identityKey = [string]$Monitor.IdentityKey
    if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey($identityKey)) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "excluded after an interrupted probe" }
    }
    $blocked = Get-CapabilitiesBlocklistEntry -Monitor $Monitor
    if ($null -ne $blocked) {
        return [PSCustomObject]@{ Action = "Blocked"; Reason = "known-bad model $($blocked.EdidId): $($blocked.Note)" }
    }
    $cached = Get-CapabilitiesCacheEntry -Monitor $Monitor
    if ($null -ne $cached) {
        return [PSCustomObject]@{ Action = "Cached"; Reason = "cached from $($cached.ReadAt)"; Capabilities = [string]$cached.Capabilities }
    }
    return [PSCustomObject]@{ Action = "Probe"; Reason = "not cached" }
}

function Test-CapabilityProbeAllowed {
    param($Monitor)
    if ($null -eq $Monitor -or $Monitor.Handle -eq [IntPtr]::Zero) { return $false }
    if (-not $script:CapabilitiesDiscoveryEnabled -or $script:CapabilitiesMaximumCompatibility) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey($identityKey)) { return $false }
    return $true
}

function Get-IdentityKeyForHandle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return "" }
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -ne $monitor -and $monitor.Handle -eq $Handle) { return [string]$monitor.IdentityKey }
    }
    return ""
}
