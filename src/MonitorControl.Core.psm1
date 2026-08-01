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

function Resolve-StatusSeverity {
    param([string]$Severity)
    if ($Severity -in @("Info", "Warning", "Error")) { return $Severity }
    return "Info"
}

function Resolve-UiCultureName {
    param([string]$RequestedCulture = "", [string]$WindowsCulture = "")
    $candidate = if (-not [string]::IsNullOrWhiteSpace($RequestedCulture)) {
        $RequestedCulture.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($WindowsCulture)) {
        $WindowsCulture.Trim()
    } else {
        [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }
    if ($candidate -eq "qps-ploc") { return $candidate }
    try { return [System.Globalization.CultureInfo]::GetCultureInfo($candidate).Name } catch {
        throw "Unknown UI culture '$candidate'."
    }
}

function Get-UiCultureInfo {
    param([string]$CultureName = "")
    $name = if ([string]::IsNullOrWhiteSpace($CultureName)) { [string]$script:UiCulture } else { $CultureName }
    if ($name -eq "qps-ploc") { return [System.Globalization.CultureInfo]::GetCultureInfo("en-US") }
    try { return [System.Globalization.CultureInfo]::GetCultureInfo($name) } catch {
        return [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
    }
}

function ConvertTo-PseudoLocalizedText {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text) -or $Text.StartsWith("[!!", [System.StringComparison]::Ordinal)) { return $Text }
    if ($Text -cmatch "^[A-Z]{1,3}$") { return $Text }
    if ($Text -notmatch '[A-Za-z]') { return $Text }
    $upperCodePoints = @(0x00C0,0x0181,0x00C7,0x00D0,0x00CB,0x0191,0x011C,0x0124,0x00CF,0x0134,0x0136,0x013B,0x1E40,0x00D1,0x00D6,0x01A4,0x024A,0x0154,0x0160,0x0162,0x00DC,0x1E7C,0x0174,0x1E8C,0x0178,0x017D)
    $lowerCodePoints = @(0x00E0,0x0180,0x00E7,0x010F,0x00EB,0x0192,0x011D,0x0125,0x00EF,0x0135,0x0137,0x013C,0x1E41,0x00F1,0x00F6,0x01A5,0x024B,0x0155,0x0161,0x0163,0x00FC,0x1E7D,0x0175,0x1E8D,0x00FF,0x017E)
    $builder = New-Object System.Text.StringBuilder
    $insideFormatItem = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '{') { $insideFormatItem = $true }
        $characterCode = [int]$character
        if (-not $insideFormatItem -and $characterCode -ge 65 -and $characterCode -le 90) {
            [void]$builder.Append([char]$upperCodePoints[$characterCode - 65])
        } elseif (-not $insideFormatItem -and $characterCode -ge 97 -and $characterCode -le 122) {
            [void]$builder.Append([char]$lowerCodePoints[$characterCode - 97])
        } else {
            [void]$builder.Append($character)
        }
        if ($character -eq '}') { $insideFormatItem = $false }
    }
    $paddingLength = [Math]::Max(2, [int][Math]::Ceiling($Text.Length * 0.3))
    return "[!! $($builder.ToString()) $('~' * $paddingLength) !!]"
}

function Get-UiResourceKey {
    param([string]$Category, [string]$DefaultText)
    $sha = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Category`n$DefaultText")
        $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
        return "$Category.$hash"
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
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
    param([string]$Key, [object[]]$ArgumentList = @())
    $text = $Key
    if ($null -ne $script:UiCultureResources -and $script:UiCultureResources.ContainsKey([string]$script:UiCulture)) {
        $cultureTable = $script:UiCultureResources[[string]$script:UiCulture]
        if ($null -ne $cultureTable -and $cultureTable.ContainsKey($Key)) { $text = [string]$cultureTable[$Key] }
    }
    if ($text -eq $Key -and $null -ne $script:UiCultureResources -and $script:UiCultureResources.ContainsKey("en-US")) {
        $englishTable = $script:UiCultureResources["en-US"]
        if ($null -ne $englishTable -and $englishTable.ContainsKey($Key)) { $text = [string]$englishTable[$Key] }
    }
    if ([string]$script:UiCulture -eq "qps-ploc") { $text = ConvertTo-PseudoLocalizedText -Text $text }
    if (@($ArgumentList).Count -gt 0) {
        return [string]::Format((Get-UiCultureInfo), $text, $ArgumentList)
    }
    return $text
}

function Get-UiRuntimeText {
    param([string]$Category, [string]$DefaultText, [string]$Key = "", [object[]]$ArgumentList = @())
    $resourceKey = if ([string]::IsNullOrWhiteSpace($Key)) { Get-UiResourceKey -Category $Category -DefaultText $DefaultText } else { $Key }
    if ($null -eq $script:UiCultureResources) { $script:UiCultureResources = @{} }
    if (-not $script:UiCultureResources.ContainsKey("en-US")) { $script:UiCultureResources["en-US"] = @{} }
    if (-not $script:UiCultureResources["en-US"].ContainsKey($resourceKey)) {
        $script:UiCultureResources["en-US"][$resourceKey] = $DefaultText
    }
    return Get-UiString -Key $resourceKey -ArgumentList $ArgumentList
}

function Format-UiNumber {
    param($Value, [string]$Format = "G")
    if ($Value -is [System.IFormattable]) { return $Value.ToString($Format, (Get-UiCultureInfo)) }
    return [string]$Value
}

function Format-UiDateTime {
    param([DateTime]$Value, [string]$Format = "g")
    return $Value.ToString($Format, (Get-UiCultureInfo))
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
