param(
    [string]$ManifestPath = "",
    [string]$OutputRoot = ""
)

# Regenerates the Scoop manifest from a real local release build. The manifest is produced here
# rather than by a hosted build: this repository builds and publishes locally, and a manifest is
# only honest if its hash came from the exact ZIP that will be uploaded. Release builds are
# deterministic (ordinal entry order plus a pinned SOURCE_DATE_EPOCH), so the hash written here
# is the hash of the published asset.

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "The Scoop manifest must be generated with Windows PowerShell 5.1, the same host that builds the release."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $repoRoot "packaging\scoop\monitorcontrol-pro.json" }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-Scoop-$([guid]::NewGuid().ToString('N'))"
    $temporaryOutput = $true
} else {
    $temporaryOutput = $false
}

try {
    $release = & (Join-Path $repoRoot "tools\build-release.ps1") -OutputRoot (Join-Path $OutputRoot "dist")
    if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.Sha256)) {
        throw "The release builder produced no checksum."
    }
    $version = [string]$release.Version
    $zipName = [System.IO.Path]::GetFileName([string]$release.ZipPath)
    $downloadBase = "https://github.com/SysAdminDoc/MonitorControl/releases/download"

    $manifest = [ordered]@{
        version = $version
        description = "Portable Windows DDC/CI display control center for brightness, contrast, color temperature, input switching, and profiles."
        homepage = "https://github.com/SysAdminDoc/MonitorControl"
        license = "MIT"
        notes = @(
            "MonitorControl Pro is distributed unsigned. SmartScreen may warn on first launch.",
            "Requires Windows PowerShell 5.1, which ships with Windows.",
            "Monitors must have DDC/CI enabled in their own on-screen menu.",
            "Settings and profiles live in %APPDATA%\MonitorControlPro and survive an update or uninstall."
        )
        architecture = [ordered]@{
            "64bit" = [ordered]@{
                url = "$downloadBase/v$version/$zipName"
                hash = [string]$release.Sha256
            }
        }
        shortcuts = @(, @("MonitorControlPro.cmd", "MonitorControl Pro"))
        checkver = "github"
        autoupdate = [ordered]@{
            architecture = [ordered]@{
                "64bit" = [ordered]@{
                    url = "$downloadBase/v`$version/MonitorControlPro-v`$version.zip"
                }
            }
            hash = [ordered]@{ url = "`$url.sha256" }
        }
    }

    $json = ($manifest | ConvertTo-Json -Depth 6)
    [System.IO.File]::WriteAllText($ManifestPath, ($json -replace "`r?`n", "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $ManifestPath for v$version (sha256 $($release.Sha256))"
    [PSCustomObject]@{ ManifestPath = $ManifestPath; Version = $version; Sha256 = [string]$release.Sha256 }
} finally {
    if ($temporaryOutput -and (Test-Path -LiteralPath $OutputRoot)) {
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force
    }
}
