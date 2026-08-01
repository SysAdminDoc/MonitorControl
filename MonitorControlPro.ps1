<#
.SYNOPSIS
    MonitorControl Pro v3.37.0 - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version: 3.37.0 - Named causes for missing DDC control and per-monitor DDC timing
#>

param(
    [switch]$StartMinimized,
    [string]$LoadProfile,
    [ValidateSet("System", "Dark", "HighContrast")]
    [string]$Theme = "System",
    [ValidateRange(0, 200)]
    [int]$TextScalePercent = 0,
    [string]$RenderDirectory = ""
)

$script:MonitorControlRoot = $PSScriptRoot
$sourceManifestPath = Join-Path $script:MonitorControlRoot "src\MonitorControl.sources"
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    throw "MonitorControl source manifest is missing: $sourceManifestPath"
}
$sourceFiles = @(Get-Content -LiteralPath $sourceManifestPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
foreach ($sourceFile in $sourceFiles) {
    $sourcePath = Join-Path $script:MonitorControlRoot $sourceFile
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "MonitorControl source component is missing: $sourcePath"
    }
    $sourceBlock = [scriptblock]::Create([System.IO.File]::ReadAllText($sourcePath))
    . $sourceBlock
}
