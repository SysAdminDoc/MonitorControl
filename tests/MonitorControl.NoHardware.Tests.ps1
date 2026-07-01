BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:AppPath = Join-Path $script:RepoRoot "MonitorControlPro.ps1"

    function Import-MonitorControlFunctions {
        param([string[]]$Name)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AppPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($functionName in $Name) {
            $functionAst = @($functions | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1)
            if (-not $functionAst) { throw "Function not found: $functionName" }
            . ([scriptblock]::Create("function global:$($functionAst.Name) $($functionAst.Body.Extent.Text)"))
        }
    }

    function Update-Status {
        param([string]$Message)
        $script:LastStatusMessage = $Message
    }

    Import-MonitorControlFunctions -Name @(
        "Set-DeferredStatus",
        "Test-JsonFileValid",
        "Move-CorruptJsonFile",
        "Read-JsonFileSafely",
        "Write-JsonFileSafely",
        "Get-SafeProfileName",
        "Get-CapabilitiesSection",
        "Get-HexTokens",
        "ConvertFrom-MonitorCapabilities",
        "Test-MonitorSupportsVcp",
        "Test-MonitorSupportsVcpValue",
        "ConvertTo-VcpCode",
        "ConvertTo-VcpValue",
        "Normalize-ScheduleTime",
        "Get-ScheduleMinutes",
        "Get-ActiveScheduleRule",
        "Get-IdleSecondsFromTicks"
    )
}

Describe "Profile filename validation" {
    BeforeEach {
        $script:ProfileMetadataFiles = @("profile-storage.json", "automation-bridge.json")
    }

    It "accepts plain profile names and strips the .json extension" {
        Get-SafeProfileName -Name " Night Mode.json " | Should -Be "Night Mode"
    }

    It "rejects paths, invalid characters, trailing dots, and metadata files" {
        Get-SafeProfileName -Name "..\Night" | Should -Be ""
        Get-SafeProfileName -Name "Night:Mode" | Should -Be ""
        Get-SafeProfileName -Name "Night." | Should -Be ""
        Get-SafeProfileName -Name "automation-bridge.json" | Should -Be ""
    }
}

Describe "Safe JSON storage" {
    BeforeEach {
        $script:PendingStatusMessage = ""
        $script:LastStatusMessage = ""
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
    }

    It "quarantines corrupt JSON and falls back to a valid backup" {
        $path = Join-Path $TestDrive "profile.json"
        Set-Content -LiteralPath $path -Value "{bad" -Encoding ASCII
        Set-Content -LiteralPath "$path.bak" -Value '{"Brightness":65}' -Encoding ASCII

        $result = Read-JsonFileSafely -Path $path -Label "Profile"

        $result.Brightness | Should -Be 65
        Test-Path -LiteralPath $path | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter "profile.json.corrupt-*").Count | Should -Be 1
        $script:PendingStatusMessage | Should -Match "loaded backup"
    }

    It "replaces a corrupt target and keeps the corrupt file quarantined" {
        $path = Join-Path $TestDrive "profile.json"
        Set-Content -LiteralPath $path -Value "{bad" -Encoding ASCII

        Write-JsonFileSafely -Path $path -Data ([pscustomobject]@{ Brightness = 72; Contrast = 48 }) | Should -BeTrue

        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $saved.Brightness | Should -Be 72
        $saved.Contrast | Should -Be 48
        @(Get-ChildItem -LiteralPath $TestDrive -Filter "profile.json.corrupt-*").Count | Should -Be 1
    }
}

Describe "Monitor capabilities parsing" {
    It "parses VCP codes and nested value lists from a capabilities string" {
        $capabilities = "prot(monitor)type(LCD)vcp(10 12 14(05 08 0B) 60(0F 10 11 12) D6(01 04 05) E9(00 21 23))"

        $parsed = ConvertFrom-MonitorCapabilities -Capabilities $capabilities

        $parsed.Known | Should -BeTrue
        $parsed.Codes.ContainsKey(0x10) | Should -BeTrue
        $parsed.Codes.ContainsKey(0x60) | Should -BeTrue
        @($parsed.Codes[0x14]) | Should -Contain 0x05
        @($parsed.Codes[0xE9]) | Should -Contain 0x23
    }

    It "reports unknown capabilities when no vcp section exists" {
        $parsed = ConvertFrom-MonitorCapabilities -Capabilities "prot(monitor)type(LCD)"

        $parsed.Known | Should -BeFalse
        $parsed.Count | Should -Be 0
    }

    It "checks code and value support from parsed capabilities" {
        $parsed = ConvertFrom-MonitorCapabilities -Capabilities "vcp(10 60(0F 11 12))"
        $monitor = [pscustomobject]@{ CapabilitiesKnown = $true; SupportedVcpCodes = $parsed.Codes }

        Test-MonitorSupportsVcp -Monitor $monitor -Code 0x10 | Should -BeTrue
        Test-MonitorSupportsVcp -Monitor $monitor -Code 0xD6 | Should -BeFalse
        Test-MonitorSupportsVcpValue -Monitor $monitor -Code 0x60 -Value 0x11 | Should -BeTrue
        Test-MonitorSupportsVcpValue -Monitor $monitor -Code 0x60 -Value 0x13 | Should -BeFalse
    }
}

Describe "VCP parser helpers" {
    It "accepts decimal and hexadecimal byte-sized VCP codes" {
        ConvertTo-VcpCode -Text "0xD6" | Should -Be 214
        ConvertTo-VcpCode -Text "214" | Should -Be 214
        ConvertTo-VcpCode -Text "0" | Should -Be 0
    }

    It "rejects malformed or out-of-range VCP codes" {
        $badText = ConvertTo-VcpCode -Text "banana"
        $tooLarge = ConvertTo-VcpCode -Text "0x100"
        $negative = ConvertTo-VcpCode -Text "-1"

        $badText | Should -BeNullOrEmpty
        $tooLarge | Should -BeNullOrEmpty
        $negative | Should -BeNullOrEmpty
    }

    It "accepts unsigned VCP values and rejects invalid values" {
        ConvertTo-VcpValue -Text "0" | Should -Be 0
        (ConvertTo-VcpValue -Text "4294967295").ToString() | Should -Be "4294967295"

        $negative = ConvertTo-VcpValue -Text "-1"
        $badText = ConvertTo-VcpValue -Text "12.5"
        $negative | Should -BeNullOrEmpty
        $badText | Should -BeNullOrEmpty
    }
}

Describe "Scheduled profile rollover" {
    BeforeEach {
        $script:ProfileSchedules = @(
            [pscustomobject]@{ Time = "06:30"; Profile = "Morning" },
            [pscustomobject]@{ Time = "12:00"; Profile = "Work" },
            [pscustomobject]@{ Time = "22:00"; Profile = "Night" }
        )
    }

    It "normalizes valid times and rejects invalid times" {
        Normalize-ScheduleTime -TimeText "6:05" | Should -Be "06:05"
        Normalize-ScheduleTime -TimeText "24:00" | Should -Be ""
        Get-ScheduleMinutes -TimeText "06:30" | Should -Be 390
    }

    It "uses the previous day's final rule before the first rule of the day" {
        $active = Get-ActiveScheduleRule -Now ([datetime]"2026-07-01T05:15:00")

        $active.Rule.Profile | Should -Be "Night"
        $active.Key | Should -Be "2026-06-30 22:00|Night"
    }

    It "uses the latest due same-day rule at and after a boundary" {
        $active = Get-ActiveScheduleRule -Now ([datetime]"2026-07-01T12:30:00")

        $active.Rule.Profile | Should -Be "Work"
        $active.Key | Should -Be "2026-07-01 12:00|Work"
    }
}

Describe "Idle tick wraparound" {
    It "computes idle seconds without tick wraparound" {
        Get-IdleSecondsFromTicks -CurrentTick 10000 -LastInputTick 4000 | Should -Be 6
    }

    It "computes idle seconds across the 32-bit tick counter rollover" {
        $lastInput = [uint32]::MaxValue - 2000

        Get-IdleSecondsFromTicks -CurrentTick 3000 -LastInputTick $lastInput | Should -Be 5
    }
}
