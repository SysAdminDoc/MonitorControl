BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Add-Type -AssemblyName System.Drawing

    function Get-MarketingImageMetrics {
        param([string]$Path)

        $bitmap = New-Object System.Drawing.Bitmap($Path)
        try {
            [PSCustomObject]@{
                Width = $bitmap.Width
                Height = $bitmap.Height
                CornerAlpha = $bitmap.GetPixel(0, 0).A
            }
        } finally {
            $bitmap.Dispose()
        }
    }

    function Get-MarketingFileHash {
        param([string]$Path)

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
        } finally {
            $stream.Dispose()
            $sha256.Dispose()
        }
    }
}

Describe "Marketing assets" {
    It "keeps the approved mark and every brand surface at its intended size" {
        $expected = [ordered]@{
            "assets\brand\monitorcontrol-mark-source.png" = @(1024, 1024, 0)
            "assets\brand\monitorcontrol-mark.png" = @(1024, 1024, 0)
            "assets\brand\monitorcontrol-app-icon.png" = @(1024, 1024, 0)
            "assets\brand\monitorcontrol-wordmark.png" = @(1400, 300, 0)
            "assets\brand\monitorcontrol-banner.png" = @(1600, 500, 255)
            "assets\brand\social-preview.png" = @(1280, 640, 255)
            "icon.png" = @(1024, 1024, 0)
        }

        foreach ($entry in $expected.GetEnumerator()) {
            $path = Join-Path $script:RepoRoot $entry.Key
            (Test-Path -LiteralPath $path -PathType Leaf) | Should -BeTrue
            (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 10240
            $metrics = Get-MarketingImageMetrics -Path $path
            $metrics.Width | Should -Be $entry.Value[0]
            $metrics.Height | Should -Be $entry.Value[1]
            $metrics.CornerAlpha | Should -Be $entry.Value[2]
        }

        (Get-Item -LiteralPath (Join-Path $script:RepoRoot "icon.ico")).Length |
            Should -BeGreaterThan 10240
    }

    It "ships seven verified product views from the private capture lane" {
        $screenshotRoot = Join-Path $script:RepoRoot "assets\screenshots"
        $report = Get-Content -LiteralPath (Join-Path $screenshotRoot "capture-report.json") -Raw |
            ConvertFrom-Json
        $expectedNames = @(
            "automation.png",
            "display.png",
            "hardware.png",
            "monitor.png",
            "profiles.png",
            "system.png",
            "vcp-explorer.png"
        )

        $report.marketingCapture | Should -BeTrue
        @($report.screenshots).Count | Should -Be 7
        (@($report.screenshots.file) | Sort-Object) -join "|" | Should -Be ($expectedNames -join "|")
        foreach ($record in @($report.screenshots)) {
            $path = Join-Path $screenshotRoot $record.file
            (Test-Path -LiteralPath $path -PathType Leaf) | Should -BeTrue
            (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 10240
            $metrics = Get-MarketingImageMetrics -Path $path
            $metrics.Width | Should -Be ([int]$record.width)
            $metrics.Height | Should -Be ([int]$record.height)
            $metrics.Width | Should -BeGreaterThan 999
            $metrics.Height | Should -BeGreaterThan 599
        }

        (Test-Path -LiteralPath (Join-Path $screenshotRoot "render.complete")) | Should -BeFalse
        Get-MarketingFileHash -Path (Join-Path $script:RepoRoot "screenshot.png") |
            Should -Be (Get-MarketingFileHash -Path (Join-Path $screenshotRoot "display.png"))
    }

    It "keeps capture deterministic and off the interactive desktop" {
        $launcher = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "MonitorControlPro.ps1"))
        $ddc = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "src\MonitorControl.Ddc.psm1"))
        $captureRunner = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\MonitorControl.MarketingCapture\Program.cs"))
        $releaseBuilder = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "tools\build-release.ps1"))

        $launcher | Should -Match '\[switch\]\$MarketingCapture'
        $marketingBranch = $ddc.IndexOf('if ($MarketingCapture)', [System.StringComparison]::Ordinal)
        $nativeEnumeration = $ddc.IndexOf('$monitorHandles = [MonitorAPI]::GetAllMonitorHandles()', [System.StringComparison]::Ordinal)
        $marketingBranch | Should -BeGreaterThan -1
        $nativeEnumeration | Should -BeGreaterThan $marketingBranch
        $captureRunner | Should -Match 'refuses to run on the interactive desktop'
        $captureRunner | Should -Match 'accessibility scan refuses to run on the interactive desktop'
        $captureRunner | Should -Match 'CreateDesktop'
        $captureRunner | Should -Match 'outputFileFormat = "None"'
        $releaseBuilder | Should -Match '\$iconPngPath'
        $releaseBuilder | Should -Match 'Copy-Item -LiteralPath \$iconPngPath'
    }

    It "references only present local images from the public README" {
        $readme = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "README.md"))
        $matches = [regex]::Matches($readme, '!\[[^\]]*\]\((?<path>[^)]+)\)')
        $matches.Count | Should -BeGreaterThan 0
        foreach ($match in $matches) {
            $path = $match.Groups["path"].Value
            if ($path -match '^https?://') { continue }
            (Test-Path -LiteralPath (Join-Path $script:RepoRoot ($path -replace '/', '\'))) |
                Should -BeTrue
        }
    }
}
