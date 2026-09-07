<#
.SYNOPSIS
    MonitorControl Pro - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version metadata is loaded by the development launcher.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter(Position = 1)]
    [string]$Argument = "",
    [string]$Monitor = "",
    [string]$Vcp = "",
    [string]$Value = "",
    [long]$Delta = [long]::MinValue,
    [string]$Cycle = "",
    [switch]$IfNeeded,
    [switch]$Json,
    [switch]$AllowRisky,
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,
    [switch]$CliWorker,
    [switch]$StartMinimized,
    [string]$LoadProfile,
    [ValidateSet("System", "Dark", "HighContrast")]
    [string]$Theme = "System",
    [ValidateRange(0, 200)]
    [int]$TextScalePercent = 0,
    [string]$Culture = "",
    [string]$RenderDirectory = "",
    [switch]$MarketingCapture
)

$script:MonitorControlRoot = $PSScriptRoot
$script:MonitorControlEntryPath = $PSCommandPath
$metadataPath = Join-Path $script:MonitorControlRoot "src\MonitorControl.Metadata.psd1"
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "MonitorControl metadata is missing: $metadataPath"
}
$metadata = $null
Import-LocalizedData -BindingVariable metadata -BaseDirectory (Split-Path $metadataPath) -FileName (Split-Path $metadataPath -Leaf)
$script:MonitorControlMetadata = $metadata
$script:AppName = [string]$script:MonitorControlMetadata.AppName
$script:AppVersion = [string]$script:MonitorControlMetadata.Version
if ([string]::IsNullOrWhiteSpace($script:AppName) -or $script:AppVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "MonitorControl metadata is invalid: $metadataPath"
}
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
