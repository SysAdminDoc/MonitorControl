param(
    [string]$ImageMagickPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$brandRoot = Join-Path $repoRoot "assets\brand"
$sourcePath = Join-Path $brandRoot "monitorcontrol-mark-source.png"
$boldFont = (Join-Path $env:SystemRoot "Fonts\seguisb.ttf").Replace("\", "/")
$regularFont = (Join-Path $env:SystemRoot "Fonts\segoeui.ttf").Replace("\", "/")

if ([string]::IsNullOrWhiteSpace($ImageMagickPath)) {
    $magickCommand = Get-Command magick.exe -ErrorAction SilentlyContinue
    if ($null -eq $magickCommand) { $magickCommand = Get-Command magick -ErrorAction SilentlyContinue }
    if ($null -eq $magickCommand) { throw "ImageMagick is required to build the MonitorControl brand assets." }
    $ImageMagickPath = $magickCommand.Source
}
foreach ($required in @($sourcePath, $boldFont, $regularFont, $ImageMagickPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing brand build input: $required" }
}

function Invoke-Magick {
    param([string[]]$Arguments)
    & $ImageMagickPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ImageMagick failed with exit code $LASTEXITCODE." }
}

function Get-ImageProperty {
    param([string]$Path, [string]$Format)
    $value = & $ImageMagickPath identify -format $Format $Path
    if ($LASTEXITCODE -ne 0) { throw "ImageMagick could not inspect $Path." }
    return [string]$value
}

New-Item -ItemType Directory -Path $brandRoot -Force | Out-Null
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-Brand-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $sourceGeometry = Get-ImageProperty -Path $sourcePath -Format "%wx%h"
    $sourceChannels = Get-ImageProperty -Path $sourcePath -Format "%[channels]"
    $cornerAlpha = Get-ImageProperty -Path $sourcePath -Format "%[fx:p{0,0}.a]"
    if ($sourceGeometry -ne "1024x1024" -or $sourceChannels -notmatch "a" -or [double]$cornerAlpha -ne 0) {
        throw "The brand master must be a 1024x1024 RGBA PNG with a fully transparent corner."
    }

    $markPath = Join-Path $brandRoot "monitorcontrol-mark.png"
    $appIconPath = Join-Path $brandRoot "monitorcontrol-app-icon.png"
    $wordmarkPath = Join-Path $brandRoot "monitorcontrol-wordmark.png"
    $bannerPath = Join-Path $brandRoot "monitorcontrol-banner.png"
    $socialPath = Join-Path $brandRoot "social-preview.png"
    $rootPngPath = Join-Path $repoRoot "icon.png"
    $rootIcoPath = Join-Path $repoRoot "icon.ico"
    $bannerBackground = Join-Path $tempRoot "banner-background.png"
    $socialBackground = Join-Path $tempRoot "social-background.png"

    Invoke-Magick @($sourcePath, "-resize", "1024x1024", "-strip", $markPath)
    Copy-Item -LiteralPath $markPath -Destination $rootPngPath -Force

    Invoke-Magick @(
        "-size", "1024x1024", "xc:none",
        "-fill", "#F5F8FC", "-stroke", "#2D6FD3", "-strokewidth", "14",
        "-draw", "roundrectangle 24,24 1000,1000 196,196",
        "(", $sourcePath, "-resize", "760x760", ")", "-gravity", "center", "-composite",
        "-strip", $appIconPath
    )

    Invoke-Magick @(
        $appIconPath,
        "(", "-clone", "0", "-resize", "16x16", ")",
        "(", "-clone", "0", "-resize", "20x20", ")",
        "(", "-clone", "0", "-resize", "24x24", ")",
        "(", "-clone", "0", "-resize", "32x32", ")",
        "(", "-clone", "0", "-resize", "40x40", ")",
        "(", "-clone", "0", "-resize", "48x48", ")",
        "(", "-clone", "0", "-resize", "64x64", ")",
        "(", "-clone", "0", "-resize", "128x128", ")",
        "(", "-clone", "0", "-resize", "256x256", ")",
        "-delete", "0", $rootIcoPath
    )

    Invoke-Magick @(
        "-size", "1400x300", "xc:none",
        "(", $appIconPath, "-resize", "238x238", ")", "-geometry", "+20+31", "-composite",
        "-font", $boldFont, "-fill", "#F5F8FC", "-pointsize", "78", "-annotate", "+294+142", "MonitorControl Pro",
        "-font", $regularFont, "-fill", "#85B7FF", "-pointsize", "28", "-annotate", "+299+202", "DDC/CI display control for Windows",
        "-strip", $wordmarkPath
    )

    Invoke-Magick @("-size", "1600x500", "gradient:#06101C-#0B2B50", "-rotate", "90", "-resize", "1600x500!", $bannerBackground)
    Invoke-Magick @(
        $bannerBackground,
        "-fill", "#123A66", "-draw", "polygon 1120,0 1600,0 1600,500 1380,500",
        "(", $appIconPath, "-resize", "322x322", ")", "-geometry", "+104+89", "-composite",
        "-font", $boldFont, "-fill", "#F8FAFC", "-pointsize", "74", "-annotate", "+490+200", "MonitorControl Pro",
        "-font", $regularFont, "-fill", "#B9C9DB", "-pointsize", "29", "-annotate", "+496+270", "DDC/CI display control for Windows",
        "-fill", "#65D9FF", "-pointsize", "21", "-annotate", "+498+330", "Brightness  |  Color  |  Inputs  |  Profiles",
        "-strip", $bannerPath
    )

    Invoke-Magick @("-size", "1280x640", "gradient:#06101C-#0B2B50", "-rotate", "90", "-resize", "1280x640!", $socialBackground)
    Invoke-Magick @(
        $socialBackground,
        "-fill", "#123A66", "-draw", "polygon 900,0 1280,0 1280,640 1110,640",
        "(", $appIconPath, "-resize", "332x332", ")", "-geometry", "+90+154", "-composite",
        "-font", $boldFont, "-fill", "#F8FAFC", "-pointsize", "65", "-annotate", "+480+278", "MonitorControl Pro",
        "-font", $regularFont, "-fill", "#B9C9DB", "-pointsize", "27", "-annotate", "+485+345", "Control every compatible display",
        "-fill", "#65D9FF", "-pointsize", "23", "-annotate", "+485+395", "Brightness  |  Color  |  Inputs  |  Profiles",
        "-strip", $socialPath
    )

    foreach ($output in @($markPath, $appIconPath, $wordmarkPath, $bannerPath, $socialPath, $rootPngPath, $rootIcoPath)) {
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -lt 1KB) {
            throw "Brand output is missing or unexpectedly small: $output"
        }
    }

    [PSCustomObject]@{
        Mark = $markPath
        AppIcon = $appIconPath
        Wordmark = $wordmarkPath
        Banner = $bannerPath
        SocialPreview = $socialPath
        IconPng = $rootPngPath
        IconIco = $rootIcoPath
    }
} finally {
    $fullTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($fullTempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($fullTempRoot) -like "MonitorControl-Brand-*") {
        Remove-Item -LiteralPath $fullTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
