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

Describe "Portable documentation" {
    BeforeAll {
        $script:DocsRelease = & (Join-Path $script:RepoRoot "tools\build-release.ps1") `
            -OutputRoot (Join-Path $TestDrive "documentation-release")
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:ExtractedDocs = Join-Path $TestDrive "extracted-docs"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($script:DocsRelease.ZipPath, $script:ExtractedDocs)
    }

    It "includes every local README image and both linked user guides in the ZIP" {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($script:DocsRelease.ZipPath)
        try {
            $names = @($archive.Entries.FullName)
            $readme = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "README.md"))
            foreach ($match in [regex]::Matches($readme, '!\[[^\]]*\]\((?<path>[^)]+)\)')) {
                $path = $match.Groups["path"].Value
                if ($path -notmatch '^https?://') { $names | Should -Contain $path }
            }
            $names | Should -Contain "docs/CLI.md"
            $names | Should -Contain "docs/SAFETY.md"
            $names | Should -Contain "assets/brand/concepts/README.md"
        } finally { $archive.Dispose() }
    }

    It "keeps every archived concept and the selected master intact in the ZIP" {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($script:DocsRelease.ZipPath)
        try {
            $expected = [ordered]@{
                "assets/brand/concepts/direction-01-monitor-calibration.png" = "9c06e5f346b947b8964fc93a76cf102d5fc57f0579a912566080e1c262511ce6"
                "assets/brand/concepts/direction-02-selected-calibration-control.png" = "15c35061582a6f88c95ebb92fe1ea20b710d9802abf587caa3299c67c900ac22"
                "assets/brand/concepts/direction-03-converging-panels.png" = "032e41ce1275f66fc348193cd55b0142065d71334c8a7c4202215d47f6a1c63d"
                "assets/brand/concepts/direction-04-calibration-control-outline.png" = "cf6d8fb23168078834e1be7f40307ef2848970c3e201eceb892b5871dd6d72b2"
                "assets/brand/monitorcontrol-selected-master.png" = "15c35061582a6f88c95ebb92fe1ea20b710d9802abf587caa3299c67c900ac22"
            }
            foreach ($item in $expected.GetEnumerator()) {
                Get-MarketingFileHash -Path (Join-Path $script:RepoRoot $item.Key) | Should -Be $item.Value
                $entry = $archive.GetEntry($item.Key)
                $entry | Should -Not -BeNullOrEmpty
                $stream = $entry.Open()
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $hash = (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
                    $hash | Should -Be $item.Value
                } finally { $sha256.Dispose(); $stream.Dispose() }
            }
            @($archive.Entries.FullName) | Should -Contain "assets/brand/concepts/selection.json"
            $selection = Get-Content -LiteralPath (Join-Path $script:RepoRoot "assets\brand\concepts\selection.json") -Raw | ConvertFrom-Json
            @($selection.selectedConcepts) | Should -Contain "direction-02-selected-calibration-control.png"
            @($selection.selectedMasters) | Should -Contain "../monitorcontrol-selected-master.png"
        } finally { $archive.Dispose() }
    }

    It "covers nested files in the payload manifest and checksum list" {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($script:DocsRelease.ZipPath)
        try {
            $manifest = Get-Content -LiteralPath $script:DocsRelease.ManifestPath -Raw | ConvertFrom-Json
            $reader = New-Object System.IO.StreamReader($archive.GetEntry("SHA256SUMS").Open())
            try { $checksums = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $lines = @($checksums -split '\r?\n' | Where-Object { $_ })
            $lines.Count | Should -Be ($archive.Entries.Count - 1)
            @($manifest.Payload).Count | Should -Be ($archive.Entries.Count - 2)
            foreach ($record in $manifest.Payload) {
                $checksums | Should -Match ([regex]::Escape("$($record.Sha256)  $($record.Name)"))
                if ($record.Name -match '^(assets|docs)/') {
                    Get-MarketingFileHash -Path (Join-Path $script:RepoRoot $record.Name) | Should -Be $record.Sha256
                }
            }
        } finally { $archive.Dispose() }
    }

    It "resolves every relative link in the extracted user documentation" {
        foreach ($doc in Get-ChildItem -LiteralPath $script:ExtractedDocs -Filter *.md -Recurse -File) {
            $text = [System.IO.File]::ReadAllText($doc.FullName)
            foreach ($match in [regex]::Matches($text, '\[[^\]]*\]\((?<path>[^)]+)\)')) {
                $path = $match.Groups["path"].Value
                if ($path -match '^(https?://|#|mailto:)') { continue }
                $path = ($path -split '#')[0]
                Test-Path -LiteralPath (Join-Path $doc.DirectoryName $path) | Should -BeTrue -Because "$($doc.Name) links to $path"
            }
        }
    }
}
