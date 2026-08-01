param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$launcherPath = Join-Path $repoRoot "MonitorControlPro.ps1"
$metadataPath = Join-Path $repoRoot "src\MonitorControl.Metadata.psd1"
$sourceManifestPath = Join-Path $repoRoot "src\MonitorControl.sources"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot "build\MonitorControlPro.ps1"
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)

$sourcePaths = @(Get-Content -LiteralPath $sourceManifestPath |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { Join-Path $repoRoot ([string]$_) })
foreach ($required in @($launcherPath, $metadataPath, $sourceManifestPath) + $sourcePaths) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing composition input: $required"
    }
    if ([System.IO.Path]::GetFullPath($required) -eq $outputFullPath) {
        throw "The composed output cannot overwrite a source file: $outputFullPath"
    }
}

$metadata = $null
Import-LocalizedData -BindingVariable metadata -BaseDirectory (Split-Path $metadataPath) -FileName (Split-Path $metadataPath -Leaf)
$appName = [string]$metadata.AppName
$appVersion = [string]$metadata.Version
if ([string]::IsNullOrWhiteSpace($appName) -or $appVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Invalid application metadata: $metadataPath"
}
if ($appName.Contains('"')) { throw "Application name cannot contain a double quote." }

$launcherText = [System.IO.File]::ReadAllText($launcherPath)
$tokens = $null
$parseErrors = $null
$launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $launcherPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
if ($null -eq $launcherAst.ParamBlock) { throw "The development launcher has no parameter block." }
$entryPrefix = $launcherText.Substring(0, $launcherAst.ParamBlock.Extent.EndOffset).TrimEnd()

$parts = New-Object System.Collections.Generic.List[string]
$parts.Add($entryPrefix)
$parts.Add('$script:MonitorControlRoot = $PSScriptRoot')
$parts.Add(('$script:AppName = "{0}"' -f $appName))
$parts.Add(('$script:AppVersion = "{0}"' -f $appVersion))
foreach ($sourcePath in $sourcePaths) {
    $parts.Add(([System.IO.File]::ReadAllText($sourcePath)).Trim())
}
$composedText = ($parts -join "`r`n`r`n") + "`r`n"

foreach ($character in $composedText.ToCharArray()) {
    if ([int]$character -gt 127) { throw "The composed source contains a non-ASCII character." }
}
$composedTokens = $null
$composedErrors = $null
$composedAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $composedText,
    [ref]$composedTokens,
    [ref]$composedErrors
)
if ($composedErrors.Count -gt 0) { throw ($composedErrors | Out-String) }

$functionNames = @($composedAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name })
$duplicates = @($functionNames | Group-Object | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) {
    throw "Duplicate function definitions in composed source: $($duplicates.Name -join ', ')"
}

$outputDirectory = [System.IO.Path]::GetDirectoryName($outputFullPath)
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
[System.IO.File]::WriteAllText($outputFullPath, $composedText, (New-Object System.Text.ASCIIEncoding))

[PSCustomObject]@{
    OutputPath = $outputFullPath
    Version = $appVersion
    SourceCount = $sourcePaths.Count
    FunctionCount = $functionNames.Count
}
