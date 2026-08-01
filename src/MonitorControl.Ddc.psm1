# MonitorControl Pro Ddc source module.

# Dot-sourced by the development launcher and composed into the portable release.



function Get-CapabilitiesSection {
    param([string]$Capabilities, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Capabilities) -or [string]::IsNullOrWhiteSpace($Name)) { return "" }
    $match = [regex]::Match($Capabilities, "(?i)\b$([regex]::Escape($Name))\s*\(")
    if (-not $match.Success) { return "" }
    $start = $match.Index + $match.Length
    $depth = 1
    for ($i = $start; $i -lt $Capabilities.Length; $i++) {
        $ch = $Capabilities[$i]
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $Capabilities.Substring($start, $i - $start) }
        }
    }
    return ""
}

function ConvertFrom-MonitorCapabilities {
    param([string]$Capabilities)
    $map = @{}
    $section = Get-CapabilitiesSection -Capabilities $Capabilities -Name "vcp"
    if ([string]::IsNullOrWhiteSpace($section)) {
        return [PSCustomObject]@{ Known = $false; Codes = $map; Count = 0 }
    }
    $i = 0
    while ($i -lt $section.Length) {
        while ($i -lt $section.Length -and [char]::IsWhiteSpace($section[$i])) { $i++ }
        if ($i -ge $section.Length) { break }
        $start = $i
        while ($i -lt $section.Length -and $section[$i] -match '[0-9A-Fa-fxX]') { $i++ }
        if ($i -eq $start) { $i++; continue }
        $token = $section.Substring($start, $i - $start)
        if ($token.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) { $token = $token.Substring(2) }
        if ($token -notmatch '^[0-9A-Fa-f]{1,2}$') { continue }
        $code = [Convert]::ToInt32($token, 16)
        while ($i -lt $section.Length -and [char]::IsWhiteSpace($section[$i])) { $i++ }
        $values = @()
        if ($i -lt $section.Length -and $section[$i] -eq '(') {
            $i++
            $valueStart = $i
            $depth = 1
            while ($i -lt $section.Length -and $depth -gt 0) {
                if ($section[$i] -eq '(') { $depth++ }
                elseif ($section[$i] -eq ')') { $depth-- }
                if ($depth -gt 0) { $i++ }
            }
            $valueText = $section.Substring($valueStart, [Math]::Max(0, $i - $valueStart))
            $values = Get-HexTokens -Text $valueText
            if ($i -lt $section.Length -and $section[$i] -eq ')') { $i++ }
        }
        $map[$code] = @($values)
    }
    return [PSCustomObject]@{ Known = $true; Codes = $map; Count = $map.Count }
}

function Test-MonitorSupportsVcp {
    param($Monitor, [int]$Code)
    if ($null -eq $Monitor -or -not [bool]$Monitor.CapabilitiesKnown) { return $true }
    return $Monitor.SupportedVcpCodes.ContainsKey($Code)
}

function Test-MonitorSupportsVcpValue {
    param($Monitor, [int]$Code, [int]$Value)
    if (-not (Test-MonitorSupportsVcp -Monitor $Monitor -Code $Code)) { return $false }
    if ($null -eq $Monitor -or -not [bool]$Monitor.CapabilitiesKnown) { return $true }
    $values = @($Monitor.SupportedVcpCodes[$Code])
    if ($values.Count -eq 0) { return $true }
    return $values -contains $Value
}

function ConvertTo-VcpCode {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $inputText = $Text.Trim()
    $style = [System.Globalization.NumberStyles]::Integer
    if ($inputText.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
        $inputText = $inputText.Substring(2)
        $style = [System.Globalization.NumberStyles]::HexNumber
    }
    if ([string]::IsNullOrWhiteSpace($inputText)) { return $null }
    $value = 0
    if (-not [int]::TryParse($inputText, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    if ($value -lt 0 -or $value -gt 255) { return $null }
    return $value
}

function ConvertTo-VcpValue {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = [uint32]0
    if (-not [uint32]::TryParse($Text.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    return $value
}

function Test-VcpCodeIsScaled {
    param([int]$Code)
    return $script:VcpScaledCodes -contains $Code
}

function Get-VcpMaximumForMonitor {
    param($Monitor, [int]$Code)
    if ($null -ne $Monitor -and $null -ne $Monitor.PSObject.Properties["VcpMaximums"] -and $null -ne $Monitor.VcpMaximums) {
        if ($Monitor.VcpMaximums.ContainsKey($Code)) {
            $cached = [int]$Monitor.VcpMaximums[$Code]
            if ($cached -gt 0) { return $cached }
        }
    }
    return $script:VcpDefaultMaximum
}

function Set-VcpMaximumForMonitor {
    param($Monitor, [int]$Code, [int]$Maximum)
    if ($null -eq $Monitor -or $Maximum -le 0) { return }
    if ($null -eq $Monitor.PSObject.Properties["VcpMaximums"] -or $null -eq $Monitor.VcpMaximums) { return }
    $Monitor.VcpMaximums[$Code] = [int]$Maximum
}

function Get-SelectedMonitorVcpMaximum {
    param([int]$Code)
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return $script:VcpDefaultMaximum }
    return Get-VcpMaximumForMonitor -Monitor $script:PhysicalMonitors[$script:CurrentMonitorIndex] -Code $Code
}

function ConvertTo-VcpPercent {
    param([double]$RawValue, [int]$Maximum)
    if ($Maximum -le 0) { return 0 }
    $percent = [Math]::Round(($RawValue * 100.0) / [double]$Maximum, [System.MidpointRounding]::AwayFromZero)
    if ($percent -lt 0) { return 0 }
    if ($percent -gt 100) { return 100 }
    return [int]$percent
}

function ConvertTo-VcpRawValue {
    param([double]$Percent, [int]$Maximum)
    if ($Maximum -le 0) { return 0 }
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $raw = [Math]::Round(($clamped * [double]$Maximum) / 100.0, [System.MidpointRounding]::AwayFromZero)
    if ($raw -lt 0) { return 0 }
    if ($raw -gt $Maximum) { return [int]$Maximum }
    return [int]$raw
}

function Convert-EdidManufacturerId {
    param([byte[]]$Edid)
    if ($null -eq $Edid -or $Edid.Length -lt 10) { return "" }
    $word = (([int]$Edid[8]) -shl 8) -bor [int]$Edid[9]
    $chars = foreach ($shift in 10,5,0) {
        $code = ($word -shr $shift) -band 31
        if ($code -lt 1 -or $code -gt 26) { return "" }
        [char](64 + $code)
    }
    return (-join $chars)
}

function Get-EdidTextDescriptor {
    param([byte[]]$Edid, [byte]$Tag)
    if ($null -eq $Edid -or $Edid.Length -lt 128) { return "" }
    for ($offset = 54; $offset -le 108; $offset += 18) {
        if ($Edid[$offset] -eq 0 -and $Edid[$offset + 1] -eq 0 -and $Edid[$offset + 2] -eq 0 -and $Edid[$offset + 3] -eq $Tag) {
            $text = [System.Text.Encoding]::ASCII.GetString($Edid, $offset + 5, 13)
            return $text.Trim([char[]]@(0, 10, 13, 32))
        }
    }
    return ""
}

function Read-MonitorEdidFromDeviceId {
    param([string]$MonitorDeviceId)
    $result = [ordered]@{
        DeviceId = $MonitorDeviceId
        HardwareId = ""
        Manufacturer = ""
        Model = ""
        Serial = ""
        Name = ""
    }
    if ([string]::IsNullOrWhiteSpace($MonitorDeviceId)) { return [PSCustomObject]$result }
    $hardwareId = ""
    $instanceId = ""
    if ($MonitorDeviceId -match '^MONITOR\\([^\\]+)\\([^\\]+)') {
        $hardwareId = $Matches[1]
        $instanceId = $Matches[2]
        $result.HardwareId = $hardwareId
    }
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
    $candidatePaths = @()
    if ($hardwareId -and $instanceId) {
        $candidatePaths += (Join-Path (Join-Path (Join-Path $basePath $hardwareId) $instanceId) "Device Parameters")
    }
    if ($hardwareId) {
        try {
            $candidatePaths += @(Get-ChildItem -LiteralPath (Join-Path $basePath $hardwareId) -ErrorAction Stop | ForEach-Object { Join-Path $_.PSPath "Device Parameters" })
        } catch {}
    }
    $edid = $null
    foreach ($path in ($candidatePaths | Select-Object -Unique)) {
        try {
            if (Test-Path -LiteralPath $path) {
                $prop = Get-ItemProperty -LiteralPath $path -Name EDID -ErrorAction Stop
                if ($prop.EDID -and $prop.EDID.Length -ge 128) {
                    $edid = [byte[]]@($prop.EDID | ForEach-Object { [byte]$_ })
                    break
                }
            }
        } catch {}
    }
    if ($null -eq $edid -or $edid.Length -lt 128) { return [PSCustomObject]$result }
    $result.Manufacturer = Convert-EdidManufacturerId -Edid $edid
    $productCode = (([int]$edid[11]) -shl 8) -bor [int]$edid[10]
    $result.Model = "{0:X4}" -f $productCode
    $numericSerial = [BitConverter]::ToUInt32($edid, 12)
    $serialText = Get-EdidTextDescriptor -Edid $edid -Tag 0xFF
    $result.Serial = if (-not [string]::IsNullOrWhiteSpace($serialText)) { $serialText } elseif ($numericSerial -ne 0) { $numericSerial.ToString() } else { "" }
    $result.Name = Get-EdidTextDescriptor -Edid $edid -Tag 0xFC
    return [PSCustomObject]$result
}

function Get-MonitorDisplayDevice {
    param([string]$DisplayDeviceName)
    if ([string]::IsNullOrWhiteSpace($DisplayDeviceName)) { return $null }
    $monitorDevice = New-Object MonitorAPI+DISPLAY_DEVICE
    $monitorDevice.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($monitorDevice)
    if ([MonitorAPI]::EnumDisplayDevices($DisplayDeviceName, 0, [ref]$monitorDevice, 0)) {
        return [PSCustomObject]@{
            DeviceName = $monitorDevice.DeviceName
            DeviceString = $monitorDevice.DeviceString
            DeviceID = $monitorDevice.DeviceID
            DeviceKey = $monitorDevice.DeviceKey
        }
    }
    return $null
}

function New-MonitorIdentity {
    param([string]$DisplayDeviceName, [string]$FriendlyName, [int]$Width, [int]$Height, [int]$MonitorIndex)
    $displayDevice = Get-MonitorDisplayDevice -DisplayDeviceName $DisplayDeviceName
    $devicePath = if ($displayDevice) { [string]$displayDevice.DeviceID } else { "" }
    $deviceString = if ($displayDevice) { [string]$displayDevice.DeviceString } else { "" }
    $edid = Read-MonitorEdidFromDeviceId -MonitorDeviceId $devicePath
    $defaultLabel = if (-not [string]::IsNullOrWhiteSpace($edid.Name)) {
        [string]$edid.Name
    } elseif (-not [string]::IsNullOrWhiteSpace($deviceString)) {
        $deviceString
    } elseif (-not [string]::IsNullOrWhiteSpace($FriendlyName)) {
        $FriendlyName
    } else {
        "Monitor $MonitorIndex"
    }
    $source = "display"
    $keySeed = @($DisplayDeviceName, $FriendlyName, $Width, $Height, $MonitorIndex) -join "|"
    if (-not [string]::IsNullOrWhiteSpace($edid.Manufacturer) -and -not [string]::IsNullOrWhiteSpace($edid.Model) -and -not [string]::IsNullOrWhiteSpace($edid.Serial)) {
        $source = "edid"
        $keySeed = @($edid.Manufacturer, $edid.Model, $edid.Serial) -join "|"
    } elseif (-not [string]::IsNullOrWhiteSpace($devicePath)) {
        $source = if (-not [string]::IsNullOrWhiteSpace($edid.Manufacturer)) { "edid-device" } else { "device" }
        $keySeed = @($devicePath, $edid.Manufacturer, $edid.Model, $edid.Name) -join "|"
    }
    return [PSCustomObject]@{
        Key = "{0}:{1}" -f $source, (Get-StableHash -Text $keySeed)
        Source = $source
        DevicePath = $devicePath
        DeviceString = $deviceString
        HardwareId = [string]$edid.HardwareId
        Manufacturer = [string]$edid.Manufacturer
        Model = [string]$edid.Model
        Serial = [string]$edid.Serial
        EdidName = [string]$edid.Name
        DefaultLabel = $defaultLabel
    }
}

function Get-MonitorIdentityRecord {
    param($Monitor)
    if ($null -eq $Monitor -or [string]::IsNullOrWhiteSpace([string]$Monitor.IdentityKey)) { return $null }
    if ($script:MonitorIdentityRecords.ContainsKey([string]$Monitor.IdentityKey)) { return $script:MonitorIdentityRecords[[string]$Monitor.IdentityKey] }
    return $null
}

function Get-MonitorDisplayLabel {
    param($Monitor)
    if ($null -eq $Monitor) { return "No monitor" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.UserLabel)) { return [string]$Monitor.UserLabel }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.IdentityDefaultLabel)) { return [string]$Monitor.IdentityDefaultLabel }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.Name)) { return [string]$Monitor.Name }
    return "Monitor $($Monitor.Index)"
}

function Apply-MonitorIdentity {
    param($Monitor)
    if ($null -eq $Monitor) { return }
    $record = Get-MonitorIdentityRecord -Monitor $Monitor
    $label = if ($record -and -not [string]::IsNullOrWhiteSpace([string]$record.Label)) { [string]$record.Label } else { "" }
    $Monitor | Add-Member -NotePropertyName UserLabel -NotePropertyValue $label -Force
    $Monitor | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue (Get-MonitorDisplayLabel -Monitor $Monitor) -Force
}

function Update-MonitorIdentityAssignments {
    foreach ($mon in @($script:PhysicalMonitors)) { Apply-MonitorIdentity -Monitor $mon }
}

function Find-MonitorIndexByIdentity {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return -1 }
    for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
        if ([string]$script:PhysicalMonitors[$i].IdentityKey -eq $IdentityKey) { return $i }
    }
    return -1
}

function Get-DisplayRecoveryBackoffDelay {
    param([int]$FailureCount)
    if ($FailureCount -le 0) { return 0 }
    $exponent = [Math]::Min(6, $FailureCount - 1)
    return [int][Math]::Min(30000, 750 * [Math]::Pow(2, $exponent))
}

function Get-DisplayRecoveryReadRetryCount {
    param($State, [int]$DefaultRetries = 2)
    $failureCount = if ($null -ne $State -and $State.PSObject.Properties.Name -contains "ConsecutiveFailures") {
        [Math]::Max(0, [int]$State.ConsecutiveFailures)
    } else {
        0
    }
    return [int][Math]::Min(5, [Math]::Max(0, $DefaultRetries) + [Math]::Floor($failureCount / 2))
}

function Get-DdcLivenessRecoveryDecision {
    param(
        [object[]]$Results,
        [int]$CurrentGeneration,
        [int]$LastRecoveryGeneration = 0
    )
    $current = @($Results | Where-Object {
        $null -ne $_ -and
        [int]$_.Generation -eq $CurrentGeneration -and
        -not [string]::IsNullOrWhiteSpace([string]$_.IdentityKey)
    })
    $successfulIdentities = @($current | Where-Object { [bool]$_.Success } |
        ForEach-Object { [string]$_.IdentityKey } | Sort-Object -Unique)
    $failedIdentities = @($current | Where-Object { -not [bool]$_.Success } |
        ForEach-Object { [string]$_.IdentityKey } | Sort-Object -Unique |
        Where-Object { $successfulIdentities -notcontains $_ })
    $mixedOutcome = $successfulIdentities.Count -gt 0 -and $failedIdentities.Count -gt 0
    $alreadyRecovered = $LastRecoveryGeneration -eq $CurrentGeneration
    return [PSCustomObject]@{
        Generation = [int]$CurrentGeneration
        SuccessfulIdentities = [object[]]$successfulIdentities
        FailedIdentities = [object[]]$failedIdentities
        MixedOutcome = [bool]$mixedOutcome
        AlreadyRecovered = [bool]$alreadyRecovered
        ShouldRecover = [bool]($mixedOutcome -and -not $alreadyRecovered)
    }
}

function Invoke-DdcLivenessRecovery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Coordinates an injected in-process refresh callback.')]
    param(
        [object[]]$Results,
        [int]$CurrentGeneration,
        [scriptblock]$RequestRecovery
    )
    $decision = Get-DdcLivenessRecoveryDecision -Results $Results -CurrentGeneration $CurrentGeneration -LastRecoveryGeneration ([int]$script:DdcLivenessLastRecoveryGeneration)
    $requested = $false
    if ([bool]$decision.ShouldRecover) {
        $script:DdcLivenessLastRecoveryGeneration = $CurrentGeneration
        if ($null -ne $RequestRecovery) {
            & $RequestRecovery ([object[]]$decision.FailedIdentities)
            $requested = $true
        }
    }
    $decision | Add-Member -NotePropertyName RecoveryRequested -NotePropertyValue ([bool]$requested) -Force
    return $decision
}

function Get-DisplayRecoveryTransition {
    param(
        [string]$IdentityKey,
        $PreviousState,
        [ValidateSet("Enumerated", "Stale", "Retry", "Success", "Failure", "Missing")]
        [string]$Outcome,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$Generation = 0,
        [string]$ErrorMessage = ""
    )
    $previousFailures = 0
    $lastSuccessUtc = $null
    if ($null -ne $PreviousState) {
        if ($PreviousState.PSObject.Properties.Name -contains "ConsecutiveFailures") {
            $previousFailures = [Math]::Max(0, [int]$PreviousState.ConsecutiveFailures)
        }
        if ($PreviousState.PSObject.Properties.Name -contains "LastSuccessUtc") {
            $lastSuccessUtc = $PreviousState.LastSuccessUtc
        }
    }
    $status = "Retrying"
    $failures = $previousFailures
    $nextRetryUtc = $null
    $lastError = $ErrorMessage
    switch ($Outcome) {
        "Success" {
            $status = "Fresh"
            $failures = 0
            $lastSuccessUtc = $NowUtc
            $lastError = ""
        }
        "Failure" {
            $failures++
            $offlineThreshold = if ($script:DisplayRecoveryOfflineThreshold -gt 0) { [int]$script:DisplayRecoveryOfflineThreshold } else { 4 }
            $status = if ($failures -ge $offlineThreshold) { "Offline" } else { "Retrying" }
            $nextRetryUtc = $NowUtc.AddMilliseconds((Get-DisplayRecoveryBackoffDelay -FailureCount $failures))
        }
        "Stale" {
            $status = "Stale"
            $lastError = ""
        }
        "Retry" {
            $status = "Retrying"
            $lastError = ""
        }
        "Missing" {
            $status = "Offline"
            $lastError = if ($ErrorMessage) { $ErrorMessage } else { "Display is not currently enumerated" }
        }
        default {
            $status = "Retrying"
            $lastError = ""
        }
    }
    return [PSCustomObject]@{
        IdentityKey = [string]$IdentityKey
        Status = [string]$status
        LastSuccessUtc = $lastSuccessUtc
        ConsecutiveFailures = [int]$failures
        NextRetryUtc = $nextRetryUtc
        LastError = [string]$lastError
        Generation = [int]$Generation
    }
}

function Set-DisplayRecoveryOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates in-memory recovery state only.')]
    param(
        [string]$IdentityKey,
        [ValidateSet("Enumerated", "Stale", "Retry", "Success", "Failure", "Missing")]
        [string]$Outcome,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$Generation = $script:DisplayRecoveryGeneration,
        [string]$ErrorMessage = ""
    )
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $null }
    $previous = if ($script:DisplayRecoveryStates.ContainsKey($IdentityKey)) { $script:DisplayRecoveryStates[$IdentityKey] } else { $null }
    $next = Get-DisplayRecoveryTransition -IdentityKey $IdentityKey -PreviousState $previous -Outcome $Outcome -NowUtc $NowUtc -Generation $Generation -ErrorMessage $ErrorMessage
    $script:DisplayRecoveryStates[$IdentityKey] = $next
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -eq $monitor -or [string]$monitor.IdentityKey -ne $IdentityKey) { continue }
        $monitor | Add-Member -NotePropertyName RecoveryState -NotePropertyValue ([string]$next.Status) -Force
        $monitor | Add-Member -NotePropertyName RecoveryLastSuccessUtc -NotePropertyValue $next.LastSuccessUtc -Force
        $monitor | Add-Member -NotePropertyName RecoveryConsecutiveFailures -NotePropertyValue ([int]$next.ConsecutiveFailures) -Force
        $monitor | Add-Member -NotePropertyName RecoveryNextRetryUtc -NotePropertyValue $next.NextRetryUtc -Force
        $monitor | Add-Member -NotePropertyName RecoveryLastError -NotePropertyValue ([string]$next.LastError) -Force
        $monitor | Add-Member -NotePropertyName RecoveryGeneration -NotePropertyValue ([int]$next.Generation) -Force
    }
    try { Update-SelectedMonitorRecoveryUi } catch { $null = $_ }
    return $next
}

function Sync-DisplayRecoveryInventory {
    $present = @{}
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -eq $monitor -or [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey)) { continue }
        $identityKey = [string]$monitor.IdentityKey
        $present[$identityKey] = $true
        Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Enumerated" -Generation $script:DisplayRecoveryGeneration | Out-Null
    }
    foreach ($identityKey in @($script:DisplayRecoveryStates.Keys)) {
        if (-not $present.ContainsKey([string]$identityKey)) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$identityKey) -Outcome "Missing" -Generation $script:DisplayRecoveryGeneration | Out-Null
        }
    }
}

function Wait-DdcWriteQueueIdle {
    param([int]$TimeoutMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        Drain-DdcWriteResults
        if (-not [MonitorAPI]::IsVCPWriteWorkerActive() -and [MonitorAPI]::GetPendingVCPWriteCount() -eq 0) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Stop-DdcWriteQueueForHandleRelease {
    param(
        [int]$TimeoutMs = 5000,
        [scriptblock]$CancelWrites,
        [scriptblock]$WaitForIdle
    )
    if ($null -eq $CancelWrites) { $CancelWrites = { [MonitorAPI]::CancelVCPWrites() | Out-Null } }
    if ($null -eq $WaitForIdle) { $WaitForIdle = { param([int]$Timeout) Wait-DdcWriteQueueIdle -TimeoutMs $Timeout } }
    & $CancelWrites
    if (& $WaitForIdle $TimeoutMs) { return $true }
    $message = "DDC write worker did not release monitor handles within $TimeoutMs ms; handle destruction was aborted"
    if (Get-Command Update-Status -ErrorAction SilentlyContinue) { Update-Status $message }
    return $false
}

function Clear-PhysicalMonitorHandles {
    param(
        [switch]$ClearList,
        [scriptblock]$DestroyHandle,
        [switch]$KeepWritesCancelled,
        [int]$WriteQueueTimeoutMs = 5000
    )
    if (-not (Stop-DdcWriteQueueForHandleRelease -TimeoutMs $WriteQueueTimeoutMs)) { return $false }
    if ($null -eq $DestroyHandle) {
        $DestroyHandle = {
            param([IntPtr]$Handle)
            [MonitorAPI]::DestroyPhysicalMonitor($Handle) | Out-Null
        }
    }
    $seen = @{}
    foreach ($mon in @($script:PhysicalMonitors)) {
        if ($null -eq $mon -or $mon.Handle -eq [IntPtr]::Zero) { continue }
        $key = $mon.Handle.ToInt64()
        if (-not $seen.ContainsKey($key)) {
            try { & $DestroyHandle $mon.Handle } catch {}
            $seen[$key] = $true
        }
        try { $mon.Handle = [IntPtr]::Zero } catch {}
    }
    try { [MonitorAPI]::InvalidateVcpValueCache() } catch {}
    if ($ClearList) { $script:PhysicalMonitors = @() }
    if (-not $KeepWritesCancelled -and -not [MonitorAPI]::ResumeVCPWrites()) {
        if (Get-Command Update-Status -ErrorAction SilentlyContinue) { Update-Status "DDC write queue could not resume after monitor handle cleanup" }
        return $false
    }
    return $true
}

function Test-VcpWriteRequiresSafetyConsent {
    param([int]$Code, [switch]$Arbitrary)
    if ($Arbitrary) { return $true }
    return $script:RiskyVcpCodes -contains $Code
}

function Test-VcpWriteEnabledForMonitor {
    param($Monitor)
    if ($null -eq $Monitor) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey) -or $identityKey.Length -gt 512) { return $false }
    return $script:RiskyVcpEnabledIdentityKeys.ContainsKey($identityKey)
}

function Set-VcpWriteEnabledForMonitor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "The calling UI owns explicit confirmation and this helper persists only that confirmed choice.")]
    param($Monitor, [bool]$Enabled)
    if ($null -eq $Monitor) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey) -or $identityKey.Length -gt 512) { return $false }
    if ($Enabled) {
        $script:RiskyVcpEnabledIdentityKeys[$identityKey] = $true
    } else {
        $null = $script:RiskyVcpEnabledIdentityKeys.Remove($identityKey)
    }
    return (Write-VcpWriteSafetyState)
}

function Get-VcpWriteSafetyStatusText {
    param($Monitor)
    if ($null -eq $Monitor) { return "No display selected" }
    if ([string]::IsNullOrWhiteSpace([string]$Monitor.IdentityKey) -or ([string]$Monitor.IdentityKey).Length -gt 512) { return "Unavailable: stable identity required" }
    $label = Get-MonitorDisplayLabel -Monitor $Monitor
    if (Test-VcpWriteEnabledForMonitor -Monitor $Monitor) { return "Enabled for $label" }
    return "Disabled for $label"
}

function Get-MonitorEdidModelId {
    param($Monitor)
    if ($null -eq $Monitor) { return "" }
    $manufacturer = [string]$Monitor.Manufacturer
    $model = [string]$Monitor.EdidModel
    if ([string]::IsNullOrWhiteSpace($manufacturer) -or [string]::IsNullOrWhiteSpace($model)) { return "" }
    return ($manufacturer + $model).ToUpperInvariant()
}

function Get-CapabilitiesBlocklistEntry {
    param($Monitor)
    $edidId = Get-MonitorEdidModelId -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($edidId)) { return $null }
    foreach ($entry in @($script:CapabilitiesKnownBadModels)) {
        if ([string]$entry.EdidId -eq $edidId) { return $entry }
    }
    return $null
}

function Get-CapabilitiesSafetyStatusText {
    $excludedCount = [int]$script:CapabilitiesExcludedIdentityKeys.Count
    $suffix = if ($excludedCount -eq 1) { "1 exclusion" } else { "$excludedCount exclusions" }
    if ($script:CapabilitiesMaximumCompatibility) { return "Maximum compatibility - reads disabled ($suffix)" }
    if (-not $script:CapabilitiesDiscoveryEnabled) { return "Discovery off ($suffix)" }
    return "Discovery on ($suffix)"
}

function Stop-CapabilitiesWorker {
    param([switch]$Cancel)
    if ($script:CapabilitiesWorkerTimer) { $script:CapabilitiesWorkerTimer.Stop() }
    if ($script:CapabilitiesWorker) {
        if ($Cancel -and $script:CapabilitiesWorkerAsyncResult -and -not $script:CapabilitiesWorkerAsyncResult.IsCompleted) {
            try { $script:CapabilitiesWorker.Stop() } catch {}
        }
        try { $script:CapabilitiesWorker.Dispose() } catch {}
    }
    if ($script:CapabilitiesWorkerInput) { try { $script:CapabilitiesWorkerInput.Dispose() } catch {} }
    if ($script:CapabilitiesWorkerOutput) { try { $script:CapabilitiesWorkerOutput.Dispose() } catch {} }
    $script:CapabilitiesWorker = $null
    $script:CapabilitiesWorkerInput = $null
    $script:CapabilitiesWorkerOutput = $null
    $script:CapabilitiesWorkerAsyncResult = $null
    $script:CapabilitiesWorkerLastOutputCount = 0
    $script:CapabilitiesWorkerGeneration = -1
}

function ConvertTo-DriverVersionParts {
    param([string]$Version)
    $parts = @()
    foreach ($token in @(([string]$Version).Trim().Split(@(".", "-", " "), [StringSplitOptions]::RemoveEmptyEntries))) {
        $number = 0
        if ([int]::TryParse($token, [ref]$number)) { $parts += $number } else { $parts += 0 }
    }
    return $parts
}

function Compare-DisplayDriverVersion {
    param([string]$Left, [string]$Right)
    $leftParts = @(ConvertTo-DriverVersionParts -Version $Left)
    $rightParts = @(ConvertTo-DriverVersionParts -Version $Right)
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $leftValue = if ($i -lt $leftParts.Count) { [int]$leftParts[$i] } else { 0 }
        $rightValue = if ($i -lt $rightParts.Count) { [int]$rightParts[$i] } else { 0 }
        if ($leftValue -lt $rightValue) { return -1 }
        if ($leftValue -gt $rightValue) { return 1 }
    }
    return 0
}

function Test-DisplayDriverVersionInRange {
    param([string]$Version, [string]$From, [string]$Through)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($From) -and (Compare-DisplayDriverVersion -Left $Version -Right $From) -lt 0) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Through) -and (Compare-DisplayDriverVersion -Left $Version -Right $Through) -gt 0) { return $false }
    return $true
}

function Get-GpuDriverAdvisory {
    param([object[]]$Gpus, [hashtable]$BrandingVersions, [object[]]$Table)
    if ($null -eq $Table) { $Table = @($script:KnownBadGpuDrivers) }
    if ($null -eq $BrandingVersions) { $BrandingVersions = @{} }
    $advisories = @()
    foreach ($entry in @($Table)) {
        foreach ($gpu in @($Gpus)) {
            if ($null -eq $gpu) { continue }
            $name = [string]$gpu.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch [string]$entry.NamePattern) { continue }
            $valueName = [string]$entry.BrandingValueName
            $observed = ""
            $source = ""
            if (-not [string]::IsNullOrWhiteSpace($valueName) -and $BrandingVersions.ContainsKey($valueName)) {
                $observed = [string]$BrandingVersions[$valueName]
                $source = $valueName
            }
            $matched = $false
            if (-not [string]::IsNullOrWhiteSpace($observed)) {
                $matched = Test-DisplayDriverVersionInRange -Version $observed -From ([string]$entry.AffectedFrom) -Through ([string]$entry.AffectedThrough)
            }
            if (-not $matched -and -not [string]::IsNullOrWhiteSpace([string]$entry.AffectedDriverFrom)) {
                $observed = [string]$gpu.DriverVersion
                $source = "DriverVersion"
                $matched = Test-DisplayDriverVersionInRange -Version $observed -From ([string]$entry.AffectedDriverFrom) -Through ([string]$entry.AffectedDriverThrough)
            }
            if (-not $matched) { continue }
            $advisories += [PSCustomObject]@{
                Gpu = $name
                Observed = $observed
                ObservedSource = $source
                FixedIn = [string]$entry.FixedIn
                Issue = [string]$entry.Issue
                Reference = [string]$entry.Reference
            }
        }
    }
    return @($advisories)
}

function Get-KnownBadGpuDriverAdvisory {
    $gpus = @()
    try { $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch {}
    if ($gpus.Count -eq 0) { return @() }
    return @(Get-GpuDriverAdvisory -Gpus $gpus -BrandingVersions (Get-GpuBrandingVersions) -Table @($script:KnownBadGpuDrivers))
}

function Get-DisplayPathClassification {
    param([string]$DeviceString, [string]$HardwareId, [string]$AdapterName, [object[]]$Signatures)
    if ($null -eq $Signatures) { $Signatures = @($script:DisplayPathSignatures) }
    $haystack = (@($DeviceString, $HardwareId, $AdapterName) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " "
    foreach ($signature in @($Signatures)) {
        if (-not [string]::IsNullOrWhiteSpace($haystack) -and $haystack -match [string]$signature.Pattern) {
            return [PSCustomObject]@{
                Kind = [string]$signature.Kind
                HasControlChannel = $false
                Reason = [string]$signature.Reason
                Fix = [string]$signature.Fix
            }
        }
    }
    return [PSCustomObject]@{ Kind = "Direct"; HasControlChannel = $true; Reason = ""; Fix = "" }
}

function Get-DisplayPathInventory {
    param([string[]]$DdcCapableDeviceNames)
    $capable = @{}
    foreach ($deviceName in @($DdcCapableDeviceNames)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$deviceName)) { $capable[[string]$deviceName] = $true }
    }
    $inventory = @()
    $devNum = 0
    $device = New-Object MonitorAPI+DISPLAY_DEVICE
    $device.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($device)
    while ([MonitorAPI]::EnumDisplayDevices([NullString]::Value, $devNum, [ref]$device, 0)) {
        $devNum++
        if (($device.StateFlags -band [MonitorAPI]::DISPLAY_DEVICE_ACTIVE) -eq 0) { continue }
        $deviceName = [string]$device.DeviceName
        $adapterName = [string]$device.DeviceString
        $monitorDevice = Get-MonitorDisplayDevice -DisplayDeviceName $deviceName
        $monitorString = if ($monitorDevice) { [string]$monitorDevice.DeviceString } else { "" }
        $monitorId = if ($monitorDevice) { [string]$monitorDevice.DeviceID } else { "" }
        $classification = Get-DisplayPathClassification -DeviceString $monitorString -HardwareId $monitorId -AdapterName $adapterName
        $hasChannel = $capable.ContainsKey($deviceName)
        $inventory += [PSCustomObject]@{
            DeviceName = $deviceName
            Name = if ([string]::IsNullOrWhiteSpace($monitorString)) { $adapterName } else { $monitorString }
            Adapter = $adapterName
            Kind = if ($hasChannel) { "Direct" } else { [string]$classification.Kind }
            HasControlChannel = $hasChannel
            Reason = if ($hasChannel) { "" } else { [string]$classification.Reason }
            Fix = if ($hasChannel) { "" } else { [string]$classification.Fix }
        }
    }
    return @($inventory)
}

function Get-DdcAvailabilityDiagnosis {
    param([object[]]$Paths, [object[]]$GpuAdvisories, [bool]$WmiBrightnessAvailable)
    $displayCount = @($Paths).Count
    $capableCount = @(@($Paths) | Where-Object { $null -ne $_ -and [bool]$_.HasControlChannel }).Count
    $causes = @()
    foreach ($advisory in @($GpuAdvisories)) {
        if ($null -eq $advisory) { continue }
        $causes += [PSCustomObject]@{
            Kind = "GpuDriver"
            Title = "$($advisory.Gpu) driver $($advisory.Observed) is a release known to break DDC/CI"
            Detail = "$($advisory.Issue). Reported in $($advisory.Reference)."
            Fix = "Update the display driver to $($advisory.FixedIn) or newer, or roll back to the release in use before the problem started."
        }
    }
    $named = 0
    $groups = @{}
    $order = @()
    foreach ($path in @($Paths)) {
        if ($null -eq $path -or [bool]$path.HasControlChannel) { continue }
        $kind = [string]$path.Kind
        if ($kind -eq "Direct") { continue }
        $named++
        if (-not $groups.ContainsKey($kind)) {
            $groups[$kind] = [PSCustomObject]@{ Count = 0; Reason = [string]$path.Reason; Fix = [string]$path.Fix; Displays = @() }
            $order += $kind
        }
        $groups[$kind].Count = [int]$groups[$kind].Count + 1
        $groups[$kind].Displays = @(@($groups[$kind].Displays) + [string]$path.Name)
    }
    foreach ($kind in $order) {
        $group = $groups[$kind]
        $causes += [PSCustomObject]@{
            Kind = $kind
            Title = "$([int]$group.Count) display(s) on a $kind path have no control channel: $(@($group.Displays) -join ', ')"
            Detail = [string]$group.Reason
            Fix = [string]$group.Fix
        }
    }
    $unexplained = [Math]::Max(0, $displayCount - $capableCount - $named)
    if ($unexplained -gt 0) {
        $causes += [PSCustomObject]@{
            Kind = "Unclassified"
            Title = "$unexplained display(s) answer no DDC/CI request on a path this app cannot identify"
            Detail = "An MST hub, a passive or active adapter, a KVM, or a cable that omits the DDC pins all terminate DDC/CI without reporting an error, and many monitors ship with DDC/CI switched off in the OSD."
            Fix = "Switch DDC/CI on in the monitor OSD, connect the monitor straight to a GPU output with a certified cable, and retest with no hub, dock, or KVM in the path."
        }
    }
    if ($capableCount -eq 0 -and $WmiBrightnessAvailable) {
        $causes += [PSCustomObject]@{
            Kind = "InternalPanel"
            Title = "The internal laptop panel is controlled through WMI instead"
            Detail = "Integrated panels are driven by the graphics driver, not by DDC/CI, so brightness works while every other VCP feature does not."
            Fix = "Use an external monitor for contrast, input switching, and colour controls."
        }
    }
    $severity = if ($displayCount -gt 0 -and $capableCount -eq 0) { "Error" } elseif (@($causes).Count -gt 0) { "Warning" } else { "None" }
    $summary = "$displayCount display(s) detected, $capableCount with a DDC/CI control channel"
    $headline = switch ($severity) {
        "Error" { "DDC/CI control is unavailable: $summary. " + $(if (@($causes).Count -gt 0) { [string]@($causes)[0].Title } else { "No cause identified." }) }
        "Warning" { "DDC/CI is partly available: $summary. " + [string]@($causes)[0].Title }
        default { $summary }
    }
    if ($severity -ne "None") { $headline = "$headline See System, DDC Compatibility Report." }
    return [PSCustomObject]@{
        DisplayCount = [int]$displayCount
        DdcCapableCount = [int]$capableCount
        Severity = [string]$severity
        Summary = [string]$summary
        Headline = [string]$headline
        Causes = @($causes)
    }
}

function Get-Monitors {
    Stop-MonitorSettingsWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-CapabilitiesWorker -Cancel
    Stop-DdcReportWorker -Cancel
    if (-not (Clear-PhysicalMonitorHandles -ClearList -KeepWritesCancelled)) {
        throw "Monitor refresh aborted because the DDC write worker still owns a physical monitor handle"
    }
    try {
    $monitorHandles = [MonitorAPI]::GetAllMonitorHandles()
    $monitorIndex = 1
    $displayDevices = @{}
    $devNum = 0
    $device = New-Object MonitorAPI+DISPLAY_DEVICE
    $device.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($device)
    while ([MonitorAPI]::EnumDisplayDevices([NullString]::Value, $devNum, [ref]$device, 0)) {
        if ($device.StateFlags -band [MonitorAPI]::DISPLAY_DEVICE_ACTIVE) { $displayDevices[$device.DeviceName] = $device.DeviceString }
        $devNum++
    }
    foreach ($hMonitor in $monitorHandles) {
        $numMons = [uint32]0
        if ([MonitorAPI]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$numMons) -and $numMons -gt 0) {
            $physMons = New-Object MonitorAPI+PHYSICAL_MONITOR[] $numMons
            if ([MonitorAPI]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $numMons, $physMons)) {
                foreach ($pm in $physMons) {
                    $monInfo = New-Object MonitorAPI+MONITORINFOEX
                    $monInfo.Size = [System.Runtime.InteropServices.Marshal]::SizeOf($monInfo)
                    if ([MonitorAPI]::GetMonitorInfo($hMonitor, [ref]$monInfo)) {
                        $devMode = New-Object MonitorAPI+DEVMODE
                        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
                        [MonitorAPI]::EnumDisplaySettingsEx($monInfo.DeviceName, [MonitorAPI]::ENUM_CURRENT_SETTINGS, [ref]$devMode, 0) | Out-Null
                        $name = if ($pm.szPhysicalMonitorDescription) { $pm.szPhysicalMonitorDescription } else {
                            if ($displayDevices.ContainsKey($monInfo.DeviceName)) { $displayDevices[$monInfo.DeviceName] } else { "Monitor $monitorIndex" }
                        }
                        $identity = New-MonitorIdentity -DisplayDeviceName $monInfo.DeviceName -FriendlyName $name -Width $devMode.dmPelsWidth -Height $devMode.dmPelsHeight -MonitorIndex $monitorIndex
                        $monitorObject = [PSCustomObject]@{
                            Handle = $pm.hPhysicalMonitor; HMonitor = $hMonitor; Name = $name; Index = $monitorIndex
                            DeviceName = $monInfo.DeviceName; Width = $devMode.dmPelsWidth; Height = $devMode.dmPelsHeight
                            RefreshRate = $devMode.dmDisplayFrequency; IsPrimary = ($monInfo.Flags -band [MonitorAPI]::MONITORINFOF_PRIMARY) -ne 0
                            Left = $monInfo.Monitor.Left; Top = $monInfo.Monitor.Top; Right = $monInfo.Monitor.Right
                            Bottom = $monInfo.Monitor.Bottom; Capabilities = ""
                            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false; VcpMaximums = @{}
                            CapabilitiesExcluded = $false; CapabilitiesSafetyError = ""
                            IdentityKey = $identity.Key; IdentitySource = $identity.Source; IdentityDefaultLabel = $identity.DefaultLabel
                            DevicePath = $identity.DevicePath; MonitorDeviceString = $identity.DeviceString; HardwareId = $identity.HardwareId
                            Manufacturer = $identity.Manufacturer; EdidModel = $identity.Model; EdidSerial = $identity.Serial; EdidName = $identity.EdidName
                            UserLabel = ""; DisplayLabel = $identity.DefaultLabel
                        }
                        Apply-MonitorIdentity -Monitor $monitorObject
                        $script:PhysicalMonitors += $monitorObject
                        $monitorIndex++
                    }
                }
            }
        }
    }
    $capableDeviceNames = @(@($script:PhysicalMonitors) | Where-Object { $_.Handle -ne [IntPtr]::Zero } | ForEach-Object { [string]$_.DeviceName })
    $script:DisplayPathInventory = @(Get-DisplayPathInventory -DdcCapableDeviceNames $capableDeviceNames)
    $script:GpuDriverAdvisories = @(Get-KnownBadGpuDriverAdvisory)
    $script:DdcAvailabilityDiagnosis = Get-DdcAvailabilityDiagnosis -Paths $script:DisplayPathInventory -GpuAdvisories $script:GpuDriverAdvisories -WmiBrightnessAvailable $script:WmiBrightnessAvailable
    if ($script:PhysicalMonitors.Count -eq 0) {
        $fallbackName = if ($script:WmiBrightnessAvailable) { "Integrated Laptop Display" } else { "No DDC/CI Monitor" }
        $fallbackDevice = if ($script:WmiBrightnessAvailable) { "WMI" } else { "" }
        $identity = New-MonitorIdentity -DisplayDeviceName $fallbackDevice -FriendlyName $fallbackName -Width 1920 -Height 1080 -MonitorIndex 1
        $fallbackObject = [PSCustomObject]@{
            Handle = [IntPtr]::Zero; HMonitor = [IntPtr]::Zero; Name = $fallbackName; Index = 1
            DeviceName = $fallbackDevice; Width = 1920; Height = 1080; RefreshRate = 60; IsPrimary = $true
            Left = 0; Top = 0; Right = 1920; Bottom = 1080; Capabilities = ""
            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false; VcpMaximums = @{}
            CapabilitiesExcluded = $false; CapabilitiesSafetyError = ""
            IdentityKey = $identity.Key; IdentitySource = $identity.Source; IdentityDefaultLabel = $identity.DefaultLabel
            DevicePath = $identity.DevicePath; MonitorDeviceString = $identity.DeviceString; HardwareId = $identity.HardwareId
            Manufacturer = $identity.Manufacturer; EdidModel = $identity.Model; EdidSerial = $identity.Serial; EdidName = $identity.EdidName
            UserLabel = ""; DisplayLabel = $identity.DefaultLabel
        }
        Apply-MonitorIdentity -Monitor $fallbackObject
        $script:PhysicalMonitors += $fallbackObject
    }
    Sync-DisplayRecoveryInventory
    if ($script:DdcAvailabilityDiagnosis -and [string]$script:DdcAvailabilityDiagnosis.Severity -ne "None") {
        Update-Status ([string]$script:DdcAvailabilityDiagnosis.Headline)
    }
    } finally {
        if (-not [MonitorAPI]::ResumeVCPWrites()) {
            throw "Monitor refresh could not resume the DDC write queue"
        }
    }
}

function Format-DdcDiagnostic {
    param([string]$Operation, [string]$Monitor, [int]$Code, $Value, [int]$LastError, [int]$Attempts, [string]$Message)
    $desc = Get-VcpDescription -Code $Code
    $monitorText = if ([string]::IsNullOrWhiteSpace($Monitor)) { "Unknown monitor" } else { $Monitor }
    $attemptedValue = if ($null -eq $Value) { "read" } else { [string]$Value }
    $retryCount = [Math]::Max(0, $Attempts - 1)
    $messageText = if ([string]::IsNullOrWhiteSpace($Message)) { "" } else { "`nMessage: $Message" }
    return "DDC/CI $Operation failed`nMonitor: $monitorText`nVCP: 0x$("{0:X2}" -f $Code) ($desc)`nAttempted value: $attemptedValue`nWin32 error: $LastError`nRetries: $retryCount$messageText"
}

function Register-DdcDiagnostic {
    param([string]$Operation, [string]$Monitor, [int]$Code, $Value, [int]$LastError, [int]$Attempts, [string]$Message, [switch]$SuppressStatus)
    $summary = Format-DdcDiagnostic -Operation $Operation -Monitor $Monitor -Code $Code -Value $Value -LastError $LastError -Attempts $Attempts -Message $Message
    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Operation = $Operation
        Monitor = $Monitor
        Code = $Code
        Value = $Value
        LastError = $LastError
        Attempts = $Attempts
        Message = $Message
        Summary = $summary
    }
    $script:DdcRecentErrors.Add($entry)
    while ($script:DdcRecentErrors.Count -gt $script:DdcRecentErrorLimit) { $script:DdcRecentErrors.RemoveAt(0) }
    Update-DdcDiagnosticsText
    if (-not $SuppressStatus) {
        Update-Status ("DDC/CI {0} failed: {1} 0x{2:X2} Win32 {3}" -f $Operation.ToLowerInvariant(), $Monitor, $Code, $LastError)
    }
    return $entry
}

function Drain-DdcWriteResults {
    $results = @([MonitorAPI]::DrainVCPWriteResults())
    foreach ($result in $results) {
        if (-not [bool]$result.Success) {
            Register-DdcDiagnostic -Operation "Write" -Monitor ([string]$result.MonitorName) -Code ([int]$result.Code) -Value ([uint32]$result.Value) -LastError ([int]$result.LastError) -Attempts ([int]$result.Attempts) -Message ([string]$result.ErrorMessage) | Out-Null
        }
    }
}

function New-DdcTimingProfile {
    param([string]$IdentityKey)
    return [PSCustomObject]@{
        IdentityKey = [string]$IdentityKey
        Mode = "Adaptive"
        SleepMultiplier = 1.0
        CalibratedAt = ""
        ReadRetries = [int][MonitorAPI]::VcpReadRetryCount
        WriteRetries = [int][MonitorAPI]::VcpWriteRetryCount
        CapabilityRetries = [int][MonitorAPI]::VcpReadRetryCount
        UnsupportedCodes = @()
    }
}

function Get-DdcTimingProfile {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return (New-DdcTimingProfile -IdentityKey "") }
    if (-not $script:DdcTimingProfiles.ContainsKey([string]$IdentityKey)) {
        $script:DdcTimingProfiles[[string]$IdentityKey] = New-DdcTimingProfile -IdentityKey ([string]$IdentityKey)
    }
    return $script:DdcTimingProfiles[[string]$IdentityKey]
}

function Get-DdcEffectiveTiming {
    param($TimingProfile)
    if ($null -eq $TimingProfile) { $TimingProfile = New-DdcTimingProfile -IdentityKey "" }
    $mode = [string]$TimingProfile.Mode
    # Manual is an override, not a modifier: an operator-set delay is used verbatim so the
    # calibration cannot quietly move it underneath them.
    $multiplier = if ($mode -eq "Manual") { 1.0 } else {
        [Math]::Min($script:DdcTimingMaxMultiplier, [Math]::Max($script:DdcTimingMinMultiplier, [double]$TimingProfile.SleepMultiplier))
    }
    $delay = [int][Math]::Round([MonitorAPI]::VcpRetryDelayMilliseconds * $multiplier, [System.MidpointRounding]::AwayFromZero)
    return [PSCustomObject]@{
        Mode = $mode
        SleepMultiplier = [double]$multiplier
        DelayMilliseconds = [int][MonitorAPI]::ClampRetryDelay($delay)
        ReadRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.ReadRetries))
        WriteRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.WriteRetries))
        CapabilityRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.CapabilityRetries))
    }
}

function Get-DdcWorkerTiming {
    param(
        [string]$IdentityKey,
        [int]$ReadRetries = -1,
        [int]$DelayMilliseconds = -1,
        $RecoveryState = $null
    )
    $effective = Get-DdcEffectiveTiming -TimingProfile (Get-DdcTimingProfile -IdentityKey $IdentityKey)
    $resolvedReadRetries = if ($ReadRetries -ge 0) {
        [Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, $ReadRetries))
    } else {
        Get-DisplayRecoveryReadRetryCount -State $RecoveryState -DefaultRetries ([int]$effective.ReadRetries)
    }
    $resolvedDelay = if ($DelayMilliseconds -ge 0) {
        [MonitorAPI]::ClampRetryDelay($DelayMilliseconds)
    } else {
        [int]$effective.DelayMilliseconds
    }
    return [PSCustomObject]@{
        ReadRetries = [int]$resolvedReadRetries
        CapabilityRetries = [int]$effective.CapabilityRetries
        DelayMilliseconds = [int]$resolvedDelay
    }
}

function Get-DdcCalibratedSleepMultiplier {
    param([int]$Attempts, [bool]$Success, [double]$Current = 1.0)
    # The delay only ever runs between retries, so a first-attempt success proves nothing
    # about it and leaves the multiplier alone. Every extra attempt the panel needed scales
    # the delay by that many times, bounded so one bad handshake cannot stall the app.
    if (-not $Success) { return [double]$Current }
    $attemptCount = [Math]::Max(1, $Attempts)
    if ($attemptCount -le 1) { return [double]$Current }
    $target = [double]$attemptCount
    if ($target -lt $script:DdcTimingMinMultiplier) { $target = $script:DdcTimingMinMultiplier }
    if ($target -gt $script:DdcTimingMaxMultiplier) { $target = $script:DdcTimingMaxMultiplier }
    return [double]$target
}

function Test-DdcCodeUnsupported {
    param($TimingProfile, [int]$Code)
    if ($null -eq $TimingProfile) { return $false }
    foreach ($entry in @($TimingProfile.UnsupportedCodes)) {
        if ($null -ne $entry -and [int]$entry.Code -eq [int]$Code) { return $true }
    }
    return $false
}

function Register-DdcCodeOutcome {
    param($TimingProfile, [int]$Code, [bool]$Success, [int]$LastError = 0, [int]$Attempts = 0, [bool]$OtherCodesResponded = $false)
    if ($null -eq $TimingProfile) { return $false }
    if ($Success) {
        $remaining = @(@($TimingProfile.UnsupportedCodes) | Where-Object { $null -ne $_ -and [int]$_.Code -ne [int]$Code })
        $changed = @($remaining).Count -ne @($TimingProfile.UnsupportedCodes).Count
        $TimingProfile.UnsupportedCodes = $remaining
        return $changed
    }
    # A code that fails every retry on a monitor that answers other codes is signalling
    # "not supported", not "not ready". ddcutil documents panels that use the DDC Null
    # Message for both, and burning the full retry budget on each of them is what makes a
    # scan look like the app has hung.
    if (-not $OtherCodesResponded) { return $false }
    if ($Attempts -lt 2) { return $false }
    if (Test-DdcCodeUnsupported -TimingProfile $TimingProfile -Code $Code) { return $false }
    $TimingProfile.UnsupportedCodes = @(@($TimingProfile.UnsupportedCodes) + [PSCustomObject]@{
        Code = [int]$Code
        LastError = [int]$LastError
        ObservedAt = (Get-Date).ToString("o")
    })
    return $true
}

function Set-DdcTimingMode {
    param([string]$IdentityKey, [string]$Mode)
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    $requested = if ($Mode -eq "Manual") { "Manual" } else { "Adaptive" }
    if ([string]$timingProfile.Mode -eq $requested) { return $timingProfile }
    $timingProfile.Mode = $requested
    if ($requested -eq "Adaptive") {
        # Adaptive and manual are mutually exclusive, so re-entering adaptive discards the
        # stored calibration rather than mixing an operator value with a learned one.
        $timingProfile.SleepMultiplier = 1.0
        $timingProfile.CalibratedAt = ""
    }
    return $timingProfile
}

function Clear-DdcTimingCalibration {
    param([string]$IdentityKey)
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    $timingProfile.SleepMultiplier = 1.0
    $timingProfile.CalibratedAt = ""
    $timingProfile.UnsupportedCodes = @()
    return $timingProfile
}

function Update-DdcTimingCalibration {
    param([string]$IdentityKey, [int]$Attempts, [bool]$Success)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    if ([string]$timingProfile.Mode -ne "Adaptive") { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { return $false }
    if (-not $Success) { return $false }
    $timingProfile.SleepMultiplier = Get-DdcCalibratedSleepMultiplier -Attempts $Attempts -Success $Success -Current ([double]$timingProfile.SleepMultiplier)
    $timingProfile.CalibratedAt = (Get-Date).ToString("o")
    return $true
}

function Test-DdcMonitorResponded {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    return [bool]$script:DdcRespondedIdentityKeys.ContainsKey([string]$IdentityKey)
}

function Get-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [string]$MonitorName = "", [string]$IdentityKey = "")
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { $IdentityKey = Get-IdentityKeyForHandle -Handle $Handle }
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    if (Test-DdcCodeUnsupported -TimingProfile $timingProfile -Code ([int]$VCPCode)) {
        return @{ Success = $false; Current = [uint32]0; Maximum = [uint32]0; Type = [uint32]0; LastError = 0; Attempts = 0; RetryCount = 0; Skipped = $true }
    }
    $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
    $vct = [uint32]0; $cur = [uint32]0; $max = [uint32]0
    $lastError = [int]0; $attempts = [int]0
    $result = [MonitorAPI]::ReadVCPWithRetry($Handle, $VCPCode, [int]$timing.ReadRetries, [int]$timing.DelayMilliseconds, [ref]$vct, [ref]$cur, [ref]$max, [ref]$lastError, [ref]$attempts)
    if (-not [string]::IsNullOrWhiteSpace($IdentityKey)) {
        $dirty = Update-DdcTimingCalibration -IdentityKey $IdentityKey -Attempts $attempts -Success $result
        if (Register-DdcCodeOutcome -TimingProfile $timingProfile -Code ([int]$VCPCode) -Success $result -LastError $lastError -Attempts $attempts -OtherCodesResponded (Test-DdcMonitorResponded -IdentityKey $IdentityKey)) { $dirty = $true }
        if ($dirty) { Save-DdcTimingSettings | Out-Null }
        if ($result) { $script:DdcRespondedIdentityKeys[$IdentityKey] = $true }
    }
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Read" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $null -LastError $lastError -Attempts $attempts -Message "" -SuppressStatus | Out-Null
    }
    return @{ Success = $result; Current = $cur; Maximum = $max; Type = $vct; LastError = $lastError; Attempts = $attempts; RetryCount = [Math]::Max(0, $attempts - 1); Skipped = $false }
}

function Set-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$MonitorName = "")
    $lastError = [int]0; $attempts = [int]0
    $timing = Get-DdcEffectiveTiming -TimingProfile (Get-DdcTimingProfile -IdentityKey (Get-IdentityKeyForHandle -Handle $Handle))
    $result = [MonitorAPI]::SetVCPWithRetry($Handle, $VCPCode, $Value, [int]$timing.WriteRetries, [int]$timing.DelayMilliseconds, [ref]$lastError, [ref]$attempts)
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Write" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $Value -LastError $lastError -Attempts $attempts -Message "" | Out-Null
    }
    return $result
}

function Queue-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$Key, [string]$MonitorName = "", [switch]$ForceWrite)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    return [bool][MonitorAPI]::QueueVCPWrite($Handle, $VCPCode, $Value, $Key, $MonitorName, [bool]$ForceWrite)
}

function Get-SuppressedDdcWriteCount {
    try { return [int64][MonitorAPI]::GetSuppressedVcpWriteCount() } catch { return [int64]0 }
}

function Invoke-SelectedMonitorVcpReread {
    param([scriptblock]$RefreshAction)
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return $false }
    $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if ($null -eq $monitor -or $monitor.Handle -eq [IntPtr]::Zero) {
        Update-Status "No DDC/CI values are available to re-read for the selected display"
        return $false
    }
    [MonitorAPI]::InvalidateVcpValueCacheForHandle([IntPtr]$monitor.Handle)
    Update-Status "Re-reading DDC/CI values from $(Get-MonitorDisplayLabel -Monitor $monitor)..."
    if ($null -eq $RefreshAction) { Load-MonitorSettings } else { & $RefreshAction }
    return $true
}

function Resolve-VcpWriteValueForMonitor {
    param($Monitor, [int]$Code, [uint32]$Value, [switch]$Percent)
    if (-not $Percent -or -not (Test-VcpCodeIsScaled -Code $Code)) { return [uint32]$Value }
    $maximum = Get-VcpMaximumForMonitor -Monitor $Monitor -Code $Code
    return [uint32](ConvertTo-VcpRawValue -Percent ([double]$Value) -Maximum $maximum)
}

function Set-VCPValueWithSync {
    param([byte]$VCPCode, [uint32]$Value, [switch]$Force, [switch]$Percent, [switch]$UserInitiated)
    if (Test-VcpWriteRequiresSafetyConsent -Code ([int]$VCPCode)) {
        if (Get-Command Update-Status -ErrorAction SilentlyContinue) {
            Update-Status "Risky VCP 0x$("{0:X2}" -f $VCPCode) requires the verified manual or consented automation path"
        }
        return $false
    }
    $code = [int]$VCPCode
    # WMI brightness is always expressed as a percentage, so an unscaled caller has to be
    # converted from the selected monitor's range before it reaches the integrated panel.
    $wmiPercent = if ($Percent) {
        [uint32][Math]::Max(0, [Math]::Min(100, [int]$Value))
    } else {
        [uint32](ConvertTo-VcpPercent -RawValue ([double]$Value) -Maximum (Get-SelectedMonitorVcpMaximum -Code $code))
    }
    $queued = 0
    if ($script:ApplyToAll -or $Force) {
        for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
            $mon = $script:PhysicalMonitors[$i]
            $target = Resolve-VcpWriteValueForMonitor -Monitor $mon -Code $code -Value $Value -Percent:$Percent
            if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $target -Key "$i`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name -ForceWrite:$UserInitiated) { $queued++ }
        }
        if ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $wmiPercent | Out-Null }
    } else {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        $target = Resolve-VcpWriteValueForMonitor -Monitor $mon -Code $code -Value $Value -Percent:$Percent
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $target -Key "$script:CurrentMonitorIndex`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name -ForceWrite:$UserInitiated) { $queued++ }
        elseif ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $wmiPercent | Out-Null }
    }
    if ($queued -gt 0) { return $true }
    return ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable)
}

function Get-VcpWriteOperation {
    param($Monitor, [int]$Code, [uint32]$Value, [string]$Backend = "DDC")
    return [PSCustomObject]@{
        Monitor = $Monitor
        MonitorName = if ($Monitor) { [string]$Monitor.Name } else { "Integrated display" }
        IdentityKey = if ($Monitor) { [string]$Monitor.IdentityKey } else { "wmi:integrated" }
        Handle = if ($Monitor) { [IntPtr]$Monitor.Handle } else { [IntPtr]::Zero }
        Code = [int]$Code
        Value = [uint32]$Value
        Backend = $Backend
    }
}

function Invoke-VerifiedVcpTransaction {
    param(
        [object[]]$Operations,
        [scriptblock]$ReadValue,
        [scriptblock]$WriteValue,
        [switch]$RollbackOnFailure,
        [int]$VerificationDelayMs = 75
    )
    $items = @($Operations | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Outcome = "NoTargets"; Results = @(); Rollback = "NotNeeded" }
    }
    if ($null -eq $ReadValue) {
        $ReadValue = {
            param($Operation)
            if ([string]$Operation.Backend -eq "WMI") {
                $current = Get-WmiBrightness
                return [PSCustomObject]@{ Success = $null -ne $current; Current = if ($null -ne $current) { [uint32]$current } else { [uint32]0 } }
            }
            return Get-VCPValue -Handle ([IntPtr]$Operation.Handle) -VCPCode ([byte]$Operation.Code) -MonitorName ([string]$Operation.MonitorName)
        }
    }
    if ($null -eq $WriteValue) {
        $WriteValue = {
            param($Operation, [uint32]$TargetValue)
            if ([string]$Operation.Backend -eq "WMI") {
                return (Set-WmiBrightness -Value $TargetValue)
            }
            return (Set-VCPValue -Handle ([IntPtr]$Operation.Handle) -VCPCode ([byte]$Operation.Code) -Value $TargetValue -MonitorName ([string]$Operation.MonitorName))
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $applied = New-Object System.Collections.Generic.List[object]
    $failureOutcome = ""
    foreach ($operation in $items) {
        $snapshot = $null
        try { $snapshot = & $ReadValue $operation } catch { $snapshot = $null }
        $snapshotReadable = $null -ne $snapshot -and [bool]$snapshot.Success
        $previousValue = if ($snapshotReadable) { [uint32]$snapshot.Current } else { [uint32]0 }
        $writeSucceeded = $false
        try { $writeSucceeded = [bool](& $WriteValue $operation ([uint32]$operation.Value)) } catch { $writeSucceeded = $false }
        $verification = "WriteFailed"
        $readbackValue = [uint32]0
        if ($writeSucceeded) {
            if ($VerificationDelayMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(1000, $VerificationDelayMs)) }
            $readback = $null
            try { $readback = & $ReadValue $operation } catch { $readback = $null }
            if ($null -eq $readback -or -not [bool]$readback.Success) {
                $verification = "Unverified"
            } else {
                $readbackValue = [uint32]$readback.Current
                $verification = if ($readbackValue -eq [uint32]$operation.Value) { "Verified" } else { "Mismatched" }
            }
        }
        $record = [PSCustomObject]@{
            Operation = $operation
            PreviousReadable = [bool]$snapshotReadable
            PreviousValue = $previousValue
            WriteSuccess = [bool]$writeSucceeded
            Verification = $verification
            ReadbackValue = $readbackValue
            Rollback = "NotNeeded"
        }
        $results.Add($record)
        if ($writeSucceeded -or $snapshotReadable) { $applied.Add($record) }
        if (-not $writeSucceeded) {
            $failureOutcome = "WriteFailed"
            break
        }
        if ($verification -eq "Mismatched") {
            $failureOutcome = "Mismatched"
            break
        }
    }

    $rollbackStatus = "NotNeeded"
    if ($failureOutcome -and $RollbackOnFailure) {
        $rollbackStatus = "Restored"
        for ($index = $applied.Count - 1; $index -ge 0; $index--) {
            $record = $applied[$index]
            if (-not [bool]$record.PreviousReadable) {
                $record.Rollback = "Unavailable"
                $rollbackStatus = "Partial"
                continue
            }
            $restored = $false
            try { $restored = [bool](& $WriteValue $record.Operation ([uint32]$record.PreviousValue)) } catch { $restored = $false }
            if (-not $restored) {
                $record.Rollback = "WriteFailed"
                $rollbackStatus = "Partial"
                continue
            }
            if ($VerificationDelayMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(1000, $VerificationDelayMs)) }
            $rollbackRead = $null
            try { $rollbackRead = & $ReadValue $record.Operation } catch { $rollbackRead = $null }
            if ($null -eq $rollbackRead -or -not [bool]$rollbackRead.Success) {
                $record.Rollback = "Unverified"
                $rollbackStatus = "Partial"
            } elseif ([uint32]$rollbackRead.Current -ne [uint32]$record.PreviousValue) {
                $record.Rollback = "Mismatched"
                $rollbackStatus = "Partial"
            } else {
                $record.Rollback = "Restored"
            }
        }
    }

    if ($failureOutcome) {
        return [PSCustomObject]@{
            Success = $false
            Outcome = $failureOutcome
            Results = $results.ToArray()
            Rollback = $rollbackStatus
        }
    }
    $unverifiedCount = @($results | Where-Object Verification -eq "Unverified").Count
    return [PSCustomObject]@{
        Success = $true
        Outcome = if ($unverifiedCount -gt 0) { "Unverified" } else { "Verified" }
        Results = $results.ToArray()
        Rollback = "NotNeeded"
    }
}

function Get-VcpWriteRiskNote {
    param([int]$Code)
    switch ($Code) {
        0x14 { return "Some monitors keep a color preset after this app closes and need a factory reset to undo it." }
        0xCA { return "This can disable the monitor's own buttons and on-screen menu, which is the only way to recover a display that stops responding to software." }
        0xCC { return "This changes the language of the monitor's own on-screen menu, which can make its settings hard to read." }
        0xD6 { return "Some monitors enter standby and will not wake from software; recovery may need the physical power button or a cable reseat." }
        0xD7 { return "This changes auxiliary power output, which can cut power to devices attached to the monitor." }
        0x60 { return "If the selected input has no signal the screen goes black, and software control may be unavailable until you switch back with the monitor's buttons." }
        0x04 { return "This resets every monitor setting to factory defaults and cannot be undone from this app." }
        0x08 { return "This resets the monitor's color settings to factory defaults." }
        default { return "" }
    }
}

function Format-VcpWriteConfirmation {
    param([object[]]$Operations, [string]$ActionLabel = "Direct VCP write")
    $items = @($Operations)
    $code = if ($items.Count -gt 0) { [int]$items[0].Code } else { 0 }
    $value = if ($items.Count -gt 0) { [uint32]$items[0].Value } else { 0 }
    $targets = @($items | ForEach-Object { [string]$_.MonitorName } | Sort-Object -Unique)
    $riskNote = Get-VcpWriteRiskNote -Code $code
    $riskLine = if ([string]::IsNullOrWhiteSpace($riskNote)) { "" } else { "$riskNote`n`n" }
    return @"
$ActionLabel

VCP code: 0x$("{0:X2}" -f $code) ($(Get-VcpDescription -Code $code))
Value: $value
Target: $($targets -join ", ")

$riskLine`This write may blank the display, change its input, remove access to the current desktop, or reset monitor settings. MonitorControl Pro will attempt an immediate readback, but some commands cannot be verified after the display changes state.

Apply this exact code and value?
"@
}

function Get-VcpDescription {
    param([int]$Code)
    if ($script:VCPCodeDescriptions.ContainsKey($Code)) { return $script:VCPCodeDescriptions[$Code] }
    return "Unknown"
}

function Format-VcpResultLine {
    param($Result)
    $code = [int]$Result.Code
    $desc = Get-VcpDescription -Code $code
    if ([bool]$Result.Success) {
        return "0x{0:X2} {1,-24} = {2} (max:{3})" -f $code, $desc, [uint32]$Result.Current, [uint32]$Result.Maximum
    }
    return "0x{0:X2} {1,-24} read failed (Win32:{2}, retries:{3})" -f $code, $desc, [int]$Result.LastError, [int]$Result.RetryCount
}

function Stop-VcpWorker {
    param([switch]$Cancel)
    if ($script:VcpWorkerTimer) { $script:VcpWorkerTimer.Stop() }
    if ($script:VcpWorker) {
        if ($Cancel -and $script:VcpWorkerAsyncResult -and -not $script:VcpWorkerAsyncResult.IsCompleted) {
            try { $script:VcpWorker.Stop() } catch {}
        }
        try { $script:VcpWorker.Dispose() } catch {}
    }
    if ($script:VcpWorkerInput) { try { $script:VcpWorkerInput.Dispose() } catch {} }
    if ($script:VcpWorkerOutput) { try { $script:VcpWorkerOutput.Dispose() } catch {} }
    $script:VcpWorker = $null
    $script:VcpWorkerInput = $null
    $script:VcpWorkerOutput = $null
    $script:VcpWorkerAsyncResult = $null
    $script:VcpWorkerMode = ""
    $script:VcpWorkerMonitorName = ""
    $script:VcpWorkerLastOutputCount = 0
    $script:VcpWorkerGeneration = -1
    $script:VcpWorkerIdentityKey = ""
    $script:VcpWorkerMonitorIndex = -1
    $script:VcpWorkerHandleValue = [int64]0
    Set-VcpWorkerUiIdle
}

function Update-VcpWorkerOutput {
    if (-not $script:VcpWorker -or -not $script:VcpWorkerOutput -or -not $script:VcpWorkerAsyncResult) { return }
    $context = [PSCustomObject]@{
        Generation = [int]$script:VcpWorkerGeneration
        MonitorIndex = [int]$script:VcpWorkerMonitorIndex
        IdentityKey = [string]$script:VcpWorkerIdentityKey
        HandleValue = [int64]$script:VcpWorkerHandleValue
    }
    if (-not (Test-DisplayWorkerResultCurrent -Result $context -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) {
        Stop-VcpWorker -Cancel
        return
    }
    $count = $script:VcpWorkerOutput.Count
    $completed = [bool]$script:VcpWorkerAsyncResult.IsCompleted
    if ($count -ne $script:VcpWorkerLastOutputCount -or $completed) {
        $script:VcpWorkerLastOutputCount = $count
        $items = @($script:VcpWorkerOutput | Where-Object {
            Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
        })
        if ($script:VcpWorkerMode -eq "Query") {
            if ($items.Count -gt 0) {
                $result = $items[-1]
                $code = [int]$result.Code
                $desc = Get-VcpDescription -Code $code
                if ([bool]$result.Success) {
                    Set-VcpWorkerResultText -Text "VCP 0x$("{0:X2}" -f $code) ($desc)`nCurrent: $($result.Current)`nMaximum: $($result.Maximum)"
                } else {
                    Set-VcpWorkerResultText -Text (Format-DdcDiagnostic -Operation "Read" -Monitor ([string]$result.MonitorName) -Code $code -Value $null -LastError ([int]$result.LastError) -Attempts ([int]$result.Attempts) -Message "")
                }
            } else {
                Set-VcpWorkerResultText -Text "Reading VCP..."
            }
        } else {
            $last = if ($items.Count -gt 0) { $items[-1] } else { $null }
            $done = if ($last) { [int]$last.Index } else { 0 }
            $total = if ($last) { [int]$last.Count } else { 0 }
            $found = @($items | Where-Object { [bool]$_.Success } | ForEach-Object { Format-VcpResultLine -Result $_ })
            $failed = @($items | Where-Object { -not [bool]$_.Success } | ForEach-Object { Format-VcpResultLine -Result $_ })
            $scanMonitor = if ([string]::IsNullOrWhiteSpace($script:VcpWorkerMonitorName)) { "selected monitor" } else { $script:VcpWorkerMonitorName }
            $header = if ($completed) { "Supported VCP Codes for ${scanMonitor}:" } else { "Scanning VCP codes $done/$total..." }
            if ($completed) {
                $sections = @()
                if ($found.Count -gt 0) { $sections += "Readable:`n$($found -join "`n")" } else { $sections += "Readable:`nNone found" }
                if ($failed.Count -gt 0) { $sections += "Failed or unsupported:`n$($failed -join "`n")" }
                $body = $sections -join "`n`n"
            } else {
                $body = if ($found.Count -gt 0) { $found -join "`n" } else { "" }
            }
            Set-VcpWorkerResultText -Text "$header`n$body"
        }
    }
    if ($completed) {
        try { $script:VcpWorker.EndInvoke($script:VcpWorkerAsyncResult) } catch { Update-Status "VCP read failed: $($_.Exception.Message)" }
        $items = @($script:VcpWorkerOutput | Where-Object {
            Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
        })
        if ($script:VcpWorkerMode -eq "Query" -and $items.Count -gt 0 -and -not [bool]$items[-1].Success) {
            $failure = $items[-1]
            Register-DdcDiagnostic -Operation "Read" -Monitor ([string]$failure.MonitorName) -Code ([int]$failure.Code) -Value $null -LastError ([int]$failure.LastError) -Attempts ([int]$failure.Attempts) -Message "" | Out-Null
        }
        if (@($items | Where-Object { [bool]$_.Success }).Count -gt 0) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$context.IdentityKey) -Outcome "Success" -Generation $script:DisplayRecoveryGeneration | Out-Null
        } elseif ($items.Count -gt 0) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$context.IdentityKey) -Outcome "Failure" -Generation $script:DisplayRecoveryGeneration -ErrorMessage "VCP read failed" | Out-Null
        }
        if ($script:VcpWorkerMode -eq "Scan") { Update-Status "VCP scan complete" }
        Stop-VcpWorker
    }
}

function Get-DdcReportProbeCodes {
    return @(
        [int][MonitorAPI]::VCP_BRIGHTNESS,
        [int][MonitorAPI]::VCP_CONTRAST,
        [int][MonitorAPI]::VCP_COLOR_PRESET,
        [int][MonitorAPI]::VCP_RED_GAIN,
        [int][MonitorAPI]::VCP_GREEN_GAIN,
        [int][MonitorAPI]::VCP_BLUE_GAIN,
        [int][MonitorAPI]::VCP_VOLUME,
        [int][MonitorAPI]::VCP_MUTE,
        [int][MonitorAPI]::VCP_SHARPNESS,
        [int][MonitorAPI]::VCP_DISPLAY_USAGE_TIME,
        [int][MonitorAPI]::VCP_DISPLAY_MODE,
        [int][MonitorAPI]::VCP_VERSION
    )
}

function Format-DdcReportCodeList {
    param([object[]]$Codes)
    $items = @($Codes | ForEach-Object { [int]$_ } | Sort-Object -Unique | ForEach-Object { "0x{0:X2}" -f $_ })
    if ($items.Count -eq 0) { return "None parsed" }
    return ($items -join ", ")
}

function Get-DdcReportTargets {
    $allProbeCodes = @(Get-DdcReportProbeCodes)
    $targets = @()
    for ($monitorIndex = 0; $monitorIndex -lt $script:PhysicalMonitors.Count; $monitorIndex++) {
        $mon = $script:PhysicalMonitors[$monitorIndex]
        if ($null -eq $mon) { continue }
        $supportedCodes = @()
        if ([bool]$mon.CapabilitiesKnown -and $mon.SupportedVcpCodes) {
            $supportedCodes = @($mon.SupportedVcpCodes.Keys | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        }
        $probeCodes = @($allProbeCodes)
        $skippedCodes = @()
        if ($supportedCodes.Count -gt 0) {
            $probeCodes = @($allProbeCodes | Where-Object { $supportedCodes -contains $_ })
            $skippedCodes = @($allProbeCodes | Where-Object { $supportedCodes -notcontains $_ })
        }
        $capabilityStatus = if ([bool]$mon.CapabilitiesPending) {
            "Pending"
        } elseif ([bool]$mon.CapabilitiesKnown) {
            "Known"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$mon.Capabilities)) {
            "Raw available; parser found no VCP map"
        } else {
            "Unavailable"
        }
        $targets += [PSCustomObject]@{
            Index = [int]$mon.Index
            MonitorIndex = [int]$monitorIndex
            Label = [string](Get-MonitorDisplayLabel -Monitor $mon)
            Name = [string]$mon.Name
            DeviceName = [string]$mon.DeviceName
            DevicePath = [string]$mon.DevicePath
            HardwareId = [string]$mon.HardwareId
            IdentityKey = [string]$mon.IdentityKey
            IdentitySource = [string]$mon.IdentitySource
            Manufacturer = [string]$mon.Manufacturer
            EdidModel = [string]$mon.EdidModel
            EdidSerial = [string]$mon.EdidSerial
            EdidName = [string]$mon.EdidName
            Resolution = "{0}x{1}@{2}Hz" -f [int]$mon.Width, [int]$mon.Height, [int]$mon.RefreshRate
            Primary = [bool]$mon.IsPrimary
            CapabilityStatus = $capabilityStatus
            CapabilitiesLength = if ($mon.Capabilities) { [int]$mon.Capabilities.Length } else { 0 }
            SupportedCodes = [object[]]$supportedCodes
            ProbeCodes = [object[]]$probeCodes
            SkippedProbeCodes = [object[]]$skippedCodes
            RiskyWritesEnabled = Test-VcpWriteEnabledForMonitor -Monitor $mon
            RecoveryState = if ($mon.PSObject.Properties.Name -contains "RecoveryState") { [string]$mon.RecoveryState } else { "Stale" }
            RecoveryLastSuccessUtc = if ($mon.PSObject.Properties.Name -contains "RecoveryLastSuccessUtc") { $mon.RecoveryLastSuccessUtc } else { $null }
            DdcLastProbeUtc = if ($mon.PSObject.Properties.Name -contains "DdcLastProbeUtc") { $mon.DdcLastProbeUtc } else { $null }
            DdcLastSuccessfulProbeUtc = if ($mon.PSObject.Properties.Name -contains "DdcLastSuccessfulProbeUtc") { $mon.DdcLastSuccessfulProbeUtc } elseif ($script:DdcLivenessLastSuccessUtc.ContainsKey([string]$mon.IdentityKey)) { $script:DdcLivenessLastSuccessUtc[[string]$mon.IdentityKey] } else { $null }
            DdcLastProbeSucceeded = if ($mon.PSObject.Properties.Name -contains "DdcLastProbeSucceeded") { [bool]$mon.DdcLastProbeSucceeded } else { $null }
            Handle = $mon.Handle
            HandleValue = [int64]$mon.Handle.ToInt64()
            Generation = [int]$script:DisplayRecoveryGeneration
        }
    }
    return $targets
}

function Get-DdcReportSystemInfo {
    $osText = [Environment]::OSVersion.VersionString
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os) { $osText = "{0} {1} (build {2})" -f $os.Caption, $os.Version, $os.BuildNumber }
    } catch {}
    $gpuLines = @()
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        foreach ($gpu in $gpus) {
            $name = if ($gpu.Name) { [string]$gpu.Name } else { "Unknown GPU" }
            $driver = if ($gpu.DriverVersion) { [string]$gpu.DriverVersion } else { "unknown driver" }
            $gpuLines += "$name | driver $driver"
        }
    } catch {}
    if ($gpuLines.Count -eq 0) { $gpuLines = @("No GPU driver data available") }
    return [PSCustomObject]@{
        OS = $osText
        PowerShell = $PSVersionTable.PSVersion.ToString()
        GPUs = [object[]]$gpuLines
    }
}

function Get-DdcReportRecentErrors {
    return @($script:DdcRecentErrors | Sort-Object -Property Timestamp -Descending | Select-Object -First 8)
}

function Format-DdcReportProbeLine {
    param($Result)
    if ([bool]$Result.Skipped) { return "  - skipped: $($Result.Message)" }
    $code = [int]$Result.Code
    $desc = Get-VcpDescription -Code $code
    if ([bool]$Result.Success) {
        return "  - 0x{0:X2} {1}: OK current={2} max={3} type={4}" -f $code, $desc, [uint32]$Result.Current, [uint32]$Result.Maximum, [uint32]$Result.Type
    }
    return "  - 0x{0:X2} {1}: failed Win32={2} retries={3}" -f $code, $desc, [int]$Result.LastError, [int]$Result.RetryCount
}

function New-DdcCompatibilityReport {
    param([object[]]$Targets, [object[]]$ProbeResults, [object[]]$RecentErrors)
    $system = Get-DdcReportSystemInfo
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("MonitorControl Pro DDC Compatibility Report")
    [void]$sb.AppendLine("Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))")
    [void]$sb.AppendLine("App version: 3.37.0")
    [void]$sb.AppendLine("OS: $($system.OS)")
    [void]$sb.AppendLine("PowerShell: $($system.PowerShell)")
    [void]$sb.AppendLine("Probe safety: read-only probes only; risky codes are never written automatically and power, input, reset, PiP/PbP, OSD, and arbitrary codes are not queried")
    $livenessInterval = if ($script:DdcLivenessProbeIntervalSeconds -gt 0) { [int]$script:DdcLivenessProbeIntervalSeconds } else { 60 }
    [void]$sb.AppendLine("DDC liveness: one read-only VCP query per monitor every $livenessInterval seconds; this probe never writes to a display")
    [void]$sb.AppendLine("Capability cache entries: $($script:CapabilitiesCache.Count); shipped known-bad models: $(@($script:CapabilitiesKnownBadModels).Count)")
    [void]$sb.AppendLine("Redundant writes suppressed this session: $(Get-SuppressedDdcWriteCount)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("GPU drivers:")
    foreach ($gpu in @($system.GPUs)) { [void]$sb.AppendLine("- $gpu") }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("DDC availability:")
    $diagnosis = $script:DdcAvailabilityDiagnosis
    if ($null -eq $diagnosis) {
        [void]$sb.AppendLine("- not evaluated")
    } else {
        [void]$sb.AppendLine("- $($diagnosis.Summary) (severity $($diagnosis.Severity))")
        foreach ($cause in @($diagnosis.Causes)) {
            [void]$sb.AppendLine("- $($cause.Title)")
            [void]$sb.AppendLine("    why: $($cause.Detail)")
            [void]$sb.AppendLine("    try: $($cause.Fix)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Display paths:")
    if (@($script:DisplayPathInventory).Count -eq 0) {
        [void]$sb.AppendLine("- none enumerated")
    } else {
        foreach ($path in @($script:DisplayPathInventory)) {
            $channelText = if ([bool]$path.HasControlChannel) { "DDC/CI channel" } else { "no DDC/CI channel" }
            [void]$sb.AppendLine("- $($path.DeviceName) [$($path.Kind)] $channelText | $($path.Name) | adapter $($path.Adapter)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("DDC timing (effective values):")
    if (@($Targets).Count -eq 0) {
        [void]$sb.AppendLine("- no monitors")
    } else {
        foreach ($target in @($Targets | Sort-Object -Property Index)) {
            $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$target.IdentityKey)
            $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
            $calibration = if ([string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { "uncalibrated" } else { "calibrated $($timingProfile.CalibratedAt)" }
            [void]$sb.AppendLine("- $($target.Label): mode=$($timing.Mode) multiplier=$($timing.SleepMultiplier) delay=$($timing.DelayMilliseconds)ms retries read=$($timing.ReadRetries) write=$($timing.WriteRetries) capability=$($timing.CapabilityRetries) ($calibration)")
            $unsupported = @($timingProfile.UnsupportedCodes)
            if ($unsupported.Count -gt 0) {
                $codeText = ($unsupported | ForEach-Object { "0x{0:X2} (Win32 {1})" -f [int]$_.Code, [int]$_.LastError }) -join ", "
                [void]$sb.AppendLine("    null-signalled unsupported: $codeText")
            }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Monitors:")
    foreach ($target in @($Targets | Sort-Object -Property Index)) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Monitor $($target.Index): $($target.Label)")
        [void]$sb.AppendLine("  Friendly name: $($target.Name)")
        [void]$sb.AppendLine("  Display device: $($target.DeviceName)")
        [void]$sb.AppendLine("  Resolution: $($target.Resolution)")
        [void]$sb.AppendLine("  Primary: $($target.Primary)")
        [void]$sb.AppendLine("  Identity: $($target.IdentityKey) ($($target.IdentitySource))")
        if (-not [string]::IsNullOrWhiteSpace([string]$target.HardwareId)) { [void]$sb.AppendLine("  Hardware ID: $($target.HardwareId)") }
        if (-not [string]::IsNullOrWhiteSpace([string]$target.DevicePath)) { [void]$sb.AppendLine("  Device path: $($target.DevicePath)") }
        $edidParts = @()
        if ($target.Manufacturer) { $edidParts += "manufacturer=$($target.Manufacturer)" }
        if ($target.EdidModel) { $edidParts += "model=$($target.EdidModel)" }
        if ($target.EdidSerial) { $edidParts += "serial=$($target.EdidSerial)" }
        if ($target.EdidName) { $edidParts += "name=$($target.EdidName)" }
        if ($edidParts.Count -gt 0) { [void]$sb.AppendLine("  EDID: $($edidParts -join "; ")") }
        [void]$sb.AppendLine("  Capabilities: $($target.CapabilityStatus), length=$($target.CapabilitiesLength), parsed codes=$(@($target.SupportedCodes).Count)")
        [void]$sb.AppendLine("  Parsed VCP list: $(Format-DdcReportCodeList -Codes $target.SupportedCodes)")
        $recoverySuccess = if ($null -ne $target.RecoveryLastSuccessUtc) { ([DateTime]$target.RecoveryLastSuccessUtc).ToString("o") } else { "never" }
        [void]$sb.AppendLine("  Recovery: $($target.RecoveryState), last successful read=$recoverySuccess")
        $livenessSuccess = if ($null -ne $target.DdcLastSuccessfulProbeUtc) { ([DateTime]$target.DdcLastSuccessfulProbeUtc).ToString("o") } else { "never" }
        $livenessAttempt = if ($null -ne $target.DdcLastProbeUtc) { ([DateTime]$target.DdcLastProbeUtc).ToString("o") } else { "never" }
        [void]$sb.AppendLine("  Liveness probe: last success=$livenessSuccess, last attempt=$livenessAttempt")
        [void]$sb.AppendLine("  Risky VCP writes: $(if ([bool]$target.RiskyWritesEnabled) { 'identity unlocked; direct confirmation still required' } else { 'disabled' })")
        if (@($target.SkippedProbeCodes).Count -gt 0) {
            [void]$sb.AppendLine("  Common probes skipped by capabilities: $(Format-DdcReportCodeList -Codes $target.SkippedProbeCodes)")
        }
        [void]$sb.AppendLine("  Tested VCP results:")
        $monitorResults = @($ProbeResults | Where-Object { [int]$_.TargetIndex -eq [int]$target.Index } | Sort-Object -Property ProbeIndex)
        if ([int64]$target.HandleValue -eq 0) {
            [void]$sb.AppendLine("  - no DDC/CI handle; probes skipped")
        } elseif ($monitorResults.Count -eq 0) {
            [void]$sb.AppendLine("  - no common probe codes available")
        } else {
            foreach ($result in $monitorResults) { [void]$sb.AppendLine((Format-DdcReportProbeLine -Result $result)) }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Recent DDC errors:")
    if (@($RecentErrors).Count -eq 0) {
        [void]$sb.AppendLine("- None recorded in this session")
    } else {
        foreach ($entry in @($RecentErrors)) {
            [void]$sb.AppendLine("- $($entry.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")) | $($entry.Operation) | monitor=$($entry.Monitor) | VCP=0x$("{0:X2}" -f [int]$entry.Code) | Win32=$($entry.LastError) | attempts=$($entry.Attempts)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Privacy: local script, profile, and report file paths are omitted.")
    return $sb.ToString().TrimEnd()
}

function Save-DdcCompatibilityReport {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $dir = Join-Path $script:DefaultProfilesPath "diagnostics"
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $leaf = "ddc-compatibility-report-$((Get-Date).ToString("yyyyMMdd-HHmmss")).txt"
        $path = Join-Path $dir $leaf
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, ($Text + [Environment]::NewLine), $encoding)
        return $path
    } catch {
        return ""
    }
}

function Stop-DdcReportWorker {
    param([switch]$Cancel)
    if ($script:DdcReportWorkerTimer) { $script:DdcReportWorkerTimer.Stop() }
    if ($script:DdcReportWorker) {
        if ($Cancel -and $script:DdcReportWorkerAsyncResult -and -not $script:DdcReportWorkerAsyncResult.IsCompleted) {
            try { $script:DdcReportWorker.Stop() } catch {}
        }
        try { $script:DdcReportWorker.Dispose() } catch {}
    }
    if ($script:DdcReportWorkerInput) { try { $script:DdcReportWorkerInput.Dispose() } catch {} }
    if ($script:DdcReportWorkerOutput) { try { $script:DdcReportWorkerOutput.Dispose() } catch {} }
    $script:DdcReportWorker = $null
    $script:DdcReportWorkerInput = $null
    $script:DdcReportWorkerOutput = $null
    $script:DdcReportWorkerAsyncResult = $null
    $script:DdcReportWorkerLastOutputCount = 0
    $script:DdcReportTargets = @()
    $script:DdcReportWorkerGeneration = -1
    Set-DdcReportWorkerUiIdle
}

function Stop-MonitorSettingsWorker {
    param([switch]$Cancel)
    if ($script:MonitorSettingsWorkerTimer) { $script:MonitorSettingsWorkerTimer.Stop() }
    if ($script:MonitorSettingsWorker) {
        if ($Cancel -and $script:MonitorSettingsWorkerAsyncResult -and -not $script:MonitorSettingsWorkerAsyncResult.IsCompleted) {
            try { $script:MonitorSettingsWorker.Stop() } catch {}
        }
        try { $script:MonitorSettingsWorker.Dispose() } catch {}
    }
    if ($script:MonitorSettingsWorkerInput) { try { $script:MonitorSettingsWorkerInput.Dispose() } catch {} }
    if ($script:MonitorSettingsWorkerOutput) { try { $script:MonitorSettingsWorkerOutput.Dispose() } catch {} }
    $script:MonitorSettingsWorker = $null
    $script:MonitorSettingsWorkerInput = $null
    $script:MonitorSettingsWorkerOutput = $null
    $script:MonitorSettingsWorkerAsyncResult = $null
    $script:MonitorSettingsWorkerIndex = -1
    $script:MonitorSettingsWorkerName = ""
    $script:MonitorSettingsWorkerLastOutputCount = 0
    $script:MonitorSettingsWorkerGeneration = -1
    $script:MonitorSettingsWorkerTotalReads = 0
    $script:MonitorSettingsWorkerTargets = @()
}

function Set-GammaRamp {
    param([double]$Gamma = 1.0, [double]$RedMult = 1.0, [double]$GreenMult = 1.0, [double]$BlueMult = 1.0)
    $hdc = [MonitorAPI]::GetDC([IntPtr]::Zero)
    if ($hdc -eq [IntPtr]::Zero) { return }
    try {
        $ramp = New-Object MonitorAPI+RAMP
        $ramp.Red = [UInt16[]]::new(256); $ramp.Green = [UInt16[]]::new(256); $ramp.Blue = [UInt16[]]::new(256)
        for ($i = 0; $i -lt 256; $i++) {
            $normalized = $i / 255.0
            $ramp.Red[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $RedMult)))
            $ramp.Green[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $GreenMult)))
            $ramp.Blue[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $BlueMult)))
        }
        [MonitorAPI]::SetDeviceGammaRamp($hdc, [ref]$ramp) | Out-Null
    } finally { [MonitorAPI]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null }
}
