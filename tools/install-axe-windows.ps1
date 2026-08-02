param(
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
$version = "2.4.2"
$archiveName = "AxeWindowsCLI-$version.zip"
$downloadUri = "https://github.com/microsoft/axe-windows/releases/download/v$version/$archiveName"
$expectedSha256 = "aeca43f41c89b3ffb1db84011539e609ecd7cb3badd6e78fada2ada327d10a64"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-AxeWindows-$version"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd([char[]]@('\', '/'))
if ([string]::IsNullOrWhiteSpace($OutputRoot) -or [System.IO.Path]::GetPathRoot($OutputRoot) -eq $OutputRoot) {
    throw "Axe.Windows output must be a child directory, not a volume root."
}
if (Test-Path -LiteralPath $OutputRoot) {
    $item = Get-Item -LiteralPath $OutputRoot -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Axe.Windows output cannot be a reparse point: $OutputRoot"
    }
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$archivePath = Join-Path $OutputRoot $archiveName
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$client = New-Object System.Net.WebClient
try { $client.DownloadFile($downloadUri, $archivePath) } finally { $client.Dispose() }

$sha = [System.Security.Cryptography.SHA256]::Create()
$stream = [System.IO.File]::OpenRead($archivePath)
try { $actualSha256 = (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $stream.Dispose(); $sha.Dispose() }
if ($actualSha256 -ne $expectedSha256) {
    throw "Axe.Windows archive hash mismatch. Expected $expectedSha256, got $actualSha256."
}

$extractRoot = Join-Path $OutputRoot "expanded"
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
$cli = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "AxeWindowsCLI.exe")
if ($cli.Count -ne 1) { throw "Axe.Windows CLI executable was not found uniquely in the verified archive." }

[PSCustomObject]@{
    Version = $version
    Path = $cli[0].FullName
    ArchivePath = $archivePath
    Sha256 = $actualSha256
}
