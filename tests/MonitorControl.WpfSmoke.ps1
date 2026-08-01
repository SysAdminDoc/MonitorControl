param(
    [int]$LaunchTimeoutSeconds = 45,
    [ValidateSet("System", "Dark", "HighContrast")]
    [string]$AppTheme = "System",
    [ValidateRange(100, 200)]
    [int]$TextScalePercent = 100,
    [switch]$ResizeToMinimum,
    [switch]$ExerciseValidationAlert,
    [string]$ScreenshotPath = "",
    [string]$ScreenshotDirectory = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appPath = Join-Path $repoRoot "MonitorControlPro.ps1"
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "The WPF smoke test must run in Windows PowerShell 5.1."
}
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) { throw "Application entry point not found: $appPath" }
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw "Windows PowerShell not found: $windowsPowerShell" }

function Get-DirectorySnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return "<missing>" }
    $root = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($root.Length).TrimStart("\")
        if ($item.PSIsContainer) {
            $entries.Add("D|$relative")
            continue
        }
        $stream = $null
        $sha = $null
        try {
            $stream = New-Object System.IO.FileStream(
                $item.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            )
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hash = (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
            $entries.Add("F|$relative|$($item.Length)|$hash")
        } finally {
            if ($stream) { $stream.Dispose() }
            if ($sha) { $sha.Dispose() }
        }
    }
    return ($entries -join "`n")
}

function Remove-ValidatedSmokeDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\") + "\"
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notlike "MonitorControl-WpfSmoke-*") {
        throw "Refusing to remove an unvalidated smoke-test directory: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Get-TabByName {
    param($Root, [string]$Name)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    foreach ($element in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        if ($element.Current.Name -eq $Name) { return $element }
    }
    return $null
}

function Get-ControlByName {
    param($Root, [string]$Name, $ControlType)
    $conditions = @(
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name
        ))
    )
    if ($null -ne $ControlType) {
        $conditions += New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            $ControlType
        )
    }
    $condition = if ($conditions.Count -eq 1) {
        $conditions[0]
    } else {
        New-Object System.Windows.Automation.AndCondition($conditions)
    }
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Save-WindowScreenshot {
    param($Root, [string]$Path)
    Add-Type -AssemblyName System.Drawing
    if (-not ("MonitorControlOffscreenCapture" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class MonitorControlOffscreenCapture
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    public static bool Capture(IntPtr window, IntPtr deviceContext)
    {
        const uint RenderFullContent = 2;
        return PrintWindow(window, deviceContext, RenderFullContent);
    }
}
"@
    }
    $bounds = $Root.Current.BoundingRectangle
    $width = [Math]::Max(1, [int][Math]::Ceiling($bounds.Width))
    $height = [Math]::Max(1, [int][Math]::Ceiling($bounds.Height))
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $deviceContext = [IntPtr]::Zero
        try {
            $deviceContext = $graphics.GetHdc()
            $windowHandle = [IntPtr][int64]$Root.Current.NativeWindowHandle
            if (-not [MonitorControlOffscreenCapture]::Capture($windowHandle, $deviceContext)) {
                throw "PrintWindow could not render the private-desktop application window."
            }
        } finally {
            if ($deviceContext -ne [IntPtr]::Zero) { $graphics.ReleaseHdc($deviceContext) }
            $graphics.Dispose()
        }
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not [string]::IsNullOrWhiteSpace($parentPath)) {
            [System.IO.Directory]::CreateDirectory($parentPath) | Out-Null
        }
        $bitmap.Save($fullPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
}

function Get-PageScreenshotFileName {
    param([string]$PageName)
    $fileName = switch ($PageName) {
        "VCP Explorer" { "vcp-explorer.png" }
        default { ($PageName.ToLowerInvariant() -replace '[^a-z0-9]+', '-') + ".png" }
    }
    return $fileName
}

$realAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
$realProfileRoot = Join-Path $realAppData "MonitorControlPro"
$realProfileBefore = Get-DirectorySnapshot -Path $realProfileRoot
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MonitorControl-WpfSmoke-$([guid]::NewGuid().ToString('N'))"
$sandboxAppData = Join-Path $smokeRoot "AppData\Roaming"
$sandboxLocalAppData = Join-Path $smokeRoot "AppData\Local"
$sandboxProfileRoot = Join-Path $sandboxAppData "MonitorControlPro"
$process = $null
$appWindowHandle = [IntPtr]::Zero
$navigated = New-Object System.Collections.Generic.List[string]
$exitCode = $null
$screenshotWritten = $false

try {
    New-Item -ItemType Directory -Path $sandboxProfileRoot, $sandboxLocalAppData -Force | Out-Null
    $capabilitySettings = [ordered]@{
        SchemaVersion = 1
        ConsentRecorded = $true
        DiscoveryEnabled = $false
        MaximumCompatibility = $true
        ExcludedIdentityKeys = @()
        LastIncidentIdentityKey = ""
        LastIncidentAt = ""
    }
    $capabilityJson = ($capabilitySettings | ConvertTo-Json -Depth 4) + [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        (Join-Path $sandboxProfileRoot "capabilities-safety.json"),
        $capabilityJson,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $windowsPowerShell
    $escapedAppPath = $appPath.Replace('"', '\"')
    $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$escapedAppPath`" -Theme $AppTheme -TextScalePercent $TextScalePercent"
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
        $escapedRenderDirectory = ([System.IO.Path]::GetFullPath($ScreenshotDirectory)).Replace('"', '\"')
        $startInfo.Arguments += " -RenderDirectory `"$escapedRenderDirectory`""
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.EnvironmentVariables["APPDATA"] = $sandboxAppData
    $startInfo.EnvironmentVariables["LOCALAPPDATA"] = $sandboxLocalAppData
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Windows PowerShell did not start." }

    if (-not ("MonitorControlWindowProbe" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MonitorControlWindowProbe
{
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr state);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr state);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int maximumLength);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static IntPtr Find(int processId, string titlePrefix)
    {
        IntPtr match = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr state) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != unchecked((uint)processId) || !IsWindowVisible(window)) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowTextW(window, title, title.Capacity);
            if (!title.ToString().StartsWith(titlePrefix, StringComparison.Ordinal)) return true;
            match = window;
            return false;
        }, IntPtr.Zero);
        return match;
    }

    public static bool RequestClose(IntPtr window)
    {
        const uint Close = 0x0010;
        return PostMessageW(window, Close, IntPtr.Zero, IntPtr.Zero);
    }
}
"@
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($LaunchTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "The WPF process exited during launch with code $($process.ExitCode)." }
        $appWindowHandle = [MonitorControlWindowProbe]::Find($process.Id, "MonitorControl Pro")
    } while ($appWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($appWindowHandle -eq [IntPtr]::Zero) { throw "The WPF window did not appear within $LaunchTimeoutSeconds seconds." }

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    if (-not ("MonitorControlLiveRegionProbe" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class MonitorControlLiveRegionProbe : IDisposable
{
    private const uint LiveRegionChanged = 0x8019;
    private const uint WmQuit = 0x0012;
    private readonly uint processId;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly ManualResetEvent signal = new ManualResetEvent(false);
    private readonly Thread eventThread;
    private WinEventDelegate callback;
    private IntPtr hook;
    private uint eventThreadId;
    private Exception startupError;
    private bool disposed;

    private delegate void WinEventDelegate(
        IntPtr hook,
        uint eventType,
        IntPtr window,
        int objectId,
        int childId,
        uint sourceThreadId,
        uint eventTime);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMessage
    {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
        public uint Private;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(
        uint eventMin,
        uint eventMax,
        IntPtr module,
        WinEventDelegate callback,
        uint processId,
        uint threadId,
        uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out NativeMessage message, IntPtr window, uint min, uint max);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    public MonitorControlLiveRegionProbe(int processId)
    {
        this.processId = unchecked((uint)processId);
        eventThread = new Thread(RunEventLoop);
        eventThread.IsBackground = true;
        eventThread.Name = "MonitorControl live-region probe";
        eventThread.SetApartmentState(ApartmentState.MTA);
        eventThread.Start();
        if (!ready.WaitOne(5000)) throw new TimeoutException("The native accessibility event hook did not initialize.");
        if (startupError != null) throw new InvalidOperationException("The native accessibility event hook failed.", startupError);
    }

    private void RunEventLoop()
    {
        try
        {
            eventThreadId = GetCurrentThreadId();
            callback = OnWinEvent;
            hook = SetWinEventHook(LiveRegionChanged, LiveRegionChanged, IntPtr.Zero, callback, processId, 0, 0);
            if (hook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        catch (Exception exception)
        {
            startupError = exception;
        }
        finally
        {
            ready.Set();
        }

        if (hook == IntPtr.Zero) return;
        NativeMessage message;
        while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { }
    }

    private void OnWinEvent(
        IntPtr eventHook,
        uint eventType,
        IntPtr window,
        int objectId,
        int childId,
        uint sourceThreadId,
        uint eventTime)
    {
        if (eventType == LiveRegionChanged) signal.Set();
    }

    public bool Wait(int millisecondsTimeout)
    {
        return signal.WaitOne(millisecondsTimeout);
    }

    public void Dispose()
    {
        if (disposed) return;
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
        if (eventThreadId != 0) PostThreadMessage(eventThreadId, WmQuit, IntPtr.Zero, IntPtr.Zero);
        eventThread.Join(3000);
        ready.Dispose();
        signal.Dispose();
        disposed = true;
    }
}
"@
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($appWindowHandle)
    if ($null -eq $root -or $root.Current.Name -notlike "MonitorControl Pro*") {
        $actualName = if ($null -eq $root) { "<null>" } else { [string]$root.Current.Name }
        throw "The launched window does not expose the expected MonitorControl Pro UI Automation root (actual: '$actualName', handle: $appWindowHandle)."
    }
    $expectedThemeText = if ($AppTheme -eq "HighContrast") { "High contrast colors are active." } else { "Dark application colors are active." }
    if ($root.Current.HelpText -notlike "$expectedThemeText*Text scale: $TextScalePercent%.*") {
        throw "The UI Automation root did not report the active theme and text scale."
    }

    $isolatedLeft = 0
    $isolatedTop = 0
    $isolatedWidth = 0
    $isolatedHeight = 0
    if ([int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_X, [ref]$isolatedLeft) -and
        [int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_Y, [ref]$isolatedTop) -and
        [int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_WIDTH, [ref]$isolatedWidth) -and
        [int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_HEIGHT, [ref]$isolatedHeight)) {
        $bounds = $root.Current.BoundingRectangle
        if ($bounds.Left -lt $isolatedLeft -or $bounds.Top -lt $isolatedTop -or
            $bounds.Right -gt ($isolatedLeft + $isolatedWidth) -or
            $bounds.Bottom -gt ($isolatedTop + $isolatedHeight)) {
            throw "The WPF window escaped the isolated display bounds."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
        $renderDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $renderCompletePath = Join-Path $ScreenshotDirectory "render.complete"
        $renderErrorPath = Join-Path $ScreenshotDirectory "render.error.txt"
        while (-not (Test-Path -LiteralPath $renderCompletePath -PathType Leaf) -and [DateTime]::UtcNow -lt $renderDeadline) {
            if (Test-Path -LiteralPath $renderErrorPath -PathType Leaf) {
                throw "The app-native render failed: $([System.IO.File]::ReadAllText($renderErrorPath))"
            }
            if ($process.HasExited) { throw "The WPF process exited before app-native renders completed." }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $renderCompletePath -PathType Leaf)) {
            throw "The app-native render did not complete within 30 seconds."
        }
    }

    if ($ResizeToMinimum) {
        $transformObject = $null
        if (-not $root.TryGetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern, [ref]$transformObject)) {
            throw "The main window does not expose the resize pattern."
        }
        $transform = [System.Windows.Automation.TransformPattern]$transformObject
        if (-not $transform.Current.CanResize) { throw "The main window cannot be resized for minimum-size verification." }
        $transform.Resize(920, 640)
        Start-Sleep -Milliseconds 250
    }

    $persistentBrand = Get-ControlByName -Root $root -Name "MonitorControl Pro" -ControlType ([System.Windows.Automation.ControlType]::Text)
    if ($null -eq $persistentBrand) { throw "The persistent application brand was not exposed through UI Automation." }

    foreach ($name in @("Display", "Monitor", "VCP Explorer", "Profiles", "Automation", "System")) {
        $tab = Get-TabByName -Root $root -Name $name
        if ($null -eq $tab) { throw "Required navigation destination '$name' was not exposed through UI Automation." }
        $patternObject = $null
        if (-not $tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject)) {
            throw "Navigation destination '$name' does not expose SelectionItemPattern."
        }
        $selection = [System.Windows.Automation.SelectionItemPattern]$patternObject
        $selection.Select()
        Start-Sleep -Milliseconds 125
        if (-not $selection.Current.IsSelected) { throw "Navigation destination '$name' did not become selected." }
        if ($tab.Current.IsOffscreen) { throw "Navigation destination '$name' remained offscreen after selection." }
        if ($persistentBrand.Current.IsOffscreen) { throw "The persistent header scrolled offscreen after selecting '$name'." }
        $navigated.Add($name)
    }

    # The DDC timing card is the only place adaptive and manual modes can be seen to be
    # mutually exclusive, so drive it rather than assert against the source text.
    $systemTab = Get-TabByName -Root $root -Name "System"
    $systemTabPattern = $null
    if ($systemTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$systemTabPattern)) {
        ([System.Windows.Automation.SelectionItemPattern]$systemTabPattern).Select()
        Start-Sleep -Milliseconds 150
        $displayDdcCategory = Get-TabByName -Root $root -Name "Display and DDC system settings"
        if ($null -eq $displayDdcCategory) { throw "The System page did not expose its Display and DDC category." }
        $displayDdcCategoryPattern = $null
        if (-not $displayDdcCategory.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$displayDdcCategoryPattern)) {
            throw "The Display and DDC category does not expose SelectionItemPattern."
        }
        ([System.Windows.Automation.SelectionItemPattern]$displayDdcCategoryPattern).Select()
        Start-Sleep -Milliseconds 150
        if (-not ([System.Windows.Automation.SelectionItemPattern]$displayDdcCategoryPattern).Current.IsSelected) {
            throw "The Display and DDC category did not become selected."
        }
        $adaptiveRadio = Get-ControlByName -Root $root -Name "Adaptive DDC timing" -ControlType ([System.Windows.Automation.ControlType]::RadioButton)
        $manualRadio = Get-ControlByName -Root $root -Name "Manual DDC timing" -ControlType ([System.Windows.Automation.ControlType]::RadioButton)
        if ($null -eq $adaptiveRadio -or $null -eq $manualRadio) { throw "The DDC timing mode controls were not exposed through UI Automation." }
        foreach ($retryName in @("DDC read retry budget", "DDC write retry budget", "DDC capability retry budget")) {
            $retryBox = Get-ControlByName -Root $root -Name $retryName -ControlType ([System.Windows.Automation.ControlType]::Edit)
            if ($null -eq $retryBox) { throw "The retry budget control '$retryName' was not exposed through UI Automation." }
        }
        if ($null -eq (Get-ControlByName -Root $root -Name "Reset DDC timing calibration for this monitor" -ControlType ([System.Windows.Automation.ControlType]::Button))) {
            throw "The DDC timing calibration reset control was not exposed through UI Automation."
        }
        if ($null -eq (Get-ControlByName -Root $root -Name "Re-read selected monitor DDC values" -ControlType ([System.Windows.Automation.ControlType]::Button))) {
            throw "The selected-monitor DDC re-read control was not exposed through UI Automation."
        }
        $adaptivePattern = $null
        $manualPattern = $null
        if (-not $adaptiveRadio.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$adaptivePattern)) {
            throw "Adaptive DDC timing does not expose SelectionItemPattern."
        }
        if (-not $manualRadio.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$manualPattern)) {
            throw "Manual DDC timing does not expose SelectionItemPattern."
        }
        if (-not ([System.Windows.Automation.SelectionItemPattern]$adaptivePattern).Current.IsSelected) {
            throw "DDC timing did not default to adaptive mode."
        }
        ([System.Windows.Automation.SelectionItemPattern]$manualPattern).Select()
        Start-Sleep -Milliseconds 200
        if (([System.Windows.Automation.SelectionItemPattern]$adaptivePattern).Current.IsSelected) {
            throw "Adaptive and manual DDC timing are not mutually exclusive."
        }
        ([System.Windows.Automation.SelectionItemPattern]$adaptivePattern).Select()
        Start-Sleep -Milliseconds 200
        if (([System.Windows.Automation.SelectionItemPattern]$manualPattern).Current.IsSelected) {
            throw "Manual DDC timing stayed selected after switching back to adaptive."
        }

        $diagnosticsCategory = Get-TabByName -Root $root -Name "Diagnostics system settings"
        if ($null -eq $diagnosticsCategory) { throw "The System page did not expose its Diagnostics category." }
        $diagnosticsCategoryPattern = $null
        if (-not $diagnosticsCategory.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$diagnosticsCategoryPattern)) {
            throw "The Diagnostics category does not expose SelectionItemPattern."
        }
        ([System.Windows.Automation.SelectionItemPattern]$diagnosticsCategoryPattern).Select()
        Start-Sleep -Milliseconds 150
        if ($null -eq (Get-ControlByName -Root $root -Name "Build DDC compatibility report" -ControlType ([System.Windows.Automation.ControlType]::Button))) {
            throw "The Diagnostics category did not expose its named DDC report action."
        }
        ([System.Windows.Automation.SelectionItemPattern]$displayDdcCategoryPattern).Select()
        Start-Sleep -Milliseconds 150
    }

    $displayTab = Get-TabByName -Root $root -Name "Display"
    $displayPattern = $null
    if ($displayTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$displayPattern)) {
        ([System.Windows.Automation.SelectionItemPattern]$displayPattern).Select()
        Start-Sleep -Milliseconds 125
        $monitorButtonCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::HelpTextProperty,
            "Select this display"
        )
        $monitorButton = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $monitorButtonCondition)
        if ($null -ne $monitorButton) {
            $invokeObject = $null
            if (-not $monitorButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)) {
                throw "A display selector does not expose keyboard-equivalent invocation."
            }
            ([System.Windows.Automation.InvokePattern]$invokeObject).Invoke()
            Start-Sleep -Milliseconds 125
        }
    }

    if ($ExerciseValidationAlert) {
        $vcpTab = Get-TabByName -Root $root -Name "VCP Explorer"
        $vcpTabPattern = $null
        if (-not $vcpTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$vcpTabPattern)) {
            throw "VCP Explorer cannot be selected for validation testing."
        }
        ([System.Windows.Automation.SelectionItemPattern]$vcpTabPattern).Select()
        Start-Sleep -Milliseconds 125
        $codeBox = Get-ControlByName -Root $root -Name "VCP code" -ControlType ([System.Windows.Automation.ControlType]::Edit)
        $queryButton = Get-ControlByName -Root $root -Name "Query" -ControlType ([System.Windows.Automation.ControlType]::Button)
        if ($null -eq $codeBox -or $null -eq $queryButton) {
            $editCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            )
            $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button
            )
            $editNames = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition) | ForEach-Object { $_.Current.Name })
            $buttonNames = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition) | ForEach-Object { $_.Current.Name })
            throw "VCP validation controls are not exposed through UI Automation. Edits: $($editNames -join ', '); Buttons: $($buttonNames -join ', ')"
        }
        $valueObject = $null
        $invokeObject = $null
        if (-not $codeBox.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valueObject) -or
            -not $queryButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokeObject)) {
            throw "VCP validation controls do not expose keyboard-equivalent patterns."
        }
        $valuePattern = [System.Windows.Automation.ValuePattern]$valueObject
        $valuePattern.SetValue("not-a-code")
        Start-Sleep -Milliseconds 125
        if ($valuePattern.Current.Value -ne "not-a-code") { throw "The VCP code field did not accept an automation value." }
        $liveRegionProbe = New-Object MonitorControlLiveRegionProbe($process.Id)
        Start-Sleep -Milliseconds 500
        $liveRegionRaised = $false
        try {
            ([System.Windows.Automation.InvokePattern]$invokeObject).Invoke()
            $liveRegionRaised = $liveRegionProbe.Wait(3000)
        } finally {
            $liveRegionProbe.Dispose()
        }
        Start-Sleep -Milliseconds 250
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($appWindowHandle)
        $alert = Get-ControlByName -Root $root -Name "Error: Invalid VCP code" -ControlType ([System.Windows.Automation.ControlType]::Text)
        if ($null -eq $alert) {
            $textCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text
            )
            $textNames = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition) | ForEach-Object { $_.Current.Name })
            throw "The invalid VCP value did not expose an inline alert through UI Automation. Text: $($textNames -join ', ')"
        }
        if ($alert.Current.IsOffscreen) { throw "The inline validation alert exists but UI Automation reports it as offscreen." }
        if (-not $liveRegionRaised) {
            throw "The invalid VCP value did not raise a UI Automation live-region event."
        }
        if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
            Save-WindowScreenshot -Root $root -Path $ScreenshotPath
            $screenshotWritten = $true
        }
        $dismissButton = Get-ControlByName -Root $root -Name "Dismiss" -ControlType ([System.Windows.Automation.ControlType]::Button)
        if ($null -eq $dismissButton) { throw "The inline validation alert has no keyboard-accessible dismiss action." }
        $dismissObject = $null
        if (-not $dismissButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$dismissObject)) {
            throw "The alert dismiss action does not expose InvokePattern."
        }
        ([System.Windows.Automation.InvokePattern]$dismissObject).Invoke()
        Start-Sleep -Milliseconds 125
    }

    $hardwareTab = Get-TabByName -Root $root -Name "Hardware"
    if ($null -ne $hardwareTab -and -not $hardwareTab.Current.IsOffscreen) {
        $patternObject = $null
        if ($hardwareTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$patternObject)) {
            ([System.Windows.Automation.SelectionItemPattern]$patternObject).Select()
            Start-Sleep -Milliseconds 125
            if (-not ([System.Windows.Automation.SelectionItemPattern]$patternObject).Current.IsSelected) {
                throw "The available Hardware destination did not become selected."
            }
            $navigated.Add("Hardware")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
        foreach ($pageName in @($navigated | Select-Object -Unique)) {
            $renderPath = Join-Path $ScreenshotDirectory (Get-PageScreenshotFileName -PageName $pageName)
            if (-not (Test-Path -LiteralPath $renderPath -PathType Leaf) -or (Get-Item -LiteralPath $renderPath).Length -lt 1024) {
                throw "The app-native render for '$pageName' was not produced."
            }
        }
    }

    if (-not $screenshotWritten -and -not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
        Save-WindowScreenshot -Root $root -Path $ScreenshotPath
        $screenshotWritten = $true
    }

    if (-not [MonitorControlWindowProbe]::RequestClose($appWindowHandle)) { throw "The WPF window rejected a normal close request." }
    if (-not $process.WaitForExit(15000)) { throw "The WPF process did not exit after its window closed." }
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0) { throw "The WPF process exited with code $exitCode." }

    $realProfileAfter = Get-DirectorySnapshot -Path $realProfileRoot
    if ($realProfileBefore -cne $realProfileAfter) {
        throw "The WPF smoke test changed the real user profile at $realProfileRoot."
    }
} finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
        } catch {}
        $process.Dispose()
    }
    Remove-ValidatedSmokeDirectory -Path $smokeRoot
}

if (-not $Quiet) {
    Write-Host "WPF smoke passed: $AppTheme theme, $TextScalePercent% text, navigated $($navigated -join ', '); clean exit $exitCode; real profile unchanged."
}
