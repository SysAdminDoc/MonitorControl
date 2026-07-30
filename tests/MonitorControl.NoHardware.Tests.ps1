BeforeAll {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
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

    function Update-ProfilesList {}

    Import-MonitorControlFunctions -Name @(
        "Set-DeferredStatus",
        "Test-JsonFileValid",
        "Move-CorruptJsonFile",
        "Read-JsonFileSafely",
        "Write-JsonFileSafely",
        "Get-SafeProfileName",
        "Get-UserProfileFiles",
        "Get-ProfilePropertyValue",
        "Get-ProfileIntValue",
        "ConvertTo-CurrentProfileSchema",
        "Save-ProfileObject",
        "Read-ProfileObject",
        "Test-ProfileBundleEntryPath",
        "Read-ProfileBundleEntryContent",
        "Get-ByteSha256Hex",
        "Get-FileSha256Hex",
        "Test-ProfileBundleIntegerValue",
        "Test-ProfileBundleTextValue",
        "Test-ProfileBundleNumberProperty",
        "Test-ImportedProfileObject",
        "Get-ProfileBundleImportPlan",
        "Format-ProfileBundleImportPreview",
        "Invoke-ProfileBundleImportCommit",
        "Export-ProfileBundle",
        "Import-ProfileBundle",
        "Get-CapabilitiesSection",
        "Get-HexTokens",
        "ConvertFrom-MonitorCapabilities",
        "Get-DisplayRecoveryBackoffDelay",
        "Get-DisplayRecoveryReadRetryCount",
        "Get-DisplayRecoveryTransition",
        "Test-DisplayWorkerResultCurrent",
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
        "Test-VcpWriteRequiresSafetyConsent",
        "Get-VcpWriteSafetySettingsObject",
        "Write-VcpWriteSafetyState",
        "Import-VcpWriteSafetyState",
        "Test-VcpWriteEnabledForMonitor",
        "Set-VcpWriteEnabledForMonitor",
        "Set-ControlVcpSupport",
        "Get-VcpWriteOperation",
        "Invoke-VerifiedVcpTransaction",
        "Get-VcpDescription",
        "Format-VcpWriteConfirmation",
        "New-AutomationBridgeApiKey",
        "Protect-AutomationBridgeApiKey",
        "Unprotect-AutomationBridgeApiKey",
        "Get-AutomationBridgeSettingsObject",
        "Save-AutomationBridgeSettings",
        "Load-AutomationBridgeSettings",
        "Resolve-AutomationBridgeIPAddress",
        "Test-AutomationBridgeLoopback",
        "New-AutomationBridgeResponse",
        "Get-AutomationBridgeBodyJson",
        "Get-AutomationBridgeInputValue",
        "Test-AutomationBridgeToken",
        "Test-AutomationBridgeRequestAuthorized",
        "Test-AutomationBridgePayloadCredential",
        "ConvertTo-AutomationBridgeAuditEntry",
        "Convert-AutomationBridgeAuditFile",
        "Initialize-AutomationBridgeAuditLog",
        "Write-AutomationBridgeWriteLog",
        "Invoke-AutomationBridgeRequest",
        "Process-AutomationBridgeRequests",
        "Get-AutomationBridgeWorkerScript",
        "Normalize-ScheduleTime",
        "Get-ScheduleMinutes",
        "Get-ActiveScheduleRule",
        "Get-IdleSecondsFromTicks"
    )

    function Start-TestAutomationBridge {
        param(
            [int]$MaxRequestLineBytes = 128,
            [int]$MaxHeaderBytes = 512,
            [int]$MaxHeaderCount = 8,
            [int]$MaxBodyBytes = 128,
            [int]$MaxConcurrentClients = 2,
            [int]$ReadTimeoutMs = 300,
            [int]$WriteTimeoutMs = 300
        )
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $requests = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $responses = [hashtable]::Synchronized(@{})
        $state = [hashtable]::Synchronized(@{
            Stop = $false
            ActiveClients = 0
            PeakActiveClients = 0
            RejectedClients = 0
            WriteFailureCount = 0
            HandlerFailureCount = 0
            LastReadTimeoutMs = 0
            LastWriteTimeoutMs = 0
        })
        $settings = [PSCustomObject]@{
            Listener = $listener
            ApiKey = "0123456789abcdef0123456789abcdef"
            MaxRequestLineBytes = $MaxRequestLineBytes
            MaxHeaderBytes = $MaxHeaderBytes
            MaxHeaderCount = $MaxHeaderCount
            MaxQueryParameterCount = 8
            MaxBodyBytes = $MaxBodyBytes
            MaxResponseBytes = 8192
            MaxConcurrentClients = $MaxConcurrentClients
            ReadTimeoutMs = $ReadTimeoutMs
            WriteTimeoutMs = $WriteTimeoutMs
            RouteTimeoutMs = 1000
        }

        $workerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $workerInput.Complete()
        $workerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $workerPowerShell = [PowerShell]::Create()
        $workerScript = Get-AutomationBridgeWorkerScript
        $workerPowerShell.AddScript($workerScript.ToString()).AddArgument($settings).AddArgument($requests).AddArgument($responses).AddArgument($state) | Out-Null
        $workerAsync = $workerPowerShell.BeginInvoke($workerInput, $workerOutput)

        $responderInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $responderInput.Complete()
        $responderOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $responderPowerShell = [PowerShell]::Create()
        $responderScript = {
            param($Requests, $Responses, $State)
            while (-not [bool]$State["Stop"]) {
                $request = $null
                if ($Requests.TryDequeue([ref]$request)) {
                    $Responses[$request.Id] = [PSCustomObject]@{
                        Status = 200
                        Body = @{ accepted = $true; path = [string]$request.Path }
                    }
                } else {
                    Start-Sleep -Milliseconds 10
                }
            }
        }
        $responderPowerShell.AddScript($responderScript.ToString()).AddArgument($requests).AddArgument($responses).AddArgument($state) | Out-Null
        $responderAsync = $responderPowerShell.BeginInvoke($responderInput, $responderOutput)

        Start-Sleep -Milliseconds 75
        return [PSCustomObject]@{
            Port = $port
            ApiKey = [string]$settings.ApiKey
            Listener = $listener
            State = $state
            WorkerPowerShell = $workerPowerShell
            WorkerAsync = $workerAsync
            WorkerInput = $workerInput
            WorkerOutput = $workerOutput
            ResponderPowerShell = $responderPowerShell
            ResponderAsync = $responderAsync
            ResponderInput = $responderInput
            ResponderOutput = $responderOutput
        }
    }

    function Stop-TestAutomationBridge {
        param($Server)
        if ($null -eq $Server) { return }
        $Server.State["Stop"] = $true
        try { $Server.Listener.Stop() } catch { $null = $_ }
        foreach ($entry in @(
            [PSCustomObject]@{ PowerShell = $Server.WorkerPowerShell; Async = $Server.WorkerAsync },
            [PSCustomObject]@{ PowerShell = $Server.ResponderPowerShell; Async = $Server.ResponderAsync }
        )) {
            if ($null -eq $entry.PowerShell) { continue }
            try {
                if (-not $entry.Async.AsyncWaitHandle.WaitOne(3000)) { $entry.PowerShell.Stop() }
                $entry.PowerShell.EndInvoke($entry.Async) | Out-Null
            } catch { $null = $_ }
            $entry.PowerShell.Dispose()
        }
        foreach ($collection in @($Server.WorkerInput, $Server.WorkerOutput, $Server.ResponderInput, $Server.ResponderOutput)) {
            if ($null -ne $collection) { $collection.Dispose() }
        }
    }

    function Invoke-RawAutomationBridgeRequest {
        param(
            $Server,
            [string]$Request,
            [switch]$ShutdownSend,
            [int]$TimeoutMs = 3000
        )
        $client = [System.Net.Sockets.TcpClient]::new()
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        try {
            $client.Connect([System.Net.IPAddress]::Loopback, [int]$Server.Port)
            $stream = $client.GetStream()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Request)
            if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
            if ($ShutdownSend) { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) }
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        } finally {
            $client.Close()
        }
    }

    function New-TestProfilePayload {
        param([string]$Name, $Brightness = 50)
        return [PSCustomObject]@{
            SchemaVersion = 3
            Name = $Name
            MonitorIdentityKey = "edid:test"
            MonitorLabel = "Test display"
            MonitorName = "Test monitor"
            MonitorDevicePath = "DISPLAY\TEST"
            MonitorSettings = @()
            Brightness = $Brightness
            Contrast = 50
            Red = 50
            Green = 50
            Blue = 50
            Gamma = 100
            GammaRed = 100
            GammaGreen = 100
            GammaBlue = 100
            UpdatedAt = "2026-07-29T12:00:00Z"
        }
    }

    function Add-TestZipTextEntry {
        param($Archive, [string]$Name, [string]$Text)
        $entry = $Archive.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
        return $entry
    }

    function New-TestProfileBundle {
        param(
            [string]$Path,
            [System.Collections.IDictionary]$Profiles,
            $ManifestOverride = $null,
            [System.Collections.IDictionary]$ExtraEntries = $null
        )
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $declarations = @()
            foreach ($name in $Profiles.Keys) {
                $profile = $Profiles[$name]
                $text = if ($profile -is [string]) { $profile } else { (($profile | ConvertTo-Json -Depth 6) + [Environment]::NewLine) }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                Add-TestZipTextEntry -Archive $archive -Name "profiles/$name.json" -Text $text | Out-Null
                $declarations += [PSCustomObject]@{
                    Name = [string]$name
                    File = "profiles/$name.json"
                    Sha256 = Get-ByteSha256Hex -Bytes $bytes
                    UncompressedBytes = $bytes.Length
                }
            }
            $manifest = if ($null -ne $ManifestOverride) {
                $ManifestOverride
            } else {
                [PSCustomObject]@{
                    BundleSchemaVersion = 2
                    AppVersion = "3.34.0"
                    ProfileSchemaVersion = 3
                    ExportedAt = "2026-07-29T12:00:00Z"
                    ProfileCount = $declarations.Count
                    Profiles = @($declarations)
                }
            }
            Add-TestZipTextEntry -Archive $archive -Name "manifest.json" -Text (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine) | Out-Null
            if ($null -ne $ExtraEntries) {
                foreach ($name in $ExtraEntries.Keys) {
                    Add-TestZipTextEntry -Archive $archive -Name ([string]$name) -Text ([string]$ExtraEntries[$name]) | Out-Null
                }
            }
        } finally {
            $archive.Dispose()
        }
        return $Path
    }
}

Describe "Profile filename validation" {
    BeforeEach {
        $script:ProfileMetadataFiles = @("profile-storage.json", "automation-bridge.json", "vcp-write-safety.json")
    }

    It "accepts plain profile names and strips the .json extension" {
        Get-SafeProfileName -Name " Night Mode.json " | Should -Be "Night Mode"
    }

    It "rejects paths, invalid characters, trailing dots, and metadata files" {
        Get-SafeProfileName -Name "..\Night" | Should -Be ""
        Get-SafeProfileName -Name "Night:Mode" | Should -Be ""
        Get-SafeProfileName -Name "Night." | Should -Be ""
        Get-SafeProfileName -Name "CON.json" | Should -Be ""
        Get-SafeProfileName -Name "automation-bridge.json" | Should -Be ""
        Get-SafeProfileName -Name "vcp-write-safety.json" | Should -Be ""
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

Describe "Transactional profile bundle import" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:ProfilesPath = Join-Path $TestDrive "profiles"
        $script:ProfileExportsPath = Join-Path $TestDrive "exports"
        New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null
        $script:ProfileSchemaVersion = 3
        $script:ProfileBundleSchemaVersion = 2
        $script:ProfileBundleMaxProfiles = 100
        $script:ProfileBundleMaxArchiveBytes = 16777216
        $script:ProfileBundleMaxManifestBytes = 65536
        $script:ProfileBundleMaxEntryBytes = 262144
        $script:ProfileBundleMaxTotalBytes = 10485760
        $script:ProfileBundleMaxCompressionRatio = 100
        $script:ProfileBundleMaxMonitorSettings = 32
        $script:ProfileMetadataFiles = @("profile-storage.json", "automation-bridge.json", "vcp-write-safety.json")
        $script:LastStatusMessage = ""
    }

    It "plans creates and replacements and can skip conflicts explicitly" {
        $alphaPath = Join-Path $script:ProfilesPath "Alpha.json"
        [System.IO.File]::WriteAllText($alphaPath, '{"original":"alpha"}', [System.Text.Encoding]::UTF8)
        $originalAlpha = [System.IO.File]::ReadAllBytes($alphaPath)
        $bundlePath = Join-Path $TestDrive "valid.zip"
        New-TestProfileBundle -Path $bundlePath -Profiles ([ordered]@{
            Alpha = New-TestProfilePayload -Name "Alpha" -Brightness 70
            Beta = New-TestProfilePayload -Name "Beta" -Brightness 40
        }) | Out-Null

        $plan = Get-ProfileBundleImportPlan -BundlePath $bundlePath

        $plan.Valid | Should -BeTrue -Because "$($plan.ErrorCode): $($plan.Message)"
        @($plan.Items | Where-Object Action -eq "Create").Name | Should -Be "Beta"
        @($plan.Items | Where-Object Action -eq "Replace").Name | Should -Be "Alpha"
        $skipPreview = Format-ProfileBundleImportPreview -Plan $plan -ConflictMode Skip
        $skipPreview | Should -Match "Create \(1\): Beta"
        $skipPreview | Should -Match "Skip \(1\): Alpha"
        Import-ProfileBundle -BundlePath $bundlePath -ConflictMode Skip | Should -Be 1
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($alphaPath)) | Should -Be ([Convert]::ToBase64String($originalAlpha))
        (Get-Content -LiteralPath (Join-Path $script:ProfilesPath "Beta.json") -Raw | ConvertFrom-Json).Name | Should -Be "Beta"
        Import-ProfileBundle -BundlePath $bundlePath -ConflictMode Replace | Should -Be 2
        (Get-Content -LiteralPath $alphaPath -Raw | ConvertFrom-Json).Brightness | Should -Be 70
    }

    It "exports a manifest-declared checksummed bundle that round-trips through validation" {
        foreach ($name in @("Alpha", "Beta")) {
            $profile = New-TestProfilePayload -Name $name
            [System.IO.File]::WriteAllText(
                (Join-Path $script:ProfilesPath "$name.json"),
                (($profile | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
                [System.Text.Encoding]::UTF8
            )
        }
        $bundlePath = Join-Path $TestDrive "exported.zip"

        Export-ProfileBundle -OutputPath $bundlePath | Should -Be $bundlePath
        $script:ProfilesPath = Join-Path $TestDrive "empty-destination"
        New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null
        $plan = Get-ProfileBundleImportPlan -BundlePath $bundlePath

        $plan.Valid | Should -BeTrue -Because "$($plan.ErrorCode): $($plan.Message)"
        $plan.BundleSchemaVersion | Should -Be 2
        $plan.Items.Count | Should -Be 2
        @($plan.Items | Where-Object Action -eq "Create").Count | Should -Be 2
    }

    It "rejects path traversal and undeclared archive files" {
        $profile = New-TestProfilePayload -Name "Alpha"
        $traversalPath = Join-Path $TestDrive "traversal.zip"
        New-TestProfileBundle -Path $traversalPath -Profiles ([ordered]@{ Alpha = $profile }) -ExtraEntries ([ordered]@{ "../outside.json" = "{}" }) | Out-Null
        $undeclaredPath = Join-Path $TestDrive "undeclared.zip"
        New-TestProfileBundle -Path $undeclaredPath -Profiles ([ordered]@{ Alpha = $profile }) -ExtraEntries ([ordered]@{ "profiles/Extra.json" = "{}" }) | Out-Null

        (Get-ProfileBundleImportPlan -BundlePath $traversalPath).ErrorCode | Should -Be "unsafe_entry_path"
        (Get-ProfileBundleImportPlan -BundlePath $undeclaredPath).ErrorCode | Should -Be "undeclared_entry"
        Test-Path -LiteralPath (Join-Path $TestDrive "outside.json") | Should -BeFalse
    }

    It "rejects duplicate destinations and unsupported schemas" {
        $duplicateManifest = [PSCustomObject]@{
            BundleSchemaVersion = 2
            ProfileSchemaVersion = 3
            ProfileCount = 2
            Profiles = @(
                [PSCustomObject]@{ Name = "Alpha"; File = "profiles/Alpha.json"; Sha256 = ("0" * 64); UncompressedBytes = 1 },
                [PSCustomObject]@{ Name = "Alpha"; File = "profiles/Alpha.json"; Sha256 = ("0" * 64); UncompressedBytes = 1 }
            )
        }
        $duplicatePath = Join-Path $TestDrive "duplicate.zip"
        New-TestProfileBundle -Path $duplicatePath -Profiles ([ordered]@{ Alpha = New-TestProfilePayload -Name "Alpha" }) -ManifestOverride $duplicateManifest | Out-Null
        $futureManifest = [PSCustomObject]@{
            BundleSchemaVersion = 99
            ProfileSchemaVersion = 3
            ProfileCount = 0
            Profiles = @()
        }
        $futurePath = Join-Path $TestDrive "future.zip"
        New-TestProfileBundle -Path $futurePath -Profiles ([ordered]@{}) -ManifestOverride $futureManifest | Out-Null

        (Get-ProfileBundleImportPlan -BundlePath $duplicatePath).ErrorCode | Should -Be "duplicate_destination"
        (Get-ProfileBundleImportPlan -BundlePath $futurePath).ErrorCode | Should -Be "unsupported_bundle_schema"
    }

    It "rejects invalid profile types and out-of-range values" {
        $badType = New-TestProfilePayload -Name "BadType" -Brightness "50"
        $badRange = New-TestProfilePayload -Name "BadRange" -Brightness 101
        $typePath = Join-Path $TestDrive "bad-type.zip"
        $rangePath = Join-Path $TestDrive "bad-range.zip"
        New-TestProfileBundle -Path $typePath -Profiles ([ordered]@{ BadType = $badType }) | Out-Null
        New-TestProfileBundle -Path $rangePath -Profiles ([ordered]@{ BadRange = $badRange }) | Out-Null

        (Get-ProfileBundleImportPlan -BundlePath $typePath).ErrorCode | Should -Be "invalid_profile"
        (Get-ProfileBundleImportPlan -BundlePath $rangePath).ErrorCode | Should -Be "invalid_profile"
    }

    It "enforces archive size, entry count, and compression-ratio limits" {
        $profile = New-TestProfilePayload -Name "Alpha"
        $sizePath = Join-Path $TestDrive "size.zip"
        New-TestProfileBundle -Path $sizePath -Profiles ([ordered]@{ Alpha = $profile }) | Out-Null
        $script:ProfileBundleMaxArchiveBytes = 10
        (Get-ProfileBundleImportPlan -BundlePath $sizePath).ErrorCode | Should -Be "archive_too_large"
        $script:ProfileBundleMaxArchiveBytes = 16777216

        $manyEntries = [ordered]@{}
        1..103 | ForEach-Object { $manyEntries["extra-$_.txt"] = "x" }
        $countPath = Join-Path $TestDrive "count.zip"
        New-TestProfileBundle -Path $countPath -Profiles ([ordered]@{}) -ExtraEntries $manyEntries | Out-Null
        (Get-ProfileBundleImportPlan -BundlePath $countPath).ErrorCode | Should -Be "too_many_entries"

        $ratioPath = Join-Path $TestDrive "ratio.zip"
        New-TestProfileBundle -Path $ratioPath -Profiles ([ordered]@{}) -ExtraEntries ([ordered]@{ "payload.bin" = ("A" * 200000) }) | Out-Null
        (Get-ProfileBundleImportPlan -BundlePath $ratioPath).ErrorCode | Should -Be "entry_limit"
    }

    It "rolls back byte-for-byte when a staged commit fails" {
        $alphaPath = Join-Path $script:ProfilesPath "Alpha.json"
        $betaPath = Join-Path $script:ProfilesPath "Beta.json"
        [System.IO.File]::WriteAllText($alphaPath, "original-alpha-bytes", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($betaPath, "original-beta-bytes", [System.Text.Encoding]::UTF8)
        $alphaBefore = [System.IO.File]::ReadAllBytes($alphaPath)
        $betaBefore = [System.IO.File]::ReadAllBytes($betaPath)
        $bundlePath = Join-Path $TestDrive "rollback.zip"
        New-TestProfileBundle -Path $bundlePath -Profiles ([ordered]@{
            Alpha = New-TestProfilePayload -Name "Alpha" -Brightness 10
            Beta = New-TestProfilePayload -Name "Beta" -Brightness 90
        }) | Out-Null
        $plan = Get-ProfileBundleImportPlan -BundlePath $bundlePath

        $result = Invoke-ProfileBundleImportCommit -Plan $plan -ConflictMode Replace -AfterCommit {
            param($count, $item)
            if ($count -eq 1) { throw "simulated commit failure" }
        }

        $result.Success | Should -BeFalse
        $result.ErrorCode | Should -Be "commit_failed"
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($alphaPath)) | Should -Be ([Convert]::ToBase64String($alphaBefore))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($betaPath)) | Should -Be ([Convert]::ToBase64String($betaBefore))
        @(Get-ChildItem -LiteralPath $script:ProfilesPath -Directory -Filter ".profile-import-*").Count | Should -Be 0
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

Describe "Display recovery generation and identity safety" {
    BeforeEach {
        $script:DisplayRecoveryOfflineThreshold = 4
    }

    It "uses bounded exponential backoff and increases read retries after repeated identity failures" {
        (Get-DisplayRecoveryBackoffDelay -FailureCount 0) | Should -Be 0
        (Get-DisplayRecoveryBackoffDelay -FailureCount 1) | Should -Be 750
        (Get-DisplayRecoveryBackoffDelay -FailureCount 2) | Should -Be 1500
        (Get-DisplayRecoveryBackoffDelay -FailureCount 6) | Should -Be 24000
        (Get-DisplayRecoveryBackoffDelay -FailureCount 12) | Should -Be 30000

        (Get-DisplayRecoveryReadRetryCount -State ([PSCustomObject]@{ ConsecutiveFailures = 0 }) -DefaultRetries 2) | Should -Be 2
        (Get-DisplayRecoveryReadRetryCount -State ([PSCustomObject]@{ ConsecutiveFailures = 4 }) -DefaultRetries 2) | Should -Be 4
        (Get-DisplayRecoveryReadRetryCount -State ([PSCustomObject]@{ ConsecutiveFailures = 20 }) -DefaultRetries 2) | Should -Be 5
    }

    It "moves one stable identity through stale retrying offline and fresh states" {
        $clock = [DateTime]::Parse("2026-07-29T12:00:00Z").ToUniversalTime()
        $state = Get-DisplayRecoveryTransition -IdentityKey "edid:a" -PreviousState $null -Outcome "Enumerated" -NowUtc $clock -Generation 3
        $state.Status | Should -Be "Retrying"

        1..3 | ForEach-Object {
            $state = Get-DisplayRecoveryTransition -IdentityKey "edid:a" -PreviousState $state -Outcome "Failure" -NowUtc $clock.AddSeconds($_) -Generation 3 -ErrorMessage "read failed"
        }
        $state.Status | Should -Be "Retrying"
        $state.ConsecutiveFailures | Should -Be 3
        $state = Get-DisplayRecoveryTransition -IdentityKey "edid:a" -PreviousState $state -Outcome "Failure" -NowUtc $clock.AddSeconds(4) -Generation 3 -ErrorMessage "read failed"
        $state.Status | Should -Be "Offline"
        $state.NextRetryUtc | Should -BeGreaterThan $clock.AddSeconds(4)

        $state = Get-DisplayRecoveryTransition -IdentityKey "edid:a" -PreviousState $state -Outcome "Success" -NowUtc $clock.AddSeconds(10) -Generation 3
        $state.Status | Should -Be "Fresh"
        $state.ConsecutiveFailures | Should -Be 0
        $state.LastSuccessUtc | Should -Be $clock.AddSeconds(10)
    }

    It "rejects obsolete workers and same-slot results from a different display" {
        $monitors = @(
            [PSCustomObject]@{ IdentityKey = "edid:a"; Handle = [IntPtr]101 },
            [PSCustomObject]@{ IdentityKey = "edid:b"; Handle = [IntPtr]202 }
        )
        $result = [PSCustomObject]@{
            Generation = 8
            MonitorIndex = 0
            IdentityKey = "edid:a"
            HandleValue = [int64]101
        }
        (Test-DisplayWorkerResultCurrent -Result $result -CurrentGeneration 8 -Monitors $monitors) | Should -BeTrue
        (Test-DisplayWorkerResultCurrent -Result $result -CurrentGeneration 9 -Monitors $monitors) | Should -BeFalse

        $replacement = @([PSCustomObject]@{ IdentityKey = "edid:replacement"; Handle = [IntPtr]101 })
        (Test-DisplayWorkerResultCurrent -Result $result -CurrentGeneration 8 -Monitors $replacement) | Should -BeFalse

        $replacement[0].IdentityKey = "edid:a"
        $replacement[0].Handle = [IntPtr]303
        (Test-DisplayWorkerResultCurrent -Result $result -CurrentGeneration 8 -Monitors $replacement) | Should -BeFalse
    }

    It "wires display device resume and WMI events through one debounced request path" {
        $source = Get-Content -LiteralPath $script:AppPath -Raw
        $source | Should -Match '0x007E \{ \$reason = "display-change" \}'
        $source | Should -Match '0x0219 \{ \$reason = "device-change" \}'
        $source | Should -Match '\$powerEvent -in @\(0x0006, 0x0007, 0x0012\)'
        $source | Should -Match 'WmiMonitorBrightnessEvent'
        $source | Should -Match 'Request-DisplayRecoveryRefresh -Reason \$reason'
        $source | Should -Match '\$script:DisplayRecoveryGeneration\+\+'
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

Describe "Verified risky VCP write safety" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:VcpWriteSafetySettingsPath = Join-Path $TestDrive "vcp-write-safety.json"
        $script:VcpWriteSafetySchemaVersion = 1
        $script:RiskyVcpCodes = @(0x04, 0x08, 0x60, 0xD6, 0xE8, 0xE9)
        $script:RiskyVcpEnabledIdentityKeys = @{}
        $script:VCPCodeDescriptions = @{ 0x10 = "Brightness"; 0x12 = "Contrast"; 0x60 = "Input Source" }
        $script:PendingStatusMessage = ""
    }

    It "persists unlocks only for stable identities and fails closed on future settings" {
        $stable = [pscustomobject]@{ IdentityKey = "edid:stable"; Name = "Stable monitor" }
        $unstable = [pscustomobject]@{ IdentityKey = ""; Name = "Unknown monitor" }

        Test-VcpWriteEnabledForMonitor -Monitor $stable | Should -BeFalse
        Set-VcpWriteEnabledForMonitor -Monitor $unstable -Enabled $true | Should -BeFalse
        Set-VcpWriteEnabledForMonitor -Monitor $stable -Enabled $true | Should -BeTrue
        Test-VcpWriteEnabledForMonitor -Monitor $stable | Should -BeTrue
        $script:RiskyVcpEnabledIdentityKeys = @{}
        Import-VcpWriteSafetyState
        Test-VcpWriteEnabledForMonitor -Monitor $stable | Should -BeTrue

        $futureJson = '{"SchemaVersion":99,"EnabledIdentityKeys":["edid:future"]}'
        Set-Content -LiteralPath $script:VcpWriteSafetySettingsPath -Encoding UTF8 -Value $futureJson
        Import-VcpWriteSafetyState

        $script:RiskyVcpEnabledIdentityKeys.Count | Should -Be 0
        (Get-Content -LiteralPath $script:VcpWriteSafetySettingsPath -Raw) | Should -Match "edid:future"
        $script:PendingStatusMessage | Should -Match "dangerous writes remain disabled"
    }

    It "classifies power, input, reset, PiP, and arbitrary commands as risky" {
        foreach ($code in @(0x04, 0x08, 0x60, 0xD6, 0xE8, 0xE9)) {
            Test-VcpWriteRequiresSafetyConsent -Code $code | Should -BeTrue
        }
        Test-VcpWriteRequiresSafetyConsent -Code 0x10 | Should -BeFalse
        Test-VcpWriteRequiresSafetyConsent -Code 0x10 -Arbitrary | Should -BeTrue

        $monitor = [pscustomobject]@{ IdentityKey = "edid:locked"; CapabilitiesKnown = $false; SupportedVcpCodes = @{} }
        $control = [pscustomobject]@{ IsEnabled = $true; ToolTip = $null }
        Set-ControlVcpSupport -Control $control -Monitor $monitor -Code 0xD6 -Value 4 -Risky
        $control.IsEnabled | Should -BeFalse
        $control.ToolTip | Should -Match "Enable risky VCP writes"
        $script:RiskyVcpEnabledIdentityKeys[$monitor.IdentityKey] = $true
        Set-ControlVcpSupport -Control $control -Monitor $monitor -Code 0xD6 -Value 4 -Risky
        $control.IsEnabled | Should -BeTrue
    }

    It "snapshots and verifies every readable value in a successful transaction" {
        $monitor = [pscustomobject]@{ Handle = [IntPtr]1; IdentityKey = "edid:test"; Name = "Test monitor" }
        $operations = @(
            Get-VcpWriteOperation -Monitor $monitor -Code 0x10 -Value 70
            Get-VcpWriteOperation -Monitor $monitor -Code 0x12 -Value 60
        )
        $state = @{ 0x10 = [uint32]20; 0x12 = [uint32]30 }
        $read = { param($operation) [pscustomobject]@{ Success = $true; Current = [uint32]$state[[int]$operation.Code] } }
        $write = { param($operation, [uint32]$value) $state[[int]$operation.Code] = $value; return $true }

        $result = Invoke-VerifiedVcpTransaction -Operations $operations -ReadValue $read -WriteValue $write -RollbackOnFailure -VerificationDelayMs 0

        $result.Success | Should -BeTrue
        $result.Outcome | Should -Be "Verified"
        @($result.Results | Where-Object PreviousReadable).Count | Should -Be 2
        @($result.Results).PreviousValue | Should -Be @(20, 30)
        $state[0x10] | Should -Be 70
        $state[0x12] | Should -Be 60
    }

    It "reports a mismatch distinctly and restores readable snapshots in reverse order" {
        $monitor = [pscustomobject]@{ Handle = [IntPtr]1; IdentityKey = "edid:test"; Name = "Test monitor" }
        $operations = @(
            Get-VcpWriteOperation -Monitor $monitor -Code 0x10 -Value 70
            Get-VcpWriteOperation -Monitor $monitor -Code 0x12 -Value 60
        )
        $state = @{ 0x10 = [uint32]20; 0x12 = [uint32]30 }
        $writes = New-Object System.Collections.Generic.List[string]
        $read = { param($operation) [pscustomobject]@{ Success = $true; Current = [uint32]$state[[int]$operation.Code] } }
        $write = {
            param($operation, [uint32]$value)
            $writes.Add("$([int]$operation.Code):$value")
            if ([int]$operation.Code -eq 0x12 -and $value -eq [uint32]$operation.Value) {
                $state[[int]$operation.Code] = $value - 1
            } else {
                $state[[int]$operation.Code] = $value
            }
            return $true
        }

        $result = Invoke-VerifiedVcpTransaction -Operations $operations -ReadValue $read -WriteValue $write -RollbackOnFailure -VerificationDelayMs 0

        $result.Success | Should -BeFalse
        $result.Outcome | Should -Be "Mismatched"
        $result.Rollback | Should -Be "Restored"
        $state[0x10] | Should -Be 20
        $state[0x12] | Should -Be 30
        @($writes)[-2..-1] | Should -Be @("18:30", "16:20")
    }

    It "distinguishes an applied write when readback becomes unavailable" {
        $monitor = [pscustomobject]@{ Handle = [IntPtr]1; IdentityKey = "edid:test"; Name = "Test monitor" }
        $operation = Get-VcpWriteOperation -Monitor $monitor -Code 0x60 -Value 0x11
        $readState = @{ Count = 0 }
        $read = {
            param($ignoredOperation)
            $readState.Count++
            return [pscustomobject]@{ Success = $readState.Count -eq 1; Current = [uint32]0x0F }
        }
        $write = { param($ignoredOperation, [uint32]$ignoredValue) return $true }

        $result = Invoke-VerifiedVcpTransaction -Operations @($operation) -ReadValue $read -WriteValue $write -VerificationDelayMs 0

        $result.Success | Should -BeTrue
        $result.Outcome | Should -Be "Unverified"
        $result.Results[0].PreviousReadable | Should -BeTrue
        $result.Results[0].Verification | Should -Be "Unverified"
    }

    It "shows the exact code and value and keeps risky codes out of automatic reports" {
        $monitor = [pscustomobject]@{ Handle = [IntPtr]1; IdentityKey = "edid:test"; Name = "Test monitor" }
        $operation = Get-VcpWriteOperation -Monitor $monitor -Code 0x60 -Value 17
        $confirmation = Format-VcpWriteConfirmation -Operations @($operation) -ActionLabel "Change input"

        $confirmation | Should -Match "VCP code: 0x60"
        $confirmation | Should -Match "Value: 17"
        $confirmation | Should -Match "blank the display"

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AppPath, [ref]$tokens, [ref]$errors)
        $reportFunction = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-DdcReportProbeCodes" }, $true))[0]
        $reportFunction.Extent.Text | Should -Not -Match "VCP_INPUT_SOURCE|VCP_POWER_MODE|VCP_RESTORE|VCP_PIP"
    }

    It "wires separate risky-write consent into application and schedule rules" {
        $source = Get-Content -LiteralPath $script:AppPath -Raw

        $source | Should -Match 'x:Name="AppProfileRiskyConsentCheckbox"'
        $source | Should -Match 'x:Name="ScheduleRiskyConsentCheckbox"'
        $source | Should -Match 'AllowRiskyAutomation:\(\[bool\]\$rule\.AllowRiskyVcp\)'
        $source | Should -Match 'AllowRiskyAutomation:\(\[bool\]\$active\.Rule\.AllowRiskyVcp\)'
    }
}

Describe "Automation bridge protected settings and routing" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:AutomationBridgeSettingsPath = Join-Path $TestDrive "automation-bridge.json"
        $script:AutomationBridgeWriteLogPath = Join-Path $TestDrive "automation-bridge-writes.jsonl"
        $script:AutomationBridgeSettingsSchemaVersion = 2
        $script:AutomationBridgeAuditLogMaxBytes = 1024
        $script:AutomationBridgeEnabled = $true
        $script:AutomationBridgeBindAddress = "127.0.0.1"
        $script:AutomationBridgePort = 34291
        $script:AutomationBridgeApiKey = "bridge-secret-0123456789abcdef"
        $script:AutomationBridgeMqttEnabled = $false
        $script:AutomationBridgeAllowedCommands = @("list", "readBrightness", "setBrightness", "loadProfile")
        $script:AutomationBridgeNetworkExposureApproved = $false
        $script:AutomationBridgeNetworkExposureApprovedFor = ""
        $script:AutomationBridgeLastError = ""
        $script:PendingStatusMessage = ""
        $script:LastStatusMessage = ""
    }

    It "stores API keys with current-user DPAPI and can unlock them" {
        Save-AutomationBridgeSettings | Should -BeTrue

        $raw = Get-Content -LiteralPath $script:AutomationBridgeSettingsPath -Raw
        $saved = $raw | ConvertFrom-Json
        $raw | Should -Not -Match ([regex]::Escape($script:AutomationBridgeApiKey))
        $saved.PSObject.Properties.Name | Should -Not -Contain "ApiKey"
        $saved.ApiKeyProtected | Should -Match '^dpapi:v1:'
        Unprotect-AutomationBridgeApiKey -ProtectedApiKey $saved.ApiKeyProtected | Should -Be $script:AutomationBridgeApiKey
    }

    It "migrates a legacy plaintext key without changing it" {
        $legacyKey = "legacy-secret-0123456789abcdef"
        Set-Content -LiteralPath $script:AutomationBridgeSettingsPath -Encoding UTF8 -Value (
            @{
                Enabled = $false
                BindAddress = "127.0.0.1"
                Port = 34291
                ApiKey = $legacyKey
                MqttEnabled = $false
            } | ConvertTo-Json
        )

        Load-AutomationBridgeSettings

        $script:AutomationBridgeApiKey | Should -Be $legacyKey
        $raw = Get-Content -LiteralPath $script:AutomationBridgeSettingsPath -Raw
        $raw | Should -Not -Match ([regex]::Escape($legacyKey))
        ($raw | ConvertFrom-Json).ApiKeyProtected | Should -Match '^dpapi:v1:'
    }

    It "fails closed without rewriting a future settings schema" {
        $futureJson = '{"SchemaVersion":99,"Enabled":true,"BindAddress":"127.0.0.1","Port":34291,"ApiKeyProtected":"future-format","FutureField":"preserve-me"}'
        Set-Content -LiteralPath $script:AutomationBridgeSettingsPath -Encoding UTF8 -Value $futureJson

        Load-AutomationBridgeSettings

        $script:AutomationBridgeEnabled | Should -BeFalse
        $script:AutomationBridgeLastError | Should -Match "newer"
        (Get-Content -LiteralPath $script:AutomationBridgeSettingsPath -Raw) | Should -Match '"FutureField":"preserve-me"'
        (Get-Content -LiteralPath $script:AutomationBridgeSettingsPath -Raw) | Should -Match '"SchemaVersion":99'
    }

    It "rejects invalid bind addresses instead of falling back to loopback" {
        Resolve-AutomationBridgeIPAddress -BindAddress "not-an-ip-address" | Should -BeNullOrEmpty
        Test-AutomationBridgeLoopback -BindAddress "localhost" | Should -BeTrue
        Test-AutomationBridgeLoopback -BindAddress "0.0.0.0" | Should -BeFalse
    }

    It "compares only header tokens and rejects payload credentials" {
        Test-AutomationBridgeToken -Provided $script:AutomationBridgeApiKey -Expected $script:AutomationBridgeApiKey | Should -BeTrue
        Test-AutomationBridgeToken -Provided "$($script:AutomationBridgeApiKey)x" -Expected $script:AutomationBridgeApiKey | Should -BeFalse
        $request = [PSCustomObject]@{
            Headers = @{ "x-monitorcontrol-key" = $script:AutomationBridgeApiKey }
            Query = @{ apiKey = $script:AutomationBridgeApiKey }
            Body = ""
        }
        Test-AutomationBridgeRequestAuthorized -Request $request | Should -BeTrue
        Test-AutomationBridgePayloadCredential -Request $request -Body $null | Should -BeTrue
    }

    It "redacts stable targets, remote endpoints, messages, and secrets from bounded logs" {
        $script:AutomationBridgeAuditLogMaxBytes = 420
        1..8 | ForEach-Object {
            Write-AutomationBridgeWriteLog -Action "loadProfile" -Target "private-profile-$($_)" -Value "" -Success $false -Remote "10.20.30.40:1234" -Message "secret exception detail"
        }

        Test-Path -LiteralPath "$script:AutomationBridgeWriteLogPath.1" | Should -BeTrue
        $allLogText = @(
            Get-Content -LiteralPath $script:AutomationBridgeWriteLogPath -Raw
            Get-Content -LiteralPath "$script:AutomationBridgeWriteLogPath.1" -Raw
        ) -join "`n"
        $allLogText | Should -Not -Match "private-profile|10\.20\.30\.40|secret exception"
        $allLogText | Should -Match '"RemoteScope":"network"'
        (Get-Item -LiteralPath $script:AutomationBridgeWriteLogPath).Length | Should -BeLessOrEqual $script:AutomationBridgeAuditLogMaxBytes
    }

    It "sanitizes retained legacy audit files during migration" {
        $legacyLine = @{
            Timestamp = "2026-07-29T12:00:00Z"
            Action = "loadProfile"
            Target = "private-profile"
            Value = ""
            Success = $false
            Remote = "10.20.30.40:1234"
            Message = "secret exception detail"
        } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $script:AutomationBridgeWriteLogPath -Encoding UTF8 -Value $legacyLine
        Set-Content -LiteralPath "$script:AutomationBridgeWriteLogPath.1" -Encoding UTF8 -Value $legacyLine

        Initialize-AutomationBridgeAuditLog

        $migrated = (Get-Content -LiteralPath $script:AutomationBridgeWriteLogPath -Raw) + (Get-Content -LiteralPath "$script:AutomationBridgeWriteLogPath.1" -Raw)
        $migrated | Should -Not -Match "private-profile|10\.20\.30\.40|secret exception"
        $migrated | Should -Match '"TargetScope":"specified"'
        $migrated | Should -Match '"RemoteScope":"network"'
    }

    It "returns a generic 500 without leaking exception text" {
        $script:AutomationBridgeRequests = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:AutomationBridgeResponses = [hashtable]::Synchronized(@{})
        $request = [PSCustomObject]@{ Id = "failure"; Method = "GET"; Path = "/api/monitors"; Query = @{}; Headers = @{}; Body = "" }
        $script:AutomationBridgeRequests.Enqueue($request)
        Mock Invoke-AutomationBridgeRequest { throw "secret-key and stable-monitor-id" }

        Process-AutomationBridgeRequests

        $responseJson = $script:AutomationBridgeResponses["failure"].Body | ConvertTo-Json -Compress
        $script:AutomationBridgeResponses["failure"].Status | Should -Be 500
        $responseJson | Should -Match "internal_error"
        $responseJson | Should -Not -Match "secret-key|stable-monitor-id"
    }
}

Describe "Automation bridge raw socket limits" {
    BeforeEach {
        $script:RawBridgeServer = Start-TestAutomationBridge
    }

    AfterEach {
        Stop-TestAutomationBridge -Server $script:RawBridgeServer
        $script:RawBridgeServer = $null
    }

    It "exposes only an empty health check without authentication" {
        $health = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/health HTTP/1.1`r`nHost: localhost`r`n`r`n"
        $healthWithQuery = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/health?detail=1 HTTP/1.1`r`nHost: localhost`r`n`r`n"

        $health | Should -Match '^HTTP/1\.1 200 OK'
        $health | Should -Match '\{"ok":true\}'
        $health | Should -Not -Match 'version|mqtt'
        $healthWithQuery | Should -Match '^HTTP/1\.1 401 Unauthorized'
    }

    It "requires a valid header key and rejects query or body keys" {
        $noKey = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/monitors HTTP/1.1`r`nHost: localhost`r`n`r`n"
        $queryKey = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/monitors?apiKey=$($script:RawBridgeServer.ApiKey) HTTP/1.1`r`nHost: localhost`r`n`r`n"
        $payload = "{`"apiKey`":`"$($script:RawBridgeServer.ApiKey)`",`"value`":50}"
        $payloadLength = [System.Text.Encoding]::UTF8.GetByteCount($payload)
        $bodyKey = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nContent-Length: $payloadLength`r`n`r`n$payload"
        $headerKey = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/monitors HTTP/1.1`r`nHost: localhost`r`nX-MonitorControl-Key: $($script:RawBridgeServer.ApiKey)`r`n`r`n"

        $noKey | Should -Match '^HTTP/1\.1 401 Unauthorized'
        $queryKey | Should -Match '^HTTP/1\.1 400 Bad Request'
        $bodyKey | Should -Match '^HTTP/1\.1 400 Bad Request'
        $headerKey | Should -Match '^HTTP/1\.1 200 OK'
    }

    It "bounds the request line, header bytes and count, body, and framing" {
        $longTarget = "/" + ("a" * 140)
        $longLine = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET $longTarget HTTP/1.1`r`nHost: localhost`r`n`r`n"
        $manyHeadersText = "GET /api/health HTTP/1.1`r`nHost: localhost`r`n" + ((1..9 | ForEach-Object { "X-H$($_): value`r`n" }) -join "") + "`r`n"
        $manyHeaders = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request $manyHeadersText
        $invalidLength = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nContent-Length: +1`r`n`r`n"
        $duplicateLength = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nContent-Length: 0`r`nContent-Length: 0`r`n`r`n"
        $transferEncoding = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nTransfer-Encoding: chunked`r`nContent-Length: 0`r`n`r`n"
        $largeBody = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nContent-Length: 129`r`n`r`n"

        $longLine | Should -Match '^HTTP/1\.1 414 URI Too Long'
        $manyHeaders | Should -Match '^HTTP/1\.1 431 Request Header Fields Too Large'
        $invalidLength | Should -Match '^HTTP/1\.1 400 Bad Request'
        $duplicateLength | Should -Match '^HTTP/1\.1 400 Bad Request'
        $transferEncoding | Should -Match '^HTTP/1\.1 400 Bad Request'
        $largeBody | Should -Match '^HTTP/1\.1 413 Payload Too Large'
    }

    It "rejects an incomplete body and enforces read and write deadlines" {
        $incompleteBody = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "POST /api/brightness HTTP/1.1`r`nHost: localhost`r`nContent-Length: 5`r`n`r`nabc" -ShutdownSend
        $timedOut = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/health HTTP/1.1"

        $incompleteBody | Should -Match '^HTTP/1\.1 400 Bad Request'
        $timedOut | Should -Match '^HTTP/1\.1 408 Request Timeout'
        $script:RawBridgeServer.State["LastReadTimeoutMs"] | Should -Be 300
        $script:RawBridgeServer.State["LastWriteTimeoutMs"] | Should -Be 300
    }

    It "rejects excess clients while keeping active work bounded" {
        Stop-TestAutomationBridge -Server $script:RawBridgeServer
        $script:RawBridgeServer = Start-TestAutomationBridge -MaxConcurrentClients 2 -ReadTimeoutMs 1500 -WriteTimeoutMs 300
        $slowClients = @()
        try {
            1..2 | ForEach-Object {
                $client = [System.Net.Sockets.TcpClient]::new()
                $client.Connect([System.Net.IPAddress]::Loopback, [int]$script:RawBridgeServer.Port)
                $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET /")
                $client.GetStream().Write($bytes, 0, $bytes.Length)
                $slowClients += $client
            }
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while ([int]$script:RawBridgeServer.State["ActiveClients"] -lt 2 -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 20
            }

            $rejected = Invoke-RawAutomationBridgeRequest -Server $script:RawBridgeServer -Request "GET /api/health HTTP/1.1`r`nHost: localhost`r`n`r`n"

            $rejected | Should -Match '^HTTP/1\.1 503 Service Unavailable'
            $script:RawBridgeServer.State["PeakActiveClients"] | Should -BeLessOrEqual 2
            $script:RawBridgeServer.State["RejectedClients"] | Should -BeGreaterOrEqual 1
        } finally {
            foreach ($client in $slowClients) { $client.Close() }
        }
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
