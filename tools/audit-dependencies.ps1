[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$ManifestPath = "",
    [string]$WorkflowPath = "",
    [string]$ReportPath = "",
    [switch]$CheckRemote
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RepoRoot = Resolve-Path (Join-Path $scriptRoot "..")
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@('\', '/'))
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $RepoRoot "tools\dependency-pins.json"
}
if ([string]::IsNullOrWhiteSpace($WorkflowPath)) {
    $WorkflowPath = Join-Path $RepoRoot ".github\workflows\verify.yml"
}

function Add-AuditError {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        [string]$Message
    )

    $Errors.Add($Message)
}

function Add-AuditFinding {
    param(
        [System.Collections.Generic.List[object]]$Findings,
        [string]$Type,
        [string]$Name,
        [string]$Pinned,
        [string]$Observed,
        [string]$Message
    )

    $Findings.Add([pscustomobject]@{
            Type = $Type
            Name = $Name
            Pinned = $Pinned
            Observed = $Observed
            Message = $Message
        })
}

function Get-Sha256 {
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Invoke-JsonGet {
    param([string]$Uri)

    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "MonitorControl-dependency-audit"
    }
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $headers -ErrorAction Stop
    return ($response.Content | ConvertFrom-Json)
}

function Get-RemoteFileHash {
    param(
        [string]$Uri,
        [string]$Name
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MonitorControlDependencyAudit-" + [guid]::NewGuid().ToString("N"))
    $filePath = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $filePath -ErrorAction Stop
        return Get-Sha256 -Path $filePath
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-LatestGalleryVersion {
    param([string]$Name)

    $uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$Name'&%24filter=IsLatestVersion%20eq%20true"
    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -ErrorAction Stop
    $versions = @([regex]::Matches($response.Content, '<d:Version>(?<version>[^<]+)</d:Version>') |
        ForEach-Object {
            try { [version]$_.Groups["version"].Value } catch { $null }
        } |
        Where-Object { $_ })
    if ($versions.Count -eq 0) { return "" }
    return (($versions | Sort-Object -Descending | Select-Object -First 1).ToString())
}

function Test-WorkflowPins {
    param(
        [pscustomobject]$Manifest,
        [string]$WorkflowText,
        [string]$RepoRoot,
        [System.Collections.Generic.List[string]]$Errors
    )

    $actionMatches = [regex]::Matches($WorkflowText, '(?m)^\s*uses:\s*(?<name>[^@\s]+)@(?<ref>[0-9a-fA-F]{40})(?:\s*#\s*(?<version>v?[^\s]+))?\s*$')
    $allActionLines = [regex]::Matches($WorkflowText, '(?m)^\s*uses:\s*(?<value>\S+)')
    foreach ($line in $allActionLines) {
        if ($line.Groups["value"].Value -notmatch '@[0-9a-fA-F]{40}$') {
            Add-AuditError -Errors $Errors -Message ("Workflow action is not pinned to a full commit SHA: {0}" -f $line.Groups["value"].Value)
        }
    }
    foreach ($match in $actionMatches) {
        $name = $match.Groups["name"].Value
        $pin = @($Manifest.Actions | Where-Object { $_.Name -eq $name })
        if ($pin.Count -ne 1) {
            Add-AuditError -Errors $Errors -Message ("Workflow action {0} is missing or duplicated in dependency-pins.json." -f $name)
            continue
        }
        if ($pin[0].Ref -ne $match.Groups["ref"].Value) {
            Add-AuditError -Errors $Errors -Message ("Workflow action hash changed for {0}: manifest {1}, workflow {2}." -f $name, $pin[0].Ref, $match.Groups["ref"].Value)
        }
        if ($match.Groups["version"].Success -and $pin[0].Version -ne $match.Groups["version"].Value) {
            Add-AuditError -Errors $Errors -Message ("Workflow action version comment changed for {0}: manifest {1}, workflow {2}." -f $name, $pin[0].Version, $match.Groups["version"].Value)
        }
    }

    $moduleMatches = [regex]::Matches($WorkflowText, '(?im)Install-Module\s+(?<name>[A-Za-z0-9_.-]+).*?-RequiredVersion\s+(?<version>[0-9.]+)')
    foreach ($match in $moduleMatches) {
        $name = $match.Groups["name"].Value
        $version = $match.Groups["version"].Value
        $pin = @($Manifest.PowerShellModules | Where-Object { $_.Name -eq $name -and $_.Version -eq $version })
        if ($pin.Count -ne 1) {
            Add-AuditError -Errors $Errors -Message ("Workflow module pin {0} {1} is missing or duplicated in dependency-pins.json." -f $name, $version)
        }
    }

    foreach ($scriptPath in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tools") -Filter "install-*.ps1" -File)) {
        $scriptText = [System.IO.File]::ReadAllText($scriptPath.FullName)
        $hashMatch = [regex]::Match($scriptText, '(?m)^\s*\$expectedSha256\s*=\s*"(?<hash>[0-9a-fA-F]{64})"')
        $uriMatch = [regex]::Match($scriptText, '(?m)^\s*\$downloadUri\s*=\s*"(?<uri>[^"]+)"')
        $versionMatch = [regex]::Match($scriptText, '(?m)^\s*\$version\s*=\s*"(?<version>[^"]+)"')
        if (-not $hashMatch.Success -or -not $uriMatch.Success -or -not $versionMatch.Success) { continue }
        $pin = @($Manifest.DownloadedCLIs | Where-Object { [System.IO.Path]::GetFileName($_.Script) -eq $scriptPath.Name })
        if ($pin.Count -ne 1) {
            Add-AuditError -Errors $Errors -Message ("Downloaded CLI script {0} is missing or duplicated in dependency-pins.json." -f $scriptPath.Name)
            continue
        }
        $scriptUri = $uriMatch.Groups["uri"].Value.Replace('$version', $versionMatch.Groups["version"].Value).Replace('$archiveName', ("AxeWindowsCLI-{0}.zip" -f $versionMatch.Groups["version"].Value))
        if ($pin[0].Version -ne $versionMatch.Groups["version"].Value -or $pin[0].Sha256 -ne $hashMatch.Groups["hash"].Value -or $pin[0].DownloadUri -ne $scriptUri) {
            Add-AuditError -Errors $Errors -Message ("Downloaded CLI pin changed in {0}; update the manifest and verify the archive before merging." -f $scriptPath.Name)
        }
    }
}

function Test-RemotePins {
    param(
        [pscustomobject]$Manifest,
        [System.Collections.Generic.List[object]]$Findings,
        [System.Collections.Generic.List[string]]$Errors
    )

    foreach ($action in @($Manifest.Actions)) {
        $repo = $action.Name
        try {
            $resolved = Invoke-JsonGet -Uri ("https://api.github.com/repos/{0}/commits/{1}" -f $repo, $action.Version)
            if ($resolved.sha -ne $action.Ref) {
                Add-AuditError -Errors $Errors -Message ("Remote action tag moved for {0} {1}: pinned {2}, tag resolves to {3}." -f $repo, $action.Version, $action.Ref, $resolved.sha)
            }
            $release = Invoke-JsonGet -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $repo)
            if ($release.tag_name -and $release.tag_name -ne $action.Version) {
                Add-AuditFinding -Findings $Findings -Type "newer-release" -Name $repo -Pinned $action.Version -Observed $release.tag_name -Message "A newer GitHub release is available; review and update the pinned SHA deliberately."
            }
            $advisories = @(Invoke-JsonGet -Uri ("https://api.github.com/advisories?affects={0}&per_page=100" -f [uri]::EscapeDataString($repo)))
            foreach ($advisory in $advisories) {
                Add-AuditFinding -Findings $Findings -Type "advisory" -Name $repo -Pinned $action.Version -Observed $advisory.ghsa_id -Message ($advisory.summary)
            }
        } catch {
            Add-AuditFinding -Findings $Findings -Type "remote-check-warning" -Name $repo -Pinned $action.Version -Observed "unavailable" -Message $_.Exception.Message
        }
    }

    foreach ($module in @($Manifest.PowerShellModules)) {
        try {
            $latest = Get-LatestGalleryVersion -Name $module.Name
            if ($latest -and ([version]$latest -gt [version]$module.Version)) {
                Add-AuditFinding -Findings $Findings -Type "newer-release" -Name $module.Name -Pinned $module.Version -Observed $latest -Message "A newer PowerShell Gallery module is available; update the version and hash together."
            }
            $actualHash = Get-RemoteFileHash -Uri $module.PackageUri -Name ("{0}-{1}.nupkg" -f $module.Name, $module.Version)
            if ($actualHash -ne $module.Sha256) {
                Add-AuditError -Errors $Errors -Message ("PowerShell Gallery hash changed for {0} {1}: expected {2}, got {3}." -f $module.Name, $module.Version, $module.Sha256, $actualHash)
            }
        } catch {
            Add-AuditFinding -Findings $Findings -Type "remote-check-warning" -Name $module.Name -Pinned $module.Version -Observed "unavailable" -Message $_.Exception.Message
        }
    }

    foreach ($cli in @($Manifest.DownloadedCLIs)) {
        try {
            $actualHash = Get-RemoteFileHash -Uri $cli.DownloadUri -Name (Split-Path -Leaf $cli.DownloadUri)
            if ($actualHash -ne $cli.Sha256) {
                Add-AuditError -Errors $Errors -Message ("Downloaded CLI hash changed for {0}: expected {1}, got {2}." -f $cli.Name, $cli.Sha256, $actualHash)
            }
            $releaseRepo = ([uri]$cli.DownloadUri).Segments[1].TrimEnd('/') + "/" + ([uri]$cli.DownloadUri).Segments[2].TrimEnd('/')
            $release = Invoke-JsonGet -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $releaseRepo)
            if ($release.tag_name -and $release.tag_name -ne ("v{0}" -f $cli.Version)) {
                Add-AuditFinding -Findings $Findings -Type "newer-release" -Name $cli.Name -Pinned $cli.Version -Observed $release.tag_name -Message "A newer CLI release is available; update the version and hash together."
            }
        } catch {
            Add-AuditFinding -Findings $Findings -Type "remote-check-warning" -Name $cli.Name -Pinned $cli.Version -Observed "unavailable" -Message $_.Exception.Message
        }
    }
}

$errors = New-Object 'System.Collections.Generic.List[string]'
$findings = New-Object 'System.Collections.Generic.List[object]'
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Dependency pin manifest was not found: $ManifestPath" }
if (-not (Test-Path -LiteralPath $WorkflowPath)) { throw "Verification workflow was not found: $WorkflowPath" }
$manifest = [System.IO.File]::ReadAllText($ManifestPath) | ConvertFrom-Json
$workflowText = [System.IO.File]::ReadAllText($WorkflowPath)
Test-WorkflowPins -Manifest $manifest -WorkflowText $workflowText -RepoRoot $RepoRoot -Errors $errors
if ($CheckRemote) {
    Test-RemotePins -Manifest $manifest -Findings $findings -Errors $errors
}

$mode = "offline"
if ($CheckRemote) { $mode = "remote" }
$pinSummary = [pscustomobject]@{
    Actions = @($manifest.Actions).Count
    PowerShellModules = @($manifest.PowerShellModules).Count
    DownloadedCLIs = @($manifest.DownloadedCLIs).Count
}
$report = [pscustomobject]@{
    GeneratedAtUtc = [DateTime]::UtcNow.ToString("o")
    Mode = $mode
    Pins = $pinSummary
    Findings = $findings.ToArray()
    Errors = $errors.ToArray()
}
$json = $report | ConvertTo-Json -Depth 8
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($ReportPath))
    if (-not (Test-Path -LiteralPath $reportParent)) { New-Item -ItemType Directory -Path $reportParent -Force | Out-Null }
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReportPath), $json, (New-Object System.Text.UTF8Encoding($false)))
}
$json
if ($errors.Count -gt 0) {
    throw (("Dependency pin audit failed with {0} error(s):" -f $errors.Count) + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
}
