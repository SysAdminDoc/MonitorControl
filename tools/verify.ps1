param(
    [version]$PesterVersion = [version]"5.8.0",
    [version]$PSScriptAnalyzerVersion = [version]"1.25.0"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "Verification must run in Windows PowerShell 5.1."
}

function Import-RequiredModuleVersion {
    param([string]$Name, [version]$Version)
    $module = Get-Module -ListAvailable -Name $Name |
        Where-Object { $_.Version -eq $Version } |
        Select-Object -First 1
    if (-not $module) {
        throw "$Name $Version is required. Install with: Install-Module $Name -RequiredVersion $Version -Scope CurrentUser"
    }
    Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue
    Import-Module $module.Path -Force
}

function Remove-ValidatedVerificationDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\") + "\"
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notlike "MonitorControl-Verify-*") {
        throw "Refusing to remove an unvalidated verification directory: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

Import-RequiredModuleVersion -Name "PSScriptAnalyzer" -Version $PSScriptAnalyzerVersion
$analysisPaths = @(
    (Join-Path $repoRoot "MonitorControlPro.ps1")
    (Join-Path $repoRoot "tools")
    (Join-Path $repoRoot "tests")
)
$analysisResults = @()
foreach ($path in $analysisPaths) {
    $analysisResults += Invoke-ScriptAnalyzer -Path $path -Recurse
}
$analysisErrors = @($analysisResults | Where-Object Severity -eq "Error")
if ($analysisErrors.Count -gt 0) {
    $details = $analysisErrors |
        Select-Object RuleName, Message, ScriptName, Line, Column |
        Format-Table -AutoSize |
        Out-String
    throw "PSScriptAnalyzer reported $($analysisErrors.Count) error(s):`n$details"
}
Write-Host "Static analysis passed with PSScriptAnalyzer $PSScriptAnalyzerVersion ($($analysisResults.Count) advisory findings)."

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
& $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tools\run-tests.ps1") -Quiet -PesterVersion $PesterVersion.ToString()
if ($LASTEXITCODE -ne 0) { throw "The deterministic Pester lane failed with exit code $LASTEXITCODE." }
& $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tests\MonitorControl.WpfSmoke.ps1") -Quiet
if ($LASTEXITCODE -ne 0) { throw "The WPF smoke lane failed with exit code $LASTEXITCODE." }

$verificationRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-Verify-$([guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $verificationRoot -Force | Out-Null
    $release = & (Join-Path $repoRoot "tools\build-release.ps1") -OutputRoot (Join-Path $verificationRoot "dist")
    if ($null -eq $release -or -not (Test-Path -LiteralPath $release.ZipPath -PathType Leaf)) {
        throw "The unsigned release builder did not produce its declared ZIP."
    }
    if ([string]::IsNullOrWhiteSpace([string]$release.Sha256) -or $release.Signing -notlike "Unsigned:*") {
        throw "The release result did not preserve the checksum and explicit unsigned contract."
    }
} finally {
    Remove-ValidatedVerificationDirectory -Path $verificationRoot
}

Write-Host "Verification passed: Pester $PesterVersion, WPF smoke, and unsigned release build."
