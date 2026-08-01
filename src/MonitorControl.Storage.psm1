# MonitorControl Pro Storage source module.

# Dot-sourced by the development launcher and composed into the portable release.



function Test-JsonFileValid {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Move-CorruptJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $dir "$leaf.corrupt-$stamp"
    $suffix = 0
    while (Test-Path -LiteralPath $target) {
        $suffix++
        $target = Join-Path $dir "$leaf.corrupt-$stamp-$suffix"
    }
    try {
        Move-Item -LiteralPath $fullPath -Destination $target -Force
        return $target
    } catch {
        return ""
    }
}

function Read-JsonFileSafely {
    param([string]$Path, [string]$Label = "JSON", [switch]$ReadOnly)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        $backupPath = "$Path.bak"
        if ($ReadOnly) {
            if (Test-Path -LiteralPath $backupPath) {
                try {
                    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
                    Set-DeferredStatus "$Label JSON corrupt; read-only fallback left untouched and backup loaded"
                    return $backup
                } catch { $null = $_ }
            }
            Set-DeferredStatus "$Label JSON corrupt; read-only fallback left untouched"
            return $null
        }
        $quarantinePath = Move-CorruptJsonFile -Path $Path
        $leaf = if ($quarantinePath) { Split-Path -Path $quarantinePath -Leaf } else { "quarantine failed" }
        if (Test-Path -LiteralPath $backupPath) {
            try {
                $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
                Set-DeferredStatus "$Label JSON corrupt; quarantined to $leaf and loaded backup"
                return $backup
            } catch {}
        }
        Set-DeferredStatus "$Label JSON corrupt; quarantined to $leaf"
        return $null
    }
}

function Write-JsonFileSafely {
    param([string]$Path, $Data, [int]$Depth = 4)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    $tempPath = Join-Path $dir ".$leaf.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Data | ConvertTo-Json -Depth $Depth
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, ($json + [Environment]::NewLine), $encoding)
        $backupPath = "$fullPath.bak"
        if (Test-Path -LiteralPath $fullPath) {
            if (Test-JsonFileValid -Path $fullPath) {
                [System.IO.File]::Replace($tempPath, $fullPath, $backupPath)
            } else {
                Move-CorruptJsonFile -Path $fullPath | Out-Null
                [System.IO.File]::Move($tempPath, $fullPath)
            }
        } else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
        return $true
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Set-DeferredStatus "JSON write failed: $($_.Exception.Message)"
        return $false
    }
}

function Resolve-ProfileStorageRootState {
    param(
        $Settings,
        [string]$DefaultPath,
        [int]$CurrentSchemaVersion = 2
    )
    $defaultFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DefaultPath))
    $configuredPath = $defaultFullPath
    $fallbackPath = $defaultFullPath
    $previousPath = ""
    $mode = "Local"
    $offline = $false
    $message = ""
    if ($null -ne $Settings) {
        $schemaVersion = if ($Settings.PSObject.Properties.Name -contains "SchemaVersion") { [int]$Settings.SchemaVersion } else { 1 }
        if ($schemaVersion -gt $CurrentSchemaVersion) {
            $offline = $true
            $message = "Profile storage settings are newer than this app; showing the local library read-only"
        } else {
            if ($Settings.PSObject.Properties.Name -contains "ProfilePath" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.ProfilePath)) {
                $configuredPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Settings.ProfilePath))
            }
            if ($Settings.PSObject.Properties.Name -contains "FallbackPath" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.FallbackPath)) {
                $fallbackPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Settings.FallbackPath))
            }
            if ($Settings.PSObject.Properties.Name -contains "PreviousPath") { $previousPath = [string]$Settings.PreviousPath }
            if ($Settings.PSObject.Properties.Name -contains "Mode" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.Mode)) {
                $mode = [string]$Settings.Mode
            }
            if (-not (Test-Path -LiteralPath $configuredPath -PathType Container)) {
                $offline = $true
                $message = "Profile storage is offline; showing the last available library read-only"
            }
        }
    }
    $activePath = if (-not $offline) {
        $configuredPath
    } elseif (Test-Path -LiteralPath $fallbackPath -PathType Container) {
        $fallbackPath
    } else {
        $defaultFullPath
    }
    return [PSCustomObject]@{
        ProfilesPath = [string]$activePath
        ConfiguredPath = [string]$configuredPath
        FallbackPath = [string]$fallbackPath
        PreviousPath = [string]$previousPath
        Mode = [string]$mode
        Offline = [bool]$offline
        Message = [string]$message
    }
}

function Get-SafeProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $trimmed = $Name.Trim()
    if ([System.IO.Path]::GetFileName($trimmed) -ne $trimmed) { return "" }
    if ($trimmed.TrimEnd(" ", ".") -ne $trimmed) { return "" }
    $safeName = [System.IO.Path]::GetFileNameWithoutExtension($trimmed)
    if ([string]::IsNullOrWhiteSpace($safeName)) { return "" }
    if ($safeName.TrimEnd(" ", ".") -ne $safeName) { return "" }
    if ($safeName -eq "." -or $safeName -eq "..") { return "" }
    if ($safeName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return "" }
    if ($safeName.ToUpperInvariant() -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return "" }
    if ($script:ProfileMetadataFiles -and $script:ProfileMetadataFiles -contains "$safeName.json") { return "" }
    return $safeName
}

function Load-MonitorIdentitySettings {
    $script:MonitorIdentityRecords = @{}
    if (-not (Test-Path -LiteralPath $script:MonitorIdentitySettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:MonitorIdentitySettingsPath -Label "Monitor identities" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        foreach ($entry in @($data.Monitors)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Key)) { continue }
            $script:MonitorIdentityRecords[[string]$entry.Key] = [PSCustomObject]@{
                Key = [string]$entry.Key
                Label = if ($entry.PSObject.Properties.Name -contains "Label") { [string]$entry.Label } else { "" }
                DefaultLabel = if ($entry.PSObject.Properties.Name -contains "DefaultLabel") { [string]$entry.DefaultLabel } else { "" }
                Source = if ($entry.PSObject.Properties.Name -contains "Source") { [string]$entry.Source } else { "" }
                DevicePath = if ($entry.PSObject.Properties.Name -contains "DevicePath") { [string]$entry.DevicePath } else { "" }
                HardwareId = if ($entry.PSObject.Properties.Name -contains "HardwareId") { [string]$entry.HardwareId } else { "" }
                Manufacturer = if ($entry.PSObject.Properties.Name -contains "Manufacturer") { [string]$entry.Manufacturer } else { "" }
                Model = if ($entry.PSObject.Properties.Name -contains "Model") { [string]$entry.Model } else { "" }
                Serial = if ($entry.PSObject.Properties.Name -contains "Serial") { [string]$entry.Serial } else { "" }
                EdidName = if ($entry.PSObject.Properties.Name -contains "EdidName") { [string]$entry.EdidName } else { "" }
                UpdatedAt = if ($entry.PSObject.Properties.Name -contains "UpdatedAt") { [string]$entry.UpdatedAt } else { "" }
            }
        }
    } catch {
        Update-Status "Monitor labels could not be loaded"
    }
}

function Save-MonitorIdentitySettings {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "monitor label changes")) { return $false }
    $entries = @($script:MonitorIdentityRecords.Values | Sort-Object -Property Label, Key)
    $payload = [PSCustomObject]@{
        SchemaVersion = 1
        UpdatedAt = (Get-Date).ToString("o")
        Monitors = $entries
    }
    return (Write-JsonFileSafely -Path $script:MonitorIdentitySettingsPath -Data $payload -Depth 5)
}

function Update-MonitorIdentityKeyedState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Migrates already-loaded in-memory settings from a legacy monitor identity to its WinRT identity.')]
    param([string]$OldKey, [string]$NewKey)
    $changed = [ordered]@{
        MonitorIdentity = $false
        CapabilitySafety = $false
        VcpWriteSafety = $false
        CapabilitiesCache = $false
        DdcTiming = $false
        DisplayStateRestore = $false
        AnyChanged = $false
    }
    if ([string]::IsNullOrWhiteSpace($OldKey) -or [string]::IsNullOrWhiteSpace($NewKey) -or $OldKey -eq $NewKey) {
        return [PSCustomObject]$changed
    }

    if ($script:MonitorIdentityRecords.ContainsKey($OldKey)) {
        $legacyRecord = $script:MonitorIdentityRecords[$OldKey]
        if (-not $script:MonitorIdentityRecords.ContainsKey($NewKey)) {
            $legacyRecord | Add-Member -NotePropertyName Key -NotePropertyValue $NewKey -Force
            $script:MonitorIdentityRecords[$NewKey] = $legacyRecord
        } else {
            $currentRecord = $script:MonitorIdentityRecords[$NewKey]
            if ([string]::IsNullOrWhiteSpace([string]$currentRecord.Label) -and -not [string]::IsNullOrWhiteSpace([string]$legacyRecord.Label)) {
                $currentRecord | Add-Member -NotePropertyName Label -NotePropertyValue ([string]$legacyRecord.Label) -Force
            }
        }
        $null = $script:MonitorIdentityRecords.Remove($OldKey)
        $changed.MonitorIdentity = $true
    }

    if ($script:CapabilitiesExcludedIdentityKeys.ContainsKey($OldKey)) {
        $script:CapabilitiesExcludedIdentityKeys[$NewKey] = [bool]$script:CapabilitiesExcludedIdentityKeys[$OldKey]
        $null = $script:CapabilitiesExcludedIdentityKeys.Remove($OldKey)
        $changed.CapabilitySafety = $true
    }
    if ([string]$script:CapabilitiesLastIncidentIdentityKey -eq $OldKey) {
        $script:CapabilitiesLastIncidentIdentityKey = $NewKey
        $changed.CapabilitySafety = $true
    }

    if ($script:RiskyVcpEnabledIdentityKeys.ContainsKey($OldKey)) {
        $script:RiskyVcpEnabledIdentityKeys[$NewKey] = [bool]$script:RiskyVcpEnabledIdentityKeys[$OldKey]
        $null = $script:RiskyVcpEnabledIdentityKeys.Remove($OldKey)
        $changed.VcpWriteSafety = $true
    }

    if ($script:CapabilitiesCache.ContainsKey($OldKey)) {
        if (-not $script:CapabilitiesCache.ContainsKey($NewKey)) { $script:CapabilitiesCache[$NewKey] = $script:CapabilitiesCache[$OldKey] }
        $null = $script:CapabilitiesCache.Remove($OldKey)
        $changed.CapabilitiesCache = $true
    }

    if ($script:DdcTimingProfiles.ContainsKey($OldKey)) {
        if (-not $script:DdcTimingProfiles.ContainsKey($NewKey)) {
            $timingProfile = $script:DdcTimingProfiles[$OldKey]
            $timingProfile | Add-Member -NotePropertyName IdentityKey -NotePropertyValue $NewKey -Force
            $script:DdcTimingProfiles[$NewKey] = $timingProfile
        }
        $null = $script:DdcTimingProfiles.Remove($OldKey)
        $changed.DdcTiming = $true
    }

    if ($script:DisplayStateRestoreValues.ContainsKey($OldKey)) {
        if (-not $script:DisplayStateRestoreValues.ContainsKey($NewKey)) { $script:DisplayStateRestoreValues[$NewKey] = $script:DisplayStateRestoreValues[$OldKey] }
        $null = $script:DisplayStateRestoreValues.Remove($OldKey)
        $changed.DisplayStateRestore = $true
    }

    $changed.AnyChanged = @($changed.Values | Where-Object { [bool]$_ }).Count -gt 0
    return [PSCustomObject]$changed
}

function Save-MonitorIdentityKeyedStateMigration {
    param($Migration)
    if ($null -eq $Migration -or -not [bool]$Migration.AnyChanged -or [bool]$script:ProfileStorageOffline) { return $false }
    $success = $true
    if ([bool]$Migration.MonitorIdentity -and -not (Save-MonitorIdentitySettings)) { $success = $false }
    if ([bool]$Migration.CapabilitySafety -and -not (Write-CapabilitySafetyState)) { $success = $false }
    if ([bool]$Migration.VcpWriteSafety -and -not (Write-VcpWriteSafetyState)) { $success = $false }
    if ([bool]$Migration.CapabilitiesCache -and -not (Save-CapabilitiesCache)) { $success = $false }
    if ([bool]$Migration.DdcTiming -and -not (Save-DdcTimingSettings)) { $success = $false }
    if ([bool]$Migration.DisplayStateRestore -and -not (Save-DisplayStateRestoreSettings)) { $success = $false }
    return $success
}

function Get-CapabilitiesSafetySettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:CapabilitiesSafetySchemaVersion
        ConsentRecorded = [bool]$script:CapabilitiesConsentRecorded
        DiscoveryEnabled = [bool]$script:CapabilitiesDiscoveryEnabled
        MaximumCompatibility = [bool]$script:CapabilitiesMaximumCompatibility
        ExcludedIdentityKeys = @($script:CapabilitiesExcludedIdentityKeys.Keys | Sort-Object)
        LastIncidentIdentityKey = [string]$script:CapabilitiesLastIncidentIdentityKey
        LastIncidentAt = [string]$script:CapabilitiesLastIncidentAt
    }
}

function Write-CapabilitySafetyState {
    return (Write-JsonFileSafely -Path $script:CapabilitiesSafetySettingsPath -Data (Get-CapabilitiesSafetySettingsObject) -Depth 5)
}

function Import-CapabilitySafetyState {
    $script:CapabilitiesConsentRecorded = $false
    $script:CapabilitiesDiscoveryEnabled = $false
    $script:CapabilitiesMaximumCompatibility = $false
    $script:CapabilitiesExcludedIdentityKeys = @{}
    $script:CapabilitiesLastIncidentIdentityKey = ""
    $script:CapabilitiesLastIncidentAt = ""

    if (Test-Path -LiteralPath $script:CapabilitiesSafetySettingsPath) {
        $data = Read-JsonFileSafely -Path $script:CapabilitiesSafetySettingsPath -Label "Capability safety settings"
        if ($null -ne $data) {
            $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
            if ($schema -gt $script:CapabilitiesSafetySchemaVersion) {
                $script:CapabilitiesConsentRecorded = $true
                $script:CapabilitiesMaximumCompatibility = $true
                Set-DeferredStatus "Capability safety settings are newer than this app; maximum compatibility enabled"
            } else {
                if ($data.PSObject.Properties.Name -contains "ConsentRecorded") { $script:CapabilitiesConsentRecorded = [bool]$data.ConsentRecorded }
                if ($data.PSObject.Properties.Name -contains "DiscoveryEnabled") { $script:CapabilitiesDiscoveryEnabled = [bool]$data.DiscoveryEnabled }
                if ($data.PSObject.Properties.Name -contains "MaximumCompatibility") { $script:CapabilitiesMaximumCompatibility = [bool]$data.MaximumCompatibility }
                foreach ($identityKey in @($data.ExcludedIdentityKeys)) {
                    $key = [string]$identityKey
                    if (-not [string]::IsNullOrWhiteSpace($key)) { $script:CapabilitiesExcludedIdentityKeys[$key] = $true }
                }
                if ($data.PSObject.Properties.Name -contains "LastIncidentIdentityKey") { $script:CapabilitiesLastIncidentIdentityKey = [string]$data.LastIncidentIdentityKey }
                if ($data.PSObject.Properties.Name -contains "LastIncidentAt") { $script:CapabilitiesLastIncidentAt = [string]$data.LastIncidentAt }
            }
        }
    }

    if (Test-Path -LiteralPath $script:CapabilitiesProbeSentinelPath) {
        $pendingIdentity = ""
        $pendingAt = [DateTime]::UtcNow.ToString("o")
        try {
            $pending = Get-Content -LiteralPath $script:CapabilitiesProbeSentinelPath -Raw | ConvertFrom-Json
            $pendingIdentity = [string]$pending.IdentityKey
            if ($pending.PSObject.Properties.Name -contains "StartedAtUtc" -and -not [string]::IsNullOrWhiteSpace([string]$pending.StartedAtUtc)) {
                $pendingAt = [string]$pending.StartedAtUtc
            }
        } catch {
            Move-CorruptJsonFile -Path $script:CapabilitiesProbeSentinelPath | Out-Null
        }
        if (Test-Path -LiteralPath $script:CapabilitiesProbeSentinelPath) {
            Remove-Item -LiteralPath $script:CapabilitiesProbeSentinelPath -Force -ErrorAction SilentlyContinue
        }
        $script:CapabilitiesDiscoveryEnabled = $false
        $script:CapabilitiesConsentRecorded = $true
        $script:CapabilitiesLastIncidentIdentityKey = $pendingIdentity
        $script:CapabilitiesLastIncidentAt = $pendingAt
        if (-not [string]::IsNullOrWhiteSpace($pendingIdentity)) {
            $script:CapabilitiesExcludedIdentityKeys[$pendingIdentity] = $true
            Set-DeferredStatus "Capability discovery disabled after an interrupted probe; the affected monitor was excluded"
        } else {
            $script:CapabilitiesMaximumCompatibility = $true
            Set-DeferredStatus "Capability discovery disabled after an unreadable probe sentinel"
        }
        Write-CapabilitySafetyState | Out-Null
    }
}

function Get-VcpWriteSafetySettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:VcpWriteSafetySchemaVersion
        EnabledIdentityKeys = @($script:RiskyVcpEnabledIdentityKeys.Keys | Sort-Object)
    }
}

function Write-VcpWriteSafetyState {
    return (Write-JsonFileSafely -Path $script:VcpWriteSafetySettingsPath -Data (Get-VcpWriteSafetySettingsObject) -Depth 4)
}

function Import-VcpWriteSafetyState {
    $script:RiskyVcpEnabledIdentityKeys = @{}
    if (-not (Test-Path -LiteralPath $script:VcpWriteSafetySettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:VcpWriteSafetySettingsPath -Label "Risky VCP write settings"
        if ($null -eq $data) { return }
        $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
        if ($schema -gt $script:VcpWriteSafetySchemaVersion) {
            Set-DeferredStatus "Risky VCP write settings are newer than this app; dangerous writes remain disabled"
            return
        }
        if ($schema -lt 1) {
            Set-DeferredStatus "Risky VCP write settings were invalid; dangerous writes remain disabled"
            return
        }
        foreach ($identityKey in @($data.EnabledIdentityKeys)) {
            $key = [string]$identityKey
            if (-not [string]::IsNullOrWhiteSpace($key) -and $key.Length -le 512) {
                $script:RiskyVcpEnabledIdentityKeys[$key] = $true
            }
        }
    } catch {
        $script:RiskyVcpEnabledIdentityKeys = @{}
        Set-DeferredStatus "Risky VCP write settings were invalid; dangerous writes remain disabled"
    }
}

function Get-CapabilitiesCacheKey {
    param($Monitor)
    if ($null -eq $Monitor) { return "" }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return "" }
    return $identityKey
}

function Save-CapabilitiesCache {
    $records = @()
    foreach ($key in @($script:CapabilitiesCache.Keys)) {
        $entry = $script:CapabilitiesCache[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            EdidId = [string]$entry.EdidId
            Capabilities = [string]$entry.Capabilities
            ReadAt = [string]$entry.ReadAt
        }
    }
    $document = [PSCustomObject]@{
        SchemaVersion = [int]$script:CapabilitiesCacheSchemaVersion
        Monitors = @($records)
    }
    return (Write-JsonFileSafely -Path $script:CapabilitiesCachePath -Data $document -Depth 5)
}

function Import-CapabilitiesCache {
    $script:CapabilitiesCache = @{}
    if (-not (Test-Path -LiteralPath $script:CapabilitiesCachePath)) { return }
    $data = Read-JsonFileSafely -Path $script:CapabilitiesCachePath -Label "Capability cache"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:CapabilitiesCacheSchemaVersion) {
        Update-Status "Capability cache uses schema v$schema; it will be re-read instead"
        return
    }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        $capabilities = [string](Get-ProfilePropertyValue -Object $record -Property "Capabilities" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey) -or [string]::IsNullOrWhiteSpace($capabilities)) { continue }
        $script:CapabilitiesCache[$identityKey] = [PSCustomObject]@{
            EdidId = [string](Get-ProfilePropertyValue -Object $record -Property "EdidId" -Default "")
            Capabilities = $capabilities
            ReadAt = [string](Get-ProfilePropertyValue -Object $record -Property "ReadAt" -Default "")
        }
    }
}

function Set-CapabilitiesCacheEntry {
    param($Monitor, [string]$Capabilities, [string]$ReadAt = "")
    $key = Get-CapabilitiesCacheKey -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($Capabilities)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ReadAt)) { $ReadAt = (Get-Date).ToString("o") }
    $script:CapabilitiesCache[$key] = [PSCustomObject]@{
        EdidId = Get-MonitorEdidModelId -Monitor $Monitor
        Capabilities = [string]$Capabilities
        ReadAt = [string]$ReadAt
    }
    return $true
}

function Get-CapabilitiesCacheEntry {
    param($Monitor)
    $key = Get-CapabilitiesCacheKey -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    if (-not $script:CapabilitiesCache.ContainsKey($key)) { return $null }
    return $script:CapabilitiesCache[$key]
}

function Clear-CapabilitiesCache {
    $script:CapabilitiesCache = @{}
    Save-CapabilitiesCache | Out-Null
    Update-Status "Capability cache cleared; capabilities will be read again"
}

function Get-DdcTimingSettingsObject {
    $records = @()
    foreach ($key in @($script:DdcTimingProfiles.Keys)) {
        $entry = $script:DdcTimingProfiles[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            Mode = [string]$entry.Mode
            SleepMultiplier = [double]$entry.SleepMultiplier
            CalibratedAt = [string]$entry.CalibratedAt
            ReadRetries = [int]$entry.ReadRetries
            WriteRetries = [int]$entry.WriteRetries
            CapabilityRetries = [int]$entry.CapabilityRetries
            UnsupportedCodes = @(@($entry.UnsupportedCodes) | ForEach-Object {
                [PSCustomObject]@{ Code = [int]$_.Code; LastError = [int]$_.LastError; ObservedAt = [string]$_.ObservedAt }
            })
        }
    }
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:DdcTimingSchemaVersion
        Monitors = @($records)
    }
}

function Save-DdcTimingSettings {
    return (Write-JsonFileSafely -Path $script:DdcTimingSettingsPath -Data (Get-DdcTimingSettingsObject) -Depth 6)
}

function Import-DdcTimingSettings {
    $script:DdcTimingProfiles = @{}
    if (-not (Test-Path -LiteralPath $script:DdcTimingSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:DdcTimingSettingsPath -Label "DDC timing settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:DdcTimingSchemaVersion) {
        Update-Status "DDC timing settings use schema v$schema; defaults will be used instead"
        return
    }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey)) { continue }
        $timingProfile = New-DdcTimingProfile -IdentityKey $identityKey
        $mode = [string](Get-ProfilePropertyValue -Object $record -Property "Mode" -Default "Adaptive")
        $timingProfile.Mode = if ($mode -eq "Manual") { "Manual" } else { "Adaptive" }
        $timingProfile.SleepMultiplier = [double](Get-ProfilePropertyValue -Object $record -Property "SleepMultiplier" -Default 1.0)
        $timingProfile.CalibratedAt = [string](Get-ProfilePropertyValue -Object $record -Property "CalibratedAt" -Default "")
        $timingProfile.ReadRetries = [int](Get-ProfilePropertyValue -Object $record -Property "ReadRetries" -Default ([int][MonitorAPI]::VcpReadRetryCount))
        $timingProfile.WriteRetries = [int](Get-ProfilePropertyValue -Object $record -Property "WriteRetries" -Default ([int][MonitorAPI]::VcpWriteRetryCount))
        $timingProfile.CapabilityRetries = [int](Get-ProfilePropertyValue -Object $record -Property "CapabilityRetries" -Default ([int][MonitorAPI]::VcpReadRetryCount))
        $codes = @()
        foreach ($codeRecord in @((Get-ProfilePropertyValue -Object $record -Property "UnsupportedCodes" -Default @()))) {
            if ($null -eq $codeRecord) { continue }
            $codes += [PSCustomObject]@{
                Code = [int](Get-ProfilePropertyValue -Object $codeRecord -Property "Code" -Default 0)
                LastError = [int](Get-ProfilePropertyValue -Object $codeRecord -Property "LastError" -Default 0)
                ObservedAt = [string](Get-ProfilePropertyValue -Object $codeRecord -Property "ObservedAt" -Default "")
            }
        }
        $timingProfile.UnsupportedCodes = @($codes)
        $script:DdcTimingProfiles[$identityKey] = $timingProfile
    }
}

function Get-DisplayStateRestoreSettingsObject {
    $records = @()
    foreach ($key in @($script:DisplayStateRestoreValues.Keys)) {
        $entry = $script:DisplayStateRestoreValues[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            Brightness = [int]$entry.Brightness
            UpdatedAt = [string]$entry.UpdatedAt
        }
    }
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:DisplayStateRestoreSchemaVersion
        Enabled = [bool]$script:DisplayStateRestoreEnabled
        Monitors = @($records)
    }
}

function Save-DisplayStateRestoreSettings {
    return (Write-JsonFileSafely -Path $script:DisplayStateRestoreSettingsPath -Data (Get-DisplayStateRestoreSettingsObject) -Depth 5)
}

function Import-DisplayStateRestoreSettings {
    $script:DisplayStateRestoreEnabled = $false
    $script:DisplayStateRestoreValues = @{}
    if (-not (Test-Path -LiteralPath $script:DisplayStateRestoreSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:DisplayStateRestoreSettingsPath -Label "Display restore settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:DisplayStateRestoreSchemaVersion) {
        Update-Status "Display restore settings use schema v$schema; restore stays disabled"
        return
    }
    if ($data.PSObject.Properties.Name -contains "Enabled") { $script:DisplayStateRestoreEnabled = [bool]$data.Enabled }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey)) { continue }
        $brightness = Get-ProfilePercentValue -Object $record -Property "Brightness" -Default -1
        if ($brightness -lt 0) { continue }
        $script:DisplayStateRestoreValues[$identityKey] = [PSCustomObject]@{
            Brightness = [int]$brightness
            UpdatedAt = [string](Get-ProfilePropertyValue -Object $record -Property "UpdatedAt" -Default "")
        }
    }
}

function Get-OptionalHelperSettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:OptionalHelperSchemaVersion
        CpuMonitorEnabled = [bool]$script:CpuMonitorEnabled
        PresentMonEnabled = [bool]$script:PresentMonEnabled
    }
}

function Save-OptionalHelperSettings {
    return (Write-JsonFileSafely -Path $script:OptionalHelperSettingsPath -Data (Get-OptionalHelperSettingsObject) -Depth 4)
}

function Import-OptionalHelperSettings {
    $script:CpuMonitorEnabled = $false
    $script:PresentMonEnabled = $false
    if (-not (Test-Path -LiteralPath $script:OptionalHelperSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:OptionalHelperSettingsPath -Label "Optional helper settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:OptionalHelperSchemaVersion) {
        Update-Status "Optional helper settings use schema v$schema; helpers stay disabled"
        return
    }
    if ($data.PSObject.Properties.Name -contains "CpuMonitorEnabled") { $script:CpuMonitorEnabled = [bool]$data.CpuMonitorEnabled }
    if ($data.PSObject.Properties.Name -contains "PresentMonEnabled") { $script:PresentMonEnabled = [bool]$data.PresentMonEnabled }
}
