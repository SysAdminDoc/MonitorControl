function Get-CliExitCodes {
    return [PSCustomObject]@{
        Success = 0
        Usage = 2
        Target = 3
        Timeout = 4
        Hardware = 5
        Safety = 6
        Internal = 10
    }
}

function New-CliEnvelope {
    param(
        [string]$Command,
        [bool]$Success,
        [int]$ExitCode,
        $Data = $null,
        [string]$ErrorCode = "",
        [string]$ErrorMessage = ""
    )
    return [ordered]@{
        SchemaVersion = 1
        Command = [string]$Command
        Success = [bool]$Success
        ExitCode = [int]$ExitCode
        Data = $Data
        Error = if ([string]::IsNullOrWhiteSpace($ErrorCode)) {
            $null
        } else {
            [ordered]@{ Code = $ErrorCode; Message = $ErrorMessage }
        }
    }
}

function New-CliResult {
    param(
        [string]$Command,
        [int]$ExitCode,
        $Data = $null,
        [string]$Text = "",
        [string]$ErrorCode = "",
        [string]$ErrorMessage = ""
    )
    $success = $ExitCode -eq (Get-CliExitCodes).Success
    return [PSCustomObject]@{
        ExitCode = [int]$ExitCode
        Text = if ($success) { [string]$Text } else { [string]$ErrorMessage }
        Envelope = New-CliEnvelope -Command $Command -Success $success -ExitCode $ExitCode -Data $Data -ErrorCode $ErrorCode -ErrorMessage $ErrorMessage
    }
}

function New-CliFailureException {
    param([int]$ExitCode, [string]$ErrorCode, [string]$Message)
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data["CliExitCode"] = [int]$ExitCode
    $exception.Data["CliErrorCode"] = [string]$ErrorCode
    return $exception
}

function ConvertTo-CliQuotedArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = "" }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashCount * 2) + 1)))
            [void]$builder.Append('"')
            $slashCount = 0
            continue
        }
        if ($slashCount -gt 0) {
            [void]$builder.Append(('\' * $slashCount))
            $slashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashCount -gt 0) { [void]$builder.Append(('\' * ($slashCount * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Wait-CliProcess {
    param($Process, [int]$TimeoutSeconds)
    if ($null -eq $Process) { return $false }
    return [bool]$Process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
}

function Get-CliChildArguments {
    param(
        [string]$EntryPath,
        [string]$Command,
        [string]$Argument,
        [string]$Monitor,
        [string]$Vcp,
        [string]$Value,
        [long]$Delta,
        [string]$Cycle,
        [string]$Culture,
        [switch]$IfNeeded,
        [switch]$Json,
        [switch]$AllowRisky,
        [int]$TimeoutSeconds
    )
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($item in @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $EntryPath, "-CliWorker", "-Command", $Command)) {
        $arguments.Add([string]$item)
    }
    foreach ($pair in @(
        [PSCustomObject]@{ Name = "-Argument"; Value = $Argument },
        [PSCustomObject]@{ Name = "-Monitor"; Value = $Monitor },
        [PSCustomObject]@{ Name = "-Vcp"; Value = $Vcp },
        [PSCustomObject]@{ Name = "-Value"; Value = $Value },
        [PSCustomObject]@{ Name = "-Cycle"; Value = $Cycle },
        [PSCustomObject]@{ Name = "-Culture"; Value = $Culture }
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pair.Value)) {
            $arguments.Add([string]$pair.Name)
            $arguments.Add([string]$pair.Value)
        }
    }
    if ($Delta -ne [long]::MinValue) {
        $arguments.Add("-Delta")
        $arguments.Add($Delta.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($IfNeeded) { $arguments.Add("-IfNeeded") }
    if ($Json) { $arguments.Add("-Json") }
    if ($AllowRisky) { $arguments.Add("-AllowRisky") }
    $arguments.Add("-TimeoutSeconds")
    $arguments.Add($TimeoutSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    return (($arguments | ForEach-Object { ConvertTo-CliQuotedArgument -Value $_ }) -join " ")
}

function Invoke-CliChildProcess {
    param(
        [string]$EntryPath,
        [string]$Command,
        [string]$Argument,
        [string]$Monitor,
        [string]$Vcp,
        [string]$Value,
        [long]$Delta,
        [string]$Cycle,
        [string]$Culture,
        [switch]$IfNeeded,
        [switch]$Json,
        [switch]$AllowRisky,
        [int]$TimeoutSeconds
    )
    $exitCodes = Get-CliExitCodes
    if ([string]::IsNullOrWhiteSpace($EntryPath) -or -not (Test-Path -LiteralPath $EntryPath -PathType Leaf)) {
        $message = "The CLI entry script could not be located."
        if ($Json) { [Console]::Out.WriteLine((New-CliEnvelope -Command $Command -Success $false -ExitCode $exitCodes.Internal -ErrorCode "entry_missing" -ErrorMessage $message | ConvertTo-Json -Depth 10 -Compress)) }
        else { [Console]::Error.WriteLine($message) }
        return $exitCodes.Internal
    }
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $startInfo.Arguments = Get-CliChildArguments -EntryPath $EntryPath -Command $Command -Argument $Argument -Monitor $Monitor -Vcp $Vcp -Value $Value -Delta $Delta -Cycle $Cycle -Culture $Culture -IfNeeded:$IfNeeded -Json:$Json -AllowRisky:$AllowRisky -TimeoutSeconds $TimeoutSeconds
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "The CLI worker could not be started." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not (Wait-CliProcess -Process $process -TimeoutSeconds $TimeoutSeconds)) {
            try { $process.Kill() } catch {}
            try { $process.WaitForExit() } catch {}
            $message = "The CLI command timed out after $TimeoutSeconds second(s)."
            if ($Json) { [Console]::Out.WriteLine((New-CliEnvelope -Command $Command -Success $false -ExitCode $exitCodes.Timeout -ErrorCode "timeout" -ErrorMessage $message | ConvertTo-Json -Depth 10 -Compress)) }
            else { [Console]::Error.WriteLine($message) }
            return $exitCodes.Timeout
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not [string]::IsNullOrEmpty($stdout)) { [Console]::Out.Write($stdout) }
        if (-not [string]::IsNullOrEmpty($stderr)) { [Console]::Error.Write($stderr) }
        return [int]$process.ExitCode
    } catch {
        $message = "The CLI worker failed to run: $($_.Exception.Message)"
        if ($Json) { [Console]::Out.WriteLine((New-CliEnvelope -Command $Command -Success $false -ExitCode $exitCodes.Internal -ErrorCode "worker_failed" -ErrorMessage $message | ConvertTo-Json -Depth 10 -Compress)) }
        else { [Console]::Error.WriteLine($message) }
        return $exitCodes.Internal
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Resolve-CliMonitor {
    param([object[]]$Monitors, [string]$Identifier)
    $exitCodes = Get-CliExitCodes
    $items = @($Monitors | Where-Object { $null -ne $_ })
    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        $usable = @($items | Where-Object { $_.Handle -ne [IntPtr]::Zero -or [string]$_.DeviceName -eq "WMI" })
        if ($usable.Count -ne 1) {
            throw (New-CliFailureException -ExitCode $exitCodes.Target -ErrorCode "monitor_required" -Message "Specify -Monitor with a stable identity from the list command.")
        }
        return $usable[0]
    }
    $exact = @($items | Where-Object {
        [string]$_.IdentityKey -eq $Identifier -or
        ($_.PSObject.Properties.Name -contains "IdentityAliases" -and @($_.IdentityAliases) -contains $Identifier)
    })
    if ($exact.Count -eq 1) { return $exact[0] }
    $friendly = @($items | Where-Object {
        [string](Get-MonitorDisplayLabel -Monitor $_) -eq $Identifier -or [string]$_.Name -eq $Identifier
    })
    if ($friendly.Count -eq 1) { return $friendly[0] }
    if ($friendly.Count -gt 1 -or $exact.Count -gt 1) {
        throw (New-CliFailureException -ExitCode $exitCodes.Target -ErrorCode "monitor_ambiguous" -Message "Monitor '$Identifier' is ambiguous; use its stable identity.")
    }
    throw (New-CliFailureException -ExitCode $exitCodes.Target -ErrorCode "monitor_not_found" -Message "Monitor '$Identifier' was not found; run the list command for stable identities.")
}

function Resolve-CliVcpCode {
    param([string]$Text)
    $code = ConvertTo-VcpCode -Text $Text
    if ($null -eq $code) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "invalid_vcp" -Message "VCP must be a decimal byte or hexadecimal byte such as 0x10.")
    }
    return [int]$code
}

function Resolve-CliVcpValue {
    param([int]$Code, [string]$Text)
    $normalized = if ($null -eq $Text) { "" } else { $Text.Trim().ToLowerInvariant().Replace("-", "").Replace("_", "").Replace(" ", "") }
    if ($Code -eq 0x60) {
        $inputs = @{
            "vga" = 0x01; "dvi" = 0x03; "displayport1" = 0x0F; "dp1" = 0x0F
            "displayport2" = 0x10; "dp2" = 0x10; "hdmi1" = 0x11; "hdmi2" = 0x12
            "usbc" = 0x13; "usbctypec" = 0x13
        }
        if ($inputs.ContainsKey($normalized)) { return [uint32]$inputs[$normalized] }
    }
    $value = ConvertTo-VcpValue -Text $Text
    if ($null -eq $value) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "invalid_value" -Message "Value must be an unsigned integer$(if ($Code -eq 0x60) { ' or a known input name' } else { '' }).")
    }
    return [uint32]$value
}

function Get-CliMonitorData {
    param([object[]]$Monitors)
    $data = @($Monitors | Where-Object { $null -ne $_ } | ForEach-Object {
        $supportedCodes = if ([bool]$_.CapabilitiesKnown -and $null -ne $_.SupportedVcpCodes) {
            @($_.SupportedVcpCodes.Keys | Sort-Object | ForEach-Object { "0x{0:X2}" -f [int]$_ })
        } else {
            [object[]]@()
        }
        [ordered]@{
            Identity = [string]$_.IdentityKey
            IdentitySource = [string]$_.IdentitySource
            Label = [string](Get-MonitorDisplayLabel -Monitor $_)
            Name = [string]$_.Name
            DdcAvailable = [bool]($_.Handle -ne [IntPtr]::Zero)
            IntegratedBrightness = [bool]([string]$_.DeviceName -eq "WMI")
            Resolution = "$([int]$_.Width)x$([int]$_.Height)"
            Primary = [bool]$_.IsPrimary
            CapabilitiesKnown = [bool]$_.CapabilitiesKnown
            SupportedVcpCodes = @($supportedCodes)
        }
    })
    return ,$data
}

function Read-CliVcpValue {
    param($Monitor, [int]$Code, [scriptblock]$ReadAction)
    $result = if ($null -ne $ReadAction) {
        & $ReadAction $Monitor $Code
    } elseif ([string]$Monitor.DeviceName -eq "WMI" -and $Code -eq 0x10) {
        $current = Get-WmiBrightness
        [PSCustomObject]@{ Success = $null -ne $current; Current = if ($null -ne $current) { [uint32]$current } else { [uint32]0 }; Maximum = [uint32]100; Type = [uint32]0; LastError = 0; Attempts = 1 }
    } elseif ($Monitor.Handle -ne [IntPtr]::Zero) {
        Get-VCPValue -Handle ([IntPtr]$Monitor.Handle) -VCPCode ([byte]$Code) -MonitorName ([string]$Monitor.Name) -IdentityKey ([string]$Monitor.IdentityKey)
    } else {
        [PSCustomObject]@{ Success = $false; Current = [uint32]0; Maximum = [uint32]0; Type = [uint32]0; LastError = 0; Attempts = 0 }
    }
    if ($null -ne $result -and [bool]$result.Success -and [uint32]$result.Maximum -gt 0) {
        Set-VcpMaximumForMonitor -Monitor $Monitor -Code $Code -Maximum ([int][uint32]$result.Maximum)
    }
    return $result
}

function Test-CliRiskyWriteAllowed {
    param($Monitor, [int]$Code, [switch]$AllowRisky)
    if (-not (Test-VcpWriteRequiresSafetyConsent -Code $Code)) { return $true }
    if (-not $AllowRisky -or -not (Test-VcpWriteEnabledForMonitor -Monitor $Monitor)) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Safety -ErrorCode "risky_write_denied" -Message "VCP 0x$('{0:X2}' -f $Code) requires both -AllowRisky and the GUI's saved unlock for this monitor identity.")
    }
    return $true
}

function Get-CliSetTarget {
    param(
        $Monitor,
        [int]$Code,
        [string]$ValueText,
        [long]$Delta,
        [string]$Cycle,
        [switch]$Percent,
        [switch]$IfNeeded,
        [scriptblock]$ReadAction
    )
    $needsRead = $Delta -ne [long]::MinValue -or -not [string]::IsNullOrWhiteSpace($Cycle) -or $Percent -or $IfNeeded
    $readback = if ($needsRead) { Read-CliVcpValue -Monitor $Monitor -Code $Code -ReadAction $ReadAction } else { $null }
    if ($needsRead -and ($null -eq $readback -or -not [bool]$readback.Success)) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Hardware -ErrorCode "read_failed" -Message "VCP 0x$('{0:X2}' -f $Code) could not be read before calculating the requested value.")
    }
    if ($Delta -ne [long]::MinValue) {
        $candidate = [long][uint32]$readback.Current + $Delta
        if ($candidate -lt 0 -or $candidate -gt [uint32]::MaxValue) {
            throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "value_out_of_range" -Message "The relative VCP value is outside the unsigned 32-bit range.")
        }
        if ([uint32]$readback.Maximum -gt 0 -and $candidate -gt [uint32]$readback.Maximum) {
            throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "value_above_maximum" -Message "The relative VCP value $candidate exceeds the monitor's reported maximum $([uint32]$readback.Maximum).")
        }
        $target = [uint32]$candidate
    } elseif (-not [string]::IsNullOrWhiteSpace($Cycle)) {
        $cycleValues = @($Cycle.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Resolve-CliVcpValue -Code $Code -Text $_ })
        if ($cycleValues.Count -lt 2) {
            throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "invalid_cycle" -Message "-Cycle requires at least two comma-separated values.")
        }
        $currentIndex = [Array]::IndexOf([uint32[]]$cycleValues, [uint32]$readback.Current)
        $nextIndex = if ($currentIndex -lt 0) { 0 } else { ($currentIndex + 1) % $cycleValues.Count }
        $target = [uint32]$cycleValues[$nextIndex]
    } else {
        if ([string]::IsNullOrWhiteSpace($ValueText)) {
            throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "value_required" -Message "Set requires -Value, -Delta, or -Cycle.")
        }
        $target = Resolve-CliVcpValue -Code $Code -Text $ValueText
        if ($Percent) {
            if ([uint32]$target -gt 100) {
                throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "percent_out_of_range" -Message "Brightness percent must be between 0 and 100.")
            }
            $maximum = if ([uint32]$readback.Maximum -gt 0) { [int][uint32]$readback.Maximum } else { Get-VcpMaximumForMonitor -Monitor $Monitor -Code $Code }
            $target = [uint32](ConvertTo-VcpRawValue -Percent ([double]$target) -Maximum $maximum)
        }
    }
    $unchanged = $null -ne $readback -and [bool]$readback.Success -and [uint32]$readback.Current -eq [uint32]$target
    return [PSCustomObject]@{ Target = [uint32]$target; Current = if ($null -ne $readback) { [uint32]$readback.Current } else { $null }; Unchanged = [bool]$unchanged }
}

function Invoke-CliTransaction {
    param([object[]]$Operations, [scriptblock]$ReadAction, [scriptblock]$TransactionAction)
    if ($null -ne $TransactionAction) {
        $transaction = & $TransactionAction $Operations
        Register-DdcHealthVerificationResult -Transaction $transaction
        return $transaction
    }
    $transactionRead = {
        param($Operation)
        return Read-CliVcpValue -Monitor $Operation.Monitor -Code ([int]$Operation.Code) -ReadAction $ReadAction
    }
    $transaction = Invoke-VerifiedVcpTransaction -Operations $Operations -ReadValue $transactionRead -RollbackOnFailure
    Register-DdcHealthVerificationResult -Transaction $transaction
    return $transaction
}

function Get-CliTransactionData {
    param($Transaction)
    return [ordered]@{
        Outcome = [string]$Transaction.Outcome
        Rollback = [string]$Transaction.Rollback
        Writes = @($Transaction.Results | ForEach-Object {
            [ordered]@{
                Identity = [string]$_.Operation.IdentityKey
                Vcp = "0x{0:X2}" -f [int]$_.Operation.Code
                Value = [uint32]$_.Operation.Value
                WriteSuccess = [bool]$_.WriteSuccess
                Verification = [string]$_.Verification
                Readback = [uint32]$_.ReadbackValue
                Rollback = [string]$_.Rollback
            }
        })
    }
}

function Read-CliProfile {
    param([string]$Name)
    $safeName = Get-SafeProfileName -Name $Name
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "invalid_profile" -Message "Profile name is invalid.")
    }
    $path = Join-Path $script:ProfilesPath "$safeName.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Target -ErrorCode "profile_not_found" -Message "Profile '$safeName' was not found.")
    }
    $profileData = Read-JsonFileSafely -Path $path -Label "Profile '$safeName'" -ReadOnly:$script:ProfileStorageOffline
    if ($null -eq $profileData) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "profile_invalid" -Message "Profile '$safeName' is invalid.")
    }
    $schema = if ($profileData.PSObject.Properties.Name -contains "SchemaVersion") { [int]$profileData.SchemaVersion } else { 1 }
    if ($schema -lt 1 -or $schema -gt $script:ProfileSchemaVersion) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "profile_schema" -Message "Profile '$safeName' uses unsupported schema v$schema.")
    }
    return $profileData
}

function Get-CliProfilePercent {
    param($Settings, $ProfileData, [string]$Property)
    try {
        $value = if ($null -ne $Settings -and $Settings.PSObject.Properties.Name -contains $Property) {
            [int]$Settings.$Property
        } elseif ($ProfileData.PSObject.Properties.Name -contains $Property) {
            [int]$ProfileData.$Property
        } else {
            50
        }
    } catch {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "profile_value" -Message "Profile property $Property must be an integer between 0 and 100.")
    }
    if ($value -lt 0 -or $value -gt 100) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "profile_value" -Message "Profile property $Property must be between 0 and 100.")
    }
    return $value
}

function Get-CliProfileOperations {
    param($ProfileData, [object[]]$Monitors, [string]$MonitorIdentifier, [scriptblock]$ReadAction)
    $settings = @($ProfileData.MonitorSettings | Where-Object { $null -ne $_ })
    $plans = @()
    $missingIdentities = @()
    if (-not [string]::IsNullOrWhiteSpace($MonitorIdentifier)) {
        $target = Resolve-CliMonitor -Monitors $Monitors -Identifier $MonitorIdentifier
        $setting = @($settings | Where-Object { [string]$_.IdentityKey -eq [string]$target.IdentityKey } | Select-Object -First 1)
        $plans += [PSCustomObject]@{ Monitor = $target; Settings = if ($setting.Count) { $setting[0] } else { $null } }
    } elseif ($settings.Count -gt 0) {
        foreach ($setting in $settings) {
            $identity = [string]$setting.IdentityKey
            if ([string]::IsNullOrWhiteSpace($identity)) {
                throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Usage -ErrorCode "profile_identity" -Message "Every profile monitor setting must contain a stable identity.")
            }
            try {
                $target = Resolve-CliMonitor -Monitors $Monitors -Identifier $identity
                $plans += [PSCustomObject]@{ Monitor = $target; Settings = $setting }
            } catch {
                if ([int]$_.Exception.Data["CliExitCode"] -ne (Get-CliExitCodes).Target) { throw }
                $missingIdentities += $identity
            }
        }
    } else {
        $plans += [PSCustomObject]@{ Monitor = Resolve-CliMonitor -Monitors $Monitors -Identifier ""; Settings = $null }
    }
    if ($missingIdentities.Count -gt 0) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Target -ErrorCode "profile_targets_missing" -Message "Profile monitor identity not connected: $($missingIdentities -join ', '). No writes were sent.")
    }
    if ($plans.Count -eq 0) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Target -ErrorCode "profile_targets_missing" -Message "None of the profile's stable monitor identities are connected. No writes were sent.")
    }
    $properties = @(
        [PSCustomObject]@{ Name = "Brightness"; Code = 0x10 },
        [PSCustomObject]@{ Name = "Contrast"; Code = 0x12 },
        [PSCustomObject]@{ Name = "Red"; Code = 0x16 },
        [PSCustomObject]@{ Name = "Green"; Code = 0x18 },
        [PSCustomObject]@{ Name = "Blue"; Code = 0x1A }
    )
    $operations = @()
    foreach ($plan in $plans) {
        foreach ($property in $properties) {
            $monitor = $plan.Monitor
            $code = [int]$property.Code
            if ([string]$monitor.DeviceName -eq "WMI" -and $code -ne 0x10) { continue }
            $readback = Read-CliVcpValue -Monitor $monitor -Code $code -ReadAction $ReadAction
            if ($null -eq $readback -or -not [bool]$readback.Success) { continue }
            $percent = Get-CliProfilePercent -Settings $plan.Settings -ProfileData $ProfileData -Property ([string]$property.Name)
            $maximum = if ([uint32]$readback.Maximum -gt 0) { [int][uint32]$readback.Maximum } else { Get-VcpMaximumForMonitor -Monitor $monitor -Code $code }
            $rawValue = [uint32](ConvertTo-VcpRawValue -Percent $percent -Maximum $maximum)
            if (Test-MonitorSupportsVcpValue -Monitor $monitor -Code $code -Value ([int]$rawValue)) {
                $backend = if ([string]$monitor.DeviceName -eq "WMI") { "WMI" } else { "DDC" }
                $operations += Get-VcpWriteOperation -Monitor $monitor -Code $code -Value $rawValue -Backend $backend
            }
        }
    }
    if ($operations.Count -eq 0) {
        throw (New-CliFailureException -ExitCode (Get-CliExitCodes).Hardware -ErrorCode "profile_unreadable" -Message "No profile VCP values could be read safely on the selected monitor(s).")
    }
    return $operations
}

function Initialize-CliMonitorState {
    Initialize-WmiBrightness
    Load-MonitorIdentitySettings
    Import-VcpWriteSafetyState
    Import-CapabilitiesCache
    Import-DdcTimingSettings
    Get-Monitors
    return @($script:PhysicalMonitors)
}

function Invoke-MonitorControlCli {
    param(
        [string]$Command,
        [string]$Argument = "",
        [string]$Monitor = "",
        [string]$Vcp = "",
        [string]$Value = "",
        [long]$Delta = [long]::MinValue,
        [string]$Cycle = "",
        [switch]$IfNeeded,
        [switch]$AllowRisky,
        [object[]]$MonitorData,
        [scriptblock]$ReadAction,
        [scriptblock]$TransactionAction,
        [scriptblock]$InitializeAction
    )
    $exitCodes = Get-CliExitCodes
    $normalized = if ($null -eq $Command) { "" } else { $Command.Trim().ToLowerInvariant() }
    try {
        if ($normalized -notin @("list", "get", "set", "profile", "diagnostics", "b", "s")) {
            throw (New-CliFailureException -ExitCode $exitCodes.Usage -ErrorCode "unknown_command" -Message "Command must be list, get, set, profile, diagnostics, b, or s.")
        }
        $monitors = if ($null -ne $MonitorData) {
            @($MonitorData)
        } elseif ($null -ne $InitializeAction) {
            @(& $InitializeAction)
        } else {
            @(Initialize-CliMonitorState)
        }
        if ($normalized -eq "list") {
            $data = Get-CliMonitorData -Monitors $monitors
            $lines = @($data | ForEach-Object { "$($_.Identity)  $($_.Label)  $(if ($_.DdcAvailable) { 'DDC/CI' } elseif ($_.IntegratedBrightness) { 'WMI brightness' } else { 'unavailable' })  $($_.Resolution)" })
            return New-CliResult -Command "list" -ExitCode $exitCodes.Success -Data $data -Text ($lines -join [Environment]::NewLine)
        }
        if ($normalized -eq "diagnostics") {
            $selected = if ([string]::IsNullOrWhiteSpace($Monitor)) { @($monitors) } else { @(Resolve-CliMonitor -Monitors $monitors -Identifier $Monitor) }
            $data = [ordered]@{
                AppVersion = [string]$script:AppVersion
                Monitors = Get-CliMonitorData -Monitors $selected
                RecentDdcErrors = @($script:DdcRecentErrors | Select-Object -Last 20 | ForEach-Object {
                    [ordered]@{ Operation = [string]$_.Operation; Vcp = "0x{0:X2}" -f [int]$_.Code; LastError = [int]$_.LastError; Attempts = [int]$_.Attempts }
                })
            }
            $text = "MonitorControl Pro $($script:AppVersion): $(@($selected).Count) monitor(s), $(@($selected | Where-Object { $_.Handle -ne [IntPtr]::Zero }).Count) DDC/CI channel(s), $(@($data.RecentDdcErrors).Count) recent error(s)"
            return New-CliResult -Command "diagnostics" -ExitCode $exitCodes.Success -Data $data -Text $text
        }
        if ($normalized -eq "profile") {
            if ([string]::IsNullOrWhiteSpace($Argument)) {
                throw (New-CliFailureException -ExitCode $exitCodes.Usage -ErrorCode "profile_required" -Message "Profile command requires a profile name as its argument.")
            }
            $profileData = Read-CliProfile -Name $Argument
            $operations = Get-CliProfileOperations -ProfileData $profileData -Monitors $monitors -MonitorIdentifier $Monitor -ReadAction $ReadAction
            $transaction = Invoke-CliTransaction -Operations $operations -ReadAction $ReadAction -TransactionAction $TransactionAction
            if (-not [bool]$transaction.Success) {
                throw (New-CliFailureException -ExitCode $exitCodes.Hardware -ErrorCode "profile_write_failed" -Message "Profile '$Argument' failed: $($transaction.Outcome); rollback $($transaction.Rollback).")
            }
            $data = Get-CliTransactionData -Transaction $transaction
            $data["Profile"] = [string]$Argument
            return New-CliResult -Command "profile" -ExitCode $exitCodes.Success -Data $data -Text "Applied profile '$Argument' with $($operations.Count) verified write(s): $($transaction.Outcome)."
        }
        $targetMonitor = Resolve-CliMonitor -Monitors $monitors -Identifier $Monitor
        $codeText = if ($normalized -eq "b") { "0x10" } elseif ($normalized -eq "s") { "0x60" } elseif (-not [string]::IsNullOrWhiteSpace($Vcp)) { $Vcp } else { $Argument }
        $code = Resolve-CliVcpCode -Text $codeText
        if (-not (Test-MonitorSupportsVcp -Monitor $targetMonitor -Code $code)) {
            throw (New-CliFailureException -ExitCode $exitCodes.Target -ErrorCode "vcp_unsupported" -Message "The selected monitor reports that VCP 0x$('{0:X2}' -f $code) is unsupported.")
        }
        if ($normalized -eq "get") {
            $readback = Read-CliVcpValue -Monitor $targetMonitor -Code $code -ReadAction $ReadAction
            if ($null -eq $readback -or -not [bool]$readback.Success) {
                throw (New-CliFailureException -ExitCode $exitCodes.Hardware -ErrorCode "read_failed" -Message "VCP 0x$('{0:X2}' -f $code) could not be read from the selected monitor.")
            }
            $data = [ordered]@{
                Identity = [string]$targetMonitor.IdentityKey
                Vcp = "0x{0:X2}" -f $code
                Current = [uint32]$readback.Current
                Maximum = [uint32]$readback.Maximum
                Type = [uint32]$readback.Type
            }
            return New-CliResult -Command "get" -ExitCode $exitCodes.Success -Data $data -Text "$($data.Identity) VCP $($data.Vcp) = $($data.Current) / $($data.Maximum)"
        }
        if ($normalized -eq "b" -or $normalized -eq "s") { $Value = $Argument }
        Test-CliRiskyWriteAllowed -Monitor $targetMonitor -Code $code -AllowRisky:$AllowRisky | Out-Null
        $target = Get-CliSetTarget -Monitor $targetMonitor -Code $code -ValueText $Value -Delta $Delta -Cycle $Cycle -Percent:($normalized -eq "b") -IfNeeded:$IfNeeded -ReadAction $ReadAction
        if ($target.Unchanged -and $IfNeeded) {
            $data = [ordered]@{ Identity = [string]$targetMonitor.IdentityKey; Vcp = "0x{0:X2}" -f $code; Value = [uint32]$target.Target; Changed = $false; Outcome = "AlreadySet" }
            return New-CliResult -Command "set" -ExitCode $exitCodes.Success -Data $data -Text "$($data.Identity) VCP $($data.Vcp) already equals $($data.Value); no write sent."
        }
        if ([bool]$targetMonitor.CapabilitiesKnown -and [uint32]$target.Target -gt [int]::MaxValue) {
            throw (New-CliFailureException -ExitCode $exitCodes.Usage -ErrorCode "value_out_of_range" -Message "The value is too large to compare with the monitor's advertised VCP values.")
        }
        if ([bool]$targetMonitor.CapabilitiesKnown -and -not (Test-MonitorSupportsVcpValue -Monitor $targetMonitor -Code $code -Value ([int][uint32]$target.Target))) {
            throw (New-CliFailureException -ExitCode $exitCodes.Target -ErrorCode "value_unsupported" -Message "The selected monitor reports that value $($target.Target) is unsupported for VCP 0x$('{0:X2}' -f $code).")
        }
        $backend = if ([string]$targetMonitor.DeviceName -eq "WMI" -and $code -eq 0x10) { "WMI" } else { "DDC" }
        $operation = Get-VcpWriteOperation -Monitor $targetMonitor -Code $code -Value ([uint32]$target.Target) -Backend $backend
        $transaction = Invoke-CliTransaction -Operations @($operation) -ReadAction $ReadAction -TransactionAction $TransactionAction
        if (-not [bool]$transaction.Success) {
            throw (New-CliFailureException -ExitCode $exitCodes.Hardware -ErrorCode "write_failed" -Message "VCP write failed: $($transaction.Outcome); rollback $($transaction.Rollback).")
        }
        $data = Get-CliTransactionData -Transaction $transaction
        $data["Changed"] = $true
        return New-CliResult -Command "set" -ExitCode $exitCodes.Success -Data $data -Text "$([string]$targetMonitor.IdentityKey) VCP 0x$('{0:X2}' -f $code) set to $([uint32]$target.Target): $($transaction.Outcome)."
    } catch {
        $exitCode = if ($_.Exception.Data.Contains("CliExitCode")) { [int]$_.Exception.Data["CliExitCode"] } else { $exitCodes.Internal }
        $errorCode = if ($_.Exception.Data.Contains("CliErrorCode")) { [string]$_.Exception.Data["CliErrorCode"] } else { "internal_error" }
        return New-CliResult -Command $normalized -ExitCode $exitCode -ErrorCode $errorCode -ErrorMessage ([string]$_.Exception.Message)
    }
}

if (-not [string]::IsNullOrWhiteSpace([string]$Command) -and -not $CliWorker) {
    $cliExitCode = Invoke-CliChildProcess -EntryPath ([string]$script:MonitorControlEntryPath) -Command $Command -Argument $Argument -Monitor $Monitor -Vcp $Vcp -Value $Value -Delta $Delta -Cycle $Cycle -Culture $Culture -IfNeeded:$IfNeeded -Json:$Json -AllowRisky:$AllowRisky -TimeoutSeconds $TimeoutSeconds
    exit $cliExitCode
}
