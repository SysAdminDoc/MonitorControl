param(
    [version]$PesterVersion = [version]"5.9.0",
    [version]$PSScriptAnalyzerVersion = [version]"1.25.0"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$privateScanHost = [string]$env:MONITORCONTROL_PRIVATE_RUNNER

if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "Verification must run in Windows PowerShell 5.1."
}
if ([string]::IsNullOrWhiteSpace($privateScanHost) -or -not (Test-Path -LiteralPath $privateScanHost -PathType Leaf)) {
    throw "Full WPF verification must be launched through tools\MonitorControl.MarketingCapture on a private Windows desktop."
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

# Windows PowerShell 5.1 reads a BOM-less file as CP1252, so a single byte above 0x7F -
# an em dash, a curly quote - decodes into a character that can terminate a string early
# and produce parse errors pointing at unrelated lines. Refuse to ship one.
$asciiExtensions = @(".ps1", ".psm1", ".psd1")
$asciiTargets = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $asciiExtensions -contains $_.Extension -and
        $_.FullName -notlike "*\dist\*" -and
        $_.FullName -notlike "*\.git\*"
    })
$nonAsciiFiles = @()
foreach ($target in $asciiTargets) {
    $offending = @([System.IO.File]::ReadAllBytes($target.FullName) | Where-Object { $_ -gt 127 })
    if ($offending.Count -gt 0) {
        $nonAsciiFiles += "{0} ({1} byte(s) above 0x7F)" -f $target.FullName.Substring($repoRoot.Length + 1), $offending.Count
    }
}
if ($nonAsciiFiles.Count -gt 0) {
    throw "PowerShell sources must be pure ASCII:`n$($nonAsciiFiles -join "`n")"
}
Write-Host "ASCII check passed across $($asciiTargets.Count) PowerShell file(s)."

Import-RequiredModuleVersion -Name "PSScriptAnalyzer" -Version $PSScriptAnalyzerVersion
$analysisSettings = Join-Path $repoRoot "PSScriptAnalyzerSettings.psd1"
if (-not (Test-Path -LiteralPath $analysisSettings -PathType Leaf)) {
    throw "Analyzer settings not found: $analysisSettings"
}
$analysisPaths = @(
    (Join-Path $repoRoot "MonitorControlPro.ps1")
    (Join-Path $repoRoot "src")
    (Join-Path $repoRoot "tools")
    (Join-Path $repoRoot "tests")
)
$analysisResults = @()
foreach ($path in $analysisPaths) {
    $analysisResults += Invoke-ScriptAnalyzer -Path $path -Recurse -Settings $analysisSettings
}
if ($analysisResults.Count -gt 0) {
    $details = $analysisResults |
        Select-Object RuleName, Message, ScriptName, Line, Column |
        Format-Table -AutoSize |
        Out-String
    throw "PSScriptAnalyzer reported $($analysisResults.Count) finding(s) at or above Warning:`n$details"
}
Write-Host "Static analysis passed with PSScriptAnalyzer $PSScriptAnalyzerVersion (errors and warnings enforced)."

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
& $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tools\run-tests.ps1") -Quiet -PesterVersion $PesterVersion.ToString()
if ($LASTEXITCODE -ne 0) { throw "The deterministic Pester lane failed with exit code $LASTEXITCODE." }
$verificationRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-Verify-$([guid]::NewGuid().ToString('N'))"
$accessibilityArtifactRoot = Join-Path $repoRoot "dist\accessibility"
try {
    New-Item -ItemType Directory -Path $verificationRoot -Force | Out-Null
    if (Test-Path -LiteralPath $accessibilityArtifactRoot) {
        $artifactItem = Get-Item -LiteralPath $accessibilityArtifactRoot -Force
        if (($artifactItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Accessibility artifact output cannot be a reparse point: $accessibilityArtifactRoot"
        }
        Remove-Item -LiteralPath $accessibilityArtifactRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $accessibilityArtifactRoot -Force | Out-Null
    $axePackage = & (Join-Path $repoRoot "tools\install-axe-windows.ps1") -OutputRoot (Join-Path $verificationRoot "axe")
    if ($null -eq $axePackage -or -not (Test-Path -LiteralPath $axePackage.Path -PathType Leaf)) {
        throw "The pinned Axe.Windows CLI package did not produce an executable."
    }
    $standardAxeOutput = Join-Path $accessibilityArtifactRoot "standard"
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tests\MonitorControl.WpfSmoke.ps1") `
        -Quiet -AxeWindowsCliPath $axePackage.Path -AxeScanHostPath $privateScanHost -AxeOutputDirectory $standardAxeOutput -AxeScanId "standard"
    if ($LASTEXITCODE -ne 0) { throw "The standard WPF smoke or Axe.Windows accessibility lane failed with exit code $LASTEXITCODE." }
    $highContrastAxeOutput = Join-Path $accessibilityArtifactRoot "high-contrast-200"
    & $windowsPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tests\MonitorControl.WpfSmoke.ps1") `
        -Quiet -AppTheme HighContrast -TextScalePercent 200 -UiCulture qps-ploc -ResizeToMinimum -ExerciseValidationAlert `
        -AxeWindowsCliPath $axePackage.Path -AxeScanHostPath $privateScanHost -AxeOutputDirectory $highContrastAxeOutput -AxeScanId "high-contrast-200"
    if ($LASTEXITCODE -ne 0) { throw "The high-contrast, pseudo-localized, and Axe.Windows accessibility lane failed with exit code $LASTEXITCODE." }
    Write-Host "Axe.Windows 2.4.2 structured accessibility reports retained under $accessibilityArtifactRoot."

    $release = & (Join-Path $repoRoot "tools\build-release.ps1") -OutputRoot (Join-Path $verificationRoot "dist")
    if ($null -eq $release -or -not (Test-Path -LiteralPath $release.ZipPath -PathType Leaf)) {
        throw "The unsigned release builder did not produce its declared ZIP."
    }
    if ([string]::IsNullOrWhiteSpace([string]$release.Sha256) -or $release.Signing -notlike "Unsigned:*") {
        throw "The release result did not preserve the checksum and explicit unsigned contract."
    }
    $integrity = & (Join-Path $repoRoot "tools\verify-release.ps1") `
        -ZipPath $release.ZipPath `
        -ManifestPath $release.ManifestPath `
        -SbomPath $release.SbomPath `
        -Sha256Path $release.Sha256Path
    if ($null -eq $integrity -or [string]$integrity.Sha256 -ne [string]$release.Sha256) {
        throw "The release integrity verifier did not validate the generated artifact."
    }
} finally {
    Remove-ValidatedVerificationDirectory -Path $verificationRoot
}
Write-Host "Verification passed: Pester $PesterVersion, standard and pseudo-localized accessible WPF smokes, Axe.Windows 2.4.2, and unsigned release build."
