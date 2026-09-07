BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:DependencyAuditPath = Join-Path $script:RepoRoot "tools\audit-dependencies.ps1"
    $script:DependencyManifestPath = Join-Path $script:RepoRoot "tools\dependency-pins.json"
}

Describe "Dependency freshness metadata" {
    It "passes the offline consistency audit" {
        $reportPath = Join-Path $TestDrive "dependency-audit.json"
        $output = & $script:DependencyAuditPath -RepoRoot $script:RepoRoot -ReportPath $reportPath
        $report = ($output -join [Environment]::NewLine) | ConvertFrom-Json

        $report.Mode | Should -Be "offline"
        $report.Pins.Actions | Should -Be 0
        $report.Pins.PowerShellModules | Should -Be 3
        $report.Pins.DownloadedCLIs | Should -Be 1
        @($report.Errors).Count | Should -Be 0
        (Test-Path -LiteralPath $reportPath) | Should -BeTrue
    }

    It "fails when a downloaded CLI hash changes" {
        $manifestPath = Join-Path $TestDrive "dependency-pins.json"
        $manifestText = [System.IO.File]::ReadAllText($script:DependencyManifestPath)
        $manifestText = $manifestText.Replace("aeca43f41c89b3ffb1db84011539e609ecd7cb3badd6e78fada2ada327d10a64", "0000000000000000000000000000000000000000000000000000000000000000")
        [System.IO.File]::WriteAllText($manifestPath, $manifestText)

        { & $script:DependencyAuditPath -RepoRoot $script:RepoRoot -ManifestPath $manifestPath } |
            Should -Throw "*Downloaded CLI pin changed*"
    }
}
