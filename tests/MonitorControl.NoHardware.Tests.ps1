BeforeAll {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:AppPath = Join-Path $script:RepoRoot "MonitorControlPro.ps1"

    # The value cache and its suppression predicate live in the inline C# layer, so the suite
    # compiles that block on its own. No P/Invoke is called from these tests; only the managed
    # cache helpers are exercised, with synthetic handle values that never reach a driver.
    function Import-MonitorControlNativeType {
        if ("MonitorAPI" -as [type]) { return }
        $text = [System.IO.File]::ReadAllText($script:AppPath)
        $start = $text.IndexOf('$nativeCode = @"')
        if ($start -lt 0) { throw "Native code block not found" }
        $start = $text.IndexOf("`n", $start) + 1
        $end = $text.IndexOf("`n`"@", $start)
        if ($end -lt 0) { throw "Native code block is unterminated" }
        Add-Type -TypeDefinition $text.Substring($start, $end - $start) -ErrorAction Stop
    }

    Import-MonitorControlNativeType

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

    function global:New-CapMonitor {
        param([string]$IdentityKey = "edid:a", [string]$Manufacturer = "DEL", [string]$Model = "A123", [bool]$HasHandle = $true)
        return [PSCustomObject]@{
            IdentityKey = $IdentityKey
            Manufacturer = $Manufacturer
            EdidModel = $Model
            Name = "Test monitor"
            Handle = if ($HasHandle) { [IntPtr]::new(0x9001) } else { [IntPtr]::Zero }
        }
    }

    function global:New-FakeWorker {
        $worker = [PSCustomObject]@{ Name = "worker" }
        $worker | Add-Member -MemberType ScriptMethod -Name Stop -Value { [void]$script:StoppedWorkers.Add("worker") }
        $worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value { [void]$script:DisposedObjects.Add("worker") }
        return $worker
    }

    function global:New-FakeDisposable {
        param([string]$Label)
        $item = [PSCustomObject]@{ Label = $Label }
        $item | Add-Member -MemberType ScriptMethod -Name Dispose -Value { [void]$script:DisposedObjects.Add($this.Label) }
        return $item
    }

    function global:New-FakeWorkerTimer {
        $timer = [PSCustomObject]@{ Running = $true }
        $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false }
        return $timer
    }

    function global:New-RangeTestMonitor {
        param([string]$IdentityKey, [int]$BrightnessMaximum)
        $monitor = [PSCustomObject]@{
            IdentityKey = $IdentityKey
            Name = "Monitor $IdentityKey"
            VcpMaximums = @{}
        }
        if ($BrightnessMaximum -gt 0) { $monitor.VcpMaximums[0x10] = $BrightnessMaximum }
        return $monitor
    }

    Import-MonitorControlFunctions -Name @(
        "Set-DeferredStatus",
        "Test-JsonFileValid",
        "Move-CorruptJsonFile",
        "Read-JsonFileSafely",
        "Write-JsonFileSafely",
        "Resolve-ProfileStorageRootState",
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
        "Set-ProfileStoragePathBinding",
        "Set-ProfileStorageRoot",
        "Get-ProfileStoragePointer",
        "Write-ProfileStoragePointer",
        "Save-ProfileStorageSettings",
        "Test-ProfileStorageWriteAllowed",
        "Get-ProfileStorageMigrationPlan",
        "Format-ProfileStorageMigrationPreview",
        "Invoke-ProfileStorageMigrationCommit",
        "Get-CapabilitiesSection",
        "Get-HexTokens",
        "ConvertFrom-MonitorCapabilities",
        "Get-DisplayRecoveryBackoffDelay",
        "Get-DisplayRecoveryReadRetryCount",
        "Get-DisplayRecoveryTransition",
        "Test-DisplayWorkerResultCurrent",
        "Clear-PhysicalMonitorHandles",
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
        "Test-VcpCodeIsScaled",
        "Get-VcpMaximumForMonitor",
        "Set-VcpMaximumForMonitor",
        "ConvertTo-VcpPercent",
        "ConvertTo-VcpRawValue",
        "Resolve-VcpWriteValueForMonitor",
        "Update-VcpMaximumCache",
        "Get-ProfilePercentValue",
        "Get-MonitorEdidModelId",
        "Get-CapabilitiesBlocklistEntry",
        "Get-CapabilitiesCacheKey",
        "Save-CapabilitiesCache",
        "Import-CapabilitiesCache",
        "Set-CapabilitiesCacheEntry",
        "Get-CapabilitiesCacheEntry",
        "Clear-CapabilitiesCache",
        "Get-CapabilityProbeDecision",
        "Get-DisplayStateRestoreSettingsObject",
        "Save-DisplayStateRestoreSettings",
        "Import-DisplayStateRestoreSettings",
        "Set-DisplayStateRestoreValue",
        "Get-DisplayStateRestorePlan",
        "Invoke-DisplayStateRestore",
        "Test-MonitorSupportsVcp",
        "Stop-MonitorSettingsWorker",
        "Stop-CapabilitiesWorker",
        "Stop-VcpWorker",
        "Stop-DdcReportWorker",
        "Get-ThemeBrushMap",
        "ConvertTo-ThemeBrush",
        "Register-DetachedThemedWindow",
        "Unregister-DetachedThemedWindow",
        "Update-DetachedWindowTheme",
        "Update-DetachedWindowThemes",
        "Invoke-ManualVcpWrite",
        "Get-MonitorDisplayLabel",
        "Wait-DdcWriteQueueIdle",
        "Drain-DdcWriteResults",
        "Register-DdcDiagnostic",
        "Get-VcpWriteRiskNote",
        "Set-VCPValueWithSync",
        "ConvertTo-HelperVersion",
        "Get-OptionalHelperSourceCategory",
        "Test-OptionalHelperVersionSupported",
        "Get-OptionalHelperProvenance",
        "Format-OptionalHelperProvenance",
        "Get-OptionalHelperSettingsObject",
        "Save-OptionalHelperSettings",
        "Import-OptionalHelperSettings",
        "Initialize-CpuMonitor",
        "Initialize-PresentMon",
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
        "Get-IdleSecondsFromTicks",
        "Get-AccessibilityThemePalette",
        "Get-WcagRelativeLuminance",
        "Get-WcagContrastRatio",
        "Resolve-TextScaleFactor",
        "Get-StatusMessageSeverity",
        "Get-NavigationShortcutTarget"
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

Describe "Profile schema migration" {
    BeforeEach {
        $script:ProfileSchemaVersion = 4
    }

    It "migrates every supported legacy schema to the current schema" {
        $fixtures = @(
            [PSCustomObject]@{
                Name = "Legacy v1"
                MonitorIdentityKey = "edid:v1"
                MonitorName = "Legacy display"
                Brightness = 42
                Contrast = 43
                Red = 44
                Green = 45
                Blue = 46
                Gamma = 101
            },
            [PSCustomObject]@{
                SchemaVersion = 2
                Name = "Legacy v2"
                MonitorIdentityKey = "edid:v2"
                MonitorSettings = @(
                    [PSCustomObject]@{
                        IdentityKey = "edid:v2"
                        MonitorName = "Schema two display"
                        Brightness = 62
                        Contrast = 63
                        Red = 64
                        Green = 65
                        Blue = 66
                        Gamma = 102
                    }
                )
            }
        )

        $migrated = @($fixtures | ForEach-Object {
            ConvertTo-CurrentProfileSchema -Profile $_ -FallbackName "Fallback"
        })

        @($migrated.SchemaVersion) | Should -Be @(4, 4)
        $migrated[0].MonitorSettings.Count | Should -Be 1
        $migrated[0].MonitorSettings[0].IdentityKey | Should -Be "edid:v1"
        $migrated[1].MonitorSettings.Count | Should -Be 1
        $migrated[1].MonitorSettings[0].Brightness | Should -Be 62
        $migrated[1].MonitorSettings[0].GammaRed | Should -Be 100
    }

    It "rejects invalid and future profile schemas instead of rewriting them" {
        { ConvertTo-CurrentProfileSchema -Profile ([PSCustomObject]@{ SchemaVersion = 0; Name = "Invalid" }) -FallbackName "Invalid" } |
            Should -Throw "*at least 1*"
        { ConvertTo-CurrentProfileSchema -Profile ([PSCustomObject]@{ SchemaVersion = 99; Name = "Future" }) -FallbackName "Future" } |
            Should -Throw "*newer than this app*"
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

    It "loads a backup without mutating a corrupt read-only fallback" {
        $path = Join-Path $TestDrive "read-only.json"
        Set-Content -LiteralPath $path -Value "{broken" -Encoding UTF8
        Set-Content -LiteralPath "$path.bak" -Value '{"source":"backup"}' -Encoding UTF8
        $beforeHash = Get-FileSha256Hex -Path $path

        $data = Read-JsonFileSafely -Path $path -Label "Read-only fixture" -ReadOnly

        $data.source | Should -Be "backup"
        (Get-FileSha256Hex -Path $path) | Should -Be $beforeHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter "read-only.json.corrupt-*").Count | Should -Be 0
    }
}

Describe "Transactional profile bundle import" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:ProfilesPath = Join-Path $TestDrive "profiles"
        $script:ProfileExportsPath = Join-Path $TestDrive "exports"
        New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null
        $script:ProfileSchemaVersion = 4
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

Describe "Transactional alternate profile storage" {
    BeforeEach {
        $script:StorageTestRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $script:DefaultProfilesPath = Join-Path $script:StorageTestRoot "default"
        $script:StorageSourceRoot = Join-Path $script:StorageTestRoot "source"
        $script:StorageDestinationRoot = Join-Path $script:StorageTestRoot "destination"
        New-Item -ItemType Directory -Path $script:DefaultProfilesPath, $script:StorageSourceRoot, $script:StorageDestinationRoot -Force | Out-Null
        $script:ProfileStorageSettingsPath = Join-Path $script:DefaultProfilesPath "profile-storage.json"
        $script:ProfileStorageSchemaVersion = 2
        $script:ProfilesPath = $script:StorageSourceRoot
        $script:ProfileStorageConfiguredPath = $script:StorageSourceRoot
        $script:ProfileStorageFallbackPath = $script:StorageSourceRoot
        $script:ProfileStoragePreviousPath = ""
        $script:ProfileStorageMode = "Local"
        $script:ProfileStorageOffline = $false
        Set-ProfileStoragePathBinding -Path $script:StorageSourceRoot -Mode "Local" -FallbackPath $script:StorageSourceRoot -PreviousPath ""
    }

    It "uses an available fallback as a read-only library when configured storage is offline" {
        '{"Name":"cached"}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "cached.json") -Encoding UTF8
        $missingRoot = Join-Path $script:StorageTestRoot "missing-sync-root"
        $settings = [PSCustomObject]@{
            SchemaVersion = 2
            Mode = "Sync"
            ProfilePath = $missingRoot
            FallbackPath = $script:StorageSourceRoot
            PreviousPath = $script:DefaultProfilesPath
        }
        $state = Resolve-ProfileStorageRootState -Settings $settings -DefaultPath $script:DefaultProfilesPath -CurrentSchemaVersion 2
        $state.Offline | Should -BeTrue
        $state.ProfilesPath | Should -Be $script:StorageSourceRoot
        (Test-Path -LiteralPath (Join-Path $state.ProfilesPath "cached.json")) | Should -BeTrue

        $script:ProfileStorageOffline = $true
        (Test-ProfileStorageWriteAllowed -Operation "test write" -SuppressStatus) | Should -BeFalse
    }

    It "previews every conflict and copy-migrates without losing either version" {
        '{"Name":"source-alpha","Value":1}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "alpha.json") -Encoding UTF8
        '{"Name":"same"}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "same.json") -Encoding UTF8
        '{"Enabled":true,"Rules":[]}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "app-profile-rules.json") -Encoding UTF8
        '{"Name":"destination-alpha","Value":2}' | Set-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Encoding UTF8
        '{"Name":"same"}' | Set-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "same.json") -Encoding UTF8
        '{"Name":"destination-only"}' | Set-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "destination-only.json") -Encoding UTF8

        $plan = Get-ProfileStorageMigrationPlan -SourceRoot $script:StorageSourceRoot -DestinationRoot $script:StorageDestinationRoot -ConflictMode "Copy" -MigrationId "test-copy"
        $plan.Valid | Should -BeTrue
        @($plan.Conflicts).Count | Should -Be 1
        $plan.Conflicts[0].RelativePath | Should -Be "alpha.json"
        $plan.Conflicts[0].ConflictCopyRelativePath | Should -Be (Join-Path "conflicts\test-copy\destination" "alpha.json")
        $preview = Format-ProfileStorageMigrationPreview -Plan $plan
        $preview | Should -Match 'alpha\.json'
        $preview | Should -Match 'conflicts'

        $destinationAlphaBefore = Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Raw
        $sourceAlpha = Get-Content -LiteralPath (Join-Path $script:StorageSourceRoot "alpha.json") -Raw
        $result = Invoke-ProfileStorageMigrationCommit -Plan $plan -DestinationMode "Sync"
        $result.Success | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Raw) | Should -BeExactly $sourceAlpha
        (Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot $plan.Conflicts[0].ConflictCopyRelativePath) -Raw) | Should -BeExactly $destinationAlphaBefore
        (Test-Path -LiteralPath (Join-Path $script:StorageDestinationRoot "destination-only.json")) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:StorageDestinationRoot "app-profile-rules.json")) | Should -BeTrue
        $script:ProfilesPath | Should -Be $script:StorageDestinationRoot
        $script:ProfileStorageOffline | Should -BeFalse

        $pointer = Get-Content -LiteralPath $script:ProfileStorageSettingsPath -Raw | ConvertFrom-Json
        $pointer.SchemaVersion | Should -Be 2
        $pointer.ProfilePath | Should -Be $script:StorageDestinationRoot
        $pointer.FallbackPath | Should -Be $script:StorageSourceRoot
    }

    It "merge-preserves the destination and writes the source as an explicit conflict copy" {
        '{"Name":"source-alpha"}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "alpha.json") -Encoding UTF8
        '{"Name":"destination-alpha"}' | Set-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Encoding UTF8
        $destinationAlphaBefore = Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Raw
        $sourceAlpha = Get-Content -LiteralPath (Join-Path $script:StorageSourceRoot "alpha.json") -Raw
        $plan = Get-ProfileStorageMigrationPlan -SourceRoot $script:StorageSourceRoot -DestinationRoot $script:StorageDestinationRoot -ConflictMode "Merge" -MigrationId "test-merge"

        $result = Invoke-ProfileStorageMigrationCommit -Plan $plan -DestinationMode "Sync"
        $result.Success | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Raw) | Should -BeExactly $destinationAlphaBefore
        (Get-Content -LiteralPath (Join-Path $script:StorageDestinationRoot $plan.Conflicts[0].ConflictCopyRelativePath) -Raw) | Should -BeExactly $sourceAlpha
    }

    It "restores destination files pointer bytes metadata backup and path bindings after a late failure" {
        '{"Name":"source-alpha"}' | Set-Content -LiteralPath (Join-Path $script:StorageSourceRoot "alpha.json") -Encoding UTF8
        '{"Name":"destination-alpha"}' | Set-Content -LiteralPath (Join-Path $script:StorageDestinationRoot "alpha.json") -Encoding UTF8
        '{"SchemaVersion":1,"Mode":"Local","ProfilePath":"old"}' | Set-Content -LiteralPath $script:ProfileStorageSettingsPath -Encoding UTF8
        'old-backup' | Set-Content -LiteralPath "$script:ProfileStorageSettingsPath.bak" -Encoding UTF8
        $pointerHash = Get-FileSha256Hex -Path $script:ProfileStorageSettingsPath
        $pointerBackupHash = Get-FileSha256Hex -Path "$script:ProfileStorageSettingsPath.bak"
        $destinationHash = Get-FileSha256Hex -Path (Join-Path $script:StorageDestinationRoot "alpha.json")
        $plan = Get-ProfileStorageMigrationPlan -SourceRoot $script:StorageSourceRoot -DestinationRoot $script:StorageDestinationRoot -ConflictMode "Copy" -MigrationId "test-rollback"

        $result = Invoke-ProfileStorageMigrationCommit -Plan $plan -DestinationMode "Sync" -AfterPointerWrite { throw "injected late failure" }
        $result.Success | Should -BeFalse
        $result.ErrorCode | Should -Be "commit_failed"
        (Get-FileSha256Hex -Path $script:ProfileStorageSettingsPath) | Should -Be $pointerHash
        (Get-FileSha256Hex -Path "$script:ProfileStorageSettingsPath.bak") | Should -Be $pointerBackupHash
        (Get-FileSha256Hex -Path (Join-Path $script:StorageDestinationRoot "alpha.json")) | Should -Be $destinationHash
        (Test-Path -LiteralPath (Join-Path $script:StorageDestinationRoot $plan.Conflicts[0].ConflictCopyRelativePath)) | Should -BeFalse
        $script:ProfilesPath | Should -Be $script:StorageSourceRoot
        $script:ProfileStorageMode | Should -Be "Local"
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

Describe "Physical monitor handle cleanup" {
    BeforeEach {
        $script:DestroyedHandleValues = @()
        $script:PhysicalMonitors = @(
            [PSCustomObject]@{ Name = "First"; Handle = [IntPtr]101 },
            [PSCustomObject]@{ Name = "Duplicate"; Handle = [IntPtr]101 },
            [PSCustomObject]@{ Name = "Second"; Handle = [IntPtr]202 },
            [PSCustomObject]@{ Name = "No handle"; Handle = [IntPtr]::Zero }
        )
    }

    It "destroys each unique native handle once and zeros every alias" {
        Clear-PhysicalMonitorHandles -ClearList -DestroyHandle {
            param([IntPtr]$Handle)
            $script:DestroyedHandleValues += $Handle.ToInt64()
        }

        @($script:DestroyedHandleValues) | Should -Be @(101, 202)
        $script:PhysicalMonitors.Count | Should -Be 0
    }

    It "continues zeroing handles when a native destroy call fails" {
        $monitors = $script:PhysicalMonitors
        Clear-PhysicalMonitorHandles -DestroyHandle {
            param([IntPtr]$Handle)
            if ($Handle.ToInt64() -eq 101) { throw "injected destroy failure" }
            $script:DestroyedHandleValues += $Handle.ToInt64()
        }

        @($script:DestroyedHandleValues) | Should -Be @(202)
        @($monitors | Where-Object { $_.Handle -ne [IntPtr]::Zero }).Count | Should -Be 0
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

Describe "Monitor reported VCP range normalization" {
    BeforeEach {
        $script:VcpScaledCodes = @(0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x87)
        $script:VcpDefaultMaximum = 100
        $script:ProfileSchemaVersion = 4
    }

    It "treats only continuous codes as scaled" {
        foreach ($code in @(0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x87)) {
            Test-VcpCodeIsScaled -Code $code | Should -BeTrue
        }
        foreach ($code in @(0x14, 0x60, 0xD6, 0xDC, 0x8D, 0x04)) {
            Test-VcpCodeIsScaled -Code $code | Should -BeFalse
        }
    }

    It "falls back to a 0-100 range until a maximum has been observed" {
        $monitor = New-RangeTestMonitor -IdentityKey "unknown" -BrightnessMaximum 0
        Get-VcpMaximumForMonitor -Monitor $monitor -Code 0x10 | Should -Be 100
        Get-VcpMaximumForMonitor -Monitor $null -Code 0x10 | Should -Be 100
    }

    It "ignores non-positive reported maximums" {
        $monitor = New-RangeTestMonitor -IdentityKey "zero" -BrightnessMaximum 0
        Set-VcpMaximumForMonitor -Monitor $monitor -Code 0x10 -Maximum 0
        Set-VcpMaximumForMonitor -Monitor $monitor -Code 0x10 -Maximum -5
        Get-VcpMaximumForMonitor -Monitor $monitor -Code 0x10 | Should -Be 100
    }

    It "maps percentages onto 0-31, 0-100, and 0-255 ranges" {
        ConvertTo-VcpRawValue -Percent 0 -Maximum 31 | Should -Be 0
        ConvertTo-VcpRawValue -Percent 100 -Maximum 31 | Should -Be 31
        ConvertTo-VcpRawValue -Percent 50 -Maximum 31 | Should -Be 16

        ConvertTo-VcpRawValue -Percent 0 -Maximum 100 | Should -Be 0
        ConvertTo-VcpRawValue -Percent 42 -Maximum 100 | Should -Be 42
        ConvertTo-VcpRawValue -Percent 100 -Maximum 100 | Should -Be 100

        ConvertTo-VcpRawValue -Percent 100 -Maximum 255 | Should -Be 255
        ConvertTo-VcpRawValue -Percent 50 -Maximum 255 | Should -Be 128
    }

    It "maps raw values back to percentages and clamps out-of-range input" {
        ConvertTo-VcpPercent -RawValue 31 -Maximum 31 | Should -Be 100
        ConvertTo-VcpPercent -RawValue 0 -Maximum 31 | Should -Be 0
        ConvertTo-VcpPercent -RawValue 128 -Maximum 255 | Should -Be 50
        ConvertTo-VcpPercent -RawValue 400 -Maximum 255 | Should -Be 100
        ConvertTo-VcpPercent -RawValue -10 -Maximum 100 | Should -Be 0
        ConvertTo-VcpRawValue -Percent 250 -Maximum 31 | Should -Be 31
        ConvertTo-VcpRawValue -Percent -40 -Maximum 31 | Should -Be 0
    }

    It "round-trips every percentage on a 0-100 monitor without drift" {
        foreach ($percent in 0..100) {
            $raw = ConvertTo-VcpRawValue -Percent $percent -Maximum 100
            ConvertTo-VcpPercent -RawValue $raw -Maximum 100 | Should -Be $percent
        }
    }

    It "keeps a percentage monotonic across a compressed range" {
        $previous = -1
        foreach ($percent in 0..100) {
            $raw = ConvertTo-VcpRawValue -Percent $percent -Maximum 31
            $raw | Should -BeGreaterOrEqual $previous
            $previous = $raw
        }
    }

    It "resolves one percentage into a different raw value per monitor" {
        $narrow = New-RangeTestMonitor -IdentityKey "narrow" -BrightnessMaximum 31
        $standard = New-RangeTestMonitor -IdentityKey "standard" -BrightnessMaximum 100
        $wide = New-RangeTestMonitor -IdentityKey "wide" -BrightnessMaximum 255

        Resolve-VcpWriteValueForMonitor -Monitor $narrow -Code 0x10 -Value 80 -Percent | Should -Be 25
        Resolve-VcpWriteValueForMonitor -Monitor $standard -Code 0x10 -Value 80 -Percent | Should -Be 80
        Resolve-VcpWriteValueForMonitor -Monitor $wide -Code 0x10 -Value 80 -Percent | Should -Be 204
    }

    It "never rescales a discrete code even when asked for percentages" {
        $wide = New-RangeTestMonitor -IdentityKey "wide" -BrightnessMaximum 255
        $wide.VcpMaximums[0x60] = 255
        Resolve-VcpWriteValueForMonitor -Monitor $wide -Code 0x60 -Value 17 -Percent | Should -Be 17
        Resolve-VcpWriteValueForMonitor -Monitor $wide -Code 0xD6 -Value 4 -Percent | Should -Be 4
    }

    It "passes raw values through untouched when percentages were not requested" {
        $wide = New-RangeTestMonitor -IdentityKey "wide" -BrightnessMaximum 255
        Resolve-VcpWriteValueForMonitor -Monitor $wide -Code 0x10 -Value 200 | Should -Be 200
    }

    It "caches reported maximums from worker results by monitor identity" {
        $narrow = New-RangeTestMonitor -IdentityKey "narrow" -BrightnessMaximum 0
        $wide = New-RangeTestMonitor -IdentityKey "wide" -BrightnessMaximum 0
        $script:PhysicalMonitors = @($narrow, $wide)

        Update-VcpMaximumCache -Results @(
            [PSCustomObject]@{ Success = $true; Code = 0x10; Maximum = 31; IdentityKey = "narrow" },
            [PSCustomObject]@{ Success = $true; Code = 0x10; Maximum = 255; IdentityKey = "wide" },
            [PSCustomObject]@{ Success = $false; Code = 0x12; Maximum = 900; IdentityKey = "narrow" },
            [PSCustomObject]@{ Success = $true; Code = 0x12; Maximum = 0; IdentityKey = "wide" },
            [PSCustomObject]@{ Success = $true; Code = 0x10; Maximum = 64; IdentityKey = "" }
        )

        Get-VcpMaximumForMonitor -Monitor $narrow -Code 0x10 | Should -Be 31
        Get-VcpMaximumForMonitor -Monitor $wide -Code 0x10 | Should -Be 255
        Get-VcpMaximumForMonitor -Monitor $narrow -Code 0x12 | Should -Be 100
        Get-VcpMaximumForMonitor -Monitor $wide -Code 0x12 | Should -Be 100
    }

    It "sends one linked brightness percentage to three differently ranged monitors" {
        $monitors = @(
            (New-RangeTestMonitor -IdentityKey "narrow" -BrightnessMaximum 31),
            (New-RangeTestMonitor -IdentityKey "standard" -BrightnessMaximum 100),
            (New-RangeTestMonitor -IdentityKey "wide" -BrightnessMaximum 255)
        )
        $written = @(foreach ($monitor in $monitors) {
            [int](Resolve-VcpWriteValueForMonitor -Monitor $monitor -Code 0x10 -Value 25 -Percent)
        })

        $written | Should -Be @(8, 25, 64)
        # A coarse range cannot represent every percentage exactly, so the contract is that
        # each monitor lands on its nearest representable step - not on the same raw number.
        foreach ($index in 0..2) {
            $maximum = Get-VcpMaximumForMonitor -Monitor $monitors[$index] -Code 0x10
            $observed = ConvertTo-VcpPercent -RawValue $written[$index] -Maximum $maximum
            [Math]::Abs($observed - 25) | Should -BeLessOrEqual ([Math]::Ceiling(100.0 / (2 * $maximum)))
        }
    }
}

Describe "Capability cache and known-bad monitor list" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:CapabilitiesCachePath = Join-Path $TestDrive "capabilities-cache.json"
        $script:CapabilitiesCacheSchemaVersion = 1
        $script:CapabilitiesCache = @{}
        $script:CapabilitiesDiscoveryEnabled = $true
        $script:CapabilitiesMaximumCompatibility = $false
        $script:CapabilitiesExcludedIdentityKeys = @{}
        $script:CapabilitiesKnownBadModels = @(
            [PSCustomObject]@{ EdidId = "LTM2C02"; Note = "Counterfeit-EDID LG 27MR400" }
            [PSCustomObject]@{ EdidId = "GSM7714"; Note = "LG UltraWide HDR WFHD" }
        )
        $script:LastStatusMessage = ""
    }

    It "builds an EDID model id from the manufacturer and product code" {
        Get-MonitorEdidModelId -Monitor (New-CapMonitor -Manufacturer "ltm" -Model "2c02") | Should -Be "LTM2C02"
        Get-MonitorEdidModelId -Monitor (New-CapMonitor -Manufacturer "" -Model "2C02") | Should -Be ""
        Get-MonitorEdidModelId -Monitor $null | Should -Be ""
    }

    It "refuses to probe a model documented to fault the kernel" {
        $decision = Get-CapabilityProbeDecision -Monitor (New-CapMonitor -Manufacturer "LTM" -Model "2C02")
        $decision.Action | Should -Be "Blocked"
        $decision.Reason | Should -Match "LTM2C02"

        $decision = Get-CapabilityProbeDecision -Monitor (New-CapMonitor -Manufacturer "GSM" -Model "7714")
        $decision.Action | Should -Be "Blocked"
    }

    It "probes a model that is not on the list" {
        (Get-CapabilityProbeDecision -Monitor (New-CapMonitor)).Action | Should -Be "Probe"
    }

    It "replays a cached capability string instead of probing again" {
        $monitor = New-CapMonitor
        Set-CapabilitiesCacheEntry -Monitor $monitor -Capabilities "(vcp(10 12))" | Should -BeTrue

        $decision = Get-CapabilityProbeDecision -Monitor $monitor
        $decision.Action | Should -Be "Cached"
        $decision.Capabilities | Should -Be "(vcp(10 12))"
    }

    It "keeps every existing safety gate ahead of the cache" {
        $monitor = New-CapMonitor
        Set-CapabilitiesCacheEntry -Monitor $monitor -Capabilities "(vcp(10))" | Out-Null

        $script:CapabilitiesDiscoveryEnabled = $false
        (Get-CapabilityProbeDecision -Monitor $monitor).Action | Should -Be "Skip"

        $script:CapabilitiesDiscoveryEnabled = $true
        $script:CapabilitiesMaximumCompatibility = $true
        (Get-CapabilityProbeDecision -Monitor $monitor).Action | Should -Be "Skip"

        $script:CapabilitiesMaximumCompatibility = $false
        $script:CapabilitiesExcludedIdentityKeys = @{ "edid:a" = $true }
        (Get-CapabilityProbeDecision -Monitor $monitor).Action | Should -Be "Skip"

        $script:CapabilitiesExcludedIdentityKeys = @{}
        (Get-CapabilityProbeDecision -Monitor (New-CapMonitor -HasHandle $false)).Action | Should -Be "Skip"
    }

    It "does not cache a monitor without a stable identity or an empty string" {
        Set-CapabilitiesCacheEntry -Monitor (New-CapMonitor -IdentityKey "") -Capabilities "(vcp(10))" | Should -BeFalse
        Set-CapabilitiesCacheEntry -Monitor (New-CapMonitor) -Capabilities "" | Should -BeFalse
        $script:CapabilitiesCache.Count | Should -Be 0
    }

    It "round-trips the cache through disk" {
        Set-CapabilitiesCacheEntry -Monitor (New-CapMonitor -IdentityKey "edid:a") -Capabilities "(vcp(10 12))" | Out-Null
        Set-CapabilitiesCacheEntry -Monitor (New-CapMonitor -IdentityKey "edid:b") -Capabilities "(vcp(10 60))" | Out-Null
        Save-CapabilitiesCache | Out-Null

        $script:CapabilitiesCache = @{}
        Import-CapabilitiesCache

        $script:CapabilitiesCache.Count | Should -Be 2
        $script:CapabilitiesCache["edid:a"].Capabilities | Should -Be "(vcp(10 12))"
        $script:CapabilitiesCache["edid:b"].EdidId | Should -Be "DELA123"
    }

    It "ignores a cache written by a newer build" {
        $future = [PSCustomObject]@{ SchemaVersion = 99; Monitors = @() }
        Write-JsonFileSafely -Path $script:CapabilitiesCachePath -Data $future -Depth 5 | Out-Null

        Import-CapabilitiesCache

        $script:CapabilitiesCache.Count | Should -Be 0
        $script:LastStatusMessage | Should -Match "schema v99"
    }

    It "clears the cache so the next launch reads again" {
        Set-CapabilitiesCacheEntry -Monitor (New-CapMonitor) -Capabilities "(vcp(10))" | Out-Null
        Save-CapabilitiesCache | Out-Null

        Clear-CapabilitiesCache

        $script:CapabilitiesCache.Count | Should -Be 0
        Import-CapabilitiesCache
        $script:CapabilitiesCache.Count | Should -Be 0
        (Get-CapabilityProbeDecision -Monitor (New-CapMonitor)).Action | Should -Be "Probe"
    }
}

Describe "Brightness restore after launch and resume" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:DisplayStateRestoreSettingsPath = Join-Path $TestDrive "display-restore.json"
        $script:DisplayStateRestoreSchemaVersion = 1
        $script:DisplayStateRestoreEnabled = $false
        $script:DisplayStateRestoreValues = @{}
        $script:DisplayStateRestoreGeneration = -1
        $script:VcpScaledCodes = @(0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x87)
        $script:VcpDefaultMaximum = 100
        $script:LastStatusMessage = ""
    }

    It "writes nothing while restore is disabled" {
        $monitors = @([PSCustomObject]@{ IdentityKey = "edid:a"; Name = "A"; DisplayLabel = "A"; Handle = [IntPtr]::new(0x11); VcpMaximums = @{}; CapabilitiesKnown = $false; SupportedVcpCodes = @{} })
        $plan = Get-DisplayStateRestorePlan -Monitors $monitors -Remembered @{ "edid:a" = [PSCustomObject]@{ Brightness = 40 } } -Enabled $false
        @($plan.Operations).Count | Should -Be 0
    }

    It "maps a remembered percentage onto each monitor's own range" {
        $monitors = @(
            [PSCustomObject]@{ IdentityKey = "edid:narrow"; Name = "N"; DisplayLabel = "N"; Handle = [IntPtr]::new(0x11); VcpMaximums = @{ 0x10 = 31 }; CapabilitiesKnown = $false; SupportedVcpCodes = @{} },
            [PSCustomObject]@{ IdentityKey = "edid:wide"; Name = "W"; DisplayLabel = "W"; Handle = [IntPtr]::new(0x12); VcpMaximums = @{ 0x10 = 255 }; CapabilitiesKnown = $false; SupportedVcpCodes = @{} }
        )
        $remembered = @{
            "edid:narrow" = [PSCustomObject]@{ Brightness = 50 }
            "edid:wide" = [PSCustomObject]@{ Brightness = 50 }
        }
        $plan = Get-DisplayStateRestorePlan -Monitors $monitors -Remembered $remembered -Enabled $true

        @($plan.Operations).Count | Should -Be 2
        @($plan.Operations | Where-Object { $_.MonitorName -eq "N" }).Value | Should -Be 16
        @($plan.Operations | Where-Object { $_.MonitorName -eq "W" }).Value | Should -Be 128
    }

    It "skips a monitor and says why when it cannot be restored" {
        $monitors = @(
            [PSCustomObject]@{ IdentityKey = ""; Name = "NoIdentity"; DisplayLabel = "NoIdentity"; Handle = [IntPtr]::new(0x11); VcpMaximums = @{}; CapabilitiesKnown = $false; SupportedVcpCodes = @{} },
            [PSCustomObject]@{ IdentityKey = "edid:unknown"; Name = "Unknown"; DisplayLabel = "Unknown"; Handle = [IntPtr]::new(0x12); VcpMaximums = @{}; CapabilitiesKnown = $false; SupportedVcpCodes = @{} },
            [PSCustomObject]@{ IdentityKey = "edid:nohandle"; Name = "NoHandle"; DisplayLabel = "NoHandle"; Handle = [IntPtr]::Zero; VcpMaximums = @{}; CapabilitiesKnown = $false; SupportedVcpCodes = @{} },
            [PSCustomObject]@{ IdentityKey = "edid:unsupported"; Name = "Unsupported"; DisplayLabel = "Unsupported"; Handle = [IntPtr]::new(0x14); VcpMaximums = @{}; CapabilitiesKnown = $true; SupportedVcpCodes = @{ 0x12 = @() } }
        )
        $remembered = @{
            "edid:nohandle" = [PSCustomObject]@{ Brightness = 40 }
            "edid:unsupported" = [PSCustomObject]@{ Brightness = 40 }
        }
        $plan = Get-DisplayStateRestorePlan -Monitors $monitors -Remembered $remembered -Enabled $true

        @($plan.Operations).Count | Should -Be 0
        @($plan.Skipped).Count | Should -Be 4
        (@($plan.Skipped | Where-Object { $_.Monitor -eq "NoIdentity" }).Reason) | Should -Be "no stable identity"
        (@($plan.Skipped | Where-Object { $_.Monitor -eq "Unknown" }).Reason) | Should -Be "nothing remembered"
        (@($plan.Skipped | Where-Object { $_.Monitor -eq "NoHandle" }).Reason) | Should -Be "no DDC/CI handle"
        (@($plan.Skipped | Where-Object { $_.Monitor -eq "Unsupported" }).Reason) | Should -Be "brightness not reported"
    }

    It "rejects an out-of-range remembered value" {
        Set-DisplayStateRestoreValue -IdentityKey "edid:a" -BrightnessPercent 101 | Should -BeFalse
        Set-DisplayStateRestoreValue -IdentityKey "edid:a" -BrightnessPercent -1 | Should -BeFalse
        Set-DisplayStateRestoreValue -IdentityKey "" -BrightnessPercent 40 | Should -BeFalse
        Set-DisplayStateRestoreValue -IdentityKey "edid:a" -BrightnessPercent 40 | Should -BeTrue
        $script:DisplayStateRestoreValues["edid:a"].Brightness | Should -Be 40
    }

    It "round-trips remembered values through disk" {
        $script:DisplayStateRestoreEnabled = $true
        Set-DisplayStateRestoreValue -IdentityKey "edid:a" -BrightnessPercent 35 | Out-Null
        Set-DisplayStateRestoreValue -IdentityKey "edid:b" -BrightnessPercent 80 | Out-Null
        Save-DisplayStateRestoreSettings | Out-Null

        $script:DisplayStateRestoreEnabled = $false
        $script:DisplayStateRestoreValues = @{}
        Import-DisplayStateRestoreSettings

        $script:DisplayStateRestoreEnabled | Should -BeTrue
        $script:DisplayStateRestoreValues["edid:a"].Brightness | Should -Be 35
        $script:DisplayStateRestoreValues["edid:b"].Brightness | Should -Be 80
    }

    It "stays disabled for a settings file from a newer build" {
        $future = [PSCustomObject]@{ SchemaVersion = 99; Enabled = $true; Monitors = @() }
        Write-JsonFileSafely -Path $script:DisplayStateRestoreSettingsPath -Data $future -Depth 5 | Out-Null

        Import-DisplayStateRestoreSettings

        $script:DisplayStateRestoreEnabled | Should -BeFalse
        $script:LastStatusMessage | Should -Match "schema v99"
    }

    It "restores at most once per recovery generation" {
        $script:DisplayStateRestoreEnabled = $true
        $script:DisplayStateRestoreValues = @{ "edid:a" = [PSCustomObject]@{ Brightness = 40 } }
        $script:PhysicalMonitors = @()

        # No monitors means no operations, but the generation guard must still latch.
        Invoke-DisplayStateRestore -Generation 7 -Reason "test" | Should -BeFalse
        $script:DisplayStateRestoreGeneration | Should -Be 7
        Invoke-DisplayStateRestore -Generation 7 -Reason "test" | Should -BeFalse
    }
}

Describe "Background worker cancellation and teardown" {
    BeforeEach {
        $script:StoppedWorkers = New-Object System.Collections.ArrayList
        $script:DisposedObjects = New-Object System.Collections.ArrayList
    }

    It "stops the in-flight <Name> runspace when cancelled and releases every handle" -ForEach @(
        @{ Name = "MonitorSettings"; Stop = "Stop-MonitorSettingsWorker" }
        @{ Name = "Capabilities"; Stop = "Stop-CapabilitiesWorker" }
        @{ Name = "Vcp"; Stop = "Stop-VcpWorker" }
        @{ Name = "DdcReport"; Stop = "Stop-DdcReportWorker" }
    ) {
        $timer = New-FakeWorkerTimer
        Set-Variable -Name "$($Name)WorkerTimer" -Scope Script -Value $timer
        Set-Variable -Name "$($Name)Worker" -Scope Script -Value (New-FakeWorker)
        Set-Variable -Name "$($Name)WorkerInput" -Scope Script -Value (New-FakeDisposable -Label "input")
        Set-Variable -Name "$($Name)WorkerOutput" -Scope Script -Value (New-FakeDisposable -Label "output")
        Set-Variable -Name "$($Name)WorkerAsyncResult" -Scope Script -Value ([PSCustomObject]@{ IsCompleted = $false })

        & $Stop -Cancel

        $script:StoppedWorkers.Count | Should -Be 1
        $script:DisposedObjects | Should -Contain "worker"
        $script:DisposedObjects | Should -Contain "input"
        $script:DisposedObjects | Should -Contain "output"
        $timer.Running | Should -BeFalse
        (Get-Variable -Name "$($Name)Worker" -Scope Script).Value | Should -BeNullOrEmpty
        (Get-Variable -Name "$($Name)WorkerInput" -Scope Script).Value | Should -BeNullOrEmpty
        (Get-Variable -Name "$($Name)WorkerOutput" -Scope Script).Value | Should -BeNullOrEmpty
        (Get-Variable -Name "$($Name)WorkerAsyncResult" -Scope Script).Value | Should -BeNullOrEmpty
    }

    It "does not stop a completed <Name> runspace but still disposes it" -ForEach @(
        @{ Name = "MonitorSettings"; Stop = "Stop-MonitorSettingsWorker" }
        @{ Name = "Capabilities"; Stop = "Stop-CapabilitiesWorker" }
        @{ Name = "Vcp"; Stop = "Stop-VcpWorker" }
        @{ Name = "DdcReport"; Stop = "Stop-DdcReportWorker" }
    ) {
        Set-Variable -Name "$($Name)WorkerTimer" -Scope Script -Value (New-FakeWorkerTimer)
        Set-Variable -Name "$($Name)Worker" -Scope Script -Value (New-FakeWorker)
        Set-Variable -Name "$($Name)WorkerInput" -Scope Script -Value (New-FakeDisposable -Label "input")
        Set-Variable -Name "$($Name)WorkerOutput" -Scope Script -Value (New-FakeDisposable -Label "output")
        Set-Variable -Name "$($Name)WorkerAsyncResult" -Scope Script -Value ([PSCustomObject]@{ IsCompleted = $true })

        & $Stop -Cancel

        $script:StoppedWorkers.Count | Should -Be 0
        $script:DisposedObjects | Should -Contain "worker"
    }

    It "tears <Name> down without cancelling when no cancel was requested" -ForEach @(
        @{ Name = "MonitorSettings"; Stop = "Stop-MonitorSettingsWorker" }
        @{ Name = "Capabilities"; Stop = "Stop-CapabilitiesWorker" }
        @{ Name = "Vcp"; Stop = "Stop-VcpWorker" }
        @{ Name = "DdcReport"; Stop = "Stop-DdcReportWorker" }
    ) {
        Set-Variable -Name "$($Name)WorkerTimer" -Scope Script -Value (New-FakeWorkerTimer)
        Set-Variable -Name "$($Name)Worker" -Scope Script -Value (New-FakeWorker)
        Set-Variable -Name "$($Name)WorkerInput" -Scope Script -Value $null
        Set-Variable -Name "$($Name)WorkerOutput" -Scope Script -Value $null
        Set-Variable -Name "$($Name)WorkerAsyncResult" -Scope Script -Value ([PSCustomObject]@{ IsCompleted = $false })

        & $Stop

        $script:StoppedWorkers.Count | Should -Be 0
        $script:DisposedObjects | Should -Contain "worker"
    }

    It "is safe to call <Stop> when nothing is running" -ForEach @(
        @{ Name = "MonitorSettings"; Stop = "Stop-MonitorSettingsWorker" }
        @{ Name = "Capabilities"; Stop = "Stop-CapabilitiesWorker" }
        @{ Name = "Vcp"; Stop = "Stop-VcpWorker" }
        @{ Name = "DdcReport"; Stop = "Stop-DdcReportWorker" }
    ) {
        Set-Variable -Name "$($Name)WorkerTimer" -Scope Script -Value $null
        Set-Variable -Name "$($Name)Worker" -Scope Script -Value $null
        Set-Variable -Name "$($Name)WorkerInput" -Scope Script -Value $null
        Set-Variable -Name "$($Name)WorkerOutput" -Scope Script -Value $null
        Set-Variable -Name "$($Name)WorkerAsyncResult" -Scope Script -Value $null

        { & $Stop -Cancel } | Should -Not -Throw
    }
}

Describe "Theme palette single source" {
    BeforeAll {
        $script:AppText = [System.IO.File]::ReadAllText($script:AppPath)
        $script:XamlBrushes = @{}
        foreach ($match in [regex]::Matches($script:AppText, '<SolidColorBrush\s+x:Key="(?<key>\w+)"\s+Color="(?<color>#[0-9a-fA-F]{6})"\s*/>')) {
            $script:XamlBrushes[$match.Groups["key"].Value] = $match.Groups["color"].Value.ToUpperInvariant()
        }
    }

    It "declares a static brush for every palette entry" {
        $palette = Get-AccessibilityThemePalette
        $script:XamlBrushes.Count | Should -Be $palette.Keys.Count
        foreach ($key in $palette.Keys) {
            $script:XamlBrushes.ContainsKey("$($key)Brush") | Should -BeTrue
        }
    }

    It "keeps the static XAML brushes byte-identical to the palette function" {
        $palette = Get-AccessibilityThemePalette
        foreach ($key in $palette.Keys) {
            $script:XamlBrushes["$($key)Brush"] | Should -Be ([string]$palette[$key]).ToUpperInvariant()
        }
    }

    It "leaves no hardcoded colour outside the palette in the tray popup" {
        $start = $script:AppText.IndexOf('[xml]$trayPopupXaml = @"')
        $start | Should -BeGreaterThan 0
        $end = $script:AppText.IndexOf('"@', $start)
        $markup = $script:AppText.Substring($start, $end - $start)

        @([regex]::Matches($markup, '#[0-9a-fA-F]{6}')).Count | Should -Be 0
        $markup | Should -Match "DynamicResource SurfaceBrush"
        $markup | Should -Match "DynamicResource TextBrush"
    }

    It "copies resolved brushes into a detached window" {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:IsHighContrastTheme = $false
        $script:DetachedThemedWindows = New-Object System.Collections.ArrayList
        $detached = New-Object System.Windows.Window
        try {
            Register-DetachedThemedWindow -Target $detached

            $detached.Resources.Contains("SurfaceBrush") | Should -BeTrue
            $detached.Resources.Contains("TextBrush") | Should -BeTrue
            $detached.Resources["SurfaceBrush"] | Should -BeOfType [System.Windows.Media.SolidColorBrush]

            $palette = Get-AccessibilityThemePalette
            $detached.Resources["SurfaceBrush"].Color.ToString().ToUpperInvariant() |
                Should -Be ("#FF" + $palette.Surface.Substring(1).ToUpperInvariant())

            # A later theme change has to reach windows that already exist.
            Update-DetachedWindowThemes
            $detached.Resources.Contains("AccentBrush") | Should -BeTrue

            Unregister-DetachedThemedWindow -Target $detached
            $script:DetachedThemedWindows.Contains($detached) | Should -BeFalse
        } finally {
            try { $detached.Close() } catch {}
        }
    }

    It "builds overlays and markers from theme brushes rather than literals" {
        $script:AppText | Should -Not -Match "\[System\.Windows\.Media\.Brushes\]::White"
        $script:AppText | Should -Not -Match "Color\]::FromArgb\(230"
        $script:AppText | Should -Not -Match "Color\]::FromRgb\(118, 185, 0\)"
    }
}

Describe "Manual VCP write recovery" {
    BeforeEach {
        $script:RiskyVcpCodes = @(0x04, 0x08, 0x14, 0x60, 0xCA, 0xCC, 0xD6, 0xD7, 0xE8, 0xE9)
        $script:RiskyVcpEnabledIdentityKeys = @{ "edid:unlocked" = $true }
        $script:VCPCodeDescriptions = @{ 0x10 = "Brightness"; 0x60 = "Input Source" }
        $script:CurrentMonitorIndex = 0
        $script:PhysicalMonitors = @(
            [PSCustomObject]@{
                IdentityKey = "edid:unlocked"
                Name = "Desk Left"
                Handle = [IntPtr]::new(0x7001)
                CapabilitiesKnown = $false
                SupportedVcpCodes = @{}
                VcpMaximums = @{}
                UserLabel = ""
                DisplayLabel = "Desk Left"
            }
        )
        $script:LastStatusMessage = ""
    }

    It "asks for confirmation before writing and makes no change when declined" {
        $script:ConfirmAsked = $false
        $script:TransactionRan = $false
        $result = Invoke-ManualVcpWrite -Code 0x60 -Value ([uint32]17) -ActionLabel "Switch input" `
            -ConfirmWrite { param([string]$Message) $script:ConfirmMessage = $Message; $script:ConfirmAsked = $true; return $false } `
            -Transaction { param([object[]]$Operations) $script:TransactionRan = $true }

        $script:ConfirmAsked | Should -BeTrue
        $script:ConfirmMessage | Should -Match "Switch input"
        $script:TransactionRan | Should -BeFalse
        $result.Outcome | Should -Be "Canceled"
        $script:LastStatusMessage | Should -Be "VCP write canceled"
    }

    It "requests rollback so a mismatched manual write is restored" {
        $script:RequestedRollback = $false
        $result = Invoke-ManualVcpWrite -Code 0x60 -Value ([uint32]17) -ActionLabel "Switch input" `
            -ConfirmWrite { param([string]$Message) return $true } `
            -Transaction {
                param([object[]]$Operations)
                # Stand in for the real transaction and record that recovery was requested.
                $script:RequestedRollback = $true
                return [PSCustomObject]@{ Success = $false; Outcome = "Mismatched"; Results = @(); Rollback = "Restored" }
            }

        $script:RequestedRollback | Should -BeTrue
        $result.Outcome | Should -Be "Mismatched"
        $script:LastStatusMessage | Should -Match "restore: Restored"
    }

    It "reports a partial restore rather than claiming success" {
        $result = Invoke-ManualVcpWrite -Code 0x60 -Value ([uint32]17) -ActionLabel "Switch input" `
            -ConfirmWrite { param([string]$Message) return $true } `
            -Transaction {
                param([object[]]$Operations)
                return [PSCustomObject]@{ Success = $false; Outcome = "WriteFailed"; Results = @(); Rollback = "Partial" }
            }

        $result.Success | Should -BeFalse
        $script:LastStatusMessage | Should -Match "restore: Partial"
    }

    It "defaults to the rollback-enabled transaction" {
        $definition = (Get-Command Invoke-ManualVcpWrite).Definition
        $definition | Should -Match ([regex]::Escape('Invoke-VerifiedVcpTransaction -Operations $Operations -RollbackOnFailure'))
    }

    It "refuses a gated code on a monitor that has not been unlocked" {
        $script:RiskyVcpEnabledIdentityKeys = @{}
        $result = Invoke-ManualVcpWrite -Code 0x14 -Value ([uint32]5) -ActionLabel "Set color preset" `
            -ConfirmWrite { param([string]$Message) return $true } `
            -Transaction { param([object[]]$Operations) throw "must not write" }

        $result.Outcome | Should -Be "SafetyLocked"
    }
}

Describe "Risky VCP code coverage" {
    BeforeEach {
        $script:RiskyVcpCodes = @(0x04, 0x08, 0x14, 0x60, 0xCA, 0xCC, 0xD6, 0xD7, 0xE8, 0xE9)
    }

    It "gates every code that can outlive the app or lock the user out" {
        foreach ($code in @(0x04, 0x08, 0x14, 0x60, 0xCA, 0xCC, 0xD6, 0xD7, 0xE8, 0xE9)) {
            Test-VcpWriteRequiresSafetyConsent -Code $code | Should -BeTrue
        }
    }

    It "leaves routine continuous codes ungated" {
        foreach ($code in @(0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x87, 0x8D, 0xDC)) {
            Test-VcpWriteRequiresSafetyConsent -Code $code | Should -BeFalse
        }
    }

    It "explains the specific consequence for each gated code" {
        (Get-VcpWriteRiskNote -Code 0x14) | Should -Match "factory reset"
        (Get-VcpWriteRiskNote -Code 0xCA) | Should -Match "buttons"
        (Get-VcpWriteRiskNote -Code 0xD6) | Should -Match "wake"
        (Get-VcpWriteRiskNote -Code 0xD7) | Should -Match "power"
        (Get-VcpWriteRiskNote -Code 0x60) | Should -Match "no signal"
        (Get-VcpWriteRiskNote -Code 0x04) | Should -Match "factory defaults"
        (Get-VcpWriteRiskNote -Code 0x10) | Should -BeNullOrEmpty
    }

    It "puts the specific consequence in the confirmation shown before writing" {
        $operations = @([PSCustomObject]@{ Code = 0x14; Value = [uint32]5; MonitorName = "Desk Left" })
        $text = Format-VcpWriteConfirmation -Operations $operations -ActionLabel "Set color temperature to sRGB"

        $text | Should -Match "Set color temperature to sRGB"
        $text | Should -Match "0x14"
        $text | Should -Match "Desk Left"
        $text | Should -Match "factory reset"
    }

    It "still refuses a gated write through the routine sync path" {
        $script:LastStatusMessage = ""
        Set-VCPValueWithSync -VCPCode ([byte]0x14) -Value ([uint32]5) | Should -BeFalse
        $script:LastStatusMessage | Should -Match "0x14"
    }
}

Describe "Optional helper gating and provenance" {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Remove-Item -Recurse -Force
        $script:OptionalHelperSettingsPath = Join-Path $TestDrive "optional-helpers.json"
        $script:OptionalHelperSchemaVersion = 1
        $script:OptionalHelperMinimumVersions = @{ CpuMonitor = [version]"0.9.0"; PresentMon = [version]"1.6.0" }
        $script:CpuMonitorEnabled = $false
        $script:PresentMonEnabled = $false
        $script:CpuMonitorProvenance = $null
        $script:PresentMonProvenance = $null
        $script:HardwareMonitorComputer = $null
        $script:HasCpuTempMonitor = $false
        $script:PresentMonPath = ""
        $script:LastStatusMessage = ""
    }

    It "parses the version forms a file version resource actually carries" {
        (ConvertTo-HelperVersion -Text "0.9.6.0").ToString() | Should -Be "0.9.6.0"
        (ConvertTo-HelperVersion -Text "2.5.1").ToString() | Should -Be "2.5.1"
        (ConvertTo-HelperVersion -Text "1.6").ToString() | Should -Be "1.6"
        (ConvertTo-HelperVersion -Text "2").ToString() | Should -Be "2.0"
        (ConvertTo-HelperVersion -Text " 2.5.1-beta").ToString() | Should -Be "2.5.1"
        ConvertTo-HelperVersion -Text "" | Should -BeNullOrEmpty
        ConvertTo-HelperVersion -Text "not-a-version" | Should -BeNullOrEmpty
    }

    It "accepts a supported version and refuses one below the minimum" {
        Test-OptionalHelperVersionSupported -Kind "CpuMonitor" -Version ([version]"0.9.6") | Should -BeTrue
        Test-OptionalHelperVersionSupported -Kind "CpuMonitor" -Version ([version]"0.9.0") | Should -BeTrue
        Test-OptionalHelperVersionSupported -Kind "CpuMonitor" -Version ([version]"0.8.9") | Should -BeFalse
        Test-OptionalHelperVersionSupported -Kind "PresentMon" -Version ([version]"2.5.1") | Should -BeTrue
        Test-OptionalHelperVersionSupported -Kind "PresentMon" -Version ([version]"1.5.0") | Should -BeFalse
    }

    It "fails closed for an unknown helper kind or a missing version" {
        Test-OptionalHelperVersionSupported -Kind "Unknown" -Version ([version]"9.9.9") | Should -BeFalse
        Test-OptionalHelperVersionSupported -Kind "PresentMon" -Version $null | Should -BeFalse
    }

    It "reports a missing helper without claiming support" {
        $record = Get-OptionalHelperProvenance -Path (Join-Path $TestDrive "absent.dll") -Kind "CpuMonitor"
        $record.Exists | Should -BeFalse
        $record.Supported | Should -BeFalse
        $record.Reason | Should -Be "File not found"
    }

    It "refuses a file with no readable version resource and still records its hash" {
        $planted = Join-Path $TestDrive "planted.dll"
        [System.IO.File]::WriteAllBytes($planted, [byte[]](1, 2, 3, 4))
        $record = Get-OptionalHelperProvenance -Path $planted -Kind "CpuMonitor"

        $record.Exists | Should -BeTrue
        $record.Supported | Should -BeFalse
        $record.Reason | Should -Match "version resource"
        $record.Sha256 | Should -Match "^[0-9a-f]{64}$"
        $record.Path | Should -Be ([System.IO.Path]::GetFullPath($planted))
    }

    It "classifies a helper outside the known roots as Other" {
        $planted = Join-Path $TestDrive "planted.exe"
        [System.IO.File]::WriteAllBytes($planted, [byte[]](1, 2, 3, 4))
        Get-OptionalHelperSourceCategory -Path $planted | Should -Be "Other"
    }

    It "loads nothing while the CPU helper is disabled" {
        $script:CpuMonitorEnabled = $false
        Initialize-CpuMonitor
        $script:HasCpuTempMonitor | Should -BeFalse
        $script:HardwareMonitorComputer | Should -BeNullOrEmpty
    }

    It "resolves nothing while PresentMon is disabled" {
        $script:PresentMonEnabled = $false
        $script:PresentMonPath = "C:\somewhere\PresentMon.exe"
        Initialize-PresentMon | Should -BeFalse
        $script:PresentMonPath | Should -BeNullOrEmpty
    }

    It "round-trips the enabled flags through disk" {
        $script:CpuMonitorEnabled = $true
        $script:PresentMonEnabled = $true
        Save-OptionalHelperSettings | Out-Null

        $script:CpuMonitorEnabled = $false
        $script:PresentMonEnabled = $false
        Import-OptionalHelperSettings

        $script:CpuMonitorEnabled | Should -BeTrue
        $script:PresentMonEnabled | Should -BeTrue
    }

    It "starts disabled when no settings file exists" {
        $script:CpuMonitorEnabled = $true
        $script:PresentMonEnabled = $true
        Import-OptionalHelperSettings
        $script:CpuMonitorEnabled | Should -BeFalse
        $script:PresentMonEnabled | Should -BeFalse
    }

    It "keeps helpers disabled when the settings schema is from a newer build" {
        $future = [PSCustomObject]@{ SchemaVersion = 99; CpuMonitorEnabled = $true; PresentMonEnabled = $true }
        Write-JsonFileSafely -Path $script:OptionalHelperSettingsPath -Data $future -Depth 4 | Out-Null

        Import-OptionalHelperSettings

        $script:CpuMonitorEnabled | Should -BeFalse
        $script:PresentMonEnabled | Should -BeFalse
        $script:LastStatusMessage | Should -Match "schema v99"
    }

    It "describes a disabled helper without probing the filesystem" {
        Format-OptionalHelperProvenance -Label "PresentMon" -Provenance $null -Enabled $false | Should -Be "PresentMon: disabled"
    }

    It "surfaces path, source, version, and hash once a helper is resolved" {
        $record = [PSCustomObject]@{
            Kind = "PresentMon"
            Path = "C:\Tools\PresentMon.exe"
            Exists = $true
            SourceCategory = "Other"
            ProductVersion = "2.5.1"
            FileVersion = "2.5.1.0"
            Version = [version]"2.5.1.0"
            Sha256 = ("a" * 64)
            Supported = $true
            Reason = "Supported"
        }
        $text = Format-OptionalHelperProvenance -Label "PresentMon" -Provenance $record -Enabled $true

        $text | Should -Match "C:\\Tools\\PresentMon.exe"
        $text | Should -Match "Source: Other"
        $text | Should -Match "2\.5\.1\.0"
        $text | Should -Match ("a" * 64)
    }
}

Describe "Redundant DDC write suppression" {
    BeforeEach {
        [MonitorAPI]::InvalidateVcpValueCache()
        $script:FakeHandleA = [IntPtr]::new(0x5101)
        $script:FakeHandleB = [IntPtr]::new(0x5102)
    }

    AfterAll {
        [MonitorAPI]::InvalidateVcpValueCache()
    }

    It "reports no cached value before anything is observed" {
        $value = [uint32]0
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x10, [ref]$value) | Should -BeFalse
    }

    It "remembers a recorded value per handle and code" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::RecordVcpValue($script:FakeHandleB, [byte]0x10, [uint32]70)
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x12, [uint32]55)

        $value = [uint32]0
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x10, [ref]$value) | Should -BeTrue
        $value | Should -Be 40
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleB, [byte]0x10, [ref]$value) | Should -BeTrue
        $value | Should -Be 70
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x12, [ref]$value) | Should -BeTrue
        $value | Should -Be 55
    }

    It "forgets a value so the next attempt is not suppressed" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ForgetVcpValue($script:FakeHandleA, [byte]0x10)
        $value = [uint32]0
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x10, [ref]$value) | Should -BeFalse
    }

    It "drops every cached value when the topology changes" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::RecordVcpValue($script:FakeHandleB, [byte]0x10, [uint32]70)
        [MonitorAPI]::InvalidateVcpValueCache()
        $value = [uint32]0
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x10, [ref]$value) | Should -BeFalse
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleB, [byte]0x10, [ref]$value) | Should -BeFalse
    }

    It "clears the cache when physical monitor handles are released" {
        $script:PhysicalMonitors = @([PSCustomObject]@{ Handle = $script:FakeHandleA; IdentityKey = "a" })
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        Clear-PhysicalMonitorHandles -ClearList -DestroyHandle { param([IntPtr]$Handle) }

        $value = [uint32]0
        [MonitorAPI]::TryGetVcpValue($script:FakeHandleA, [byte]0x10, [ref]$value) | Should -BeFalse
    }

    It "suppresses a write that matches the last known value" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleA, [byte]0x10, [uint32]40, $false) | Should -BeTrue
    }

    It "does not suppress a write when the value differs" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleA, [byte]0x10, [uint32]41, $false) | Should -BeFalse
    }

    It "does not suppress a write for a different monitor or code" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleB, [byte]0x10, [uint32]40, $false) | Should -BeFalse
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleA, [byte]0x12, [uint32]40, $false) | Should -BeFalse
    }

    It "honours an explicit force even when the value is unchanged" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleA, [byte]0x10, [uint32]40, $true) | Should -BeFalse
    }

    It "issues one write for a repeated ambient target and none after" {
        $handle = $script:FakeHandleA
        $writes = 0
        foreach ($tick in 1..10) {
            $value = [uint32]40
            if ([MonitorAPI]::ShouldSuppressVcpWrite($handle, [byte]0x10, $value, $false)) { continue }
            $writes++
            # Stand in for the queue worker completing the write.
            [MonitorAPI]::RecordVcpValue($handle, [byte]0x10, $value)
        }

        $writes | Should -Be 1
    }

    It "resumes writing after a failed write forgets the cached value" {
        [MonitorAPI]::RecordVcpValue($script:FakeHandleA, [byte]0x10, [uint32]40)
        [MonitorAPI]::ForgetVcpValue($script:FakeHandleA, [byte]0x10)
        [MonitorAPI]::ShouldSuppressVcpWrite($script:FakeHandleA, [byte]0x10, [uint32]40, $false) | Should -BeFalse
    }

    It "never suppresses a write to a null handle" {
        [MonitorAPI]::ShouldSuppressVcpWrite([IntPtr]::Zero, [byte]0x10, [uint32]40, $false) | Should -BeFalse
    }
}

Describe "Profile percentage schema" {
    It "clamps pre-v4 raw values into the percentage domain" {
        $legacy = [PSCustomObject]@{ Brightness = 200; Contrast = 31; Red = -5 }
        Get-ProfilePercentValue -Object $legacy -Property "Brightness" -Default 50 | Should -Be 100
        Get-ProfilePercentValue -Object $legacy -Property "Contrast" -Default 50 | Should -Be 31
        Get-ProfilePercentValue -Object $legacy -Property "Red" -Default 50 | Should -Be 0
        Get-ProfilePercentValue -Object $legacy -Property "Missing" -Default 50 | Should -Be 50
    }

    It "upgrades every legacy profile schema to the percentage schema" {
        foreach ($schema in @(1, 2, 3)) {
            $legacy = [PSCustomObject]@{
                SchemaVersion = $schema
                Name = "Legacy$schema"
                Brightness = 240
                Contrast = 60
            }
            $converted = ConvertTo-CurrentProfileSchema -Profile $legacy -FallbackName "Legacy$schema"
            $converted.SchemaVersion | Should -Be 4
            $converted.Brightness | Should -Be 100
            $converted.Contrast | Should -Be 60
        }
    }

    It "rejects a profile schema newer than this build" {
        $future = [PSCustomObject]@{ SchemaVersion = 5; Name = "Future" }
        { ConvertTo-CurrentProfileSchema -Profile $future -FallbackName "Future" } | Should -Throw
    }
}

Describe "Scheduled profile rule precedence and rollover" {
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

    It "gives the later declaration precedence when rules share a boundary" {
        $script:ProfileSchedules += [pscustomobject]@{ Time = "12:00"; Profile = "Meeting" }

        $active = Get-ActiveScheduleRule -Now ([datetime]"2026-07-01T12:30:00")

        $active.Rule.Profile | Should -Be "Meeting"
        $active.Key | Should -Be "2026-07-01 12:00|Meeting"
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

Describe "System-aware accessibility contract" {
    BeforeAll {
        $script:AccessibilitySource = Get-Content -LiteralPath $script:AppPath -Raw
        $xamlMatch = [regex]::Match($script:AccessibilitySource, '(?s)\[xml\]\$xaml = @"\r?\n(.*?)\r?\n"@')
        if (-not $xamlMatch.Success) { throw "Main XAML block not found." }
        $script:AccessibilityXaml = $xamlMatch.Groups[1].Value
    }

    It "meets WCAG AA text contrast and non-text control contrast in the dark palette" {
        $palette = Get-AccessibilityThemePalette
        $textPairs = @(
            @($palette.Text, $palette.Canvas),
            @($palette.Text, $palette.Surface),
            @($palette.MutedText, $palette.Canvas),
            @($palette.MutedText, $palette.Card),
            @($palette.OnAccent, $palette.Accent),
            @($palette.OnAccent, $palette.AccentHover),
            @($palette.OnAccent, $palette.AccentPressed),
            @($palette.Danger, $palette.DangerSurface),
            @($palette.Warning, $palette.WarningSurface)
        )
        foreach ($pair in $textPairs) {
            (Get-WcagContrastRatio -Foreground $pair[0] -Background $pair[1]) |
                Should -BeGreaterOrEqual 4.5 -Because "$($pair[0]) on $($pair[1]) is normal-sized text"
        }
        foreach ($background in @($palette.Canvas, $palette.Card, $palette.Control)) {
            (Get-WcagContrastRatio -Foreground $palette.Border -Background $background) |
                Should -BeGreaterOrEqual 3.0 -Because "control boundaries must remain distinguishable"
        }
    }

    It "resolves system text scaling deterministically through 200 percent" {
        Resolve-TextScaleFactor -SystemPercent 100 | Should -Be 1.0
        Resolve-TextScaleFactor -SystemPercent 150 | Should -Be 1.5
        Resolve-TextScaleFactor -SystemPercent 200 | Should -Be 2.0
        Resolve-TextScaleFactor -SystemPercent 125 -OverridePercent 200 | Should -Be 2.0
        Resolve-TextScaleFactor -SystemPercent 400 | Should -Be 2.0
    }

    It "keeps shell text at 12 DIPs or larger and makes palette resources dynamic" {
        $fontSizes = @([regex]::Matches($script:AccessibilityXaml, 'FontSize="([0-9]+(?:\.[0-9]+)?)"') | ForEach-Object {
            [double]$_.Groups[1].Value
        })
        ($fontSizes | Measure-Object -Minimum).Minimum | Should -BeGreaterOrEqual 12
        $script:AccessibilityXaml | Should -Match '\{DynamicResource CanvasBrush\}'
        $script:AccessibilityXaml | Should -Match '\{DynamicResource TextBrush\}'
        $script:AccessibilityXaml | Should -Match 'x:Key="KeyboardFocusVisual"'
        $script:AccessibilityXaml | Should -Match 'FocusVisualStyle'
    }

    It "wires live high contrast, per-monitor DPI, keyboard navigation, and assertive errors" {
        $script:AccessibilitySource | Should -Match 'SetProcessDpiAwarenessContext\(\[IntPtr\]\(-4\)\)'
        $script:AccessibilitySource | Should -Match 'SystemEvents\]::add_UserPreferenceChanged'
        $script:AccessibilitySource | Should -Match 'SystemEvents\]::remove_UserPreferenceChanged'
        $script:AccessibilitySource | Should -Match 'AutomationEvents\]::LiveRegionChanged'
        $script:AccessibilityXaml | Should -Match 'AutomationProperties\.LiveSetting="Assertive"'
        $script:AccessibilitySource | Should -Match 'New-Object System\.Windows\.Controls\.Button'
        $script:AccessibilitySource | Should -Match 'Get-NavigationShortcutTarget -Key'
    }

    It "classifies actionable alerts and exposes stable navigation shortcuts" {
        Get-StatusMessageSeverity -Message "Profile import failed" | Should -Be "Error"
        Get-StatusMessageSeverity -Message "VCP write queue is busy; try again" | Should -Be "Warning"
        Get-StatusMessageSeverity -Message "Saved profile" | Should -Be "Info"
        Get-NavigationShortcutTarget -Key "d" | Should -Be "Display"
        Get-NavigationShortcutTarget -Key "S" | Should -Be "System"
        Get-NavigationShortcutTarget -Key "x" | Should -Be ""
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

Describe "Named causes for unavailable DDC control" {
    BeforeAll {
        Import-MonitorControlFunctions -Name @(
            "ConvertTo-DriverVersionParts", "Compare-DisplayDriverVersion", "Test-DisplayDriverVersionInRange",
            "Get-GpuDriverAdvisory", "Get-DisplayPathClassification", "Get-DdcAvailabilityDiagnosis",
            "Get-StatusMessageSeverity"
        )

        # Mirrors the shipped table so the tests exercise the real signatures rather than fixtures.
        $appText = [System.IO.File]::ReadAllText($script:AppPath)
        $start = $appText.IndexOf('$script:DisplayPathSignatures = @(')
        $end = $appText.IndexOf('$script:KnownBadGpuDrivers = @(')
        if ($start -lt 0 -or $end -lt $start) { throw "Display path signature table not found" }
        . ([scriptblock]::Create($appText.Substring($start, $end - $start)))
        $tableEnd = $appText.IndexOf("`n)", $end)
        . ([scriptblock]::Create($appText.Substring($end, $tableEnd - $end + 2)))
        $script:Signatures = @($script:DisplayPathSignatures)
        $script:DriverTable = @($script:KnownBadGpuDrivers)

        function global:New-PathEntry {
            param([string]$Name, [string]$Kind = "Direct", [bool]$HasControlChannel = $true, [string]$Reason = "", [string]$Fix = "")
            return [PSCustomObject]@{
                DeviceName = "\\.\DISPLAY$Name"
                Name = $Name
                Adapter = "Test adapter"
                Kind = $Kind
                HasControlChannel = $HasControlChannel
                Reason = $Reason
                Fix = $Fix
            }
        }
    }

    It "orders dotted driver versions with unequal segment counts" {
        Compare-DisplayDriverVersion -Left "26.1.1" -Right "26.2.1" | Should -Be -1
        Compare-DisplayDriverVersion -Left "26.10.0" -Right "26.9.9" | Should -Be 1
        Compare-DisplayDriverVersion -Left "26.1" -Right "26.1.0" | Should -Be 0
        Compare-DisplayDriverVersion -Left "32.0.12019.1028" -Right "32.0.12019.1028" | Should -Be 0
    }

    It "treats an unreadable version as out of range instead of a match" {
        Test-DisplayDriverVersionInRange -Version "" -From "26.1.1" -Through "26.2.0" | Should -BeFalse
        Test-DisplayDriverVersionInRange -Version "26.1.1" -From "26.1.1" -Through "26.2.0" | Should -BeTrue
        Test-DisplayDriverVersionInRange -Version "26.2.0" -From "26.1.1" -Through "26.2.0" | Should -BeTrue
        Test-DisplayDriverVersionInRange -Version "26.2.1" -From "26.1.1" -Through "26.2.0" | Should -BeFalse
    }

    It "names the shipped AMD regression and the release that fixed it" {
        $gpus = @([PSCustomObject]@{ Name = "AMD Radeon RX 7900 XT"; DriverVersion = "32.0.12019.1028" })
        $advisories = @(Get-GpuDriverAdvisory -Gpus $gpus -BrandingVersions @{ RadeonSoftwareVersion = "26.1.1" } -Table $script:DriverTable)
        $advisories.Count | Should -Be 1
        $advisories[0].FixedIn | Should -Be "26.2.1"
        $advisories[0].Observed | Should -Be "26.1.1"
        $advisories[0].ObservedSource | Should -Be "RadeonSoftwareVersion"
    }

    It "stays silent on a fixed driver, another vendor, and an unknown branding version" {
        $amd = @([PSCustomObject]@{ Name = "AMD Radeon RX 7900 XT"; DriverVersion = "32.0.0.0" })
        @(Get-GpuDriverAdvisory -Gpus $amd -BrandingVersions @{ RadeonSoftwareVersion = "26.2.1" } -Table $script:DriverTable).Count | Should -Be 0
        @(Get-GpuDriverAdvisory -Gpus $amd -BrandingVersions @{} -Table $script:DriverTable).Count | Should -Be 0
        $nvidia = @([PSCustomObject]@{ Name = "NVIDIA GeForce RTX 4080"; DriverVersion = "32.0.15.7283" })
        @(Get-GpuDriverAdvisory -Gpus $nvidia -BrandingVersions @{ RadeonSoftwareVersion = "26.1.1" } -Table $script:DriverTable).Count | Should -Be 0
    }

    It "classifies paths that terminate DDC by design" -ForEach @(
        @{ DeviceString = "DisplayLink USB Device"; HardwareId = ""; Adapter = "DisplayLink USB Graphics"; Kind = "DisplayLink" }
        @{ DeviceString = "Generic Monitor"; HardwareId = "USB\VID_17E9&PID_4301"; Adapter = "USB Graphics"; Kind = "DisplayLink" }
        @{ DeviceString = "spacedesk Display"; HardwareId = ""; Adapter = "spacedesk Graphics Adapter"; Kind = "IndirectDisplay" }
        @{ DeviceString = "Generic Non-PnP Monitor"; HardwareId = "ROOT\DISPLAY\0000"; Adapter = "IddCx Adapter"; Kind = "IndirectDisplay" }
        @{ DeviceString = "Remote Desktop Display"; HardwareId = ""; Adapter = "Microsoft Remote Display Adapter"; Kind = "RemoteSession" }
        @{ DeviceString = "Generic PnP Monitor"; HardwareId = ""; Adapter = "Microsoft Basic Display Adapter"; Kind = "BasicDisplayAdapter" }
        @{ DeviceString = "DELL U2718Q"; HardwareId = "MONITOR\DEL40D5"; Adapter = "NVIDIA GeForce RTX 4080"; Kind = "Direct" }
    ) {
        $classification = Get-DisplayPathClassification -DeviceString $DeviceString -HardwareId $HardwareId -AdapterName $Adapter -Signatures $script:Signatures
        $classification.Kind | Should -Be $Kind
        if ($Kind -eq "Direct") {
            $classification.HasControlChannel | Should -BeTrue
        } else {
            $classification.HasControlChannel | Should -BeFalse
            $classification.Reason | Should -Not -BeNullOrEmpty
            $classification.Fix | Should -Not -BeNullOrEmpty
        }
    }

    It "reports the display count alongside the DDC-capable count" {
        $paths = @(
            (New-PathEntry -Name "One")
            (New-PathEntry -Name "Two" -Kind "DisplayLink" -HasControlChannel $false -Reason "DisplayLink terminates the channel" -Fix "Use a GPU output")
            (New-PathEntry -Name "Three" -Kind "Direct" -HasControlChannel $false)
        )
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths $paths -GpuAdvisories @() -WmiBrightnessAvailable $false
        $diagnosis.DisplayCount | Should -Be 3
        $diagnosis.DdcCapableCount | Should -Be 1
        $diagnosis.Summary | Should -Be "3 display(s) detected, 1 with a DDC/CI control channel"
        $diagnosis.Severity | Should -Be "Warning"
    }

    It "reports a design-terminated path as a named cause rather than a failure" {
        $paths = @(
            (New-PathEntry -Name "Panel" -Kind "DisplayLink" -HasControlChannel $false -Reason "DisplayLink terminates the DDC/CI channel inside its own driver" -Fix "Connect the monitor to a GPU output")
        )
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths $paths -GpuAdvisories @() -WmiBrightnessAvailable $false
        $named = @($diagnosis.Causes | Where-Object { $_.Kind -eq "DisplayLink" })
        $named.Count | Should -Be 1
        $named[0].Title | Should -Match "no control channel"
        $named[0].Detail | Should -Match "DisplayLink"
        @($diagnosis.Causes | Where-Object { $_.Kind -eq "Unclassified" }).Count | Should -Be 0
    }

    It "falls back to hub, adapter, cable, and OSD guidance for an unclassified path" {
        $paths = @((New-PathEntry -Name "Mystery" -Kind "Direct" -HasControlChannel $false))
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths $paths -GpuAdvisories @() -WmiBrightnessAvailable $false
        $unclassified = @($diagnosis.Causes | Where-Object { $_.Kind -eq "Unclassified" })
        $unclassified.Count | Should -Be 1
        $unclassified[0].Detail | Should -Match "MST hub"
        $unclassified[0].Fix | Should -Match "OSD"
    }

    It "leads with the GPU driver advisory when one applies" {
        $paths = @((New-PathEntry -Name "Panel" -Kind "Direct" -HasControlChannel $false))
        $advisories = @([PSCustomObject]@{
            Gpu = "AMD Radeon RX 7900 XT"; Observed = "26.1.1"; ObservedSource = "RadeonSoftwareVersion"
            FixedIn = "26.2.1"; Issue = "DDC/CI writes are dropped"; Reference = "Twinkle Tray 1187"
        })
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths $paths -GpuAdvisories $advisories -WmiBrightnessAvailable $false
        @($diagnosis.Causes)[0].Kind | Should -Be "GpuDriver"
        @($diagnosis.Causes)[0].Title | Should -Match "known to break DDC/CI"
        @($diagnosis.Causes)[0].Fix | Should -Match "26\.2\.1"
    }

    It "stays quiet when every display has a control channel" {
        $paths = @((New-PathEntry -Name "One"), (New-PathEntry -Name "Two"))
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths $paths -GpuAdvisories @() -WmiBrightnessAvailable $false
        $diagnosis.Severity | Should -Be "None"
        @($diagnosis.Causes).Count | Should -Be 0
        $diagnosis.Headline | Should -Be $diagnosis.Summary
    }

    It "raises the alert banner for both the unavailable and the partial headline" {
        $none = Get-DdcAvailabilityDiagnosis -Paths @((New-PathEntry -Name "Panel" -Kind "Direct" -HasControlChannel $false)) -GpuAdvisories @() -WmiBrightnessAvailable $false
        $none.Severity | Should -Be "Error"
        Get-StatusMessageSeverity -Message $none.Headline | Should -Be "Error"
        $none.Headline | Should -Match "DDC Compatibility Report"

        $partial = Get-DdcAvailabilityDiagnosis -Paths @((New-PathEntry -Name "One"), (New-PathEntry -Name "Two" -Kind "Direct" -HasControlChannel $false)) -GpuAdvisories @() -WmiBrightnessAvailable $false
        $partial.Severity | Should -Be "Warning"
        Get-StatusMessageSeverity -Message $partial.Headline | Should -Be "Warning"
    }

    It "never hands a bare $null to a string P/Invoke parameter" {
        # PowerShell marshals $null into a [string] P/Invoke parameter as an empty string, not as
        # NULL, so EnumDisplayDevices($null, ...) silently returns false and enumerates nothing.
        # This is a source-level property: there is no runtime signal to assert against.
        $appText = [System.IO.File]::ReadAllText($script:AppPath)
        $appText | Should -Not -Match 'EnumDisplayDevices\(\$null'
        $appText | Should -Match 'EnumDisplayDevices\(\[NullString\]::Value'
    }

    It "explains a laptop panel that only answers WMI" {
        $diagnosis = Get-DdcAvailabilityDiagnosis -Paths @((New-PathEntry -Name "Internal" -Kind "Direct" -HasControlChannel $false)) -GpuAdvisories @() -WmiBrightnessAvailable $true
        @($diagnosis.Causes | Where-Object { $_.Kind -eq "InternalPanel" }).Count | Should -Be 1
    }
}
