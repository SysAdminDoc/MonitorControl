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

function Initialize-GPU {
    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        if ($gpu.Name -match "NVIDIA") {
            $script:HasNvidia = $true
            @("${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "${env:SystemRoot}\System32\nvidia-smi.exe") | ForEach-Object { if (Test-Path $_) { $script:NvidiaSmiPath = $_; return } }
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
