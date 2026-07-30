param(
    [switch]$Quiet,
    [version]$PesterVersion = [version]"5.8.0"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$testsPath = Join-Path $repoRoot "tests"

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -eq $PesterVersion } |
    Select-Object -First 1

if (-not $pester) {
    throw "Pester $PesterVersion is required. Install with: Install-Module Pester -RequiredVersion $PesterVersion -Scope CurrentUser"
}

Import-Module $pester.Path -Force
$output = if ($Quiet) { "Normal" } else { "Detailed" }
$result = Invoke-Pester -Path $testsPath -Output $output -PassThru

if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) Pester test(s) failed."
}
