param(
    [string]$Version = "",
    [string]$OutputRoot = "",
    [string]$CertificateThumbprint = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $repoRoot "dist" }
$scriptPath = Join-Path $repoRoot "MonitorControlPro.ps1"
$readmePath = Join-Path $repoRoot "README.md"
$licensePath = Join-Path $repoRoot "LICENSE"
$iconPath = Join-Path $repoRoot "icon.ico"

foreach ($required in @($scriptPath, $readmePath, $licensePath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing release input: $required" }
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

if ([string]::IsNullOrWhiteSpace($Version)) {
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    $match = [regex]::Match($scriptText, "Version:\s+([0-9]+\.[0-9]+\.[0-9]+)")
    if (-not $match.Success) { throw "Could not detect version from MonitorControlPro.ps1" }
    $Version = $match.Groups[1].Value
}

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Version must use X.Y.Z format" }

$stageRoot = Join-Path $OutputRoot "MonitorControlPro-v$Version"
$zipPath = Join-Path $OutputRoot "MonitorControlPro-v$Version.zip"
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
Get-ChildItem -LiteralPath $OutputRoot -Filter "MonitorControlPro-v*" -Force |
    Where-Object { $_.PSIsContainer -or $_.Name -like "*.zip" } |
    Remove-Item -Recurse -Force
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$releaseScript = Join-Path $stageRoot "MonitorControlPro.ps1"
Copy-Item -LiteralPath $scriptPath -Destination $releaseScript -Force
Copy-Item -LiteralPath $readmePath -Destination (Join-Path $stageRoot "README.md") -Force
Copy-Item -LiteralPath $licensePath -Destination (Join-Path $stageRoot "LICENSE") -Force
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stageRoot "icon.ico") -Force

$signStatus = "Unsigned: no usable code-signing certificate was found."
$cert = $null
function Get-CodeSigningCertificates {
    param([string]$StorePath)
    Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue | Where-Object {
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date) -and
        @($_.EnhancedKeyUsageList | Where-Object {
            $_.ObjectId.Value -eq "1.3.6.1.5.5.7.3.3" -or $_.FriendlyName -eq "Code Signing"
        }).Count -gt 0
    }
}

if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    foreach ($store in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        $cert = Get-CodeSigningCertificates -StorePath $store |
            Where-Object { $_.Thumbprint -eq $CertificateThumbprint } |
            Select-Object -First 1
        if ($cert) { break }
    }
    if (-not $cert) { throw "Code-signing certificate not found: $CertificateThumbprint" }
} else {
    foreach ($store in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        $cert = Get-CodeSigningCertificates -StorePath $store |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
        if ($cert) { break }
    }
}

if ($cert) {
    $signature = Set-AuthenticodeSignature -FilePath $releaseScript -Certificate $cert
    if ($signature.Status -ne "Valid") { throw "Authenticode signing failed: $($signature.StatusMessage)" }
    $signStatus = "Signed: $($cert.Subject) [$($cert.Thumbprint)]"
}

$signingText = @(
    "MonitorControl Pro v$Version"
    $signStatus
    "BuiltAt: $((Get-Date).ToString('o'))"
)
$signingText | Set-Content -LiteralPath (Join-Path $stageRoot "SIGNING.txt") -Encoding ASCII

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $stageRoot -File | Sort-Object Name) {
    $hash = Get-Sha256Hash -Path $file.FullName
    "$hash  $($file.Name)"
}
$hashLines | Set-Content -LiteralPath (Join-Path $stageRoot "SHA256SUMS") -Encoding ASCII

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath)
$zipHash = Get-Sha256Hash -Path $zipPath

[PSCustomObject]@{
    Version = $Version
    ZipPath = $zipPath
    Sha256 = $zipHash
    Signing = $signStatus
    Files = @((Get-ChildItem -LiteralPath $stageRoot -File | Sort-Object Name | ForEach-Object { $_.Name }))
}
