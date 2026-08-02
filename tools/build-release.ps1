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

function Get-GitSourceCommit {
    $commit = "unknown"
    try {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $gitCommand) {
            $candidate = ([string](& $gitCommand.Source -C $repoRoot rev-parse --verify HEAD 2>$null)).Trim()
            if ($candidate -match '^[0-9a-fA-F]{40}$') { $commit = $candidate.ToLowerInvariant() }
        }
    } catch {}
    if ($commit -eq "unknown") {
        try {
            $gitDirectory = Join-Path $repoRoot ".git"
            $headPath = Join-Path $gitDirectory "HEAD"
            $head = (Get-Content -LiteralPath $headPath -Raw).Trim()
            if ($head -match '^ref:\s+(.+)$') {
                $refPath = Join-Path $gitDirectory ($matches[1] -replace '/', '\\')
                $head = (Get-Content -LiteralPath $refPath -Raw).Trim()
            }
            if ($head -match '^[0-9a-fA-F]{40}$') { $commit = $head.ToLowerInvariant() }
        } catch {}
    }
    return $commit
}

function Get-FileManifestRecord {
    param([string]$Directory, [string]$Name)
    $path = Join-Path $Directory $Name
    $item = Get-Item -LiteralPath $path -Force
    return [ordered]@{
        Name = $Name
        Size = [long]$item.Length
        Sha256 = Get-Sha256Hash -Path $path
    }
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

function New-CycloneDxSbom {
    param(
        [string]$AppName,
        [string]$Version,
        [string]$BuiltAt,
        [string]$SourceCommit,
        [string]$ApplicationSha256
    )
    $components = @(
        [ordered]@{
            type = "application"
            name = $AppName
            version = $Version
            "bom-ref" = "pkg:generic/monitorcontrol-pro@$Version"
            hashes = @([ordered]@{ alg = "SHA-256"; content = $ApplicationSha256 })
        },
        [ordered]@{
            type = "framework"
            name = "Windows PowerShell"
            version = "5.1"
            scope = "required"
        },
        [ordered]@{
            type = "framework"
            name = ".NET Framework WPF"
            version = "4.8+"
            scope = "required"
        }
    )
    return [ordered]@{
        bomFormat = "CycloneDX"
        specVersion = "1.5"
        serialNumber = "urn:monitorcontrol:$($SourceCommit):$Version"
        version = 1
        metadata = [ordered]@{
            timestamp = $BuiltAt
            component = [ordered]@{
                type = "application"
                name = $AppName
                version = $Version
            }
            properties = @(
                [ordered]@{ name = "monitorcontrol.sourceCommit"; value = $SourceCommit }
                [ordered]@{ name = "monitorcontrol.runtime"; value = "Windows PowerShell 5.1" }
            )
        }
        components = $components
    }
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

# Scoop resolves `shortcuts` against a file it can execute. A bare .ps1 is not one, and a GUI
# app should not get a `bin` shim either, so the ZIP carries a launcher that starts the script
# with the STA host it needs and no console window left behind.
$launcherText = @(
    "@echo off"
    "setlocal"
    "start """" /b powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""%~dp0MonitorControlPro.ps1"" %*"
    "endlocal"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stageRoot "MonitorControlPro.cmd"), $launcherText + "`r`n", (New-Object System.Text.ASCIIEncoding))

$signStatus = "Unsigned: MonitorControl Pro release artifacts are intentionally not code signed."
$builtAt = $buildTime.Timestamp.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$signingText = @(
    "$appName v$Version"
    $signStatus
    "BuiltAt: $builtAt"
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stageRoot "SIGNING.txt"), $signingText + "`r`n", (New-Object System.Text.ASCIIEncoding))

$sourceCommit = Get-GitSourceCommit
$applicationSha256 = Get-Sha256Hash -Path $releaseScript
$sbomDocument = New-CycloneDxSbom `
    -AppName $appName `
    -Version $Version `
    -BuiltAt $builtAt `
    -SourceCommit $sourceCommit `
    -ApplicationSha256 $applicationSha256
$sbomJson = ($sbomDocument | ConvertTo-Json -Depth 8) + "`r`n"
[System.IO.File]::WriteAllText((Join-Path $stageRoot "SBOM.cdx.json"), $sbomJson, (New-Object System.Text.ASCIIEncoding))

$payloadNames = @(Get-OrdinalFileNames -Directory $stageRoot | Where-Object { $_ -notin @("RELEASE.json", "SHA256SUMS") })
$payloadRecords = @($payloadNames | ForEach-Object { Get-FileManifestRecord -Directory $stageRoot -Name $_ })
$releaseManifest = [ordered]@{
    SchemaVersion = 2
    AppName = $appName
    Version = $Version
    BuiltAt = $builtAt
    SourceDateEpoch = $buildTime.SourceDateEpoch
    SourceCommit = $sourceCommit
    Runtime = "Windows PowerShell 5.1"
    BuildTool = "tools/build-release.ps1"
    Signing = "Unsigned"
    Payload = $payloadRecords
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
$zipItem = Get-Item -LiteralPath $zipPath -Force

$distributionManifest = [ordered]@{
    SchemaVersion = 2
    AppName = $appName
    Version = $Version
    BuiltAt = $builtAt
    SourceDateEpoch = $buildTime.SourceDateEpoch
    SourceCommit = $sourceCommit
    Runtime = "Windows PowerShell 5.1"
    BuildTool = "tools/build-release.ps1"
    Signing = "Unsigned"
    Artifact = [ordered]@{
        Name = [System.IO.Path]::GetFileName($zipPath)
        Size = [long]$zipItem.Length
        Sha256 = $zipHash
    }
    Payload = $payloadRecords
}
$basePath = [System.IO.Path]::Combine($OutputRoot, [System.IO.Path]::GetFileNameWithoutExtension($zipPath))
$manifestPath = "$basePath.manifest.json"
$sbomPath = "$basePath.sbom.json"
[System.IO.File]::WriteAllText(
    $manifestPath,
    (($distributionManifest | ConvertTo-Json -Depth 5) + "`r`n"),
    (New-Object System.Text.ASCIIEncoding)
)
[System.IO.File]::WriteAllText($sbomPath, $sbomJson, (New-Object System.Text.ASCIIEncoding))

# Scoop autoupdate fetches `$url.sha256` and expects a bare hash or a `hash *name` line. The
# SHA256SUMS inside the ZIP covers the payload; this sidecar covers the ZIP itself, which is
# the only thing a package manager can verify before extracting anything.
$sidecarPath = "$zipPath.sha256"
if (Test-Path -LiteralPath $sidecarPath) { Remove-Item -LiteralPath $sidecarPath -Force }
[System.IO.File]::WriteAllText(
    $sidecarPath,
    ("$zipHash *$([System.IO.Path]::GetFileName($zipPath))`r`n"),
    (New-Object System.Text.ASCIIEncoding)
)

[PSCustomObject]@{
    Version = $Version
    ZipPath = $zipPath
    Sha256Path = $sidecarPath
    Sha256 = $zipHash
    ManifestPath = $manifestPath
    SbomPath = $sbomPath
    Signing = $signStatus
    SourceDateEpoch = $buildTime.SourceDateEpoch
    Files = @(Get-OrdinalFileNames -Directory $stageRoot)
}
