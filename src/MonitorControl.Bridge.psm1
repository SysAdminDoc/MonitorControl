# MonitorControl Pro Bridge source module.

# Dot-sourced by the development launcher and composed into the portable release.



function New-AutomationBridgeApiKey {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Protect-AutomationBridgeApiKey {
    param([string]$ApiKey)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { return "" }
    if ($null -eq ("System.Security.Cryptography.ProtectedData" -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($ApiKey)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("MonitorControlPro.AutomationBridge.v2")
    try {
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return "dpapi:v1:$([Convert]::ToBase64String($protectedBytes))"
    } finally {
        if ($plainBytes.Length -gt 0) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($entropy.Length -gt 0) { [Array]::Clear($entropy, 0, $entropy.Length) }
    }
}

function Unprotect-AutomationBridgeApiKey {
    param([string]$ProtectedApiKey)
    if ([string]::IsNullOrWhiteSpace($ProtectedApiKey) -or -not $ProtectedApiKey.StartsWith("dpapi:v1:", [StringComparison]::Ordinal)) { return "" }
    if ($null -eq ("System.Security.Cryptography.ProtectedData" -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $encoded = $ProtectedApiKey.Substring(9)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("MonitorControlPro.AutomationBridge.v2")
    $plainBytes = $null
    try {
        $protectedBytes = [Convert]::FromBase64String($encoded)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($plainBytes)
    } catch {
        return ""
    } finally {
        if ($null -ne $plainBytes -and $plainBytes.Length -gt 0) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($entropy.Length -gt 0) { [Array]::Clear($entropy, 0, $entropy.Length) }
    }
}

function Get-AutomationBridgeSettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:AutomationBridgeSettingsSchemaVersion
        Enabled = [bool]$script:AutomationBridgeEnabled
        BindAddress = [string]$script:AutomationBridgeBindAddress
        Port = [int]$script:AutomationBridgePort
        ApiKeyProtected = Protect-AutomationBridgeApiKey -ApiKey $script:AutomationBridgeApiKey
        NetworkExposureApproved = [bool]$script:AutomationBridgeNetworkExposureApproved
        NetworkExposureApprovedFor = [string]$script:AutomationBridgeNetworkExposureApprovedFor
        AllowedCommands = @($script:AutomationBridgeAllowedCommands)
        UpdatedAt = (Get-Date).ToString("o")
    }
}

function Save-AutomationBridgeSettings {
    if ([string]::IsNullOrWhiteSpace($script:AutomationBridgeApiKey)) { $script:AutomationBridgeApiKey = New-AutomationBridgeApiKey }
    try {
        $saved = Write-JsonFileSafely -Path $script:AutomationBridgeSettingsPath -Data (Get-AutomationBridgeSettingsObject) -Depth 5
        if (-not $saved) {
            $script:AutomationBridgeLastError = "Settings could not be protected and saved"
            Update-Status "Automation bridge settings could not be protected and saved"
        } elseif ($script:AutomationBridgeLastError -eq "Settings could not be protected and saved") {
            $script:AutomationBridgeLastError = ""
        }
        return [bool]$saved
    } catch {
        $script:AutomationBridgeLastError = "Settings could not be protected and saved"
        Update-Status "Automation bridge settings could not be protected and saved"
        return $false
    }
}

function Load-AutomationBridgeSettings {
    $script:AutomationBridgeEnabled = $false
    $script:AutomationBridgeBindAddress = "127.0.0.1"
    $script:AutomationBridgePort = 34291
    $script:AutomationBridgeApiKey = New-AutomationBridgeApiKey
        $script:AutomationBridgeNetworkExposureApproved = $false
    $script:AutomationBridgeNetworkExposureApprovedFor = ""
    $script:AutomationBridgeLastError = ""
    $settingsExists = Test-Path -LiteralPath $script:AutomationBridgeSettingsPath
    $rewriteSettings = $false
    if ($settingsExists) {
        try {
            $data = Read-JsonFileSafely -Path $script:AutomationBridgeSettingsPath -Label "Automation bridge"
            if ($null -ne $data) {
                $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
                if ($schema -gt $script:AutomationBridgeSettingsSchemaVersion) {
                    $script:AutomationBridgeLastError = "Settings schema is newer than this app"
                } else {
                    $script:AutomationBridgeEnabled = [bool]$data.Enabled
                    if ($schema -lt $script:AutomationBridgeSettingsSchemaVersion) { $rewriteSettings = $true }
                    if ($data.BindAddress) {
                        $script:AutomationBridgeBindAddress = [string]$data.BindAddress
                        if ($null -eq (Resolve-AutomationBridgeIPAddress -BindAddress $script:AutomationBridgeBindAddress)) {
                            $script:AutomationBridgeEnabled = $false
                            $script:AutomationBridgeLastError = "Invalid bind address"
                            $rewriteSettings = $true
                        }
                    }
                    if ($data.Port) { $script:AutomationBridgePort = [Math]::Max(1024, [Math]::Min(65535, [int]$data.Port)) }
                    if ($data.PSObject.Properties.Name -contains "ApiKeyProtected") {
                        $unprotected = Unprotect-AutomationBridgeApiKey -ProtectedApiKey ([string]$data.ApiKeyProtected)
                        if ([string]::IsNullOrWhiteSpace($unprotected)) {
                            $script:AutomationBridgeEnabled = $false
                            $script:AutomationBridgeLastError = "Stored API key could not be unlocked"
                        } else {
                            $script:AutomationBridgeApiKey = $unprotected
                        }
                    } elseif ($data.PSObject.Properties.Name -contains "ApiKey" -and -not [string]::IsNullOrWhiteSpace([string]$data.ApiKey)) {
                        $script:AutomationBridgeApiKey = [string]$data.ApiKey
                        $rewriteSettings = $true
                    }
                    if ($data.PSObject.Properties.Name -contains "NetworkExposureApproved") {
                        $script:AutomationBridgeNetworkExposureApproved = [bool]$data.NetworkExposureApproved
                    }
                    if ($data.PSObject.Properties.Name -contains "NetworkExposureApprovedFor") {
                        $script:AutomationBridgeNetworkExposureApprovedFor = [string]$data.NetworkExposureApprovedFor
                    }
                }
            }
        } catch {
            $script:AutomationBridgeEnabled = $false
            $script:AutomationBridgeLastError = "Settings could not be loaded"
        }
    }
    $resolved = Resolve-AutomationBridgeIPAddress -BindAddress $script:AutomationBridgeBindAddress
    if ($script:AutomationBridgeEnabled -and $null -ne $resolved -and -not [System.Net.IPAddress]::IsLoopback($resolved)) {
        if (-not $script:AutomationBridgeNetworkExposureApproved -or $script:AutomationBridgeNetworkExposureApprovedFor -ne $resolved.ToString()) {
            $script:AutomationBridgeEnabled = $false
            $script:AutomationBridgeLastError = "Network exposure requires approval"
            $rewriteSettings = $true
        }
    }
    if ($rewriteSettings) { Save-AutomationBridgeSettings | Out-Null }
    Initialize-AutomationBridgeAuditLog
}

function Resolve-AutomationBridgeIPAddress {
    param([string]$BindAddress)
    if ([string]::IsNullOrWhiteSpace($BindAddress) -or $BindAddress.Trim().ToLowerInvariant() -eq "localhost") {
        return [System.Net.IPAddress]::Loopback
    }
    $address = [System.Net.IPAddress]::Loopback
    if ([System.Net.IPAddress]::TryParse($BindAddress.Trim(), [ref]$address)) { return $address }
    return $null
}

function Test-AutomationBridgeLoopback {
    param([string]$BindAddress)
    $address = Resolve-AutomationBridgeIPAddress -BindAddress $BindAddress
    return ($null -ne $address -and [System.Net.IPAddress]::IsLoopback($address))
}

function New-AutomationBridgeResponse {
    param([int]$Status, $Body)
    return [PSCustomObject]@{ Status = [int]$Status; Body = $Body }
}

function Get-AutomationBridgeBodyJson {
    param($Request)
    if ($null -eq $Request -or [string]::IsNullOrWhiteSpace([string]$Request.Body)) { return $null }
    try { return ([string]$Request.Body | ConvertFrom-Json) } catch { return $null }
}

function Get-AutomationBridgeInputValue {
    param($Request, $Body, [string]$Name)
    if ($Request.Query -and $Request.Query.ContainsKey($Name)) { return [string]$Request.Query[$Name] }
    if ($null -ne $Body -and $Body.PSObject.Properties.Name -contains $Name) { return [string]$Body.$Name }
    return ""
}

function Test-AutomationBridgeToken {
    param([string]$Provided, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Provided) -or [string]::IsNullOrWhiteSpace($Expected) -or $Provided.Length -gt 256 -or $Expected.Length -gt 256) {
        return $false
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $providedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Provided))
        $expectedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Expected))
        $difference = 0
        for ($i = 0; $i -lt $expectedHash.Length; $i++) {
            $difference = $difference -bor ($providedHash[$i] -bxor $expectedHash[$i])
        }
        return $difference -eq 0
    } finally {
        $sha.Dispose()
    }
}

function Test-AutomationBridgeRequestAuthorized {
    param($Request)
    if ($null -ne $Request -and $Request.PSObject.Properties.Name -contains "Authenticated" -and [bool]$Request.Authenticated) { return $true }
    $provided = ""
    if ($Request.Headers -and $Request.Headers.ContainsKey("x-monitorcontrol-key")) { $provided = [string]$Request.Headers["x-monitorcontrol-key"] }
    if (-not $provided -and $Request.Headers -and $Request.Headers.ContainsKey("authorization")) {
        $auth = [string]$Request.Headers["authorization"]
        if ($auth -match '^Bearer\s+(.+)$') { $provided = $matches[1] }
    }
    return Test-AutomationBridgeToken -Provided $provided -Expected $script:AutomationBridgeApiKey
}

function Test-AutomationBridgePayloadCredential {
    param($Request, $Body)
    if ($Request.Query -and $Request.Query.ContainsKey("apiKey")) { return $true }
    if ($null -ne $Body -and @($Body.PSObject.Properties.Name | Where-Object { $_ -ieq "apiKey" }).Count -gt 0) { return $true }
    return $false
}

function ConvertTo-AutomationBridgeAuditEntry {
    param([string]$Action, [string]$Target, $Value, [bool]$Success, [string]$Remote, [string]$Message, [string]$Timestamp)
    $safeAction = if ($Action -in @("setBrightness", "loadProfile")) { $Action } else { "unknown" }
    $targetScope = if ([string]::IsNullOrWhiteSpace($Target)) { "default" } else { "specified" }
    $remoteScope = "network"
    if ([string]::IsNullOrWhiteSpace($Remote)) {
        $remoteScope = "unknown"
    } elseif ($Remote -eq "loopback" -or $Remote -match '^\[?(127\.|::1\]?:)') {
        $remoteScope = "loopback"
    }
    $resultCode = if ($Message -in @("queued", "loaded", "no_monitors", "monitor_not_found", "no_write_target", "completed", "operation_failed")) {
        $Message
    } else {
        switch ($Message) {
            "Queued" { "queued" }
            "Loaded" { "loaded" }
            "No monitors enumerated" { "no_monitors" }
            "Monitor not found" { "monitor_not_found" }
            "No write target" { "no_write_target" }
            default { if ($Success) { "completed" } else { "operation_failed" } }
        }
    }
    $safeValue = ""
    $parsedValue = 0
    if ($safeAction -eq "setBrightness" -and [int]::TryParse([string]$Value, [ref]$parsedValue)) {
        $safeValue = [Math]::Max(0, [Math]::Min(100, $parsedValue))
    }
    $parsedTimestamp = [DateTime]::MinValue
    $safeTimestamp = if (
        -not [string]::IsNullOrWhiteSpace($Timestamp) -and
        [DateTime]::TryParse($Timestamp, [ref]$parsedTimestamp)
    ) {
        $parsedTimestamp.ToUniversalTime().ToString("o")
    } else {
        [DateTime]::UtcNow.ToString("o")
    }
    return [PSCustomObject]@{
        Timestamp = $safeTimestamp
        Action = $safeAction
        TargetScope = $targetScope
        Value = $safeValue
        Success = [bool]$Success
        RemoteScope = $remoteScope
        ResultCode = $resultCode
    }
}

function Convert-AutomationBridgeAuditFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $retained = New-Object 'System.Collections.Generic.Queue[object]'
        $retainedBytes = 0
        foreach ($rawLine in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
            try {
                $legacy = $rawLine | ConvertFrom-Json
            } catch {
                continue
            }
            $sanitized = ConvertTo-AutomationBridgeAuditEntry `
                -Action ([string]$legacy.Action) `
                -Target $(if ($legacy.PSObject.Properties.Name -contains "TargetScope") { if ([string]$legacy.TargetScope -eq "default") { "" } else { "specified" } } else { [string]$legacy.Target }) `
                -Value $legacy.Value `
                -Success ([bool]$legacy.Success) `
                -Remote $(if ($legacy.PSObject.Properties.Name -contains "RemoteScope") { [string]$legacy.RemoteScope } else { [string]$legacy.Remote }) `
                -Message $(if ($legacy.PSObject.Properties.Name -contains "ResultCode") { [string]$legacy.ResultCode } else { [string]$legacy.Message }) `
                -Timestamp ([string]$legacy.Timestamp)
            $line = (($sanitized | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
            $byteCount = $encoding.GetByteCount($line)
            if ($byteCount -gt $script:AutomationBridgeAuditLogMaxBytes) { continue }
            while ($retained.Count -gt 0 -and ($retainedBytes + $byteCount) -gt $script:AutomationBridgeAuditLogMaxBytes) {
                $removed = $retained.Dequeue()
                $retainedBytes -= [int]$removed.Bytes
            }
            $retained.Enqueue([PSCustomObject]@{ Text = $line; Bytes = $byteCount })
            $retainedBytes += $byteCount
        }
        $builder = New-Object System.Text.StringBuilder
        foreach ($item in $retained) { [void]$builder.Append([string]$item.Text) }
        [System.IO.File]::WriteAllText($tempPath, $builder.ToString(), $encoding)
        [System.IO.File]::Copy($tempPath, $Path, $true)
        Remove-Item -LiteralPath $tempPath -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Set-DeferredStatus "Automation bridge audit log privacy migration failed"
        return $false
    }
}

function Initialize-AutomationBridgeAuditLog {
    Convert-AutomationBridgeAuditFile -Path $script:AutomationBridgeWriteLogPath | Out-Null
    Convert-AutomationBridgeAuditFile -Path "$script:AutomationBridgeWriteLogPath.1" | Out-Null
}

function Write-AutomationBridgeWriteLog {
    param([string]$Action, [string]$Target, $Value, [bool]$Success, [string]$Remote, [string]$Message)
    $entry = ConvertTo-AutomationBridgeAuditEntry -Action $Action -Target $Target -Value $Value -Success $Success -Remote $Remote -Message $Message -Timestamp ([DateTime]::UtcNow.ToString("o"))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $line = (($entry | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
        $lineBytes = $encoding.GetByteCount($line)
        if (Test-Path -LiteralPath $script:AutomationBridgeWriteLogPath) {
            $currentLength = (Get-Item -LiteralPath $script:AutomationBridgeWriteLogPath).Length
            if (($currentLength + $lineBytes) -gt $script:AutomationBridgeAuditLogMaxBytes) {
                $archivePath = "$script:AutomationBridgeWriteLogPath.1"
                if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
                Move-Item -LiteralPath $script:AutomationBridgeWriteLogPath -Destination $archivePath
            }
        }
        [System.IO.File]::AppendAllText($script:AutomationBridgeWriteLogPath, $line, $encoding)
    } catch {
        Set-DeferredStatus "Automation bridge audit log is unavailable"
    }
}

function Get-AutomationBridgeMonitorList {
    $items = @()
    foreach ($mon in @($script:PhysicalMonitors)) {
        if ($null -eq $mon) { continue }
        $brightness = $null
        if (($mon.Index - 1) -eq $script:CurrentMonitorIndex) { $brightness = [int](Get-SelectedBrightnessPercent) }
        $items += [PSCustomObject]@{
            Index = [int]$mon.Index
            Label = [string](Get-MonitorDisplayLabel -Monitor $mon)
            Name = [string]$mon.Name
            IdentityKey = [string]$mon.IdentityKey
            DeviceName = [string]$mon.DeviceName
            HasDdc = ([int64]$mon.Handle.ToInt64() -ne 0)
            Brightness = $brightness
            BrightnessMaximum = [int](Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))
        }
    }
    return $items
}

function Resolve-AutomationBridgeMonitorIndex {
    param([string]$MonitorRef)
    if ([string]::IsNullOrWhiteSpace($MonitorRef) -or $MonitorRef.Trim().ToLowerInvariant() -eq "current") {
        return $script:CurrentMonitorIndex
    }
    $ref = $MonitorRef.Trim()
    $number = 0
    if ([int]::TryParse($ref, [ref]$number)) {
        for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
            if ([int]$script:PhysicalMonitors[$i].Index -eq $number) { return $i }
        }
    }
    for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
        $mon = $script:PhysicalMonitors[$i]
        if ($ref -eq [string]$mon.IdentityKey -or $ref -eq (Get-MonitorDisplayLabel -Monitor $mon)) { return $i }
    }
    return -1
}

function Read-AutomationBridgeBrightness {
    param([string]$MonitorRef)
    $index = Resolve-AutomationBridgeMonitorIndex -MonitorRef $MonitorRef
    if ($index -lt 0 -or $index -ge $script:PhysicalMonitors.Count) { return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Monitor not found" } }
    $mon = $script:PhysicalMonitors[$index]
    if ($mon.Handle -eq [IntPtr]::Zero) {
        if ($script:WmiBrightnessAvailable) {
            $wmi = Get-WmiBrightness
            if ($null -ne $wmi) { return New-AutomationBridgeResponse -Status 200 -Body @{ monitor = $mon.Index; brightness = [int]$wmi; source = "WMI" } }
        }
        return New-AutomationBridgeResponse -Status 409 -Body @{ error = "No DDC/CI handle" }
    }
    $result = Get-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -MonitorName $mon.Name
    if (-not [bool]$result.Success) { return New-AutomationBridgeResponse -Status 502 -Body @{ error = "ddc_read_failed" } }
    Set-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS) -Maximum ([int]$result.Maximum)
    $maximum = Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
    return New-AutomationBridgeResponse -Status 200 -Body @{
        monitor = $mon.Index
        brightness = [int](ConvertTo-VcpPercent -RawValue ([double]$result.Current) -Maximum $maximum)
        raw = [int]$result.Current
        maximum = [int]$result.Maximum
        source = "DDC"
    }
}

function Set-AutomationBridgeBrightness {
    param([string]$MonitorRef, [int]$Value, [string]$Remote)
    $value = [Math]::Max(0, [Math]::Min(100, $Value))
    $targets = @()
    if ($script:PhysicalMonitors.Count -eq 0) {
        Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $MonitorRef -Value $value -Success $false -Remote $Remote -Message "No monitors enumerated"
        return New-AutomationBridgeResponse -Status 404 -Body @{ error = "No monitors enumerated" }
    }
    if ($MonitorRef -and $MonitorRef.Trim().ToLowerInvariant() -eq "all") {
        $targets = @(0..($script:PhysicalMonitors.Count - 1))
    } else {
        $index = Resolve-AutomationBridgeMonitorIndex -MonitorRef $MonitorRef
        if ($index -lt 0 -or $index -ge $script:PhysicalMonitors.Count) {
            Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $MonitorRef -Value $value -Success $false -Remote $Remote -Message "Monitor not found"
            return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Monitor not found" }
        }
        $targets = @($index)
    }
    $queued = 0
    foreach ($index in $targets) {
        $mon = $script:PhysicalMonitors[$index]
        $rawTarget = [uint32](ConvertTo-VcpRawValue -Percent ([double]$value) -Maximum (Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)))
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $rawTarget -Key "bridge:$index`:0x10" -MonitorName $mon.Name) { $queued++ }
        if ($index -eq $script:CurrentMonitorIndex) {
            $script:UpdatingUI = $true
            try {
                $rawValue = ConvertTo-SelectedRawValue -Percent $value -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
                Update-AutomationBridgeBrightnessUi -RawValue $rawValue
            } finally { $script:UpdatingUI = $false }
        }
    }
    if ($queued -eq 0 -and $script:WmiBrightnessAvailable) {
        if (Set-WmiBrightness -Value ([uint32]$value)) { $queued = 1 }
    }
    $success = $queued -gt 0
    Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $(if ($MonitorRef) { $MonitorRef } else { "current" }) -Value $value -Success $success -Remote $Remote -Message $(if ($success) { "Queued" } else { "No write target" })
    if (-not $success) { return New-AutomationBridgeResponse -Status 409 -Body @{ error = "No DDC/CI or WMI write target" } }
    Update-Status "Bridge brightness $value queued"
    Update-TrayPopupState
    Update-TrayIconText
    return New-AutomationBridgeResponse -Status 202 -Body @{ queued = $queued; brightness = $value }
}

function Invoke-AutomationBridgeRequest {
    param($Request)
    $body = Get-AutomationBridgeBodyJson -Request $Request
    $path = ([string]$Request.Path).TrimEnd("/").ToLowerInvariant()
    if ($path -eq "") { $path = "/" }
    $queryCount = if ($Request.Query) { [int]$Request.Query.Count } else { 0 }
    $isEmptyHealthCheck = (
        $Request.Method -eq "GET" -and
        ($path -eq "/health" -or $path -eq "/api/health") -and
        $queryCount -eq 0 -and
        [string]::IsNullOrEmpty([string]$Request.Body)
    )
    if ($isEmptyHealthCheck) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ ok = $true }
    }
    if (Test-AutomationBridgePayloadCredential -Request $Request -Body $body) {
        return New-AutomationBridgeResponse -Status 400 -Body @{ error = "credential_must_use_header" }
    }
    if (-not (Test-AutomationBridgeRequestAuthorized -Request $Request)) {
        return New-AutomationBridgeResponse -Status 401 -Body @{ error = "unauthorized" }
    }
    if ($Request.Method -eq "GET" -and ($path -eq "/monitors" -or $path -eq "/api/monitors")) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ monitors = @(Get-AutomationBridgeMonitorList) }
    }
    if ($Request.Method -eq "GET" -and ($path -eq "/profiles" -or $path -eq "/api/profiles")) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ profiles = @((Get-UserProfileFiles | ForEach-Object { $_.BaseName })) }
    }
    if ($path -eq "/brightness" -or $path -eq "/api/brightness") {
        if ($Request.Method -eq "GET") { return Read-AutomationBridgeBrightness -MonitorRef (Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "monitor") }
        if ($Request.Method -eq "POST") {
            $rawValue = Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "value"
            $value = 0
            if (-not [int]::TryParse($rawValue, [ref]$value)) { return New-AutomationBridgeResponse -Status 400 -Body @{ error = "Brightness value required" } }
            return Set-AutomationBridgeBrightness -MonitorRef (Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "monitor") -Value $value -Remote ([string]$Request.Remote)
        }
    }
    if (($path -eq "/profile" -or $path -eq "/api/profile") -and $Request.Method -eq "POST") {
        $name = Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "name"
        if ([string]::IsNullOrWhiteSpace($name)) { return New-AutomationBridgeResponse -Status 400 -Body @{ error = "Profile name required" } }
        $ok = Apply-ProfileByName -Name $name -Reason "Bridge profile" -AutomationRuleId "bridge:profile:$name"
        Write-AutomationBridgeWriteLog -Action "loadProfile" -Target $name -Value "" -Success $ok -Remote ([string]$Request.Remote) -Message $(if ($ok) { "Loaded" } else { "Failed" })
        if (-not $ok) { return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Profile not found or failed" } }
        return New-AutomationBridgeResponse -Status 202 -Body @{ profile = $name; queued = $true }
    }
    return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Endpoint not allowed"; allowed = @($script:AutomationBridgeAllowedCommands) }
}

function Process-AutomationBridgeRequests {
    $request = $null
    while ($script:AutomationBridgeRequests.TryDequeue([ref]$request)) {
        if (
            $request.PSObject.Properties.Name -contains "ExpiresAtUtc" -and
            [DateTime]::UtcNow -ge [DateTime]$request.ExpiresAtUtc
        ) {
            Complete-AutomationBridgeResponse -Request $request -Response $null | Out-Null
            $request = $null
            continue
        }
        try {
            $response = Invoke-AutomationBridgeRequest -Request $request
        } catch {
            $response = New-AutomationBridgeResponse -Status 500 -Body @{ error = "internal_error"; code = "bridge_request_failed" }
        }
        Complete-AutomationBridgeResponse -Request $request -Response $response | Out-Null
        $request = $null
    }
}

function Complete-AutomationBridgeResponse {
    param($Request, $Response, $ResponseMap = $script:AutomationBridgeResponses)
    if ($null -eq $Request -or $null -eq $ResponseMap) { return $false }
    $id = [string]$Request.Id
    if ([string]::IsNullOrWhiteSpace($id)) { return $false }
    $syncRoot = $ResponseMap.SyncRoot
    [System.Threading.Monitor]::Enter($syncRoot)
    try {
        $expired = $Request.PSObject.Properties.Name -contains "ExpiresAtUtc" -and
            [DateTime]::UtcNow -ge [DateTime]$Request.ExpiresAtUtc
        if ($expired) {
            $null = $ResponseMap.Remove($id)
            return $false
        }
        if (-not $ResponseMap.ContainsKey($id)) { return $false }
        $ResponseMap[$id] = $Response
        return $true
    } finally {
        [System.Threading.Monitor]::Exit($syncRoot)
    }
}

function Get-AutomationBridgeWorkerScript {
    return {
        param($Settings, $RequestQueue, $ResponseMap, $BridgeState)

        function Send-BridgeBusy {
            param($Client, $Settings, $BridgeState)
            try {
                $Client.SendTimeout = [int]$Settings.WriteTimeoutMs
                $stream = $Client.GetStream()
                $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout
                $payload = '{"error":"server_busy"}'
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $header = "HTTP/1.1 503 Service Unavailable`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            } catch {
                $BridgeState["WriteFailureCount"] = [int]$BridgeState["WriteFailureCount"] + 1
            } finally {
                try {
                    $stream = $Client.GetStream()
                    $buffer = New-Object byte[] 1024
                    $deadline = [DateTime]::UtcNow.AddMilliseconds(75)
                    while ([DateTime]::UtcNow -lt $deadline) {
                        $available = [int]$Client.Available
                        if ($available -le 0) { Start-Sleep -Milliseconds 5; continue }
                        $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $available))
                        if ($read -le 0) { break }
                    }
                } catch { $null = $_ }
                try { $Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { $null = $_ }
                try { $Client.Close() } catch { $null = $_ }
            }
        }

        $handlerScript = {
            param($Client, $Settings, $RequestQueue, $ResponseMap, $BridgeState)

            function Read-BridgeLine {
                param($Stream, [int]$Limit)
                $bytes = New-Object 'System.Collections.Generic.List[byte]'
                $sawCarriageReturn = $false
                while ($true) {
                    $value = $Stream.ReadByte()
                    if ($value -lt 0) {
                        return [PSCustomObject]@{ Ok = $false; Error = "unexpected_eof"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($sawCarriageReturn) {
                        if ($value -ne 10) {
                            return [PSCustomObject]@{ Ok = $false; Error = "invalid_line_ending"; Line = ""; Bytes = [int]$bytes.Count }
                        }
                        return [PSCustomObject]@{
                            Ok = $true
                            Error = ""
                            Line = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
                            Bytes = [int]$bytes.Count + 2
                        }
                    }
                    if ($value -eq 13) {
                        $sawCarriageReturn = $true
                        continue
                    }
                    if ($value -eq 10) {
                        return [PSCustomObject]@{ Ok = $false; Error = "invalid_line_ending"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($value -gt 127 -or ($value -lt 32 -and $value -ne 9)) {
                        return [PSCustomObject]@{ Ok = $false; Error = "invalid_header_character"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($bytes.Count -ge $Limit) {
                        return [PSCustomObject]@{ Ok = $false; Error = "line_too_long"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    $bytes.Add([byte]$value)
                }
            }

            function ConvertFrom-BridgeQuery {
                param([string]$Query)
                $result = @{}
                if ([string]::IsNullOrEmpty($Query)) { return $result }
                foreach ($pair in $Query.TrimStart("?").Split("&")) {
                    if ([string]::IsNullOrEmpty($pair)) { continue }
                    $parts = $pair.Split("=", 2)
                    $name = [Uri]::UnescapeDataString($parts[0].Replace("+", " "))
                    $value = if ($parts.Count -gt 1) { [Uri]::UnescapeDataString($parts[1].Replace("+", " ")) } else { "" }
                    $result[$name] = $value
                }
                return $result
            }

            function Test-BridgeToken {
                param([string]$Provided, [string]$Expected)
                if ([string]::IsNullOrWhiteSpace($Provided) -or [string]::IsNullOrWhiteSpace($Expected) -or $Provided.Length -gt 256 -or $Expected.Length -gt 256) {
                    return $false
                }
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $providedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Provided))
                    $expectedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Expected))
                    $difference = 0
                    for ($i = 0; $i -lt $expectedHash.Length; $i++) {
                        $difference = $difference -bor ($providedHash[$i] -bxor $expectedHash[$i])
                    }
                    return $difference -eq 0
                } finally {
                    $sha.Dispose()
                }
            }

            function Send-BridgeJson {
                param($Client, [int]$Status, $Body, $Settings, $BridgeState)
                try {
                    $reason = switch ($Status) {
                        200 { "OK" }
                        202 { "Accepted" }
                        400 { "Bad Request" }
                        401 { "Unauthorized" }
                        404 { "Not Found" }
                        405 { "Method Not Allowed" }
                        408 { "Request Timeout" }
                        409 { "Conflict" }
                        411 { "Length Required" }
                        413 { "Payload Too Large" }
                        414 { "URI Too Long" }
                        431 { "Request Header Fields Too Large" }
                        500 { "Internal Server Error" }
                        502 { "Bad Gateway" }
                        503 { "Service Unavailable" }
                        504 { "Gateway Timeout" }
                        505 { "HTTP Version Not Supported" }
                        default { "Bad Request" }
                    }
                    $payload = if ($null -eq $Body) { "{}" } else { $Body | ConvertTo-Json -Depth 8 -Compress }
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    if ($bodyBytes.Length -gt [int]$Settings.MaxResponseBytes) {
                        $Status = 500
                        $reason = "Internal Server Error"
                        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"response_too_large"}')
                    }
                    $authenticationHeader = if ($Status -eq 401) { "WWW-Authenticate: Bearer`r`n" } else { "" }
                    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n$authenticationHeader" + "Connection: close`r`n`r`n"
                    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                    $stream = $Client.GetStream()
                    $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                    $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    return $true
                } catch {
                    $BridgeState["WriteFailureCount"] = [int]$BridgeState["WriteFailureCount"] + 1
                    return $false
                }
            }

            function Close-BridgeClient {
                param($Client, [bool]$DrainInput)
                if ($DrainInput) {
                    try {
                        $drainStream = $Client.GetStream()
                        $drainBuffer = New-Object byte[] 1024
                        $drainDeadline = [DateTime]::UtcNow.AddMilliseconds(75)
                        while ([DateTime]::UtcNow -lt $drainDeadline) {
                            $available = [int]$Client.Available
                            if ($available -le 0) { Start-Sleep -Milliseconds 5; continue }
                            $read = $drainStream.Read($drainBuffer, 0, [Math]::Min($drainBuffer.Length, $available))
                            if ($read -le 0) { break }
                        }
                    } catch { $null = $_ }
                }
                try { $Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { $null = $_ }
                try { $Client.Close() } catch { $null = $_ }
            }

            $stream = $null
            $responseId = ""
            $requestFullyRead = $false
            try {
                $Client.NoDelay = $true
                $Client.ReceiveTimeout = [int]$Settings.ReadTimeoutMs
                $Client.SendTimeout = [int]$Settings.WriteTimeoutMs
                $stream = $Client.GetStream()
                $stream.ReadTimeout = [int]$Settings.ReadTimeoutMs
                $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                $BridgeState["LastReadTimeoutMs"] = [int]$stream.ReadTimeout
                $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout

                $requestLineResult = Read-BridgeLine -Stream $stream -Limit ([int]$Settings.MaxRequestLineBytes)
                if (-not $requestLineResult.Ok) {
                    $status = if ($requestLineResult.Error -eq "line_too_long") { 414 } else { 400 }
                    Send-BridgeJson -Client $Client -Status $status -Body @{ error = [string]$requestLineResult.Error } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $requestLine = [string]$requestLineResult.Line
                $match = [regex]::Match($requestLine, '^([A-Z]+) ([^ ]+) (HTTP/[0-9]+\.[0-9]+)$')
                if (-not $match.Success) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_line" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $method = $match.Groups[1].Value
                $target = $match.Groups[2].Value
                $httpVersion = $match.Groups[3].Value
                if ($method -notin @("GET", "POST")) {
                    Send-BridgeJson -Client $Client -Status 405 -Body @{ error = "method_not_allowed" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($httpVersion -notin @("HTTP/1.0", "HTTP/1.1")) {
                    Send-BridgeJson -Client $Client -Status 505 -Body @{ error = "http_version_not_supported" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if (-not $target.StartsWith("/") -or $target.Contains("#")) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_target" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $headers = @{}
                $headerBytesRead = 0
                $headerCount = 0
                while ($true) {
                    $headerResult = Read-BridgeLine -Stream $stream -Limit ([int]$Settings.MaxHeaderBytes)
                    if (-not $headerResult.Ok) {
                        $status = if ($headerResult.Error -eq "line_too_long") { 431 } else { 400 }
                        Send-BridgeJson -Client $Client -Status $status -Body @{ error = [string]$headerResult.Error } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $headerBytesRead += [int]$headerResult.Bytes
                    if ($headerBytesRead -gt [int]$Settings.MaxHeaderBytes) {
                        Send-BridgeJson -Client $Client -Status 431 -Body @{ error = "headers_too_large" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $line = [string]$headerResult.Line
                    if ($line.Length -eq 0) { break }
                    $headerCount++
                    if ($headerCount -gt [int]$Settings.MaxHeaderCount) {
                        Send-BridgeJson -Client $Client -Status 431 -Body @{ error = "too_many_headers" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    if ($line.StartsWith(" ") -or $line.StartsWith("`t")) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "folded_header_not_allowed" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $colon = $line.IndexOf(":")
                    if ($colon -le 0) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $name = $line.Substring(0, $colon)
                    if (-not [regex]::IsMatch($name, "^[A-Za-z0-9!#$%&'*+.^_|~-]+$")) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_header_name" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $name = $name.ToLowerInvariant()
                    if ($headers.ContainsKey($name)) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "duplicate_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $headers[$name] = $line.Substring($colon + 1).Trim()
                }

                if ($httpVersion -eq "HTTP/1.1" -and (-not $headers.ContainsKey("host") -or [string]::IsNullOrWhiteSpace([string]$headers["host"]))) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "host_required" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($headers.ContainsKey("transfer-encoding")) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "transfer_encoding_not_supported" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $contentLength = [long]0
                if ($headers.ContainsKey("content-length")) {
                    $lengthText = [string]$headers["content-length"]
                    if (-not [regex]::IsMatch($lengthText, '^(0|[1-9][0-9]*)$') -or -not [long]::TryParse($lengthText, [ref]$contentLength)) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_content_length" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                } elseif ($method -eq "POST") {
                    Send-BridgeJson -Client $Client -Status 411 -Body @{ error = "content_length_required" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($contentLength -gt [int]$Settings.MaxBodyBytes) {
                    Send-BridgeJson -Client $Client -Status 413 -Body @{ error = "body_too_large" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $body = ""
                if ($contentLength -gt 0) {
                    $bodyBytes = New-Object byte[] ([int]$contentLength)
                    $offset = 0
                    while ($offset -lt $bodyBytes.Length) {
                        $read = $stream.Read($bodyBytes, $offset, $bodyBytes.Length - $offset)
                        if ($read -le 0) {
                            Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "incomplete_body" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                            return
                        }
                        $offset += $read
                    }
                    try {
                        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
                        $body = $strictUtf8.GetString($bodyBytes)
                    } catch {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_utf8_body" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                }
                $requestFullyRead = $true

                try {
                    $uri = [Uri]::new("http://localhost$target")
                    $rawQueryCount = if ([string]::IsNullOrEmpty($uri.Query)) {
                        0
                    } else {
                        @($uri.Query.TrimStart("?").Split("&") | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count
                    }
                    if ($rawQueryCount -gt [int]$Settings.MaxQueryParameterCount) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "too_many_query_parameters" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $query = ConvertFrom-BridgeQuery -Query $uri.Query
                } catch {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_target" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $isEmptyHealthCheck = (
                    $method -eq "GET" -and
                    ($uri.AbsolutePath -ieq "/health" -or $uri.AbsolutePath -ieq "/api/health") -and
                    $query.Count -eq 0 -and
                    $contentLength -eq 0
                )
                if ($isEmptyHealthCheck) {
                    Send-BridgeJson -Client $Client -Status 200 -Body @{ ok = $true } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $bodyJson = $null
                if (-not [string]::IsNullOrEmpty($body)) {
                    try { $bodyJson = $body | ConvertFrom-Json } catch { $bodyJson = $null }
                }
                $payloadCredential = $query.ContainsKey("apiKey")
                if ($null -ne $bodyJson -and @($bodyJson.PSObject.Properties.Name | Where-Object { $_ -ieq "apiKey" }).Count -gt 0) {
                    $payloadCredential = $true
                }
                if ($payloadCredential) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "credential_must_use_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $provided = ""
                if ($headers.ContainsKey("x-monitorcontrol-key")) {
                    $provided = [string]$headers["x-monitorcontrol-key"]
                } elseif ($headers.ContainsKey("authorization")) {
                    $authorization = [string]$headers["authorization"]
                    if ($authorization -match '^Bearer\s+(.+)$') { $provided = $matches[1] }
                }
                if (-not (Test-BridgeToken -Provided $provided -Expected ([string]$Settings.ApiKey))) {
                    Send-BridgeJson -Client $Client -Status 401 -Body @{ error = "unauthorized" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $headers.Remove("x-monitorcontrol-key")
                $headers.Remove("authorization")

                $remoteScope = "unknown"
                try {
                    if ([System.Net.IPAddress]::IsLoopback($Client.Client.RemoteEndPoint.Address)) { $remoteScope = "loopback" } else { $remoteScope = "network" }
                } catch {
                    $remoteScope = "unknown"
                }
                $id = [guid]::NewGuid().ToString("N")
                $responseId = $id
                $request = [PSCustomObject]@{
                    Id = $id
                    Method = $method
                    Path = [string]$uri.AbsolutePath
                    Query = $query
                    Headers = $headers
                    Body = $body
                    Remote = $remoteScope
                    Authenticated = $true
                    ExpiresAtUtc = [DateTime]::UtcNow.AddMilliseconds([int]$Settings.RouteTimeoutMs)
                }
                $responseSyncRoot = $ResponseMap.SyncRoot
                [System.Threading.Monitor]::Enter($responseSyncRoot)
                try {
                    $ResponseMap[$id] = $null
                } finally {
                    [System.Threading.Monitor]::Exit($responseSyncRoot)
                }
                $RequestQueue.Enqueue($request)
                $deadline = [DateTime]$request.ExpiresAtUtc
                $response = $null
                while ([DateTime]::UtcNow -lt $deadline -and -not [bool]$BridgeState["Stop"]) {
                    [System.Threading.Monitor]::Enter($responseSyncRoot)
                    try {
                        if ($ResponseMap.ContainsKey($id) -and $null -ne $ResponseMap[$id]) {
                            $response = $ResponseMap[$id]
                            $null = $ResponseMap.Remove($id)
                        }
                    } finally {
                        [System.Threading.Monitor]::Exit($responseSyncRoot)
                    }
                    if ($null -ne $response) { break }
                    Start-Sleep -Milliseconds 20
                }
                if ($null -eq $response) {
                    [System.Threading.Monitor]::Enter($responseSyncRoot)
                    try {
                        if ($ResponseMap.ContainsKey($id)) {
                            if ($null -ne $ResponseMap[$id]) { $response = $ResponseMap[$id] }
                            $null = $ResponseMap.Remove($id)
                        }
                    } finally {
                        [System.Threading.Monitor]::Exit($responseSyncRoot)
                    }
                }
                if ($null -eq $response) {
                    Send-BridgeJson -Client $Client -Status 504 -Body @{ error = "route_timeout" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                } else {
                    Send-BridgeJson -Client $Client -Status ([int]$response.Status) -Body $response.Body -Settings $Settings -BridgeState $BridgeState | Out-Null
                }
            } catch [System.IO.IOException] {
                if ($null -ne $stream) {
                    Send-BridgeJson -Client $Client -Status 408 -Body @{ error = "request_timeout" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                }
            } catch {
                Send-BridgeJson -Client $Client -Status 500 -Body @{ error = "internal_error" } -Settings $Settings -BridgeState $BridgeState | Out-Null
            } finally {
                if (-not [string]::IsNullOrWhiteSpace($responseId)) {
                    $responseSyncRoot = $ResponseMap.SyncRoot
                    [System.Threading.Monitor]::Enter($responseSyncRoot)
                    try { $null = $ResponseMap.Remove($responseId) } finally { [System.Threading.Monitor]::Exit($responseSyncRoot) }
                }
                Close-BridgeClient -Client $Client -DrainInput (-not $requestFullyRead)
            }
        }

        $listener = $Settings.Listener
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [int]$Settings.MaxConcurrentClients)
        $pool.Open()
        $active = New-Object System.Collections.ArrayList
        try {
            while (-not [bool]$BridgeState["Stop"]) {
                foreach ($job in @($active.ToArray())) {
                    if ($job.Async.IsCompleted) {
                        try { $job.PowerShell.EndInvoke($job.Async) | Out-Null } catch {
                            $BridgeState["HandlerFailureCount"] = [int]$BridgeState["HandlerFailureCount"] + 1
                        }
                        $job.PowerShell.Dispose()
                        [void]$active.Remove($job)
                    }
                }
                $BridgeState["ActiveClients"] = [int]$active.Count
                if ([int]$active.Count -gt [int]$BridgeState["PeakActiveClients"]) {
                    $BridgeState["PeakActiveClients"] = [int]$active.Count
                }

                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                    if ($active.Count -ge [int]$Settings.MaxConcurrentClients) {
                        $BridgeState["RejectedClients"] = [int]$BridgeState["RejectedClients"] + 1
                        Send-BridgeBusy -Client $client -Settings $Settings -BridgeState $BridgeState
                        continue
                    }
                    $powershell = [PowerShell]::Create()
                    $powershell.RunspacePool = $pool
                    $powershell.AddScript($handlerScript.ToString()).AddArgument($client).AddArgument($Settings).AddArgument($RequestQueue).AddArgument($ResponseMap).AddArgument($BridgeState) | Out-Null
                    $async = $powershell.BeginInvoke()
                    [void]$active.Add([PSCustomObject]@{ PowerShell = $powershell; Async = $async; Client = $client })
                    continue
                }
                Start-Sleep -Milliseconds 20
            }
        } finally {
            try { $listener.Stop() } catch { $null = $_ }
            foreach ($job in @($active.ToArray())) {
                try { $job.Client.Close() } catch { $null = $_ }
                try {
                    if (-not $job.Async.AsyncWaitHandle.WaitOne(500)) { $job.PowerShell.Stop() }
                    $job.PowerShell.EndInvoke($job.Async) | Out-Null
                } catch {
                    $BridgeState["HandlerFailureCount"] = [int]$BridgeState["HandlerFailureCount"] + 1
                }
                $job.PowerShell.Dispose()
            }
            $active.Clear()
            $BridgeState["ActiveClients"] = 0
            try { $pool.Close() } catch { $null = $_ }
            $pool.Dispose()
        }
    }
}
