param(
    [Parameter(Mandatory = $true)]
    [string]$ZipPath,
    [string]$ManifestPath = "",
    [string]$SbomPath = "",
    [string]$Sha256Path = ""
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredFile {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label was not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-ByteArraySha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally { $sha.Dispose() }
}

function Read-ZipEntryBytes {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    $input = $Entry.Open()
    $output = New-Object System.IO.MemoryStream
    try {
        $input.CopyTo($output)
        return ,$output.ToArray()
    } finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function Read-ZipEntryText {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    $bytes = Read-ZipEntryBytes -Entry $Entry
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Test-ByteArraysEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

$zipFullPath = Resolve-RequiredFile -Path $ZipPath -Label "Release ZIP"
$zipItem = Get-Item -LiteralPath $zipFullPath -Force
$basePath = Join-Path $zipItem.DirectoryName ([System.IO.Path]::GetFileNameWithoutExtension($zipItem.Name))
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = "$basePath.manifest.json" }
if ([string]::IsNullOrWhiteSpace($SbomPath)) { $SbomPath = "$basePath.sbom.json" }
if ([string]::IsNullOrWhiteSpace($Sha256Path)) { $Sha256Path = "$zipFullPath.sha256" }
$manifestFullPath = Resolve-RequiredFile -Path $ManifestPath -Label "Release manifest"
$sbomFullPath = Resolve-RequiredFile -Path $SbomPath -Label "Release SBOM"
$sha256FullPath = Resolve-RequiredFile -Path $Sha256Path -Label "Release checksum sidecar"

try { $manifest = Get-Content -LiteralPath $manifestFullPath -Raw | ConvertFrom-Json } catch { throw "Release manifest is not valid JSON: $manifestFullPath" }
try { $sbom = Get-Content -LiteralPath $sbomFullPath -Raw | ConvertFrom-Json } catch { throw "Release SBOM is not valid JSON: $sbomFullPath" }
if ([int]$manifest.SchemaVersion -ne 2) { throw "Unsupported release manifest schema: $($manifest.SchemaVersion)" }
if ([string]$manifest.Signing -ne "Unsigned") { throw "Release manifest does not preserve the unsigned contract." }
if ([string]$manifest.Artifact.Name -ne $zipItem.Name) { throw "Manifest artifact name does not match the ZIP." }
if ([long]$manifest.Artifact.Size -ne [long]$zipItem.Length) { throw "Manifest artifact size does not match the ZIP." }

$zipHash = Get-FileSha256 -Path $zipFullPath
if ([string]$manifest.Artifact.Sha256 -ne $zipHash) { throw "Manifest artifact SHA-256 does not match the ZIP." }
$sidecarText = (Get-Content -LiteralPath $sha256FullPath -Raw).Trim()
$sidecarMatch = [regex]::Match($sidecarText, '^(?<hash>[0-9a-fA-F]{64})\s+\*?.+$')
if (-not $sidecarMatch.Success -or $sidecarMatch.Groups["hash"].Value.ToLowerInvariant() -ne $zipHash) {
    throw "Release checksum sidecar does not match the ZIP."
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipFullPath)
try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
        if ([string]::IsNullOrWhiteSpace($entry.Name) -or $entry.FullName -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Release ZIP contains an unsafe entry: $($entry.FullName)"
        }
        if ($entries.ContainsKey($entry.FullName)) { throw "Release ZIP contains a duplicate entry: $($entry.FullName)" }
        $entries[$entry.FullName] = $entry
    }

    foreach ($record in @($manifest.Payload)) {
        $name = [string]$record.Name
        if (-not $entries.ContainsKey($name)) { throw "Release ZIP is missing payload entry: $name" }
        [byte[]]$bytes = Read-ZipEntryBytes -Entry $entries[$name]
        if ([long]$record.Size -ne [long]$bytes.Length) { throw "Payload size mismatch: $name" }
        if ([string]$record.Sha256 -ne (Get-ByteArraySha256 -Bytes $bytes)) { throw "Payload SHA-256 mismatch: $name" }
    }

    foreach ($required in @("RELEASE.json", "SBOM.cdx.json", "SHA256SUMS")) {
        if (-not $entries.ContainsKey($required)) { throw "Release ZIP is missing required metadata: $required" }
    }
    $internalManifest = Read-ZipEntryText -Entry $entries["RELEASE.json"] | ConvertFrom-Json
    if ([int]$internalManifest.SchemaVersion -ne 2 -or [string]$internalManifest.Version -ne [string]$manifest.Version) {
        throw "Internal release manifest does not match the sidecar manifest."
    }
    if ([string]$internalManifest.SourceCommit -ne [string]$manifest.SourceCommit) {
        throw "Internal release manifest source commit does not match the sidecar manifest."
    }
    if (@($internalManifest.Payload).Count -ne @($manifest.Payload).Count) {
        throw "Internal release manifest payload count does not match the sidecar manifest."
    }
    [byte[]]$zipSbomBytes = Read-ZipEntryBytes -Entry $entries["SBOM.cdx.json"]
    [byte[]]$sidecarSbomBytes = [System.IO.File]::ReadAllBytes($sbomFullPath)
    if (-not (Test-ByteArraysEqual -Left $zipSbomBytes -Right $sidecarSbomBytes)) {
        throw "The sidecar SBOM does not match the SBOM packaged in the ZIP."
    }
} finally { $archive.Dispose() }

if ([string]$sbom.bomFormat -ne "CycloneDX" -or [string]$sbom.specVersion -ne "1.5") {
    throw "Release SBOM is not CycloneDX 1.5."
}
if (@($sbom.components).Count -lt 1 -or [string]$sbom.metadata.component.version -ne [string]$manifest.Version) {
    throw "Release SBOM metadata is incomplete or mismatched."
}

[PSCustomObject]@{
    Version = [string]$manifest.Version
    ZipPath = $zipFullPath
    ManifestPath = $manifestFullPath
    SbomPath = $sbomFullPath
    Sha256 = $zipHash
    SourceCommit = [string]$manifest.SourceCommit
    Signing = [string]$manifest.Signing
}
