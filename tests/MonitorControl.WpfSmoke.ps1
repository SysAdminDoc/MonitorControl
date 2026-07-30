param(
    [int]$LaunchTimeoutSeconds = 45,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appPath = Join-Path $repoRoot "MonitorControlPro.ps1"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "The WPF smoke test must run in Windows PowerShell 5.1."
}
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) { throw "Application entry point not found: $appPath" }
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw "Windows PowerShell not found: $windowsPowerShell" }

function Get-DirectorySnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return "<missing>" }
    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($root.Length).TrimStart("\")
        if ($item.PSIsContainer) {
            $entries.Add("D|$relative")
            continue
        }
        $stream = $null
        $sha = $null
        try {
            $stream = New-Object System.IO.FileStream(
                $item.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            )
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hash = (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
            $entries.Add("F|$relative|$($item.Length)|$hash")
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($sha) { $sha.Dispose() }
        }
    }
    return ($entries -join "`n")
}

function Remove-ValidatedSmokeDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\") + "\"
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notlike "MonitorControl-WpfSmoke-*") {
        throw "Refusing to remove an unvalidated smoke-test directory: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Get-TabByName {
    param($Root, [string]$Name)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    foreach ($element in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        if ($element.Current.Name -eq $Name) { return $element }
    }
    return $null
}

$realAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
$realProfileRoot = Join-Path $realAppData "MonitorControlPro"
$realProfileBefore = Get-DirectorySnapshot -Path $realProfileRoot
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-WpfSmoke-$([guid]::NewGuid().ToString('N'))"
$sandboxAppData = Join-Path $smokeRoot "AppData\Roaming"
$sandboxLocalAppData = Join-Path $smokeRoot "AppData\Local"
$sandboxProfileRoot = Join-Path $sandboxAppData "MonitorControlPro"
$process = $null
$navigated = New-Object System.Collections.Generic.List[string]
$exitCode = $null

try {
    New-Item -ItemType Directory -Path $sandboxProfileRoot, $sandboxLocalAppData -Force | Out-Null
    $capabilitySettings = [ordered]@{
        SchemaVersion = 1
        ConsentRecorded = $true
        DiscoveryEnabled = $false
        MaximumCompatibility = $true
        ExcludedIdentityKeys = @()
        LastIncidentIdentityKey = ""
        LastIncidentAt = ""
    }
    $capabilityJson = ($capabilitySettings | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        (Join-Path $sandboxProfileRoot "capabilities-safety.json"),
        $capabilityJson,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $windowsPowerShell
    $escapedAppPath = $appPath.Replace('"', '\"')
    $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$escapedAppPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.EnvironmentVariables["APPDATA"] = $sandboxAppData
    $startInfo.EnvironmentVariables["LOCALAPPDATA"] = $sandboxLocalAppData
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Windows PowerShell did not start." }

    $deadline = [DateTime]::UtcNow.AddSeconds($LaunchTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "The WPF process exited during launch with code $($process.ExitCode)." }
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw "The WPF window did not appear within $LaunchTimeoutSeconds seconds." }

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    if ($null -eq $root -or $root.Current.Name -notlike "MonitorControl Pro*") {
        throw "The launched window does not expose the expected MonitorControl Pro UI Automation root."
    }

    foreach ($name in @("Display", "Monitor", "VCP Explorer", "Profiles", "Automation", "System")) {
        $tab = Get-TabByName -Root $root -Name $name
        if ($null -eq $tab) { throw "Required navigation destination '$name' was not exposed through UI Automation." }
        $patternObject = $null
        if (-not $tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject)) {
            throw "Navigation destination '$name' does not expose SelectionItemPattern."
        }
        $selection = [System.Windows.Automation.SelectionItemPattern]$patternObject
        $selection.Select()
        Start-Sleep -Milliseconds 125
        if (-not $selection.Current.IsSelected) { throw "Navigation destination '$name' did not become selected." }
        $navigated.Add($name)
    }

    $hardwareTab = Get-TabByName -Root $root -Name "Hardware"
    if ($null -ne $hardwareTab -and -not $hardwareTab.Current.IsOffscreen) {
        $patternObject = $null
        if ($hardwareTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject)) {
            ([System.Windows.Automation.SelectionItemPattern]$patternObject).Select()
            Start-Sleep -Milliseconds 125
            if (-not ([System.Windows.Automation.SelectionItemPattern]$patternObject).Current.IsSelected) {
                throw "The available Hardware destination did not become selected."
            }
            $navigated.Add("Hardware")
        }
    }

    if (-not $process.CloseMainWindow()) { throw "The WPF window rejected a normal close request." }
    if (-not $process.WaitForExit(15000)) { throw "The WPF process did not exit after its window closed." }
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) { throw "The WPF process exited with code $exitCode." }

    $realProfileAfter = Get-DirectorySnapshot -Path $realProfileRoot
    if ($realProfileBefore -cne $realProfileAfter) {
        throw "The WPF smoke test changed the real user profile at $realProfileRoot."
    }
} finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
        } catch {}
        $process.Dispose()
    }
    Remove-ValidatedSmokeDirectory -Path $smokeRoot
}

if (-not $Quiet) {
    Write-Host "WPF smoke passed: navigated $($navigated -join ', '); clean exit $exitCode; real profile unchanged."
}

