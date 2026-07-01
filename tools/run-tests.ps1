param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$testsPath = Join-Path $repoRoot "tests"

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]"5.0.0" } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    throw "Pester 5.0 or newer is required. Install with: Install-Module Pester -Scope CurrentUser"
}

Import-Module $pester.Path -Force
$output = if ($Quiet) { "Normal" } else { "Detailed" }
$result = Invoke-Pester -Path $testsPath -Output $output -PassThru

if ($result.FailedCount -gt 0) {
    exit 1
}
