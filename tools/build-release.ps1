param(
    [string]$Version = "",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "Portable releases must be built with Windows PowerShell 5.1."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $repoRoot "dist" }
$metadataPath = Join-Path $repoRoot "src\MonitorControl.Metadata.psd1"
$scriptPath = Join-Path $repoRoot "MonitorControlPro.ps1"
$compilePath = Join-Path $repoRoot "tools\compile.ps1"
$readmePath = Join-Path $repoRoot "README.md"
$licensePath = Join-Path $repoRoot "LICENSE"
$iconPath = Join-Path $repoRoot "icon.ico"
$screenshotPath = Join-Path $repoRoot "screenshot.png"

foreach ($required in @($metadataPath, $scriptPath, $compilePath, $readmePath, $licensePath, $iconPath, $screenshotPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing release input: $required" }
}

function Test-EqualPath {
    param([string]$Left, [string]$Right)
    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd([char[]]@('\', '/')),
        [System.IO.Path]::GetFullPath($Right).TrimEnd([char[]]@('\', '/')),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-SafeOutputRoot {
    param([string]$Path, [string]$RepositoryRoot)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($fullPath) -or (Test-EqualPath -Left $fullPath -Right $volumeRoot)) {
        throw "Release output cannot be a volume root: $fullPath"
    }
    $protectedRoots = @(
        $RepositoryRoot,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($protectedRoot in $protectedRoots) {
        if (Test-EqualPath -Left $fullPath -Right $protectedRoot) {
            throw "Release output cannot use a protected directory: $fullPath"
        }
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        throw "Release output must be a directory: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $outputItem = Get-Item -LiteralPath $fullPath -Force
        if (($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release output cannot be a reparse point: $fullPath"
        }
    }
    return $fullPath
}

function Get-Sha256Hash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path $Path))
    try {
        $bytes = $sha.ComputeHash($stream)
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-OrdinalFileNames {
    param([string]$Directory)
    [string[]]$names = @(Get-ChildItem -LiteralPath $Directory -File | ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

function Get-DeterministicBuildTime {
    $sourceDateEpoch = [long]946684800
    if (-not [string]::IsNullOrWhiteSpace($env:SOURCE_DATE_EPOCH)) {
        if (-not [long]::TryParse($env:SOURCE_DATE_EPOCH, [ref]$sourceDateEpoch)) {
            throw "SOURCE_DATE_EPOCH must be an integer number of seconds since 1970-01-01 UTC."
        }
    }
    $timestamp = (New-Object System.DateTimeOffset([datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc))).AddSeconds($sourceDateEpoch)
    if ($timestamp -lt [datetimeoffset]'1980-01-01T00:00:00Z' -or $timestamp -gt [datetimeoffset]'2107-12-31T23:59:58Z') {
        throw "SOURCE_DATE_EPOCH must resolve to a ZIP-compatible UTC time from 1980 through 2107."
    }
    return [PSCustomObject]@{ SourceDateEpoch = $sourceDateEpoch; Timestamp = $timestamp }
}

function New-DeterministicZip {
    param([string]$SourceDirectory, [string]$DestinationPath, [datetimeoffset]$Timestamp)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zipStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $zipStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($name in Get-OrdinalFileNames -Directory $SourceDirectory) {
                $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $Timestamp
                $input = [System.IO.File]::OpenRead((Join-Path $SourceDirectory $name))
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $zipStream.Dispose()
    }
}

$metadata = $null
Import-LocalizedData -BindingVariable metadata -BaseDirectory (Split-Path $metadataPath) -FileName (Split-Path $metadataPath -Leaf)
$appName = [string]$metadata.AppName
$metadataVersion = [string]$metadata.Version
if ([string]::IsNullOrWhiteSpace($appName) -or $metadataVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Release metadata must contain AppName and an X.Y.Z Version."
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $metadataVersion
} elseif ($Version -ne $metadataVersion) {
    throw "Requested version $Version does not match canonical metadata version $metadataVersion."
}

$OutputRoot = Get-SafeOutputRoot -Path $OutputRoot -RepositoryRoot $repoRoot
$stageRoot = [System.IO.Path]::GetFullPath((Join-Path $OutputRoot "MonitorControlPro-v$Version"))
$zipPath = [System.IO.Path]::GetFullPath((Join-Path $OutputRoot "MonitorControlPro-v$Version.zip"))
if (-not (Test-EqualPath -Left ([System.IO.Directory]::GetParent($stageRoot).FullName) -Right $OutputRoot) -or
    -not (Test-EqualPath -Left ([System.IO.Directory]::GetParent($zipPath).FullName) -Right $OutputRoot)) {
    throw "Release targets escaped the validated output directory."
}

if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
if (Test-Path -LiteralPath $stageRoot) {
    $stageItem = Get-Item -LiteralPath $stageRoot -Force
    if (-not $stageItem.PSIsContainer -or ($stageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release stage must be an ordinary directory: $stageRoot"
    }
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$buildTime = Get-DeterministicBuildTime
$releaseScript = Join-Path $stageRoot "MonitorControlPro.ps1"
$compileResult = & $compilePath -OutputPath $releaseScript
if ($compileResult.Version -ne $Version) { throw "Compiled version drifted from release metadata." }
Copy-Item -LiteralPath $readmePath -Destination (Join-Path $stageRoot "README.md") -Force
Copy-Item -LiteralPath $licensePath -Destination (Join-Path $stageRoot "LICENSE") -Force
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stageRoot "icon.ico") -Force
Copy-Item -LiteralPath $screenshotPath -Destination (Join-Path $stageRoot "screenshot.png") -Force

$signStatus = "Unsigned: MonitorControl Pro release artifacts are intentionally not code signed."
$builtAt = $buildTime.Timestamp.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$signingText = @(
    "$appName v$Version"
    $signStatus
    "BuiltAt: $builtAt"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stageRoot "SIGNING.txt"), $signingText + "`r`n", (New-Object System.Text.ASCIIEncoding))

$releaseManifest = [ordered]@{
    SchemaVersion = 1
    AppName = $appName
    Version = $Version
    BuiltAt = $builtAt
    SourceDateEpoch = $buildTime.SourceDateEpoch
    Runtime = "Windows PowerShell 5.1"
    Signing = "Unsigned"
    Payload = @("MonitorControlPro.ps1", "README.md", "LICENSE", "icon.ico", "screenshot.png", "SIGNING.txt")
}
$manifestJson = ($releaseManifest | ConvertTo-Json -Depth 3) + "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stageRoot "RELEASE.json"), $manifestJson, (New-Object System.Text.ASCIIEncoding))

$hashLines = foreach ($name in Get-OrdinalFileNames -Directory $stageRoot) {
    "$(Get-Sha256Hash -Path (Join-Path $stageRoot $name))  $name"
}
[System.IO.File]::WriteAllText(
    (Join-Path $stageRoot "SHA256SUMS"),
    (($hashLines -join "`r`n") + "`r`n"),
    (New-Object System.Text.ASCIIEncoding)
)

New-DeterministicZip -SourceDirectory $stageRoot -DestinationPath $zipPath -Timestamp $buildTime.Timestamp
$zipHash = Get-Sha256Hash -Path $zipPath

[PSCustomObject]@{
    Version = $Version
    ZipPath = $zipPath
    Sha256 = $zipHash
    Signing = $signStatus
    SourceDateEpoch = $buildTime.SourceDateEpoch
    Files = @(Get-OrdinalFileNames -Directory $stageRoot)
}
