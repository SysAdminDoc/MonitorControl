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
        "Get-CapabilitiesSafetySettingsObject",
        "Write-CapabilitySafetyState",
        "Import-CapabilitySafetyState",
        "Test-CapabilityProbeAllowed",
        "Get-CapabilitiesSafetyStatusText",
        "Start-CapabilitiesWorker",
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

Describe "Capability discovery safety" {
    BeforeEach {
        $script:CapabilitiesSafetySchemaVersion = 1
        $script:CapabilitiesSafetySettingsPath = Join-Path $TestDrive "capabilities-safety.json"
        $script:CapabilitiesProbeSentinelPath = Join-Path $TestDrive "capabilities-probe-pending.json"
        $script:CapabilitiesConsentRecorded = $false
        $script:CapabilitiesDiscoveryEnabled = $false
        $script:CapabilitiesMaximumCompatibility = $false
        $script:CapabilitiesExcludedIdentityKeys = @{}
        $script:CapabilitiesLastIncidentIdentityKey = ""
        $script:CapabilitiesLastIncidentAt = ""
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
    }

    It "fails closed until consent and honors maximum compatibility and exclusions" {
        $monitor = [pscustomobject]@{ Handle = [IntPtr]1; IdentityKey = "edid:test-monitor" }

        Test-CapabilityProbeAllowed -Monitor $monitor | Should -BeFalse
        $script:CapabilitiesDiscoveryEnabled = $true
        Test-CapabilityProbeAllowed -Monitor $monitor | Should -BeTrue
        $script:CapabilitiesExcludedIdentityKeys[$monitor.IdentityKey] = $true
        Test-CapabilityProbeAllowed -Monitor $monitor | Should -BeFalse
        $script:CapabilitiesExcludedIdentityKeys = @{}
        $script:CapabilitiesMaximumCompatibility = $true
        Test-CapabilityProbeAllowed -Monitor $monitor | Should -BeFalse
    }

    It "disables discovery and excludes the pending identity after an interrupted probe" {
        Set-Content -LiteralPath $script:CapabilitiesSafetySettingsPath -Encoding UTF8 -Value '{"SchemaVersion":1,"ConsentRecorded":true,"DiscoveryEnabled":true,"MaximumCompatibility":false,"ExcludedIdentityKeys":[]}'
        Set-Content -LiteralPath $script:CapabilitiesProbeSentinelPath -Encoding UTF8 -Value '{"SchemaVersion":1,"IdentityKey":"edid:crash-monitor","MonitorName":"Test","StartedAtUtc":"2026-07-29T12:00:00.0000000Z"}'

        Import-CapabilitySafetyState

        $script:CapabilitiesDiscoveryEnabled | Should -BeFalse
        $script:CapabilitiesConsentRecorded | Should -BeTrue
        $script:CapabilitiesExcludedIdentityKeys.ContainsKey("edid:crash-monitor") | Should -BeTrue
        Test-Path -LiteralPath $script:CapabilitiesProbeSentinelPath | Should -BeFalse
        (Get-Content -LiteralPath $script:CapabilitiesSafetySettingsPath -Raw | ConvertFrom-Json).LastIncidentIdentityKey | Should -Be "edid:crash-monitor"
    }

    It "uses maximum compatibility for unknown future settings" {
        Set-Content -LiteralPath $script:CapabilitiesSafetySettingsPath -Encoding UTF8 -Value '{"SchemaVersion":99,"ConsentRecorded":true,"DiscoveryEnabled":true,"MaximumCompatibility":false}'

        Import-CapabilitySafetyState

        $script:CapabilitiesDiscoveryEnabled | Should -BeFalse
        $script:CapabilitiesMaximumCompatibility | Should -BeTrue
        Get-CapabilitiesSafetyStatusText | Should -Match "Maximum compatibility"
    }

    It "persists the crash sentinel before invoking monitor firmware" {
        $definition = (Get-Command Start-CapabilitiesWorker).Definition
        $markerIndex = $definition.IndexOf('[System.IO.File]::Move($sentinelTempPath, $SentinelPath)')
        $firmwareIndex = $definition.IndexOf('[MonitorAPI]::GetCapabilitiesStringLength')

        $markerIndex | Should -BeGreaterThan -1
        $firmwareIndex | Should -BeGreaterThan $markerIndex
        $definition | Should -Match 'finally\s*\{'
        $definition | Should -Match 'Remove-Item -LiteralPath \$SentinelPath'
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

Describe "Modern control-center shell" {
    BeforeAll {
        $appText = Get-Content -LiteralPath $script:AppPath -Raw
        $xamlMatch = [regex]::Match($appText, '(?s)\[xml\]\$xaml = @"\r?\n(.*?)\r?\n"@')
        if (-not $xamlMatch.Success) { throw "Main XAML block not found." }
        [xml]$script:MainXaml = $xamlMatch.Groups[1].Value
    }

    It "keeps every primary destination in the persistent navigation" {
        $tabs = @($script:MainXaml.SelectNodes("//*[local-name()='TabItem']"))

        $tabs.Count | Should -Be 7
        ($tabs.Header -join "|") | Should -Be "Display|Monitor|Hardware|VCP Explorer|Profiles|Automation|System"
    }

    It "keeps one display-layout canvas and a widescreen DPI-aware window" {
        @($script:MainXaml.SelectNodes("//*[@*[local-name()='Name']='MonitorCanvas']")).Count | Should -Be 1
        $window = $script:MainXaml.DocumentElement
        [int]$window.Width | Should -BeGreaterOrEqual 1000
        [int]$window.MinWidth | Should -BeGreaterOrEqual 900
        $window.GetAttribute("TextOptions.TextRenderingMode") | Should -Be "ClearType"
    }
}

Describe "Unsigned release packaging" {
    BeforeAll {
        $script:BuildReleasePath = Join-Path $script:RepoRoot "tools\build-release.ps1"
        $script:BuildReleaseText = Get-Content -LiteralPath $script:BuildReleasePath -Raw
    }

    It "cannot invoke Authenticode signing" {
        $script:BuildReleaseText | Should -Not -Match "Set-AuthenticodeSignature"
        $script:BuildReleaseText | Should -Match "intentionally not code signed"
    }

    It "packages the screenshot referenced by the README" {
        $script:BuildReleaseText | Should -Match 'Copy-Item -LiteralPath \$screenshotPath'
    }
}
