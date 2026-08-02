# MonitorControl Pro Automation source module.

# Dot-sourced by the development launcher and composed into the portable release.



function Get-GpuBrandingVersions {
    param([object[]]$Table)
    if ($null -eq $Table) { $Table = @($script:KnownBadGpuDrivers) }
    $versions = @{}
    $names = @()
    foreach ($entry in @($Table)) {
        $valueName = [string]$entry.BrandingValueName
        if (-not [string]::IsNullOrWhiteSpace($valueName) -and $names -notcontains $valueName) { $names += $valueName }
    }
    if ($names.Count -eq 0) { return $versions }
    # The vendor control panel writes its branded release into the display
    # adapter class key; Win32_VideoController only carries the file version.
    $classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction Stop)) {
            foreach ($valueName in $names) {
                if ($versions.ContainsKey($valueName)) { continue }
                $value = $null
                try { $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name $valueName -ErrorAction Stop).$valueName } catch {}
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $versions[$valueName] = [string]$value }
            }
        }
    } catch {}
    return $versions
}

function Get-TimeBasedSettings {
    $hour = (Get-Date).Hour
    if ($hour -ge 7 -and $hour -lt 18) { return @{ Mode = "Day"; Brightness = 80; GammaRed = 1.0; GammaGreen = 1.0; GammaBlue = 1.0 } }
    elseif ($hour -ge 18 -and $hour -lt 21) { return @{ Mode = "Evening"; Brightness = 60; GammaRed = 1.0; GammaGreen = 0.95; GammaBlue = 0.85 } }
    else { return @{ Mode = "Night"; Brightness = 40; GammaRed = 1.0; GammaGreen = 0.9; GammaBlue = 0.75 } }
}

function Initialize-WmiBrightness {
    try {
        $script:WmiBrightnessAvailable = @(
            Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop
        ).Count -gt 0
    } catch {
        $script:WmiBrightnessAvailable = $false
    }
}

function Get-WmiBrightness {
    try {
        $level = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
        if ($level -and $null -ne $level.CurrentBrightness) { return [int]$level.CurrentBrightness }
    } catch {}
    return $null
}

function Set-WmiBrightness {
    param([int]$Value)
    if (-not $script:WmiBrightnessAvailable) { return $false }
    $brightness = [Math]::Max(0, [Math]::Min(100, $Value))
    try {
        $methods = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
        foreach ($method in $methods) {
            Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = $brightness } -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        Update-Status "WMI brightness failed: $_"
        return $false
    }
}

function Initialize-AmbientLightSensor {
    if ($script:AmbientLightSensor) { return $true }
    try {
        [void][Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
        $sensor = [Windows.Devices.Sensors.LightSensor]::GetDefault()
        if ($sensor) {
            $script:AmbientLightSensor = $sensor
            return $true
        }
    } catch {}
    return $false
}

function Get-AmbientLux {
    if (-not (Initialize-AmbientLightSensor)) { return $null }
    try {
        $reading = $script:AmbientLightSensor.GetCurrentReading()
        if ($reading -and $null -ne $reading.IlluminanceInLux) { return [double]$reading.IlluminanceInLux }
    } catch {}
    return $null
}

function Get-AmbientLevelIndex {
    param([int]$CurrentIndex, [double]$Lux, [object[]]$Ladder)
    if ($null -eq $Ladder -or @($Ladder).Count -eq 0) { $Ladder = @($script:AmbientLuxLadder) }
    $ladderEntries = @($Ladder)
    $last = $ladderEntries.Count - 1
    if ($CurrentIndex -lt 0) {
        # No previous reading, so there is nothing to be sticky about: take the plain ladder.
        $index = 0
        for ($i = 1; $i -le $last; $i++) {
            if ($Lux -ge [double]$ladderEntries[$i].RiseAbove) { $index = $i }
        }
        return $index
    }
    $index = [Math]::Min($last, [Math]::Max(0, $CurrentIndex))
    while ($index -lt $last -and $Lux -ge [double]$ladderEntries[$index + 1].RiseAbove) { $index++ }
    while ($index -gt 0 -and $Lux -lt [double]$ladderEntries[$index].FallBelow) { $index-- }
    return $index
}

function Get-AmbientBrightnessDecision {
    param(
        [double]$Lux,
        [int]$CurrentIndex = -1,
        [int]$CurrentBrightness = -1,
        [DateTime]$LastWriteUtc = [DateTime]::MinValue,
        [DateTime]$NowUtc = [DateTime]::MinValue,
        [int]$MaxStep = 0,
        [int]$MinIntervalSeconds = -1,
        [object[]]$Ladder
    )
    if ($null -eq $Ladder -or @($Ladder).Count -eq 0) { $Ladder = @($script:AmbientLuxLadder) }
    if ($MaxStep -le 0) { $MaxStep = [int]$script:AmbientMaxStepPercent }
    if ($MinIntervalSeconds -lt 0) { $MinIntervalSeconds = [int]$script:AmbientMinWriteIntervalSeconds }
    if ($NowUtc -eq [DateTime]::MinValue) { $NowUtc = [DateTime]::UtcNow }
    $levelIndex = Get-AmbientLevelIndex -CurrentIndex $CurrentIndex -Lux $Lux -Ladder $Ladder
    $target = [int]@($Ladder)[$levelIndex].Brightness
    $result = [PSCustomObject]@{
        LevelIndex = [int]$levelIndex
        TargetBrightness = [int]$target
        NextBrightness = [int]$target
        ShouldWrite = $false
        Reason = ""
    }
    if ($CurrentIndex -lt 0 -or $CurrentBrightness -lt 0) {
        # The first application after enabling ambient mode goes straight to the target: a slow
        # crawl from whatever the panel happened to be at is worse than one correct write.
        $result.ShouldWrite = $true
        $result.Reason = "first reading"
        return $result
    }
    if ($target -eq $CurrentBrightness) {
        $result.NextBrightness = [int]$CurrentBrightness
        $result.Reason = "already at the target for this light level"
        return $result
    }
    if (($NowUtc - $LastWriteUtc).TotalSeconds -lt $MinIntervalSeconds) {
        $result.NextBrightness = [int]$CurrentBrightness
        $result.Reason = "rate limited"
        return $result
    }
    $delta = $target - $CurrentBrightness
    if ($delta -gt $MaxStep) { $delta = $MaxStep }
    if ($delta -lt (-1 * $MaxStep)) { $delta = -1 * $MaxStep }
    $result.NextBrightness = [int]($CurrentBrightness + $delta)
    $result.ShouldWrite = $result.NextBrightness -ne $CurrentBrightness
    $result.Reason = if ($result.ShouldWrite) { "ramping toward $target" } else { "no change" }
    return $result
}

function Reset-AmbientBrightnessState {
    $script:AmbientLevelIndex = -1
    $script:AmbientAppliedBrightness = -1
    $script:AmbientLastWriteUtc = [DateTime]::MinValue
}

function Find-FirstExistingPath {
    param([string[]]$CandidatePaths, [scriptblock]$PathExists)
    if ($null -eq $PathExists) { $PathExists = { param([string]$Path) Test-Path -LiteralPath $Path } }
    foreach ($candidate in @($CandidatePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (& $PathExists $candidate)) { return $candidate }
    }
    return ""
}

function Get-RunAtLoginShortcutDefinition {
    param([string]$LauncherPath)
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $LauncherPath = Join-Path $script:MonitorControlRoot "MonitorControlPro.ps1"
    }
    $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    return [PSCustomObject]@{
        TargetPath = [System.IO.Path]::GetFullPath($powerShellPath)
        Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$([System.IO.Path]::GetFullPath($LauncherPath))`" -StartMinimized"
        WorkingDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($LauncherPath))
        IconLocation = "imageres.dll,109"
    }
}

function Get-RunAtLoginShortcutPath {
    $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    if ([string]::IsNullOrWhiteSpace($startup)) {
        $startup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    }
    return (Join-Path $startup "MonitorControl Pro.lnk")
}

function Test-RunAtLoginShortcut {
    param([string]$ShortcutPath, [string]$LauncherPath, [scriptblock]$ReadShortcut)
    if ([string]::IsNullOrWhiteSpace($ShortcutPath)) { $ShortcutPath = Get-RunAtLoginShortcutPath }
    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return $false }
    $expected = Get-RunAtLoginShortcutDefinition -LauncherPath $LauncherPath
    if ($null -eq $ReadShortcut) {
        $ReadShortcut = {
            param([string]$Path)
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $null
            try {
                $shortcut = $shell.CreateShortcut($Path)
                return [PSCustomObject]@{
                    TargetPath = [string]$shortcut.TargetPath
                    Arguments = [string]$shortcut.Arguments
                    WorkingDirectory = [string]$shortcut.WorkingDirectory
                }
            } finally {
                if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
            }
        }
    }
    try { $actual = & $ReadShortcut $ShortcutPath } catch { return $false }
    if ($null -eq $actual) { return $false }
    try {
        return [string]::Equals([System.IO.Path]::GetFullPath([string]$actual.TargetPath), [string]$expected.TargetPath, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$actual.Arguments -eq [string]$expected.Arguments -and
            [string]::Equals([System.IO.Path]::GetFullPath([string]$actual.WorkingDirectory), [string]$expected.WorkingDirectory, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Set-RunAtLoginEnabled {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "This user-invoked setting mutates one per-user Startup shortcut and verifies the exact result.")]
    param(
        [bool]$Enabled,
        [string]$ShortcutPath,
        [string]$LauncherPath,
        [scriptblock]$WriteShortcut,
        [scriptblock]$RemoveShortcut,
        [scriptblock]$ReadShortcut
    )
    if ([string]::IsNullOrWhiteSpace($ShortcutPath)) { $ShortcutPath = Get-RunAtLoginShortcutPath }
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) { $LauncherPath = Join-Path $script:MonitorControlRoot "MonitorControlPro.ps1" }
    $LauncherPath = [System.IO.Path]::GetFullPath($LauncherPath)
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) { throw "MonitorControl launcher not found: $LauncherPath" }
    if ($Enabled) {
        $definition = Get-RunAtLoginShortcutDefinition -LauncherPath $LauncherPath
        if ($null -eq $WriteShortcut) {
            $WriteShortcut = {
                param([string]$Path, $Definition)
                $directory = [System.IO.Path]::GetDirectoryName($Path)
                if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $null
                try {
                    $shortcut = $shell.CreateShortcut($Path)
                    $shortcut.TargetPath = [string]$Definition.TargetPath
                    $shortcut.Arguments = [string]$Definition.Arguments
                    $shortcut.WorkingDirectory = [string]$Definition.WorkingDirectory
                    $shortcut.IconLocation = [string]$Definition.IconLocation
                    $shortcut.Save()
                } finally {
                    if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
                }
            }
        }
        & $WriteShortcut $ShortcutPath $definition
        if (-not (Test-RunAtLoginShortcut -ShortcutPath $ShortcutPath -LauncherPath $LauncherPath -ReadShortcut $ReadShortcut)) {
            throw "The Startup shortcut was not created with the expected command"
        }
        return $true
    }
    if ($null -eq $RemoveShortcut) { $RemoveShortcut = { param([string]$Path) Remove-Item -LiteralPath $Path -Force } }
    if (Test-Path -LiteralPath $ShortcutPath) { & $RemoveShortcut $ShortcutPath }
    if (Test-Path -LiteralPath $ShortcutPath) { throw "The Startup shortcut could not be removed" }
    return $false
}

function Initialize-GPU {
    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        if ($gpu.Name -match "NVIDIA") {
            $script:HasNvidia = $true
            $script:NvidiaSmiPath = Find-FirstExistingPath -CandidatePaths @(
                "${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
                "${env:SystemRoot}\System32\nvidia-smi.exe"
            )
        }
        if ($gpu.Name -match "AMD|Radeon") {
            $script:HasAmd = $true
        }
    }
}

function Get-NvidiaStats {
    if (-not $script:NvidiaSmiPath) { return $null }
    try {
        $output = & $script:NvidiaSmiPath --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed,power.draw,power.limit,clocks.gr --format=csv,noheader,nounits 2>$null
        if ($output) {
            $p = $output.Split(',').Trim()
            if ($p.Count -ge 9) {
                return @{ Name = $p[0]; Temp = [int]$p[1]; Util = [int]$p[2]; MemUsed = [math]::Round([double]$p[3]/1024, 1)
                    MemTotal = [math]::Round([double]$p[4]/1024, 1); Fan = if ($p[5] -match '\d+') { [int]$p[5] } else { 0 }
                    Power = [math]::Round([double]$p[6], 0); PowerLimit = [math]::Round([double]$p[7], 0); Clock = [int]$p[8] }
            }
        }
    } catch {}
    return $null
}

function Get-AmdStats {
    $name = ""; $temp = 0; $util = 0; $engineClock = 0; $memoryClock = 0; $fan = 0; $message = ""
    if ([AmdAdlInterop]::TryGetStats([ref]$name, [ref]$temp, [ref]$util, [ref]$engineClock, [ref]$memoryClock, [ref]$fan, [ref]$message)) {
        return @{
            Name = $name; Temp = $temp; Util = $util; MemUsed = 0; MemTotal = 0; Fan = $fan
            Power = 0; PowerLimit = 0; Clock = $engineClock; MemoryClock = $memoryClock; Message = ""
        }
    }
    return @{ Name = "AMD Radeon"; Temp = 0; Util = 0; MemUsed = 0; MemTotal = 0; Fan = 0; Power = 0; PowerLimit = 0; Clock = 0; MemoryClock = 0; Message = $message }
}

function ConvertTo-HelperVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $parts = @()
    for ($group = 1; $group -le 4; $group++) {
        if (-not $match.Groups[$group].Success) { break }
        $parts += [int]$match.Groups[$group].Value
    }
    while ($parts.Count -lt 2) { $parts += 0 }
    try { return [version]($parts -join ".") } catch { return $null }
}

function Get-OptionalHelperSourceCategory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "Unknown" }
    $full = try { [System.IO.Path]::GetFullPath($Path) } catch { return "Unknown" }
    $roots = @(
        @{ Category = "ScriptDirectory"; Root = $script:MonitorControlRoot },
        @{ Category = "ProgramFiles"; Root = $env:ProgramFiles },
        @{ Category = "ProgramFiles"; Root = ${env:ProgramFiles(x86)} }
    )
    foreach ($candidate in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Root)) { continue }
        $root = try { [System.IO.Path]::GetFullPath([string]$candidate.Root).TrimEnd("\") + "\" } catch { continue }
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$candidate.Category }
    }
    foreach ($entry in @(([string]$env:PATH) -split ";")) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $root = try { [System.IO.Path]::GetFullPath($entry.Trim()).TrimEnd("\") + "\" } catch { continue }
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return "SystemPath" }
    }
    return "Other"
}

function Test-OptionalHelperVersionSupported {
    param([string]$Kind, $Version)
    if (-not $script:OptionalHelperMinimumVersions.ContainsKey($Kind)) { return $false }
    if ($null -eq $Version) { return $false }
    return ([version]$Version -ge [version]$script:OptionalHelperMinimumVersions[$Kind])
}

function Get-OptionalHelperProvenance {
    param([string]$Path, [string]$Kind)
    $record = [PSCustomObject]@{
        Kind = [string]$Kind
        Path = [string]$Path
        Exists = $false
        SourceCategory = "Unknown"
        ProductVersion = ""
        FileVersion = ""
        Version = $null
        Sha256 = ""
        Supported = $false
        Reason = ""
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $record.Reason = "No path supplied"
        return $record
    }
    try { $record.Path = [System.IO.Path]::GetFullPath($Path) } catch {
        $record.Reason = "Path could not be resolved"
        return $record
    }
    if (-not (Test-Path -LiteralPath $record.Path -PathType Leaf)) {
        $record.Reason = "File not found"
        return $record
    }
    $record.Exists = $true
    $record.SourceCategory = Get-OptionalHelperSourceCategory -Path $record.Path
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($record.Path)
        $record.ProductVersion = [string]$info.ProductVersion
        $record.FileVersion = [string]$info.FileVersion
    } catch {}
    $record.Version = ConvertTo-HelperVersion -Text $record.FileVersion
    if ($null -eq $record.Version) { $record.Version = ConvertTo-HelperVersion -Text $record.ProductVersion }
    try { $record.Sha256 = Get-FileSha256Hex -Path $record.Path } catch { $record.Sha256 = "" }
    if ($null -eq $record.Version) {
        $record.Reason = "No readable version resource; refusing to load"
        return $record
    }
    if (-not (Test-OptionalHelperVersionSupported -Kind $Kind -Version $record.Version)) {
        $record.Reason = "Version $($record.Version) is below the supported minimum $($script:OptionalHelperMinimumVersions[$Kind])"
        return $record
    }
    $record.Supported = $true
    $record.Reason = "Supported"
    return $record
}

function Format-OptionalHelperProvenance {
    param([string]$Label, $Provenance, [bool]$Enabled)
    if (-not $Enabled) { return "${Label}: disabled" }
    if ($null -eq $Provenance) { return "${Label}: enabled, no helper resolved" }
    if (-not $Provenance.Exists) { return "${Label}: enabled, not found ($($Provenance.Reason))" }
    $fileVersion = if ($Provenance.FileVersion) { $Provenance.FileVersion } else { "unknown" }
    $productVersion = if ($Provenance.ProductVersion) { $Provenance.ProductVersion } else { "unknown" }
    $hash = if ($Provenance.Sha256) { $Provenance.Sha256 } else { "unavailable" }
    $lines = @(
        "${Label}: $($Provenance.Reason)",
        "  Path: $($Provenance.Path)",
        "  Source: $($Provenance.SourceCategory)",
        "  Version: $fileVersion (product $productVersion)",
        "  SHA-256: $hash"
    )
    return ($lines -join "`n")
}

function Get-OptionalHelperStatusText {
    return (@(
        (Format-OptionalHelperProvenance -Label "CPU temperature library" -Provenance $script:CpuMonitorProvenance -Enabled $script:CpuMonitorEnabled),
        (Format-OptionalHelperProvenance -Label "PresentMon" -Provenance $script:PresentMonProvenance -Enabled $script:PresentMonEnabled)
    ) -join "`n`n")
}

function Set-DisplayStateRestoreValue {
    param([string]$IdentityKey, [int]$BrightnessPercent, [string]$UpdatedAt = "")
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    if ($BrightnessPercent -lt 0 -or $BrightnessPercent -gt 100) { return $false }
    if ([string]::IsNullOrWhiteSpace($UpdatedAt)) { $UpdatedAt = (Get-Date).ToString("o") }
    $script:DisplayStateRestoreValues[$IdentityKey] = [PSCustomObject]@{
        Brightness = [int]$BrightnessPercent
        UpdatedAt = [string]$UpdatedAt
    }
    return $true
}

function Get-DisplayStateRestorePlan {
    param([object[]]$Monitors, [hashtable]$Remembered, [bool]$Enabled)
    $plan = [PSCustomObject]@{ Operations = @(); Skipped = @() }
    if (-not $Enabled) { return $plan }
    $operations = @()
    $skipped = @()
    foreach ($monitor in @($Monitors)) {
        if ($null -eq $monitor) { continue }
        $identityKey = [string]$monitor.IdentityKey
        $label = if ($monitor.PSObject.Properties["DisplayLabel"] -and $monitor.DisplayLabel) { [string]$monitor.DisplayLabel } else { [string]$monitor.Name }
        if ([string]::IsNullOrWhiteSpace($identityKey)) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "no stable identity" }
            continue
        }
        if (-not $Remembered.ContainsKey($identityKey)) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "nothing remembered" }
            continue
        }
        if ([int64]$monitor.Handle.ToInt64() -eq 0) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "no DDC/CI handle" }
            continue
        }
        $percent = [int]$Remembered[$identityKey].Brightness
        if (-not (Test-MonitorSupportsVcp -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "brightness not reported" }
            continue
        }
        $raw = [uint32](ConvertTo-VcpRawValue -Percent ([double]$percent) -Maximum (Get-VcpMaximumForMonitor -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)))
        $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS) -Value $raw
    }
    $plan.Operations = @($operations)
    $plan.Skipped = @($skipped)
    return $plan
}

function Invoke-DisplayStateRestore {
    param([int]$Generation = $script:DisplayRecoveryGeneration, [string]$Reason = "startup")
    if (-not $script:DisplayStateRestoreEnabled) { return $false }
    # One restore per recovery generation, so a burst of display events cannot replay writes.
    if ($script:DisplayStateRestoreGeneration -eq $Generation) { return $false }
    $script:DisplayStateRestoreGeneration = $Generation
    $plan = Get-DisplayStateRestorePlan -Monitors @($script:PhysicalMonitors) -Remembered $script:DisplayStateRestoreValues -Enabled $true
    if (@($plan.Operations).Count -eq 0) { return $false }
    $applied = @($plan.Operations).Count
    $completionReason = $Reason
    $completion = {
        param($result)
        if ([bool]$result.Success) {
            Update-Status "Restored brightness on $applied display(s) after $completionReason"
        } else {
            Update-Status "Brightness restore after $completionReason ended $($result.Outcome); restore: $($result.Rollback)"
        }
    }.GetNewClosure()
    $started = Start-VerifiedVcpTransactionWorker -Operations @($plan.Operations) -ActionLabel "Restore brightness after $Reason" -CompletionAction $completion
    return [bool]$started
}

function Get-PresentMonCandidatePaths {
    # Well-known install locations are probed before PATH: a PATH-resolved executable is the
    # easiest thing for another process to place ahead of the real one.
    $paths = @(
        (Join-Path $script:MonitorControlRoot "PresentMon.exe"),
        (Join-Path $script:MonitorControlRoot "PresentMon64.exe"),
        "${env:ProgramFiles}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles}\Intel\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\Intel\PresentMon\PresentMon.exe"
    )
    foreach ($command in @(Get-Command PresentMon.exe, PresentMon64.exe -ErrorAction SilentlyContinue)) {
        if ($command -and $command.Source) { $paths += [string]$command.Source }
    }
    return $paths
}

function Get-CpuTemperature {
    if (-not $script:HardwareMonitorComputer) { return $null }
    try {
        $temperatures = @()
        foreach ($hardware in $script:HardwareMonitorComputer.Hardware) {
            if ($hardware.HardwareType.ToString() -ne "Cpu") { continue }
            $hardware.Update()
            foreach ($subHardware in $hardware.SubHardware) { $subHardware.Update() }
            foreach ($sensor in @($hardware.Sensors) + @($hardware.SubHardware | ForEach-Object { $_.Sensors })) {
                if ($sensor -and $sensor.SensorType.ToString() -eq "Temperature" -and $null -ne $sensor.Value) {
                    $temperatures += [double]$sensor.Value
                }
            }
        }
        if ($temperatures.Count -gt 0) { return [math]::Round(($temperatures | Measure-Object -Maximum).Maximum, 0) }
    } catch {}
    return $null
}

function Get-CpuMonitorCandidatePaths {
    return @(
        (Join-Path $script:MonitorControlRoot "LibreHardwareMonitorLib.dll"),
        (Join-Path $script:MonitorControlRoot "OpenHardwareMonitorLib.dll"),
        "${env:ProgramFiles}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll"
    )
}

function Stop-CpuMonitor {
    if ($script:HardwareMonitorComputer) {
        try { $script:HardwareMonitorComputer.Close() } catch {}
    }
    $script:HardwareMonitorComputer = $null
    $script:HasCpuTempMonitor = $false
    $script:HardwareMonitorKind = ""
    $script:CpuMonitorProvenance = $null
}

function Initialize-CpuMonitor {
    if (-not $script:CpuMonitorEnabled) { return }
    if ($script:HardwareMonitorComputer) { return }
    $rejected = $null
    foreach ($candidate in (Get-CpuMonitorCandidatePaths)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $provenance = Get-OptionalHelperProvenance -Path $candidate -Kind "CpuMonitor"
        if (-not $provenance.Supported) {
            if ($null -eq $rejected) { $rejected = $provenance }
            continue
        }
        $path = $provenance.Path
        try {
            [System.Reflection.Assembly]::LoadFrom($path) | Out-Null
            $computerType = if ($path -like "*LibreHardwareMonitor*") {
                [Type]::GetType("LibreHardwareMonitor.Hardware.Computer, LibreHardwareMonitorLib", $false)
            } else {
                [Type]::GetType("OpenHardwareMonitor.Hardware.Computer, OpenHardwareMonitorLib", $false)
            }
            if (-not $computerType) { continue }
            $computer = [Activator]::CreateInstance($computerType)
            $computer.IsCpuEnabled = $true
            $computer.Open()
            $script:HardwareMonitorComputer = $computer
            $script:HardwareMonitorKind = if ($path -like "*LibreHardwareMonitor*") { "LibreHardwareMonitor" } else { "OpenHardwareMonitor" }
            $script:HasCpuTempMonitor = $true
            $script:CpuMonitorProvenance = $provenance
            return
        } catch {}
    }
    $script:CpuMonitorProvenance = $rejected
}

# --- USB device triggers for input switching ---------------------------------------------
# A USB switch box moves one keyboard and mouse between two machines; the monitors do not
# follow, because they are switched on the panel rather than on the box. Windows already
# broadcasts the arrival and removal of the device interface, so a rule that maps that
# broadcast to a per-monitor input plan is the whole feature. Everything here is pure: the
# caller supplies the monitor list, the last-known input values, and the clock.

# Accepts the three shapes people actually have to hand: what Device Manager shows
# (VID_046D&PID_C52B), what lsusb-style tools print (046d:c52b), and a full interface path.
function ConvertTo-UsbDeviceId {
    param([string]$Text)
    $trimmed = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }
    if ($trimmed -match '(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
        return ("VID_{0}&PID_{1}" -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    if ($trimmed -match '^(?i)([0-9A-F]{4})[:_-]([0-9A-F]{4})$') {
        return ("VID_{0}&PID_{1}" -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    return ""
}

function Get-UsbDeviceIdFromInterfacePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ($Path -notmatch '(?i)(^|[\\#])USB[\\#]') { return "" }
    return (ConvertTo-UsbDeviceId -Text $Path)
}

function Get-UsbInputRuleTriggerName {
    param([string]$Trigger)
    if ([string]$Trigger -eq "Removal") { return "Removal" }
    return "Arrival"
}

function ConvertTo-UsbInputRuleTargets {
    param($Targets)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $result = @()
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $identityKey = [string]$target.IdentityKey
        if ([string]::IsNullOrWhiteSpace($identityKey) -or $identityKey.Length -gt 512) { continue }
        if (-not $seen.Add($identityKey)) { continue }
        $parsedValue = 0
        if (-not [int]::TryParse([string]$target.InputValue, [ref]$parsedValue)) { continue }
        if ($parsedValue -lt 0 -or $parsedValue -gt 255) { continue }
        $result += [PSCustomObject]@{ IdentityKey = $identityKey; InputValue = [int]$parsedValue }
        if ($result.Count -ge 16) { break }
    }
    return @($result)
}

function ConvertTo-UsbInputRules {
    param($Records)
    $result = @()
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $deviceId = ConvertTo-UsbDeviceId -Text ([string]$record.DeviceId)
        if ([string]::IsNullOrWhiteSpace($deviceId)) { continue }
        $targets = @(ConvertTo-UsbInputRuleTargets -Targets $record.Targets)
        if ($targets.Count -eq 0) { continue }
        $suppression = 10
        $parsedSuppression = 0
        if ($record.PSObject.Properties.Name -contains "SuppressionSeconds" -and [int]::TryParse([string]$record.SuppressionSeconds, [ref]$parsedSuppression)) {
            $suppression = [Math]::Max(0, [Math]::Min(3600, $parsedSuppression))
        }
        $id = [string]$record.Id
        if ([string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 64) { $id = [guid]::NewGuid().ToString("N") }
        $result += [PSCustomObject]@{
            Id = $id
            Enabled = if ($record.PSObject.Properties.Name -contains "Enabled") { [bool]$record.Enabled } else { $true }
            DeviceId = $deviceId
            Trigger = Get-UsbInputRuleTriggerName -Trigger ([string]$record.Trigger)
            SuppressionSeconds = [int]$suppression
            AllowRiskyVcp = if ($record.PSObject.Properties.Name -contains "AllowRiskyVcp") { [bool]$record.AllowRiskyVcp } else { $false }
            Targets = @($targets)
        }
        if ($result.Count -ge 32) { break }
    }
    return @($result)
}

function New-UsbInputRuleObject {
    param([string]$DeviceId, [string]$Trigger, [int]$SuppressionSeconds, [bool]$AllowRiskyVcp, $Targets)
    return @(ConvertTo-UsbInputRules -Records @([PSCustomObject]@{
        Id = [guid]::NewGuid().ToString("N")
        Enabled = $true
        DeviceId = $DeviceId
        Trigger = $Trigger
        SuppressionSeconds = $SuppressionSeconds
        AllowRiskyVcp = $AllowRiskyVcp
        Targets = $Targets
    }))
}

function Test-UsbInputRuleMatches {
    param($Rule, [string]$DeviceId, [string]$Trigger)
    if ($null -eq $Rule -or -not [bool]$Rule.Enabled) { return $false }
    if ([string]::IsNullOrWhiteSpace($DeviceId)) { return $false }
    if ([string]$Rule.DeviceId -ne (ConvertTo-UsbDeviceId -Text $DeviceId)) { return $false }
    return ([string]$Rule.Trigger -eq (Get-UsbInputRuleTriggerName -Trigger $Trigger))
}

# The documented failure of the leading tool: a USB hub built into a monitor drops and
# re-enumerates its devices when the panel sleeps, so the same arrival fires again seconds
# later and switches a display the user has just moved away from. The window is per rule and
# starts when the rule fires.
function Test-UsbInputRuleSuppressed {
    param($Rule, $LastFiredUtc, [datetime]$NowUtc)
    if ($null -eq $Rule -or $null -eq $LastFiredUtc) { return $false }
    $seconds = [int]$Rule.SuppressionSeconds
    if ($seconds -le 0) { return $false }
    return ((($NowUtc - [datetime]$LastFiredUtc).TotalSeconds) -lt $seconds)
}

# Deselecting a DisplayPort input drops the link, and a monitor with no link cannot be sent the
# DDC command that would bring it back - the switch is one way until someone uses the panel's
# own buttons. Name it at configuration time rather than after the display goes dark.
function Test-InputValueIsDisplayPort {
    param([int]$Value)
    return ($Value -eq 0x0F -or $Value -eq 0x10)
}

function Get-UsbInputSwitchPlan {
    param($Rule, $Monitors, $CurrentInputs, [datetime]$NowUtc, $LastFiredUtc)
    if ($null -eq $Rule) { return [PSCustomObject]@{ Suppressed = $false; Entries = @() } }
    if (Test-UsbInputRuleSuppressed -Rule $Rule -LastFiredUtc $LastFiredUtc -NowUtc $NowUtc) {
        return [PSCustomObject]@{ Suppressed = $true; Entries = @() }
    }
    $entries = @()
    foreach ($target in @($Rule.Targets)) {
        $identityKey = [string]$target.IdentityKey
        $matched = @($Monitors | Where-Object {
            $null -ne $_ -and ([string]$_.IdentityKey -eq $identityKey -or
            ($_.PSObject.Properties.Name -contains "IdentityAliases" -and @($_.IdentityAliases) -contains $identityKey))
        } | Select-Object -First 1)
        if ($matched.Count -eq 0) {
            $entries += [PSCustomObject]@{ IdentityKey = $identityKey; MonitorName = ""; InputValue = [int]$target.InputValue; WriteValue = [int]$target.InputValue; Action = "MonitorMissing" }
            continue
        }
        $monitor = $matched[0]
        $singleByte = Test-MonitorInputSourceSingleByte -Monitor $monitor
        $action = "Switch"
        if (-not [bool]$Rule.AllowRiskyVcp) {
            $action = "NoRuleConsent"
        } elseif (-not (Test-VcpWriteEnabledForMonitor -Monitor $monitor)) {
            $action = "NotUnlocked"
        } else {
            $current = $null
            if ($null -ne $CurrentInputs -and $CurrentInputs.Contains($identityKey)) { $current = $CurrentInputs[$identityKey] }
            if ($null -ne $current -and
                (Resolve-InputSourceReadValue -Value ([int]$current) -SingleByte $singleByte) -eq (Resolve-InputSourceReadValue -Value ([int]$target.InputValue) -SingleByte $singleByte)) {
                $action = "AlreadyOnTarget"
            }
        }
        $entries += [PSCustomObject]@{
            IdentityKey = [string]$monitor.IdentityKey
            MonitorName = [string]$monitor.Name
            InputValue = [int]$target.InputValue
            WriteValue = [int](Resolve-InputSourceWriteValue -Value ([int]$target.InputValue) -SingleByte $singleByte)
            Action = $action
        }
    }
    return [PSCustomObject]@{ Suppressed = $false; Entries = @($entries) }
}

function Get-UsbInputRuleDescription {
    param($Rule)
    if ($null -eq $Rule) { return "" }
    $targetText = (@($Rule.Targets) | ForEach-Object { "{0} -> 0x{1:X2}" -f [string]$_.IdentityKey, [int]$_.InputValue }) -join ", "
    $state = if ([bool]$Rule.Enabled) { "on" } else { "off" }
    $consent = if ([bool]$Rule.AllowRiskyVcp) { "risky writes allowed" } else { "no rule consent" }
    return "$([string]$Rule.DeviceId) $([string]$Rule.Trigger) [$state, $([int]$Rule.SuppressionSeconds)s suppression, $consent]: $targetText"
}

# --- Per-monitor, video-aware idle dimming ------------------------------------------------
# System-wide idle is the only signal `GetLastInputInfo` gives, and it is wrong twice over on a
# multi-display desk: it dims the display the user is watching a film on, and it cannot dim the
# unused display while the user works on another. The two extra modes ask *where* the user is,
# and the display-required execution state answers *whether they are watching something*.

function Get-IdleDimModeName {
    param([string]$Mode)
    if ([string]$Mode -eq "Cursor") { return "Cursor" }
    if ([string]$Mode -eq "ForegroundWindow") { return "ForegroundWindow" }
    return "System"
}

# In System mode every monitor shares one verdict, which is exactly the behaviour that shipped
# before per-monitor idle existed. Cursor and ForegroundWindow spare the monitor the user is on
# and dim the rest; when the active monitor cannot be resolved they fall back to sparing nothing
# rather than dimming everything, because a wrong dim is more disruptive than a missed one.
function Test-IdleDimMonitorIsActive {
    param($Monitor, [string]$Mode, $ActiveMonitorHandle)
    if ((Get-IdleDimModeName -Mode $Mode) -eq "System") { return $false }
    if ($null -eq $Monitor -or $null -eq $ActiveMonitorHandle) { return $true }
    if ([IntPtr]$ActiveMonitorHandle -eq [IntPtr]::Zero) { return $true }
    if ($null -eq $Monitor.PSObject.Properties["HMonitor"]) { return $true }
    return ([IntPtr]$Monitor.HMonitor -eq [IntPtr]$ActiveMonitorHandle)
}

function Get-IdleDimMonitorDecisions {
    param(
        $Monitors,
        [string]$Mode,
        [int]$IdleSeconds,
        [int]$ThresholdSeconds,
        $ActiveMonitorHandle,
        [bool]$DisplayRequired,
        [bool]$RestoreOnActivity,
        $ActiveStates
    )
    $modeName = Get-IdleDimModeName -Mode $Mode
    $decisions = @()
    foreach ($monitor in @($Monitors | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IdentityKey) })) {
        $identityKey = [string]$monitor.IdentityKey
        $state = $null
        if ($null -ne $ActiveStates -and $ActiveStates.Contains($identityKey)) { $state = $ActiveStates[$identityKey] }
        $isDimmed = $null -ne $state
        $isActiveMonitor = Test-IdleDimMonitorIsActive -Monitor $monitor -Mode $modeName -ActiveMonitorHandle $ActiveMonitorHandle
        # An inhibitor suppresses *entering* the dim, never leaving it. A film starting while a
        # display is already dimmed should restore it, not strand it dark.
        $shouldDim = $IdleSeconds -ge $ThresholdSeconds -and -not $isActiveMonitor -and -not $DisplayRequired
        $action = "None"
        $reason = ""
        if (-not $isDimmed -and $shouldDim) {
            $action = "Dim"
        } elseif ($isDimmed -and -not $shouldDim) {
            $action = if ($RestoreOnActivity) { "Restore" } else { "Clear" }
            $reason = if ($DisplayRequired) {
                "a display-required inhibitor is active"
            } elseif ($isActiveMonitor) {
                "the user is on this display"
            } else {
                "activity resumed"
            }
        } elseif (-not $isDimmed -and $IdleSeconds -ge $ThresholdSeconds) {
            $reason = if ($DisplayRequired) { "a display-required inhibitor is active" } else { "the user is on this display" }
        }
        $decisions += [PSCustomObject]@{
            IdentityKey = $identityKey
            MonitorName = [string]$monitor.Name
            Monitor = $monitor
            IsActiveMonitor = [bool]$isActiveMonitor
            IsDimmed = [bool]$isDimmed
            PreviousBrightness = if ($isDimmed) { [int]$state.PreviousBrightness } else { $null }
            Action = $action
            Reason = $reason
        }
    }
    return @($decisions)
}
