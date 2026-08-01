function Update-AutomationBridgeBrightnessUi {
    param([double]$RawValue)
    if ($brightnessSlider) { $brightnessSlider.Value = $RawValue }
    if ($brightnessValue) { $brightnessValue.Text = ([int]$RawValue).ToString() }
}

function Set-VcpWorkerUiIdle {
    if ($vcpQueryBtn) { $vcpQueryBtn.IsEnabled = $true }
    if ($vcpScanBtn) { $vcpScanBtn.IsEnabled = $true }
}

function Set-VcpWorkerResultText {
    param([AllowEmptyString()][string]$Text)
    if ($vcpResultBox) { $vcpResultBox.Text = $Text }
}

function Set-DdcReportWorkerUiIdle {
    if ($ddcReportGenerateBtn) { $ddcReportGenerateBtn.IsEnabled = $true }
    if ($ddcReportCopyBtn) { $ddcReportCopyBtn.IsEnabled = $true }
    if ($ddcReportIncludeIdentifiersCheckbox) { $ddcReportIncludeIdentifiersCheckbox.IsEnabled = $true }
    if ($ddcReportIncludeNamesCheckbox) { $ddcReportIncludeNamesCheckbox.IsEnabled = $true }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationTypes, UIAutomationProvider, System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem, System.Management

$script:WinRtDisplayManagerType = $null
try {
    # Windows PowerShell 5.1 needs the assembly-qualified WinRT type name on first use.
    $script:WinRtDisplayManagerType = [Windows.Devices.Display.Core.DisplayManager, Windows.Devices.Display.Core, ContentType=WindowsRuntime]
} catch {
    $script:WinRtDisplayManagerType = $null
}

$nativeCode = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;
using System.Threading;

public class MonitorAPI
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();
    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFOEX {
        public int Size; public RECT Monitor; public RECT WorkArea; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    }
    
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const uint DISPLAY_DEVICE_ACTIVE = 1;
    public const uint MONITORINFOF_PRIMARY = 1;

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte bVCPCode, out uint pvct, out uint pdwCurrentValue, out uint pdwMaximumValue);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetCapabilitiesStringLength(IntPtr hMonitor, out uint pdwCapabilitiesStringLengthInCharacters);
    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr hMonitor, StringBuilder pszASCIICapabilitiesString, uint dwCapabilitiesStringLengthInCharacters);

    private class QueuedVcpWrite {
        public IntPtr Handle;
        public byte Code;
        public uint Value;
        public string Key;
        public string MonitorName;
        public bool Force;
    }

    private class CachedVcpValue {
        public uint Value;
        public DateTime ObservedUtc;
    }

    public delegate bool VcpSetFeatureAdapter(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);

    public class VcpWriteResult {
        public string MonitorName;
        public string Key;
        public byte Code;
        public uint Value;
        public bool Success;
        public int LastError;
        public int Attempts;
        public string ErrorMessage;
        public DateTime TimestampUtc;
    }

    // Last value known to be on the panel for a given handle+code, seeded by successful reads
    // and updated by successful writes. Monitors commonly store these in EEPROM with a limited
    // write endurance, so an unchanged value must not be pushed to the hardware again.
    private static readonly object VcpValueCacheLock = new object();
    private static readonly Dictionary<string, CachedVcpValue> VcpValueCache = new Dictionary<string, CachedVcpValue>();
    public const int VcpValueCacheTtlMilliseconds = 300000;
    private static long SuppressedVcpWrites = 0;

    private static string VcpCacheKey(IntPtr hMonitor, byte bVCPCode)
    {
        return hMonitor.ToInt64().ToString("X") + ":" + bVCPCode.ToString("X2");
    }

    public static void RecordVcpValue(IntPtr hMonitor, byte bVCPCode, uint value)
    {
        RecordVcpValueAt(hMonitor, bVCPCode, value, DateTime.UtcNow);
    }

    public static void RecordVcpValueAt(IntPtr hMonitor, byte bVCPCode, uint value, DateTime observedUtc)
    {
        if (hMonitor == IntPtr.Zero) { return; }
        lock (VcpValueCacheLock)
        {
            VcpValueCache[VcpCacheKey(hMonitor, bVCPCode)] = new CachedVcpValue {
                Value = value,
                ObservedUtc = observedUtc.ToUniversalTime()
            };
        }
    }

    public static void ForgetVcpValue(IntPtr hMonitor, byte bVCPCode)
    {
        if (hMonitor == IntPtr.Zero) { return; }
        lock (VcpValueCacheLock) { VcpValueCache.Remove(VcpCacheKey(hMonitor, bVCPCode)); }
    }

    public static bool TryGetVcpValue(IntPtr hMonitor, byte bVCPCode, out uint value)
    {
        value = 0;
        if (hMonitor == IntPtr.Zero) { return false; }
        lock (VcpValueCacheLock)
        {
            string key = VcpCacheKey(hMonitor, bVCPCode);
            CachedVcpValue cached;
            if (!VcpValueCache.TryGetValue(key, out cached)) { return false; }
            if ((DateTime.UtcNow - cached.ObservedUtc).TotalMilliseconds > VcpValueCacheTtlMilliseconds)
            {
                VcpValueCache.Remove(key);
                return false;
            }
            value = cached.Value;
            return true;
        }
    }

    // Handles are destroyed and reissued on every re-enumeration, so a stale entry could be
    // matched against an unrelated monitor. Any topology change must drop the whole cache.
    public static void InvalidateVcpValueCache()
    {
        lock (VcpValueCacheLock) { VcpValueCache.Clear(); }
    }

    public static void InvalidateVcpValueCacheForHandle(IntPtr hMonitor)
    {
        if (hMonitor == IntPtr.Zero) { return; }
        string prefix = hMonitor.ToInt64().ToString("X") + ":";
        lock (VcpValueCacheLock)
        {
            List<string> matches = new List<string>();
            foreach (string key in VcpValueCache.Keys)
            {
                if (key.StartsWith(prefix, StringComparison.Ordinal)) { matches.Add(key); }
            }
            foreach (string key in matches) { VcpValueCache.Remove(key); }
        }
    }

    public static long GetSuppressedVcpWriteCount()
    {
        return Interlocked.Read(ref SuppressedVcpWrites);
    }

    private static readonly object VcpWriteQueueLock = new object();
    private static readonly Dictionary<string, QueuedVcpWrite> QueuedVcpWrites = new Dictionary<string, QueuedVcpWrite>();
    private static readonly object VcpWriteResultsLock = new object();
    private static readonly List<VcpWriteResult> VcpWriteResults = new List<VcpWriteResult>();
    private static bool VcpWriteWorkerActive = false;
    private static bool VcpWriteCancellationRequested = false;
    private static readonly object VcpSetFeatureAdapterLock = new object();
    private static VcpSetFeatureAdapter VcpSetFeatureOverride = null;
    public const int VcpReadRetryCount = 2;
    public const int VcpWriteRetryCount = 2;
    public const int VcpRetryDelayMilliseconds = 60;
    public const int VcpRetryDelayCeilingMilliseconds = 2000;
    private const int ErrorGraphicsDdcciInvalidData = unchecked((int)0xC0262585);

    public static bool QueueVCPWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, string coalesceKey, string monitorName)
    {
        return QueueVCPWrite(hMonitor, bVCPCode, dwNewValue, coalesceKey, monitorName, false);
    }

    // Pure predicate so the decision can be exercised without touching hardware.
    public static bool ShouldSuppressVcpWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, bool force)
    {
        if (force || hMonitor == IntPtr.Zero) { return false; }
        uint known;
        return TryGetVcpValue(hMonitor, bVCPCode, out known) && known == dwNewValue;
    }

    public static bool QueueVCPWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, string coalesceKey, string monitorName, bool force)
    {
        if (hMonitor == IntPtr.Zero) { return false; }
        if (ShouldSuppressVcpWrite(hMonitor, bVCPCode, dwNewValue, force))
        {
            Interlocked.Increment(ref SuppressedVcpWrites);
            return true;
        }
        string key = String.IsNullOrEmpty(coalesceKey) ? hMonitor.ToInt64().ToString("X") + ":" + bVCPCode.ToString("X2") : coalesceKey;
        lock (VcpWriteQueueLock)
        {
            if (VcpWriteCancellationRequested) { return false; }
            QueuedVcpWrites[key] = new QueuedVcpWrite { Handle = hMonitor, Code = bVCPCode, Value = dwNewValue, Key = key, MonitorName = monitorName, Force = force };
            if (!VcpWriteWorkerActive)
            {
                VcpWriteWorkerActive = true;
                ThreadPool.QueueUserWorkItem(ProcessQueuedVcpWrites);
            }
        }
        return true;
    }

    public static int CancelVCPWrites()
    {
        lock (VcpWriteQueueLock)
        {
            VcpWriteCancellationRequested = true;
            int cancelled = QueuedVcpWrites.Count;
            QueuedVcpWrites.Clear();
            return cancelled;
        }
    }

    public static bool ResumeVCPWrites()
    {
        lock (VcpWriteQueueLock)
        {
            if (VcpWriteWorkerActive) { return false; }
            VcpWriteCancellationRequested = false;
            return true;
        }
    }

    public static bool IsVCPWriteCancellationRequested()
    {
        lock (VcpWriteQueueLock) { return VcpWriteCancellationRequested; }
    }

    public static void SetVcpSetFeatureAdapter(VcpSetFeatureAdapter adapter)
    {
        lock (VcpSetFeatureAdapterLock) { VcpSetFeatureOverride = adapter; }
    }

    public static void ResetVcpSetFeatureAdapter()
    {
        lock (VcpSetFeatureAdapterLock) { VcpSetFeatureOverride = null; }
    }

    private static bool InvokeSetVcpFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue)
    {
        VcpSetFeatureAdapter adapter;
        lock (VcpSetFeatureAdapterLock) { adapter = VcpSetFeatureOverride; }
        return adapter == null ? SetVCPFeature(hMonitor, bVCPCode, dwNewValue) : adapter(hMonitor, bVCPCode, dwNewValue);
    }

    // The delay between retries is a per-monitor property: panels differ by an order of
    // magnitude in how long they need before they will answer a second request. The
    // parameterless overload keeps the shipped default for callers that have no profile.
    public static bool ReadVCPWithRetry(IntPtr hMonitor, byte bVCPCode, int maxRetries, out uint pvct, out uint pdwCurrentValue, out uint pdwMaximumValue, out int lastError, out int attempts)
    {
        return ReadVCPWithRetry(hMonitor, bVCPCode, maxRetries, VcpRetryDelayMilliseconds, out pvct, out pdwCurrentValue, out pdwMaximumValue, out lastError, out attempts);
    }

    public static int ClampRetryDelay(int delayMilliseconds)
    {
        if (delayMilliseconds < 0) { return 0; }
        if (delayMilliseconds > VcpRetryDelayCeilingMilliseconds) { return VcpRetryDelayCeilingMilliseconds; }
        return delayMilliseconds;
    }

    public static bool ReadVCPWithRetry(IntPtr hMonitor, byte bVCPCode, int maxRetries, int delayMilliseconds, out uint pvct, out uint pdwCurrentValue, out uint pdwMaximumValue, out int lastError, out int attempts)
    {
        return ReadVCPWithRetry(hMonitor, bVCPCode, maxRetries, delayMilliseconds, false, out pvct, out pdwCurrentValue, out pdwMaximumValue, out lastError, out attempts);
    }

    public static bool ReadVCPWithRetry(IntPtr hMonitor, byte bVCPCode, int maxRetries, int delayMilliseconds, bool stopOnNullResponse, out uint pvct, out uint pdwCurrentValue, out uint pdwMaximumValue, out int lastError, out int attempts)
    {
        delayMilliseconds = ClampRetryDelay(delayMilliseconds);
        pvct = 0;
        pdwCurrentValue = 0;
        pdwMaximumValue = 0;
        lastError = 0;
        attempts = 0;
        if (maxRetries < 0) { maxRetries = 0; }
        for (int retry = 0; retry <= maxRetries; retry++)
        {
            attempts = retry + 1;
            bool ok = GetVCPFeatureAndVCPFeatureReply(hMonitor, bVCPCode, out pvct, out pdwCurrentValue, out pdwMaximumValue);
            if (ok)
            {
                lastError = 0;
                RecordVcpValue(hMonitor, bVCPCode, pdwCurrentValue);
                return true;
            }
            lastError = Marshal.GetLastWin32Error();
            if (stopOnNullResponse && lastError == ErrorGraphicsDdcciInvalidData) { return false; }
            if (retry < maxRetries) { Thread.Sleep(delayMilliseconds); }
        }
        return false;
    }

    public static bool SetVCPWithRetry(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, int maxRetries, out int lastError, out int attempts)
    {
        return SetVCPWithRetry(hMonitor, bVCPCode, dwNewValue, maxRetries, VcpRetryDelayMilliseconds, out lastError, out attempts);
    }

    public static bool SetVCPWithRetry(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, int maxRetries, int delayMilliseconds, out int lastError, out int attempts)
    {
        delayMilliseconds = ClampRetryDelay(delayMilliseconds);
        lastError = 0;
        attempts = 0;
        if (maxRetries < 0) { maxRetries = 0; }
        for (int retry = 0; retry <= maxRetries; retry++)
        {
            attempts = retry + 1;
            bool ok = InvokeSetVcpFeature(hMonitor, bVCPCode, dwNewValue);
            if (ok)
            {
                lastError = 0;
                RecordVcpValue(hMonitor, bVCPCode, dwNewValue);
                return true;
            }
            lastError = Marshal.GetLastWin32Error();
            if (retry < maxRetries) { Thread.Sleep(delayMilliseconds); }
        }
        ForgetVcpValue(hMonitor, bVCPCode);
        return false;
    }

    private static void AddVcpWriteResult(VcpWriteResult result)
    {
        lock (VcpWriteResultsLock)
        {
            VcpWriteResults.Add(result);
            if (VcpWriteResults.Count > 100)
            {
                VcpWriteResults.RemoveRange(0, VcpWriteResults.Count - 100);
            }
        }
    }

    private static void ProcessQueuedVcpWrites(object state)
    {
        while (true)
        {
            QueuedVcpWrite[] batch;
            lock (VcpWriteQueueLock)
            {
                if (VcpWriteCancellationRequested)
                {
                    QueuedVcpWrites.Clear();
                    VcpWriteWorkerActive = false;
                    return;
                }
                if (QueuedVcpWrites.Count == 0)
                {
                    VcpWriteWorkerActive = false;
                    return;
                }
                batch = new QueuedVcpWrite[QueuedVcpWrites.Count];
                QueuedVcpWrites.Values.CopyTo(batch, 0);
                QueuedVcpWrites.Clear();
            }
            foreach (QueuedVcpWrite write in batch)
            {
                lock (VcpWriteQueueLock)
                {
                    if (VcpWriteCancellationRequested)
                    {
                        VcpWriteWorkerActive = false;
                        return;
                    }
                }
                if (!write.Force)
                {
                    uint known;
                    bool suppress = TryGetVcpValue(write.Handle, write.Code, out known) && known == write.Value;
                    if (!suppress && !TryGetVcpValue(write.Handle, write.Code, out known))
                    {
                        uint valueType = 0;
                        uint currentValue = 0;
                        uint maximumValue = 0;
                        int readError = 0;
                        int readAttempts = 0;
                        suppress = ReadVCPWithRetry(write.Handle, write.Code, 0, out valueType, out currentValue, out maximumValue, out readError, out readAttempts) && currentValue == write.Value;
                    }
                    if (suppress)
                    {
                        Interlocked.Increment(ref SuppressedVcpWrites);
                        Thread.Sleep(50);
                        continue;
                    }
                }
                int lastError = 0;
                int attempts = 0;
                bool success = false;
                string errorMessage = "";
                try
                {
                    success = SetVCPWithRetry(write.Handle, write.Code, write.Value, VcpWriteRetryCount, out lastError, out attempts);
                }
                catch (Exception ex)
                {
                    errorMessage = ex.Message;
                }
                AddVcpWriteResult(new VcpWriteResult {
                    MonitorName = write.MonitorName,
                    Key = write.Key,
                    Code = write.Code,
                    Value = write.Value,
                    Success = success,
                    LastError = lastError,
                    Attempts = attempts,
                    ErrorMessage = errorMessage,
                    TimestampUtc = DateTime.UtcNow
                });
                Thread.Sleep(50);
            }
        }
    }

    public static VcpWriteResult[] DrainVCPWriteResults()
    {
        lock (VcpWriteResultsLock)
        {
            VcpWriteResult[] copy = VcpWriteResults.ToArray();
            VcpWriteResults.Clear();
            return copy;
        }
    }

    public static int GetPendingVCPWriteCount()
    {
        lock (VcpWriteQueueLock) { return QueuedVcpWrites.Count; }
    }

    public static bool IsVCPWriteWorkerActive()
    {
        lock (VcpWriteQueueLock) { return VcpWriteWorkerActive; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

    public const byte VCP_BRIGHTNESS = 0x10, VCP_CONTRAST = 0x12, VCP_COLOR_PRESET = 0x14;
    public const byte VCP_RED_GAIN = 0x16, VCP_GREEN_GAIN = 0x18, VCP_BLUE_GAIN = 0x1A;
    public const byte VCP_SHARPNESS = 0x87, VCP_VOLUME = 0x62, VCP_MUTE = 0x8D;
    public const byte VCP_INPUT_SOURCE = 0x60, VCP_POWER_MODE = 0xD6, VCP_DISPLAY_MODE = 0xDC;
    public const byte VCP_PIP_SECONDARY_SOURCE = 0xE8, VCP_PIP_MODE = 0xE9;
    public const byte VCP_RESTORE_FACTORY_DEFAULTS = 0x04, VCP_RESTORE_FACTORY_COLOR = 0x08;
    public const byte VCP_VERSION = 0xDF, VCP_DISPLAY_USAGE_TIME = 0xC0;
    public const uint POWER_ON = 0x01, POWER_STANDBY = 0x02, POWER_OFF = 0x04;
    public const uint DISPLAY_MODE_STANDARD = 0x00, DISPLAY_MODE_PRODUCTIVITY = 0x01, DISPLAY_MODE_MOVIE = 0x03, DISPLAY_MODE_GAMES = 0x05, DISPLAY_MODE_DYNAMIC_CONTRAST = 0xF0;
    public const uint PIP_MODE_OFF = 0x00, PIP_MODE_UPPER_RIGHT = 0x21, PIP_MODE_PBP_SPLIT = 0x23;
    public const uint PIP_SECONDARY_HDMI1 = 0x11, PIP_SECONDARY_HDMI2 = 0x12, PIP_SECONDARY_DISPLAYPORT = 0x21;
    public const uint COLOR_PRESET_SRGB = 0x01, COLOR_PRESET_5000K = 0x04, COLOR_PRESET_6500K = 0x05, COLOR_PRESET_9300K = 0x08;

    [DllImport("gdi32.dll")]
    public static extern bool SetDeviceGammaRamp(IntPtr hDC, ref RAMP lpRamp);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [StructLayout(LayoutKind.Sequential)]
    public struct RAMP {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Red;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Green;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public ushort[] Blue;
    }

    public static List<IntPtr> MonitorHandles = new List<IntPtr>();
    public static bool MonitorEnumCallback(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData) { MonitorHandles.Add(hMonitor); return true; }
    public static List<IntPtr> GetAllMonitorHandles() { MonitorHandles.Clear(); EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, MonitorEnumCallback, IntPtr.Zero); return MonitorHandles; }
}

public class NvApiInterop
{
    private const int NVAPI_OK = 0;
    private const uint NVAPI_INITIALIZE_ID = 0x0150E828;
    private const uint NVAPI_SET_DVC_LEVEL_ID = 0x172409B4;

    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr QueryInterface(uint functionId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiInitializeDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetDvcLevelDelegate(IntPtr displayHandle, uint outputId, int level);

    private static T GetDelegate<T>(uint functionId) where T : class
    {
        IntPtr ptr = QueryInterface(functionId);
        if (ptr == IntPtr.Zero) { return null; }
        return Marshal.GetDelegateForFunctionPointer(ptr, typeof(T)) as T;
    }

    public static bool SetDigitalVibrance(int level, out string message)
    {
        if (level < 0) { level = 0; }
        if (level > 100) { level = 100; }
        try
        {
            NvApiInitializeDelegate initialize = GetDelegate<NvApiInitializeDelegate>(NVAPI_INITIALIZE_ID);
            NvApiSetDvcLevelDelegate setDvcLevel = GetDelegate<NvApiSetDvcLevelDelegate>(NVAPI_SET_DVC_LEVEL_ID);
            if (initialize == null || setDvcLevel == null)
            {
                message = "NVAPI digital vibrance entry point unavailable";
                return false;
            }
            int status = initialize();
            if (status != NVAPI_OK)
            {
                message = "NVAPI init failed: " + status;
                return false;
            }
            status = setDvcLevel(IntPtr.Zero, 0, level);
            if (status != NVAPI_OK)
            {
                message = "NVAPI digital vibrance failed: " + status;
                return false;
            }
            message = "Digital vibrance set to " + level + "%";
            return true;
        }
        catch (DllNotFoundException)
        {
            message = "nvapi64.dll not found";
            return false;
        }
        catch (EntryPointNotFoundException)
        {
            message = "nvapi_QueryInterface not found";
            return false;
        }
        catch (Exception ex)
        {
            message = "NVAPI digital vibrance error: " + ex.Message;
            return false;
        }
    }
}

public class AmdAdlInterop
{
    private const int ADL_OK = 0;
    private const int ADL_FAN_SPEED_TYPE_PERCENT = 1;
    private static bool initialized = false;
    private static ADL_MAIN_MALLOC_CALLBACK mallocCallback = Alloc;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr ADL_MAIN_MALLOC_CALLBACK(int size);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Main_Control_Create(ADL_MAIN_MALLOC_CALLBACK callback, int enumConnectedAdapters);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Adapter_NumberOfAdapters_Get(ref int numAdapters);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Adapter_AdapterInfo_Get(IntPtr adapterInfo, int inputSize);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Overdrive5_Temperature_Get(int adapterIndex, int thermalControllerIndex, ref ADLTemperature temperature);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Overdrive5_CurrentActivity_Get(int adapterIndex, ref ADLPMActivity activity);

    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ADL_Overdrive5_FanSpeed_Get(int adapterIndex, int thermalControllerIndex, ref ADLFanSpeedValue fanSpeed);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct ADLAdapterInfo
    {
        public int Size;
        public int AdapterIndex;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string UDID;
        public int BusNumber;
        public int DeviceNumber;
        public int FunctionNumber;
        public int VendorID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AdapterName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string DisplayName;
        public int Present;
        public int Exist;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string DriverPath;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string DriverPathExt;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string PNPString;
        public int OSDisplayIndex;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ADLTemperature
    {
        public int Size;
        public int Temperature;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ADLPMActivity
    {
        public int Size;
        public int EngineClock;
        public int MemoryClock;
        public int Vddc;
        public int ActivityPercent;
        public int CurrentPerformanceLevel;
        public int CurrentBusSpeed;
        public int CurrentBusLanes;
        public int MaximumBusLanes;
        public int Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ADLFanSpeedValue
    {
        public int Size;
        public int SpeedType;
        public int FanSpeed;
        public int Flags;
    }

    private static IntPtr Alloc(int size)
    {
        return Marshal.AllocHGlobal(size);
    }

    private static bool EnsureInitialized(out string message)
    {
        if (initialized)
        {
            message = "";
            return true;
        }
        int status = ADL_Main_Control_Create(mallocCallback, 1);
        if (status != ADL_OK)
        {
            message = "ADL init failed: " + status;
            return false;
        }
        initialized = true;
        message = "";
        return true;
    }

    public static bool TryGetStats(out string name, out int tempC, out int utilization, out int engineClockMhz, out int memoryClockMhz, out int fanPercent, out string message)
    {
        name = "AMD Radeon";
        tempC = 0;
        utilization = 0;
        engineClockMhz = 0;
        memoryClockMhz = 0;
        fanPercent = 0;
        try
        {
            if (!EnsureInitialized(out message)) { return false; }
            int adapterCount = 0;
            int status = ADL_Adapter_NumberOfAdapters_Get(ref adapterCount);
            if (status != ADL_OK || adapterCount <= 0)
            {
                message = "No ADL adapters";
                return false;
            }
            int adapterSize = Marshal.SizeOf(typeof(ADLAdapterInfo));
            IntPtr buffer = Marshal.AllocHGlobal(adapterSize * adapterCount);
            int adapterIndex = -1;
            try
            {
                status = ADL_Adapter_AdapterInfo_Get(buffer, adapterSize * adapterCount);
                if (status != ADL_OK)
                {
                    message = "ADL adapter query failed: " + status;
                    return false;
                }
                for (int i = 0; i < adapterCount; i++)
                {
                    IntPtr itemPtr = new IntPtr(buffer.ToInt64() + (adapterSize * i));
                    ADLAdapterInfo info = (ADLAdapterInfo)Marshal.PtrToStructure(itemPtr, typeof(ADLAdapterInfo));
                    if (info.VendorID == 1002 || (info.AdapterName != null && info.AdapterName.ToUpperInvariant().Contains("RADEON")))
                    {
                        adapterIndex = info.AdapterIndex;
                        if (!String.IsNullOrWhiteSpace(info.AdapterName)) { name = info.AdapterName; }
                        break;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            if (adapterIndex < 0)
            {
                message = "No AMD ADL adapter";
                return false;
            }
            bool hasMetric = false;
            ADLTemperature temp = new ADLTemperature();
            temp.Size = Marshal.SizeOf(typeof(ADLTemperature));
            if (ADL_Overdrive5_Temperature_Get(adapterIndex, 0, ref temp) == ADL_OK)
            {
                tempC = temp.Temperature / 1000;
                hasMetric = true;
            }
            ADLPMActivity activity = new ADLPMActivity();
            activity.Size = Marshal.SizeOf(typeof(ADLPMActivity));
            if (ADL_Overdrive5_CurrentActivity_Get(adapterIndex, ref activity) == ADL_OK)
            {
                utilization = activity.ActivityPercent;
                engineClockMhz = activity.EngineClock / 100;
                memoryClockMhz = activity.MemoryClock / 100;
                hasMetric = true;
            }
            ADLFanSpeedValue fan = new ADLFanSpeedValue();
            fan.Size = Marshal.SizeOf(typeof(ADLFanSpeedValue));
            fan.SpeedType = ADL_FAN_SPEED_TYPE_PERCENT;
            if (ADL_Overdrive5_FanSpeed_Get(adapterIndex, 0, ref fan) == ADL_OK)
            {
                fanPercent = fan.FanSpeed;
                hasMetric = true;
            }
            message = hasMetric ? "" : "ADL metrics unavailable";
            return hasMetric;
        }
        catch (DllNotFoundException)
        {
            message = "atiadlxx.dll not found";
            return false;
        }
        catch (EntryPointNotFoundException ex)
        {
            message = "ADL entry point missing: " + ex.Message;
            return false;
        }
        catch (Exception ex)
        {
            message = "ADL error: " + ex.Message;
            return false;
        }
    }
}
"@

function Import-MonitorControlNativeApi {
    param([string]$TypeDefinition, [scriptblock]$CompileType, [scriptblock]$TypeExists)
    if ($null -eq $TypeExists) { $TypeExists = { return $null -ne ("MonitorAPI" -as [type]) } }
    if (& $TypeExists) { return $true }
    if ($null -eq $CompileType) {
        $CompileType = {
            param([string]$Definition)
            Add-Type -TypeDefinition $Definition -ErrorAction Stop | Out-Null
        }
    }
    try {
        & $CompileType $TypeDefinition
    } catch {
        throw "MonitorControl inline C# block failed to compile: $($_.Exception.Message)"
    }
    if (-not (& $TypeExists)) {
        throw "MonitorControl inline C# block failed to compile: expected type MonitorAPI was not created"
    }
    return $true
}

Import-MonitorControlNativeApi -TypeDefinition $nativeCode | Out-Null
try { [MonitorAPI]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch {}

function Set-DeferredStatus {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    try {
        if ($statusText) { Update-Status $Message; return }
    } catch {}
    $script:PendingStatusMessage = $Message
}













$script:PhysicalMonitors = @()
$script:CurrentMonitorIndex = 0
$script:PendingStatusMessage = ""
$script:HasNvidia = $false
$script:HasAmd = $false
$script:HasCpuTempMonitor = $false
$script:NvidiaSmiPath = $null
$script:HardwareMonitorComputer = $null
$script:HardwareMonitorKind = $null
$script:PresentMonPath = $null
$script:FpsOverlayWindow = $null
$script:FpsOverlayText = $null
$script:FpsOverlayTimer = $null
$script:GpuTimer = $null
$script:AutoModeTimer = $null
$script:VcpWorker = $null
$script:VcpWorkerInput = $null
$script:VcpWorkerOutput = $null
$script:VcpWorkerAsyncResult = $null
$script:VcpWorkerTimer = $null
$script:VcpWorkerMode = ""
$script:VcpWorkerMonitorName = ""
$script:VcpWorkerLastOutputCount = 0
$script:VcpWorkerGeneration = -1
$script:VcpWorkerIdentityKey = ""
$script:VcpWorkerMonitorIndex = -1
$script:VcpWorkerHandleValue = [int64]0
$script:MonitorSettingsWorker = $null
$script:MonitorSettingsWorkerInput = $null
$script:MonitorSettingsWorkerOutput = $null
$script:MonitorSettingsWorkerAsyncResult = $null
$script:MonitorSettingsWorkerTimer = $null
$script:MonitorSettingsWorkerIndex = -1
$script:MonitorSettingsWorkerName = ""
$script:MonitorSettingsWorkerLastOutputCount = 0
$script:MonitorSettingsWorkerGeneration = -1
$script:MonitorSettingsWorkerTotalReads = 0
$script:MonitorSettingsWorkerTargets = @()
$script:VerifiedTransactionWorker = $null
$script:VerifiedTransactionWorkerInput = $null
$script:VerifiedTransactionWorkerOutput = $null
$script:VerifiedTransactionWorkerAsyncResult = $null
$script:VerifiedTransactionWorkerTimer = $null
$script:VerifiedTransactionWorkerLastOutputCount = 0
$script:VerifiedTransactionWorkerGeneration = -1
$script:VerifiedTransactionWorkerTargets = @()
$script:VerifiedTransactionWorkerCancelState = $null
$script:VerifiedTransactionWorkerCompletionAction = $null
$script:VerifiedTransactionWorkerActionLabel = ""
$script:VerifiedTransactionWorkerTotalOperations = 0
$script:CapabilitiesWorker = $null
$script:CapabilitiesWorkerInput = $null
$script:CapabilitiesWorkerOutput = $null
$script:CapabilitiesWorkerAsyncResult = $null
$script:CapabilitiesWorkerTimer = $null
$script:CapabilitiesWorkerLastOutputCount = 0
$script:CapabilitiesWorkerGeneration = -1
$script:CapabilitiesSafetySettingsPath = ""
$script:CapabilitiesProbeSentinelPath = ""
$script:CapabilitiesConsentRecorded = $false
$script:CapabilitiesDiscoveryEnabled = $false
$script:CapabilitiesMaximumCompatibility = $false
$script:CapabilitiesExcludedIdentityKeys = @{}
$script:CapabilitiesLastIncidentIdentityKey = ""
$script:CapabilitiesLastIncidentAt = ""
$script:UpdatingCapabilitiesSafetyUI = $false
$script:CapabilitiesConsentPromptHandled = $false
$script:VcpWriteSafetySettingsPath = ""
$script:RiskyVcpEnabledIdentityKeys = @{}
$script:RiskyVcpCodes = @(0x04, 0x08, 0x14, 0x60, 0xCA, 0xCC, 0xD6, 0xD7, 0xE8, 0xE9)
# Continuous VCP codes whose reported maximum is monitor-defined. Stored profile,
# automation, tray, and bridge values for these codes are percentages; the raw value
# is derived per monitor at the write boundary. Discrete codes (color preset, display
# mode, mute, input, power) carry enumerated values and are never rescaled.
$script:VcpScaledCodes = @(0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x87)
$script:VcpDefaultMaximum = 100
$script:UpdatingVcpWriteSafetyUI = $false
$script:DdcReportWorker = $null
$script:DdcReportWorkerInput = $null
$script:DdcReportWorkerOutput = $null
$script:DdcReportWorkerAsyncResult = $null
$script:DdcReportWorkerTimer = $null
$script:DdcReportWorkerLastOutputCount = 0
$script:DdcReportTargets = @()
$script:DdcReportWorkerGeneration = -1
$script:DdcReportLastText = ""
$script:DdcReportLastJson = ""
$script:DdcReportOutputPath = ""
$script:DdcReportIncludeRawMonitorIdentifiers = $false
$script:DdcReportIncludeRawNames = $false
$script:AutomationBridgeSettingsPath = ""
$script:AutomationBridgeEntropyPath = ""
$script:AutomationBridgeWriteLogPath = ""
$script:AutomationBridgeEnabled = $false
$script:AutomationBridgeBindAddress = "127.0.0.1"
$script:AutomationBridgePort = 34291
$script:AutomationBridgeApiKey = ""
$script:AutomationBridgeNetworkExposureApproved = $false
$script:AutomationBridgeNetworkExposureApprovedFor = ""
$script:AutomationBridgeLastError = ""
$script:AutomationBridgeMaxRequestLineBytes = 2048
$script:AutomationBridgeMaxHeaderBytes = 8192
$script:AutomationBridgeMaxHeaderCount = 32
$script:AutomationBridgeMaxQueryParameterCount = 32
$script:AutomationBridgeMaxBodyBytes = 65536
$script:AutomationBridgeMaxResponseBytes = 262144
$script:AutomationBridgeMaxConcurrentClients = 4
$script:AutomationBridgeReadTimeoutMs = 5000
$script:AutomationBridgeWriteTimeoutMs = 5000
$script:AutomationBridgeRouteTimeoutMs = 10000
$script:AutomationBridgeAuditLogMaxBytes = 1048576
$script:AutomationBridgeAllowedCommands = @("list", "readBrightness", "setBrightness", "loadProfile")
$script:AutomationBridgeListener = $null
$script:AutomationBridgeWorker = $null
$script:AutomationBridgeInput = $null
$script:AutomationBridgeOutput = $null
$script:AutomationBridgeAsyncResult = $null
$script:AutomationBridgeTimer = $null
$script:AutomationBridgeRequests = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:AutomationBridgeResponses = [hashtable]::Synchronized(@{})
$script:AutomationBridgeState = [hashtable]::Synchronized(@{ Stop = $false })
$script:UpdatingAutomationBridgeUI = $false
$script:UpdatingRunAtLoginUI = $false
$script:DdcTimingProfiles = @{}
$script:DdcRespondedIdentityKeys = @{}
# ddcutil calls this the sleep multiplier: how much longer than the default a panel
# needs between DDC requests. Calibrated once from the first successful handshake.
$script:DdcTimingMinMultiplier = 1.0
$script:DdcTimingMaxMultiplier = 4.0
$script:DdcTimingMaxRetries = 10
$script:DdcReadRetryCount = [MonitorAPI]::VcpReadRetryCount
$script:DdcWriteRetryCount = [MonitorAPI]::VcpWriteRetryCount
$script:DdcScanRetryCount = 0
$script:DdcRecentErrors = New-Object System.Collections.Generic.List[object]
$script:DdcRecentErrorLimit = 20
$script:DdcWriteResultTimer = $null
$script:DefaultProfilesPath = "$env:APPDATA\MonitorControlPro"
$script:ProfileStorageSettingsPath = Join-Path $script:DefaultProfilesPath "profile-storage.json"
$script:AutomationBridgeSettingsPath = Join-Path $script:DefaultProfilesPath "automation-bridge.json"
$script:AutomationBridgeEntropyPath = Join-Path $script:DefaultProfilesPath "automation-bridge.entropy"
$script:AutomationBridgeWriteLogPath = Join-Path $script:DefaultProfilesPath "automation-bridge-writes.jsonl"
$script:CapabilitiesCachePath = Join-Path $script:DefaultProfilesPath "capabilities-cache.json"
$script:DdcTimingSettingsPath = Join-Path $script:DefaultProfilesPath "ddc-timing.json"
$script:CapabilitiesCache = @{}
# Reading a capability string is the one call Microsoft documents as able to bring down
# Windows on a monitor with a malformed EDID, so a model known to do that is never asked.
# Keyed on the EDID manufacturer + product code. Entries cite the upstream report.
$script:CapabilitiesKnownBadModels = @(
    [PSCustomObject]@{ EdidId = "LTM2C02"; Note = "Counterfeit-EDID LG 27MR400; kernel fault in win32kfull (PowerToys 47556)" }
    [PSCustomObject]@{ EdidId = "GSM7714"; Note = "LG UltraWide HDR WFHD; kernel fault in win32kfull (PowerToys 47968)" }
)
$script:DisplayStateRestoreSettingsPath = Join-Path $script:DefaultProfilesPath "display-restore.json"
# Monitors commonly reset themselves to full brightness after a power cycle or a sleep
# cycle. Restoring is opt-in because it writes to hardware without the user asking.
$script:DisplayStateRestoreEnabled = $false
$script:DisplayStateRestoreValues = @{}
$script:DisplayStateRestoreGeneration = -1
$script:UpdatingDisplayStateRestoreUI = $false
$script:UpdatingDdcTimingUI = $false
$script:OptionalHelperSettingsPath = Join-Path $script:DefaultProfilesPath "optional-helpers.json"
# Optional native helpers are discovered next to the script and on PATH, so they stay off
# until the user enables them. Nothing is loaded or executed before that.
$script:CpuMonitorEnabled = $false
$script:PresentMonEnabled = $false
$script:CpuMonitorProvenance = $null
$script:PresentMonProvenance = $null
$script:OptionalHelperMinimumVersions = @{ CpuMonitor = [version]"0.9.0"; PresentMon = [version]"1.6.0" }
$script:PresentMonTimeoutMs = 8000
$script:PresentMonMaxOutputChars = 262144
$script:UpdatingOptionalHelperUI = $false
$script:CapabilitiesSafetySettingsPath = Join-Path $script:DefaultProfilesPath "capabilities-safety.json"
$script:CapabilitiesProbeSentinelPath = Join-Path $script:DefaultProfilesPath "capabilities-probe-pending.json"
$script:VcpWriteSafetySettingsPath = Join-Path $script:DefaultProfilesPath "vcp-write-safety.json"
$script:ProfilesPath = $script:DefaultProfilesPath
$script:ProfileStorageMode = "Local"
$script:ProfileStorageOffline = $false
$script:ProfileStorageConfiguredPath = $script:DefaultProfilesPath
$script:ProfileStorageFallbackPath = $script:DefaultProfilesPath
$script:ProfileStoragePreviousPath = ""
$script:SettingsDocumentRegistry = Initialize-MonitorControlSettingsDocumentRegistry
$script:ProfileSchemaVersion = [int]$script:SettingsDocumentRegistry.Profile.CurrentVersion
$script:ProfileBundleSchemaVersion = [int]$script:SettingsDocumentRegistry.ProfileBundle.CurrentVersion
$script:ProfileStorageSchemaVersion = [int]$script:SettingsDocumentRegistry.ProfileStorage.CurrentVersion
$script:MonitorIdentitySchemaVersion = [int]$script:SettingsDocumentRegistry.MonitorIdentity.CurrentVersion
$script:AppProfileRulesSchemaVersion = [int]$script:SettingsDocumentRegistry.AppProfileRules.CurrentVersion
$script:ProfileSchedulesSchemaVersion = [int]$script:SettingsDocumentRegistry.ProfileSchedules.CurrentVersion
$script:IdleDimSchemaVersion = [int]$script:SettingsDocumentRegistry.IdleDim.CurrentVersion
$script:BatteryProfileSchemaVersion = [int]$script:SettingsDocumentRegistry.BatteryProfile.CurrentVersion
$script:AutomationBridgeSettingsSchemaVersion = [int]$script:SettingsDocumentRegistry.AutomationBridge.CurrentVersion
$script:CapabilitiesSafetySchemaVersion = [int]$script:SettingsDocumentRegistry.CapabilitiesSafety.CurrentVersion
$script:CapabilitiesProbeSentinelSchemaVersion = [int]$script:SettingsDocumentRegistry.CapabilitiesProbeSentinel.CurrentVersion
$script:VcpWriteSafetySchemaVersion = [int]$script:SettingsDocumentRegistry.VcpWriteSafety.CurrentVersion
$script:OptionalHelperSchemaVersion = [int]$script:SettingsDocumentRegistry.OptionalHelpers.CurrentVersion
$script:DisplayStateRestoreSchemaVersion = [int]$script:SettingsDocumentRegistry.DisplayRestore.CurrentVersion
$script:CapabilitiesCacheSchemaVersion = [int]$script:SettingsDocumentRegistry.CapabilitiesCache.CurrentVersion
$script:DdcTimingSchemaVersion = [int]$script:SettingsDocumentRegistry.DdcTiming.CurrentVersion
$script:ProfileTrashSchemaVersion = [int]$script:SettingsDocumentRegistry.ProfileTrash.CurrentVersion
$script:ProfileTrashPath = Join-Path $script:DefaultProfilesPath "trash"
$script:ProfileTrashMaxRecords = 20
$script:ProfileTrashMaxBytes = 10485760
if (-not (Test-Path -LiteralPath $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
if (Test-Path -LiteralPath $script:ProfileStorageSettingsPath) {
    try {
        $profileStorage = Read-JsonFileSafely -Path $script:ProfileStorageSettingsPath -Label "Profile storage"
        if (-not (Test-SettingsDocumentSupported -Name "ProfileStorage" -Document $profileStorage -Label "Profile storage")) { throw "Unsupported profile storage schema" }
        $storageState = Resolve-ProfileStorageRootState -Settings $profileStorage -DefaultPath $script:DefaultProfilesPath -CurrentSchemaVersion $script:ProfileStorageSchemaVersion
        $script:ProfilesPath = $storageState.ProfilesPath
        $script:ProfileStorageConfiguredPath = $storageState.ConfiguredPath
        $script:ProfileStorageFallbackPath = $storageState.FallbackPath
        $script:ProfileStoragePreviousPath = $storageState.PreviousPath
        $script:ProfileStorageMode = $storageState.Mode
        $script:ProfileStorageOffline = $storageState.Offline
        if ($storageState.Message) {
            Set-DeferredStatus $storageState.Message
        }
    } catch {
        $script:ProfilesPath = $script:DefaultProfilesPath
        $script:ProfileStorageConfiguredPath = $script:DefaultProfilesPath
        $script:ProfileStorageFallbackPath = $script:DefaultProfilesPath
        $script:ProfileStorageOffline = $true
    }
}
$script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
$script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
$script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
$script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
$script:MonitorIdentitySettingsPath = Join-Path $script:ProfilesPath "monitor-identities.json"
$script:ProfileBundleMaxProfiles = 100
$script:ProfileBundleMaxArchiveBytes = 16777216
$script:ProfileBundleMaxManifestBytes = 65536
$script:ProfileBundleMaxEntryBytes = 262144
$script:ProfileBundleMaxTotalBytes = 10485760
$script:ProfileBundleMaxCompressionRatio = 100
$script:ProfileBundleMaxMonitorSettings = 32
$script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
$script:ProfileMetadataFiles = @("app-profile-rules.json", "profile-schedules.json", "idle-dim.json", "battery-profile.json", "profile-storage.json", "monitor-identities.json", "automation-bridge.json", "capabilities-safety.json", "capabilities-probe-pending.json", "vcp-write-safety.json", "optional-helpers.json", "display-restore.json", "capabilities-cache.json", "ddc-timing.json")
$script:MonitorIdentityRecords = @{}
$script:UpdatingMonitorLabelUI = $false
$script:UiCulture = "en-US"
$script:ThemePreference = $Theme
$script:TextScaleOverridePercent = $TextScalePercent
$script:CurrentTextScaleFactor = 1.0
$script:AppliedTextScaleFactor = 1.0
$script:BaseFontSizes = New-Object "System.Collections.Generic.Dictionary[System.Windows.DependencyObject,double]"
$script:SystemPreferenceChangedHandler = $null
$script:IsHighContrastTheme = $false
$script:UiStrings = @{
    "App.Title" = "MonitorControl Pro"
    "App.Subtitle" = "Version $script:AppVersion"
    "Tab.Display" = "Display"
    "Tab.Monitor" = "Monitor"
    "Tab.GPU" = "Hardware"
    "Tab.VCP" = "VCP Explorer"
    "Tab.Profiles" = "Profiles"
    "Tab.Schedule" = "Automation"
    "Tab.System" = "System"
    "Action.AllMonitors" = "All displays"
    "Action.Identify" = "Identify"
    "Action.Refresh" = "Refresh"
    "Action.Save" = "Save"
    "Action.Reset" = "Reset"
    "Action.Query" = "Query"
    "Action.Set" = "Set"
    "Action.ScanAll" = "Scan All"
    "Action.CapsOnly" = "Caps only"
    "Action.Export" = "Export"
    "Action.Import" = "Import"
    "Action.Load" = "Load"
    "Action.Delete" = "Delete"
    "Action.Capture" = "Capture"
    "Action.Add" = "Add"
    "Action.Remove" = "Remove"
    "Action.Start" = "Start"
    "Action.Stop" = "Stop"
    "Action.SyncFolder" = "Sync Folder"
    "Action.UseLocal" = "Use Local"
    "Action.BuildReport" = "Build"
    "Action.Copy" = "Copy"
    "A11y.MonitorCanvas" = "Monitor layout selector"
    "A11y.SelectedMonitor" = "Selected monitor details"
    "A11y.MonitorLabel" = "Custom monitor label"
    "A11y.MonitorIdentity" = "Stable monitor identity"
    "A11y.Brightness" = "Brightness"
    "A11y.Contrast" = "Contrast"
    "A11y.RedGain" = "Red gain"
    "A11y.GreenGain" = "Green gain"
    "A11y.BlueGain" = "Blue gain"
    "A11y.Volume" = "Volume"
    "A11y.Mute" = "Mute"
    "A11y.Sharpness" = "Sharpness"
    "A11y.InputSource" = "Input source"
    "A11y.ProfileName" = "Profile name"
    "A11y.ProfilesList" = "Saved profiles"
    "A11y.VcpCode" = "VCP code"
    "A11y.VcpPreset" = "VCP preset"
    "A11y.VcpSetValue" = "VCP set value"
    "A11y.VcpResults" = "VCP results"
    "A11y.Capabilities" = "Monitor capabilities"
    "A11y.CapabilitiesDiscovery" = "Allow monitor capability discovery"
    "A11y.ClearCapabilityCache" = "Clear cached monitor capabilities"
    "A11y.DdcTimingAdaptive" = "Adaptive DDC timing"
    "A11y.DdcTimingManual" = "Manual DDC timing"
    "A11y.DdcTimingReset" = "Reset DDC timing calibration for this monitor"
    "A11y.DdcValuesReread" = "Re-read selected monitor DDC values"
    "A11y.DdcTimingReadRetries" = "DDC read retry budget"
    "A11y.DdcTimingWriteRetries" = "DDC write retry budget"
    "A11y.DdcTimingCapabilityRetries" = "DDC capability retry budget"
    "A11y.DisplayRestore" = "Restore brightness at launch and after resume"
    "A11y.CpuMonitorHelper" = "Load CPU temperature library"
    "A11y.PresentMonHelper" = "Run PresentMon for the FPS overlay"
    "A11y.OptionalHelperStatus" = "Optional hardware helper provenance"
    "A11y.CapabilitiesCompatibility" = "Maximum compatibility mode"
    "A11y.CapabilitiesExclude" = "Exclude the selected monitor from capability discovery"
    "A11y.CapabilitiesClearExclusions" = "Clear capability discovery exclusions"
    "A11y.RiskyVcp" = "Enable risky VCP writes for the selected monitor identity"
    "A11y.DdcReport" = "DDC compatibility report"
    "A11y.AutomationBridge" = "Local automation bridge"
    "A11y.Status" = "Status"
    "A11y.AppProfileExe" = "Application executable"
    "A11y.AppProfileProfile" = "Application profile"
    "A11y.AppProfileRisky" = "Allow risky VCP writes for this application rule"
    "A11y.AppProfileRules" = "Application profile rules"
    "A11y.ScheduleTime" = "Schedule time"
    "A11y.ScheduleProfile" = "Schedule profile"
    "A11y.ScheduleRisky" = "Allow risky VCP writes for this schedule rule"
    "A11y.ScheduleRules" = "Schedule rules"
    "A11y.IdleMinutes" = "Idle minutes"
    "A11y.IdleBrightness" = "Idle brightness"
    "A11y.BatteryBrightness" = "Battery brightness"
    "A11y.AcBrightness" = "AC brightness"
    "A11y.Gamma" = "Software gamma"
    "A11y.GammaRed" = "Red gamma"
    "A11y.GammaGreen" = "Green gamma"
    "A11y.GammaBlue" = "Blue gamma"
    "A11y.Vibrance" = "Digital vibrance"
    "A11y.BridgeBind" = "Automation bridge bind address"
    "A11y.BridgePort" = "Automation bridge port"
    "A11y.BridgeKey" = "Automation bridge API key"
    "A11y.ScheduleTimeline" = "Profile schedule timeline"
    "A11y.ErrorBanner" = "Application alert"
}
$script:UpdatingUI = $false
$script:UpdatingVcpValueEditor = $false
$script:VcpValueEditorMode = "FreeEntry"
$script:VcpValueEditorAllowsWrite = $true
$script:VcpValueEditorMessage = "Capabilities unknown - enter a value"
$script:ApplyToAll = $false
$script:AutoModeEnabled = $false
$script:WmiBrightnessAvailable = $false
$script:DisplayPathInventory = @()
$script:DdcAvailabilityDiagnosis = $null
$script:GpuDriverAdvisories = @()
# A display can be active in Windows and still have no DDC/CI channel at all.
# These paths terminate DDC/CI by design, so they are named rather than reported
# as a failure to talk to the panel.
$script:DisplayPathSignatures = @(
    [PSCustomObject]@{
        Kind = "DisplayLink"
        Pattern = 'DisplayLink|USB\\VID_17E9'
        Reason = "DisplayLink terminates the DDC/CI channel inside its own driver, so no application can reach the panel over this path"
        Fix = "Connect the monitor to a GPU output to control it, or use the DisplayLink monitor only for output"
    }
    [PSCustomObject]@{
        Kind = "IndirectDisplay"
        Pattern = 'IddCx|Indirect Display|spacedesk|Virtual Display|Duet Display|Amyuni|ROOT\\DISPLAY'
        Reason = "An indirect display is synthesized in software and has no physical DDC/CI channel"
        Fix = "Nothing to fix: there is no panel behind this display to address"
    }
    [PSCustomObject]@{
        Kind = "RemoteSession"
        Pattern = 'Remote Desktop|Microsoft Remote Display|RDPUDD|RDPIDD'
        Reason = "A remote-session display has no physical panel to address"
        Fix = "Run the app on the machine the monitor is attached to"
    }
    [PSCustomObject]@{
        Kind = "BasicDisplayAdapter"
        Pattern = 'Microsoft Basic Display'
        Reason = "The Microsoft Basic Display Adapter is in use, so the vendor driver that carries DDC/CI is not installed"
        Fix = "Install the GPU vendor driver and reboot"
    }
)
# Keyed on the vendor branding version rather than the Win32 driver version,
# because the upstream reports that identify these regressions cite the branded
# release. Each entry names what breaks and the release that fixed it.
$script:KnownBadGpuDrivers = @(
    [PSCustomObject]@{
        NamePattern = 'AMD|Radeon'
        BrandingValueName = "RadeonSoftwareVersion"
        AffectedFrom = "26.1.1"
        AffectedThrough = "26.2.0"
        FixedIn = "26.2.1"
        Issue = "DDC/CI writes are accepted and then dropped, so every Windows brightness tool stops working at once"
        Reference = "Twinkle Tray 1187 and 1210, Monitorian 728"
    }
)
$script:AmbientLightEnabled = $false
$script:AmbientLightSensor = $null
$script:AmbientLightTimer = $null
$script:AppProfileEnabled = $false
$script:AppProfileRules = @()
$script:AppProfileTimer = $null
$script:AppProfileCaptureTimer = $null
$script:UpdatingAppProfileUI = $false
$script:LastForegroundExe = $null
$script:LastAppliedAppProfileKey = $null
$script:ProfileScheduleEnabled = $false
$script:ProfileSchedules = @()
$script:ProfileScheduleTimer = $null
$script:UpdatingScheduleUI = $false
$script:LastAppliedScheduleKey = $null
$script:IdleDimEnabled = $false
$script:IdleDimMinutes = 10
$script:IdleDimBrightness = 20
$script:IdleDimRestoreOnActivity = $true
$script:IdleDimTimer = $null
$script:IdleDimActive = $false
$script:IdleDimPreviousBrightness = $null
$script:UpdatingIdleDimUI = $false
$script:BatteryProfileEnabled = $false
$script:BatteryBrightness = 35
$script:AcBrightness = 75
$script:BatteryProfileTimer = $null
$script:UpdatingBatteryProfileUI = $false
$script:LastPowerLineStatus = $null
$script:TrayIcon = $null
$script:TrayPopup = $null
$script:TrayBrightnessSlider = $null
$script:TrayBrightnessValue = $null
$script:TrayMonitorText = $null
$script:TrayLinkCheckbox = $null
$script:TrayLinkMenuItem = $null
$script:TrayPopupUpdating = $false
$script:TrayHasShownMinimizeTip = $false
$script:TraySuppressWindowStateEvent = $false
$script:IsQuitting = $false
$script:ProfileCycleIndex = -1
$script:DeferredRefreshTimers = @()
$script:DisplayRecoveryGeneration = 1
$script:DisplayRecoveryStates = @{}
$script:DisplayRecoveryPendingReasons = @{}
$script:DisplayRecoveryDebounceTimer = $null
$script:DisplayRecoveryEventPumpTimer = $null
$script:DisplayRecoveryEventQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:DisplayRecoveryHwndSource = $null
$script:DisplayRecoveryWindowHook = $null
$script:WmiBrightnessEventWatcher = $null
$script:WmiBrightnessEventSubscription = $null
$script:DisplayRecoveryEventSourceIdentifier = "MonitorControlPro.WmiBrightness.$PID"
$script:DisplayRecoveryDebounceMilliseconds = 650
$script:DisplayRecoveryOfflineThreshold = 4
$script:DdcLivenessProbeIntervalSeconds = 60
$script:DdcLivenessNextProbeUtc = [DateTime]::UtcNow.AddSeconds($script:DdcLivenessProbeIntervalSeconds)
$script:DdcLivenessLastRecoveryGeneration = 0
$script:DdcLivenessLastSuccessUtc = @{}
$script:DdcLivenessWorker = $null
$script:DdcLivenessWorkerInput = $null
$script:DdcLivenessWorkerOutput = $null
$script:DdcLivenessWorkerAsyncResult = $null
$script:DdcLivenessWorkerGeneration = 0
$script:DdcLivenessWorkerTargets = @()

$script:VCPCodeDescriptions = @{
    0x04 = "Factory Reset"; 0x08 = "Reset Color"; 0x10 = "Brightness"; 0x12 = "Contrast"
    0x14 = "Color Preset"; 0x16 = "Red Gain"; 0x18 = "Green Gain"; 0x1A = "Blue Gain"
    0x60 = "Input Source"; 0x62 = "Volume"; 0x72 = "Gamma"; 0x87 = "Sharpness"; 0x8D = "Mute"
    0xC0 = "Display Usage Time"; 0xC6 = "Application Enable Key"; 0xCA = "OSD/Button Control"; 0xCC = "OSD Language"
    0xCD = "Status Indicators / LED"; 0xD6 = "Power Mode"; 0xD7 = "Aux Power Output"; 0xDC = "Display Mode"; 0xDF = "VCP Version"
    0xE8 = "Secondary Input Source"; 0xE9 = "PiP/PbP Mode"
}



























function Set-ControlVcpSupport {
    param($Control, $Monitor, [int]$Code, $Value = $null, [switch]$Risky)
    if ($null -eq $Control) { return }
    $supported = if ($null -eq $Value) {
        Test-MonitorSupportsVcp -Monitor $Monitor -Code $Code
    } else {
        Test-MonitorSupportsVcpValue -Monitor $Monitor -Code $Code -Value ([int]$Value)
    }
    $safetyEnabled = -not $Risky -or (Test-VcpWriteEnabledForMonitor -Monitor $Monitor)
    $Control.IsEnabled = [bool]($supported -and $safetyEnabled)
    $desc = Get-VcpDescription -Code $Code
    $Control.ToolTip = if (-not $supported) {
        "VCP 0x$("{0:X2}" -f $Code) ($desc) is not reported in this monitor's capabilities."
    } elseif (-not $safetyEnabled) {
        "Enable risky VCP writes for this stable monitor identity in System."
    } else {
        $null
    }
}

function Update-VcpPresetItems {
    param($Monitor)
    if ($null -eq $vcpPresetCombo) { return }
    $selectedCode = if ($vcpPresetCombo.SelectedItem) { [int]$vcpPresetCombo.SelectedItem.Tag } else { $null }
    if ($null -eq $selectedCode -and $vcpCodeBox -and -not [string]::IsNullOrWhiteSpace($vcpCodeBox.Text)) {
        try {
            $codeText = $vcpCodeBox.Text.Trim()
            $selectedCode = if ($codeText -match '^0x') { [Convert]::ToInt32($codeText, 16) } else { [int]$codeText }
        } catch {}
    }
    if ($null -eq $selectedCode) { $selectedCode = [int][MonitorAPI]::VCP_BRIGHTNESS }
    $vcpPresetCombo.Items.Clear()
    foreach ($code in ($script:VCPCodeDescriptions.Keys | Sort-Object)) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $supported = Test-MonitorSupportsVcp -Monitor $Monitor -Code $code
        $suffix = if ($supported) { "" } else { " (not in caps)" }
        $item.Content = "0x{0:X2} - {1}{2}" -f $code, $script:VCPCodeDescriptions[$code], $suffix
        $item.Tag = $code
        $item.IsEnabled = [bool]$supported
        if (-not $supported) { $item.ToolTip = "Not reported in this monitor's capabilities." }
        $vcpPresetCombo.Items.Add($item) | Out-Null
        if ($null -ne $selectedCode -and $selectedCode -eq [int]$code -and $supported) { $vcpPresetCombo.SelectedItem = $item }
    }
    if ($null -eq $vcpPresetCombo.SelectedItem -and $vcpPresetCombo.Items.Count -gt 0) {
        $brightnessItem = @($vcpPresetCombo.Items | Where-Object { $_.IsEnabled -and [int]$_.Tag -eq [int][MonitorAPI]::VCP_BRIGHTNESS } | Select-Object -First 1)
        $firstEnabled = @($vcpPresetCombo.Items | Where-Object { $_.IsEnabled } | Select-Object -First 1)
        if ($brightnessItem.Count -gt 0) { $vcpPresetCombo.SelectedItem = $brightnessItem[0] }
        elseif ($firstEnabled.Count -gt 0) { $vcpPresetCombo.SelectedItem = $firstEnabled[0] }
        else { $vcpPresetCombo.SelectedIndex = 0 }
    }
}

function Update-VcpValueEditorForCurrentCode {
    if ($null -eq $vcpSetValueBox -or $script:UpdatingVcpValueEditor) { return }
    $code = ConvertTo-VcpCode -Text ([string]$vcpCodeBox.Text)
    $script:UpdatingVcpValueEditor = $true
    try {
        $vcpSetValueBox.Visibility = [System.Windows.Visibility]::Collapsed
        $vcpSetValueCombo.Visibility = [System.Windows.Visibility]::Collapsed
        $vcpSetValueRangePanel.Visibility = [System.Windows.Visibility]::Collapsed
        if ($null -eq $code) {
            $script:VcpValueEditorMode = "Unavailable"
            $script:VcpValueEditorAllowsWrite = $false
            $script:VcpValueEditorMessage = "Enter a valid VCP code first"
            $vcpSetValueLabel.Text = $script:VcpValueEditorMessage
            return
        }
        $monitor = if ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
            $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        } else {
            $null
        }
        $model = Get-VcpValueEditorModel -Monitor $monitor -Code ([int]$code)
        $script:VcpValueEditorMode = [string]$model.Mode
        $script:VcpValueEditorAllowsWrite = [bool]$model.AllowsWrite
        $script:VcpValueEditorMessage = [string]$model.Message
        $vcpSetValueLabel.Text = [string]$model.Message
        switch ([string]$model.Mode) {
            "Picker" {
                $previous = ConvertTo-VcpValue -Text ([string]$vcpSetValueBox.Text)
                $vcpSetValueCombo.Items.Clear()
                foreach ($valueItem in @($model.Values)) {
                    $item = New-Object System.Windows.Controls.ComboBoxItem
                    $item.Content = [string]$valueItem.Label
                    $item.Tag = [uint32]$valueItem.Value
                    $vcpSetValueCombo.Items.Add($item) | Out-Null
                    if ($null -ne $previous -and [uint32]$previous -eq [uint32]$valueItem.Value) { $vcpSetValueCombo.SelectedItem = $item }
                }
                if ($null -eq $vcpSetValueCombo.SelectedItem -and $vcpSetValueCombo.Items.Count -gt 0) { $vcpSetValueCombo.SelectedIndex = 0 }
                $vcpSetValueCombo.Visibility = [System.Windows.Visibility]::Visible
            }
            "Range" {
                $vcpSetValueSlider.Minimum = [double]$model.Minimum
                $vcpSetValueSlider.Maximum = [double]$model.Maximum
                $candidate = ConvertTo-VcpValue -Text ([string]$vcpSetValueBox.Text)
                if ($null -eq $candidate) { $candidate = [uint32]$model.Minimum }
                $vcpSetValueSlider.Value = [Math]::Max([double]$model.Minimum, [Math]::Min([double]$model.Maximum, [double]$candidate))
                $vcpSetValueSliderText.Text = ([uint32]$vcpSetValueSlider.Value).ToString()
                $vcpSetValueRangePanel.Visibility = [System.Windows.Visibility]::Visible
            }
            "FreeEntry" { $vcpSetValueBox.Visibility = [System.Windows.Visibility]::Visible }
        }
    } finally {
        $script:UpdatingVcpValueEditor = $false
    }
}

function Get-VcpValueEditorValue {
    switch ($script:VcpValueEditorMode) {
        "Picker" {
            if ($null -eq $vcpSetValueCombo.SelectedItem) { return $null }
            return [uint32]$vcpSetValueCombo.SelectedItem.Tag
        }
        "Range" { return [uint32]$vcpSetValueSlider.Value }
        "FreeEntry" { return ConvertTo-VcpValue -Text ([string]$vcpSetValueBox.Text) }
        default { return $null }
    }
}

function Update-CapabilityControls {
    param($Monitor)
    Set-ControlVcpSupport -Control $brightnessSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_BRIGHTNESS)
    Set-ControlVcpSupport -Control $contrastSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_CONTRAST)
    Set-ControlVcpSupport -Control $redSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_RED_GAIN)
    Set-ControlVcpSupport -Control $greenSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_GREEN_GAIN)
    Set-ControlVcpSupport -Control $blueSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_BLUE_GAIN)
    Set-ControlVcpSupport -Control $volumeSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_VOLUME)
    Set-ControlVcpSupport -Control $muteCheckbox -Monitor $Monitor -Code ([MonitorAPI]::VCP_MUTE)
    Set-ControlVcpSupport -Control $sharpnessSlider -Monitor $Monitor -Code ([MonitorAPI]::VCP_SHARPNESS)
    Set-ControlVcpSupport -Control $inputSourceCombo -Monitor $Monitor -Code ([MonitorAPI]::VCP_INPUT_SOURCE) -Risky
    Set-ControlVcpSupport -Control $powerOffBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_OFF) -Risky
    Set-ControlVcpSupport -Control $powerStandbyBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) -Risky
    Set-ControlVcpSupport -Control $powerOnBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_ON) -Risky
    Set-ControlVcpSupport -Control $resetColorBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_COLOR) -Value 1 -Risky
    Set-ControlVcpSupport -Control $factoryResetBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_DEFAULTS) -Value 1 -Risky
    Set-ControlVcpSupport -Control $allMonitorsStandbyBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) -Risky
    Set-ControlVcpSupport -Control $colorTempWarm -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_5000K) -Risky
    Set-ControlVcpSupport -Control $colorTemp6500 -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_6500K) -Risky
    Set-ControlVcpSupport -Control $colorTempCool -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_9300K) -Risky
    Set-ControlVcpSupport -Control $colorTempSRGB -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_SRGB) -Risky
    Set-ControlVcpSupport -Control $dynamicContrastOff -Monitor $Monitor -Code ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_STANDARD)
    Set-ControlVcpSupport -Control $dynamicContrastOn -Monitor $Monitor -Code ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_DYNAMIC_CONTRAST)
    Set-ControlVcpSupport -Control $pictureModeWeb -Monitor $Monitor -Code ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_PRODUCTIVITY)
    Set-ControlVcpSupport -Control $pictureModeCinema -Monitor $Monitor -Code ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_MOVIE)
    Set-ControlVcpSupport -Control $pictureModeGame -Monitor $Monitor -Code ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_GAMES)
    Set-ControlVcpSupport -Control $pipPbpOffBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_OFF) -Risky
    Set-ControlVcpSupport -Control $pipModeBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_UPPER_RIGHT) -Risky
    Set-ControlVcpSupport -Control $pbpModeBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_PBP_SPLIT) -Risky
    Set-ControlVcpSupport -Control $pipSecondaryDpBtn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_DISPLAYPORT) -Risky
    Set-ControlVcpSupport -Control $pipSecondaryHdmi1Btn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI1) -Risky
    Set-ControlVcpSupport -Control $pipSecondaryHdmi2Btn -Monitor $Monitor -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI2) -Risky
    $brightnessSupported = Test-MonitorSupportsVcp -Monitor $Monitor -Code ([MonitorAPI]::VCP_BRIGHTNESS)
    foreach ($control in @($presetDay, $presetNight, $presetAutoMode, $presetAmbientMode, $presetReset)) {
        if ($control) {
            $control.IsEnabled = [bool]$brightnessSupported
            $control.ToolTip = if ($brightnessSupported) { $null } else { "Brightness VCP 0x10 is not reported in this monitor's capabilities." }
        }
    }
    foreach ($item in @($inputSourceCombo.Items)) {
        if ($null -ne $item.Tag) {
            $supported = Test-MonitorSupportsVcpValue -Monitor $Monitor -Code ([MonitorAPI]::VCP_INPUT_SOURCE) -Value ([int]$item.Tag)
            $item.IsEnabled = [bool]$supported
            $item.ToolTip = if ($supported) { $null } else { "Input value 0x$("{0:X2}" -f [int]$item.Tag) is not reported in capabilities." }
        }
    }
    Update-VcpPresetItems -Monitor $Monitor
    Update-VcpValueEditorForCurrentCode
    Update-RiskyVcpControlState -Monitor $Monitor
}

function Update-RiskyVcpControlState {
    param($Monitor)
    if ($vcpSetBtn) {
        $identityEnabled = Test-VcpWriteEnabledForMonitor -Monitor $Monitor
        $editorAllowsWrite = $null -eq $script:VcpValueEditorAllowsWrite -or [bool]$script:VcpValueEditorAllowsWrite
        $vcpSetBtn.IsEnabled = [bool]($identityEnabled -and $editorAllowsWrite)
        $vcpSetBtn.ToolTip = if (-not $editorAllowsWrite) {
            $script:VcpValueEditorMessage
        } elseif (-not $identityEnabled) {
            "Arbitrary VCP writes require the selected stable monitor identity to be enabled in System."
        } else {
            "Every direct write requires an exact code/value confirmation."
        }
    }
    if ($allMonitorsStandbyBtn -and $allMonitorsStandbyBtn.IsEnabled) {
        foreach ($candidate in @($script:PhysicalMonitors)) {
            if ($candidate.Handle -ne [IntPtr]::Zero -and -not (Test-VcpWriteEnabledForMonitor -Monitor $candidate)) {
                $allMonitorsStandbyBtn.IsEnabled = $false
                $allMonitorsStandbyBtn.ToolTip = "Enable risky VCP writes separately for every connected DDC/CI monitor."
                break
            }
        }
    }
    Sync-VcpWriteSafetyUi
}







































function Update-MonitorIdentityControls {
    if ($null -eq $monitorLabelBox -or $null -eq $monitorIdentityText) { return }
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    $script:UpdatingMonitorLabelUI = $true
    try {
        $monitorLabelBox.Text = if (-not [string]::IsNullOrWhiteSpace([string]$mon.UserLabel)) { [string]$mon.UserLabel } else { "" }
        $identitySummary = if (-not [string]::IsNullOrWhiteSpace([string]$mon.Manufacturer)) {
            "Identity: $($mon.Manufacturer) $($mon.EdidModel) $($mon.EdidSerial)"
        } else {
            "Identity: $($mon.IdentitySource)"
        }
        $monitorIdentityText.Text = $identitySummary
        $monitorIdentityText.ToolTip = "Key: $($mon.IdentityKey)`nDevice: $($mon.DevicePath)"
    } finally {
        $script:UpdatingMonitorLabelUI = $false
    }
}

function Set-MonitorUserLabel {
    param($Monitor, [string]$Label)
    if ($null -eq $Monitor -or [string]::IsNullOrWhiteSpace([string]$Monitor.IdentityKey)) { return $false }
    $cleanLabel = if ($null -eq $Label) { "" } else { $Label.Trim() }
    if ($cleanLabel.Length -gt 80) { $cleanLabel = $cleanLabel.Substring(0, 80) }
    $record = Get-MonitorIdentityRecord -Monitor $Monitor
    if ($null -eq $record) {
        $record = [PSCustomObject]@{
            Key = [string]$Monitor.IdentityKey
            Label = ""
            DefaultLabel = [string]$Monitor.IdentityDefaultLabel
            Source = [string]$Monitor.IdentitySource
            DevicePath = [string]$Monitor.DevicePath
            HardwareId = [string]$Monitor.HardwareId
            Manufacturer = [string]$Monitor.Manufacturer
            Model = [string]$Monitor.EdidModel
            Serial = [string]$Monitor.EdidSerial
            EdidName = [string]$Monitor.EdidName
            UpdatedAt = ""
        }
    }
    $record.Label = $cleanLabel
    $record.DefaultLabel = [string]$Monitor.IdentityDefaultLabel
    $record.Source = [string]$Monitor.IdentitySource
    $record.DevicePath = [string]$Monitor.DevicePath
    $record.HardwareId = [string]$Monitor.HardwareId
    $record.Manufacturer = [string]$Monitor.Manufacturer
    $record.Model = [string]$Monitor.EdidModel
    $record.Serial = [string]$Monitor.EdidSerial
    $record.EdidName = [string]$Monitor.EdidName
    $record.UpdatedAt = (Get-Date).ToString("o")
    $script:MonitorIdentityRecords[[string]$Monitor.IdentityKey] = $record
    if (-not (Save-MonitorIdentitySettings)) { return $false }
    Apply-MonitorIdentity -Monitor $Monitor
    Draw-MonitorLayout
    Update-MonitorIdentityControls
    Update-TrayPopupState
    Update-TrayIconText
    return $true
}

function Get-AccessibilityThemePalette {
    return [ordered]@{
        Canvas = "#07111C"
        Sidebar = "#091420"
        Header = "#0A1522"
        Footer = "#08131F"
        Surface = "#111D2B"
        Card = "#142235"
        CardHover = "#1A2C43"
        Control = "#0B1724"
        Track = "#35475A"
        Border = "#586E84"
        Accent = "#2563C7"
        AccentHover = "#2D6BCD"
        AccentPressed = "#1E54B5"
        Focus = "#65A2FF"
        Text = "#F2F5F9"
        MutedText = "#A0ADBC"
        OnAccent = "#FFFFFF"
        Success = "#61D683"
        Warning = "#F2B452"
        WarningSurface = "#312719"
        Danger = "#FF6666"
        DangerSurface = "#321D24"
    }
}









function Set-ApplicationTextScale {
    param([double]$Scale)
    if ($null -eq $window) { return }

    $elements = New-Object "System.Collections.Generic.List[System.Windows.DependencyObject]"
    $queue = New-Object "System.Collections.Generic.Queue[System.Windows.DependencyObject]"
    $visited = New-Object "System.Collections.Generic.HashSet[System.Windows.DependencyObject]"
    $queue.Enqueue($window)
    while ($queue.Count -gt 0) {
        $element = $queue.Dequeue()
        if (-not $visited.Add($element)) { continue }
        if ($element -is [System.Windows.Controls.Control] -or $element -is [System.Windows.Controls.TextBlock]) {
            $isSymbol = $element -is [System.Windows.Controls.TextBlock] -and
                $null -ne $element.FontFamily -and
                $element.FontFamily.Source -eq "Segoe MDL2 Assets"
            if (-not $isSymbol) { $elements.Add($element) }
        }
        try {
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($element)) {
                if ($child -is [System.Windows.DependencyObject]) { $queue.Enqueue($child) }
            }
        } catch {}
    }

    foreach ($element in $elements) {
        $fontSizeProperty = if ($element -is [System.Windows.Controls.TextBlock]) {
            [System.Windows.Controls.TextBlock]::FontSizeProperty
        } else {
            [System.Windows.Controls.Control]::FontSizeProperty
        }
        if (-not $script:BaseFontSizes.ContainsKey($element)) {
            $baseFontSize = [double]$element.GetValue($fontSizeProperty)
            $valueSource = [System.Windows.DependencyPropertyHelper]::GetValueSource($element, $fontSizeProperty)
            if ($valueSource.BaseValueSource -eq [System.Windows.BaseValueSource]::Inherited -and
                $script:AppliedTextScaleFactor -gt 0) {
                $baseFontSize = $baseFontSize / $script:AppliedTextScaleFactor
            }
            $script:BaseFontSizes.Add($element, $baseFontSize)
        }
    }
    foreach ($element in $elements) {
        $fontSizeProperty = if ($element -is [System.Windows.Controls.TextBlock]) {
            [System.Windows.Controls.TextBlock]::FontSizeProperty
        } else {
            [System.Windows.Controls.Control]::FontSizeProperty
        }
        $element.SetValue($fontSizeProperty, [double]($script:BaseFontSizes[$element] * $Scale))
    }
    $script:AppliedTextScaleFactor = $Scale
}

function ConvertTo-ThemeBrush {
    param([string]$Color)
    $brush = New-Object System.Windows.Media.SolidColorBrush (
        [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    )
    if ($brush.CanFreeze) { $brush.Freeze() }
    return $brush
}

function Get-ThemeBrushMap {
    param([bool]$HighContrast)
    if ($HighContrast) {
        [ordered]@{
            CanvasBrush = [System.Windows.SystemColors]::WindowBrush
            SidebarBrush = [System.Windows.SystemColors]::ControlBrush
            HeaderBrush = [System.Windows.SystemColors]::ControlBrush
            FooterBrush = [System.Windows.SystemColors]::ControlBrush
            SurfaceBrush = [System.Windows.SystemColors]::WindowBrush
            CardBrush = [System.Windows.SystemColors]::ControlBrush
            CardHoverBrush = [System.Windows.SystemColors]::HighlightBrush
            ControlBrush = [System.Windows.SystemColors]::WindowBrush
            TrackBrush = [System.Windows.SystemColors]::WindowTextBrush
            BorderBrush = [System.Windows.SystemColors]::WindowTextBrush
            AccentBrush = [System.Windows.SystemColors]::HighlightBrush
            AccentHoverBrush = [System.Windows.SystemColors]::HighlightBrush
            AccentPressedBrush = [System.Windows.SystemColors]::HighlightBrush
            FocusBrush = [System.Windows.SystemColors]::HighlightBrush
            TextBrush = [System.Windows.SystemColors]::WindowTextBrush
            MutedTextBrush = [System.Windows.SystemColors]::WindowTextBrush
            OnAccentBrush = [System.Windows.SystemColors]::HighlightTextBrush
            SuccessBrush = [System.Windows.SystemColors]::WindowTextBrush
            WarningBrush = [System.Windows.SystemColors]::WindowTextBrush
            WarningSurfaceBrush = [System.Windows.SystemColors]::WindowBrush
            DangerBrush = [System.Windows.SystemColors]::WindowTextBrush
            DangerSurfaceBrush = [System.Windows.SystemColors]::WindowBrush
        }
    } else {
        $palette = Get-AccessibilityThemePalette
        [ordered]@{
            CanvasBrush = ConvertTo-ThemeBrush $palette.Canvas
            SidebarBrush = ConvertTo-ThemeBrush $palette.Sidebar
            HeaderBrush = ConvertTo-ThemeBrush $palette.Header
            FooterBrush = ConvertTo-ThemeBrush $palette.Footer
            SurfaceBrush = ConvertTo-ThemeBrush $palette.Surface
            CardBrush = ConvertTo-ThemeBrush $palette.Card
            CardHoverBrush = ConvertTo-ThemeBrush $palette.CardHover
            ControlBrush = ConvertTo-ThemeBrush $palette.Control
            TrackBrush = ConvertTo-ThemeBrush $palette.Track
            BorderBrush = ConvertTo-ThemeBrush $palette.Border
            AccentBrush = ConvertTo-ThemeBrush $palette.Accent
            AccentHoverBrush = ConvertTo-ThemeBrush $palette.AccentHover
            AccentPressedBrush = ConvertTo-ThemeBrush $palette.AccentPressed
            FocusBrush = ConvertTo-ThemeBrush $palette.Focus
            TextBrush = ConvertTo-ThemeBrush $palette.Text
            MutedTextBrush = ConvertTo-ThemeBrush $palette.MutedText
            OnAccentBrush = ConvertTo-ThemeBrush $palette.OnAccent
            SuccessBrush = ConvertTo-ThemeBrush $palette.Success
            WarningBrush = ConvertTo-ThemeBrush $palette.Warning
            WarningSurfaceBrush = ConvertTo-ThemeBrush $palette.WarningSurface
            DangerBrush = ConvertTo-ThemeBrush $palette.Danger
            DangerSurfaceBrush = ConvertTo-ThemeBrush $palette.DangerSurface
        }
    }
}

# The tray popup, identify overlays, and FPS overlay are separate top-level windows, so a
# DynamicResource in their markup never reaches the main window's dictionary. They get the
# resolved brushes copied in, and refreshed whenever the theme changes.
$script:DetachedThemedWindows = New-Object System.Collections.ArrayList

function Register-DetachedThemedWindow {
    param($Target)
    if ($null -eq $Target) { return }
    if (-not $script:DetachedThemedWindows.Contains($Target)) { [void]$script:DetachedThemedWindows.Add($Target) }
    Update-DetachedWindowTheme -Target $Target
}

function Unregister-DetachedThemedWindow {
    param($Target)
    if ($null -eq $Target) { return }
    if ($script:DetachedThemedWindows.Contains($Target)) { $script:DetachedThemedWindows.Remove($Target) }
}

function Update-DetachedWindowTheme {
    param($Target)
    if ($null -eq $Target) { return }
    $brushes = Get-ThemeBrushMap -HighContrast ([bool]$script:IsHighContrastTheme)
    foreach ($key in $brushes.Keys) {
        $value = $brushes[$key]
        if ($null -ne $value -and $value.PSObject.BaseObject -is [System.Windows.Media.Brush]) {
            $value = $value.PSObject.BaseObject
        }
        try { $Target.Resources[$key] = $value } catch {}
    }
}

function Get-ThemeBrush {
    param([string]$Key)
    if ($null -ne $window -and $null -ne $window.Resources -and $window.Resources.Contains($Key)) {
        return $window.Resources[$Key]
    }
    $brushes = Get-ThemeBrushMap -HighContrast ([bool]$script:IsHighContrastTheme)
    if ($brushes.Contains($Key)) {
        $value = $brushes[$Key]
        if ($null -ne $value -and $value.PSObject.BaseObject -is [System.Windows.Media.Brush]) {
            return $value.PSObject.BaseObject
        }
        return $value
    }
    return [System.Windows.Media.Brushes]::Gray
}

function Update-DetachedWindowThemes {
    foreach ($target in @($script:DetachedThemedWindows)) { Update-DetachedWindowTheme -Target $target }
}

function Set-SystemAwareTheme {
    param([bool]$HighContrast)
    if ($null -eq $window) { return }
    $resources = Get-ThemeBrushMap -HighContrast $HighContrast
    foreach ($key in $resources.Keys) {
        $resourceValue = $resources[$key]
        if ($null -ne $resourceValue -and $resourceValue.PSObject.BaseObject -is [System.Windows.Media.Brush]) {
            $resourceValue = $resourceValue.PSObject.BaseObject
        }
        $window.Resources[$key] = $resourceValue
    }
    $script:IsHighContrastTheme = $HighContrast
    Update-DetachedWindowThemes
    [System.Windows.Automation.AutomationProperties]::SetHelpText(
        $window,
        $(if ($HighContrast) { "High contrast colors are active." } else { "Dark application colors are active." })
    )
}

function Update-SystemAccessibility {
    if ($null -eq $window -or $null -eq $shellRoot) { return }
    $useHighContrast = switch ($script:ThemePreference) {
        "HighContrast" { $true }
        "Dark" { $false }
        default { [bool][System.Windows.SystemParameters]::HighContrast }
    }
    Set-SystemAwareTheme -HighContrast $useHighContrast
    $systemPercent = Get-SystemTextScalePercent
    $scale = Resolve-TextScaleFactor -SystemPercent $systemPercent -OverridePercent $script:TextScaleOverridePercent
    $script:CurrentTextScaleFactor = $scale
    if ($shellRoot.LayoutTransform -is [System.Windows.Media.ScaleTransform]) {
        $shellRoot.LayoutTransform.ScaleX = 1.0
        $shellRoot.LayoutTransform.ScaleY = 1.0
    }
    Set-ApplicationTextScale -Scale $scale
    if ($shellScrollViewer) {
        $shellScrollViewer.HorizontalScrollBarVisibility = "Disabled"
        $shellScrollViewer.VerticalScrollBarVisibility = "Disabled"
    }
    $themeDescription = if ($useHighContrast) { "High contrast colors are active." } else { "Dark application colors are active." }
    [System.Windows.Automation.AutomationProperties]::SetHelpText($window, "$themeDescription Text scale: $([int]($scale * 100))%.")
}

function Initialize-SystemAccessibility {
    Update-SystemAccessibility
    if ($null -ne $script:SystemPreferenceChangedHandler) { return }
    $script:SystemPreferenceChangedHandler = [Microsoft.Win32.UserPreferenceChangedEventHandler]{
        param($sender, $eventArgs)
        if ($null -eq $window -or $script:IsQuitting) { return }
        $refresh = [Action]{ Update-SystemAccessibility }
        try {
            if ($window.Dispatcher.CheckAccess()) {
                & $refresh
            } else {
                $window.Dispatcher.BeginInvoke($refresh) | Out-Null
            }
        } catch {}
    }
    [Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged($script:SystemPreferenceChangedHandler)
}

function Stop-SystemAccessibility {
    if ($null -eq $script:SystemPreferenceChangedHandler) { return }
    try { [Microsoft.Win32.SystemEvents]::remove_UserPreferenceChanged($script:SystemPreferenceChangedHandler) } catch {}
    $script:SystemPreferenceChangedHandler = $null
}





function Invoke-LiveRegionAnnouncement {
    param($Control)
    if ($null -eq $Control) { return }
    $announcementControl = $Control
    $announcement = {
        try {
            $announcementControl.UpdateLayout()
            $peer = [System.Windows.Automation.Peers.FrameworkElementAutomationPeer]::FromElement($announcementControl)
            if ($null -eq $peer) { $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($announcementControl) }
            if ($null -ne $peer) {
                $listenerExists = [System.Windows.Automation.Peers.AutomationPeer]::ListenerExists([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
                $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
                if (-not $listenerExists) {
                    $providerMethod = [System.Windows.Automation.Peers.AutomationPeer].GetMethod(
                        "ProviderFromPeer",
                        [System.Reflection.BindingFlags]"Instance,NonPublic"
                    )
                    if ($null -ne $providerMethod) {
                        $provider = $providerMethod.Invoke($peer, @($peer))
                        $eventId = [System.Windows.Automation.AutomationElementIdentifiers]::LiveRegionChangedEvent
                        [System.Windows.Automation.Provider.AutomationInteropProvider]::RaiseAutomationEvent(
                            $eventId,
                            $provider,
                            (New-Object System.Windows.Automation.AutomationEventArgs($eventId))
                        )
                    }
                }
            }
        } catch {}
    }.GetNewClosure()
    $announcementControl.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ContextIdle,
        [Action]$announcement
    ) | Out-Null
}



function Set-LocalizedText {
    param($Control, [string]$Key, [string]$Property = "")
    if ($null -eq $Control) { return }
    $text = Get-UiString -Key $Key
    if (-not [string]::IsNullOrWhiteSpace($Property)) {
        $Control.$Property = $text
    } elseif ($Control.PSObject.Properties.Name -contains "Content") {
        $Control.Content = $text
    } elseif ($Control.PSObject.Properties.Name -contains "Header") {
        $Control.Header = $text
    } elseif ($Control.PSObject.Properties.Name -contains "Text") {
        $Control.Text = $text
    }
}

function Set-AccessibleName {
    param($Control, [string]$Key, [string]$HelpKey = "")
    if ($null -eq $Control) { return }
    [System.Windows.Automation.AutomationProperties]::SetName($Control, (Get-UiString -Key $Key))
    if (-not [string]::IsNullOrWhiteSpace($HelpKey)) {
        [System.Windows.Automation.AutomationProperties]::SetHelpText($Control, (Get-UiString -Key $HelpKey))
    }
}

function Set-TabOrder {
    param([object[]]$Controls)
    $index = 0
    foreach ($control in $Controls) {
        if ($null -eq $control) { continue }
        try {
            $control.TabIndex = $index
            $index++
        } catch {}
    }
}

function Initialize-LocalizationAndAccessibility {
    if ($window) {
        $window.Title = "$(Get-UiString -Key 'App.Title') v$script:AppVersion"
        [System.Windows.Automation.AutomationProperties]::SetName($window, "$(Get-UiString -Key 'App.Title') main window")
    }
    Set-LocalizedText -Control $appTitleText -Key "App.Title" -Property "Text"
    Set-LocalizedText -Control $appSubtitleText -Key "App.Subtitle" -Property "Text"
    Set-LocalizedText -Control $displayTab -Key "Tab.Display" -Property "Header"
    Set-LocalizedText -Control $monitorTab -Key "Tab.Monitor" -Property "Header"
    Set-LocalizedText -Control $gpuTab -Key "Tab.GPU" -Property "Header"
    Set-LocalizedText -Control $vcpTab -Key "Tab.VCP" -Property "Header"
    Set-LocalizedText -Control $profilesTab -Key "Tab.Profiles" -Property "Header"
    Set-LocalizedText -Control $scheduleTab -Key "Tab.Schedule" -Property "Header"
    Set-LocalizedText -Control $systemTab -Key "Tab.System" -Property "Header"
    Set-LocalizedText -Control $applyAllCheckbox -Key "Action.AllMonitors"
    Set-LocalizedText -Control $identifyBtn -Key "Action.Identify"
    Set-LocalizedText -Control $refreshBtn -Key "Action.Refresh"
    Set-LocalizedText -Control $monitorLabelSaveBtn -Key "Action.Save"
    Set-LocalizedText -Control $monitorLabelResetBtn -Key "Action.Reset"
    Set-LocalizedText -Control $vcpQueryBtn -Key "Action.Query"
    Set-LocalizedText -Control $vcpSetBtn -Key "Action.Set"
    Set-LocalizedText -Control $vcpScanBtn -Key "Action.ScanAll"
    Set-LocalizedText -Control $vcpScanCapabilitiesOnlyCheckbox -Key "Action.CapsOnly"
    Set-LocalizedText -Control $saveProfileBtn -Key "Action.Save"
    Set-LocalizedText -Control $loadProfileBtn -Key "Action.Load"
    Set-LocalizedText -Control $deleteProfileBtn -Key "Action.Delete"
    Set-LocalizedText -Control $exportProfilesBtn -Key "Action.Export"
    Set-LocalizedText -Control $importProfilesBtn -Key "Action.Import"
    Set-LocalizedText -Control $profileSyncFolderBtn -Key "Action.SyncFolder"
    Set-LocalizedText -Control $profileLocalFolderBtn -Key "Action.UseLocal"
    Set-LocalizedText -Control $appProfileCaptureBtn -Key "Action.Capture"
    Set-LocalizedText -Control $appProfileAddBtn -Key "Action.Add"
    Set-LocalizedText -Control $appProfileRemoveBtn -Key "Action.Remove"
    Set-LocalizedText -Control $scheduleAddBtn -Key "Action.Add"
    Set-LocalizedText -Control $scheduleRemoveBtn -Key "Action.Remove"
    Set-LocalizedText -Control $idleDimSaveBtn -Key "Action.Save"
    Set-LocalizedText -Control $batteryProfileSaveBtn -Key "Action.Save"
    Set-LocalizedText -Control $fpsOverlayStartBtn -Key "Action.Start"
    Set-LocalizedText -Control $fpsOverlayStopBtn -Key "Action.Stop"
    Set-LocalizedText -Control $automationBridgeSaveBtn -Key "Action.Save"
    Set-LocalizedText -Control $ddcReportGenerateBtn -Key "Action.BuildReport"
    Set-LocalizedText -Control $ddcReportCopyBtn -Key "Action.Copy"

    Set-AccessibleName -Control $monitorCanvas -Key "A11y.MonitorCanvas"
    Set-AccessibleName -Control $selectedMonitorName -Key "A11y.SelectedMonitor"
    Set-AccessibleName -Control $monitorLabelBox -Key "A11y.MonitorLabel"
    Set-AccessibleName -Control $monitorIdentityText -Key "A11y.MonitorIdentity"
    Set-AccessibleName -Control $brightnessSlider -Key "A11y.Brightness"
    Set-AccessibleName -Control $contrastSlider -Key "A11y.Contrast"
    Set-AccessibleName -Control $redSlider -Key "A11y.RedGain"
    Set-AccessibleName -Control $greenSlider -Key "A11y.GreenGain"
    Set-AccessibleName -Control $blueSlider -Key "A11y.BlueGain"
    Set-AccessibleName -Control $volumeSlider -Key "A11y.Volume"
    Set-AccessibleName -Control $muteCheckbox -Key "A11y.Mute"
    Set-AccessibleName -Control $sharpnessSlider -Key "A11y.Sharpness"
    Set-AccessibleName -Control $inputSourceCombo -Key "A11y.InputSource"
    Set-AccessibleName -Control $profileNameBox -Key "A11y.ProfileName"
    Set-AccessibleName -Control $profilesList -Key "A11y.ProfilesList"
    Set-AccessibleName -Control $vcpCodeBox -Key "A11y.VcpCode"
    Set-AccessibleName -Control $vcpPresetCombo -Key "A11y.VcpPreset"
    Set-AccessibleName -Control $vcpSetValueBox -Key "A11y.VcpSetValue"
    Set-AccessibleName -Control $vcpResultBox -Key "A11y.VcpResults"
    Set-AccessibleName -Control $capabilitiesBox -Key "A11y.Capabilities"
    Set-AccessibleName -Control $capabilitiesDiscoveryEnabledCheckbox -Key "A11y.CapabilitiesDiscovery"
    Set-AccessibleName -Control $capabilitiesClearCacheBtn -Key "A11y.ClearCapabilityCache"
    Set-AccessibleName -Control $ddcTimingAdaptiveRadio -Key "A11y.DdcTimingAdaptive"
    Set-AccessibleName -Control $ddcTimingManualRadio -Key "A11y.DdcTimingManual"
    Set-AccessibleName -Control $ddcTimingResetBtn -Key "A11y.DdcTimingReset"
    Set-AccessibleName -Control $ddcValuesRereadBtn -Key "A11y.DdcValuesReread"
    Set-AccessibleName -Control $ddcTimingReadRetriesBox -Key "A11y.DdcTimingReadRetries"
    Set-AccessibleName -Control $ddcTimingWriteRetriesBox -Key "A11y.DdcTimingWriteRetries"
    Set-AccessibleName -Control $ddcTimingCapabilityRetriesBox -Key "A11y.DdcTimingCapabilityRetries"
    Set-AccessibleName -Control $displayRestoreEnabledCheckbox -Key "A11y.DisplayRestore"
    Set-AccessibleName -Control $cpuMonitorEnabledCheckbox -Key "A11y.CpuMonitorHelper"
    Set-AccessibleName -Control $presentMonEnabledCheckbox -Key "A11y.PresentMonHelper"
    Set-AccessibleName -Control $optionalHelperStatusBox -Key "A11y.OptionalHelperStatus"
    Set-AccessibleName -Control $capabilitiesMaximumCompatibilityCheckbox -Key "A11y.CapabilitiesCompatibility"
    Set-AccessibleName -Control $capabilitiesExcludeCurrentBtn -Key "A11y.CapabilitiesExclude"
    Set-AccessibleName -Control $capabilitiesClearExclusionsBtn -Key "A11y.CapabilitiesClearExclusions"
    Set-AccessibleName -Control $riskyVcpEnabledCheckbox -Key "A11y.RiskyVcp"
    Set-AccessibleName -Control $ddcReportBox -Key "A11y.DdcReport"
    Set-AccessibleName -Control $automationBridgeEnabledCheckbox -Key "A11y.AutomationBridge"
    Set-AccessibleName -Control $statusText -Key "A11y.Status"
    Set-AccessibleName -Control $appProfileExeBox -Key "A11y.AppProfileExe"
    Set-AccessibleName -Control $appProfileProfileCombo -Key "A11y.AppProfileProfile"
    Set-AccessibleName -Control $appProfileRiskyConsentCheckbox -Key "A11y.AppProfileRisky"
    Set-AccessibleName -Control $appProfileRulesList -Key "A11y.AppProfileRules"
    Set-AccessibleName -Control $scheduleTimeBox -Key "A11y.ScheduleTime"
    Set-AccessibleName -Control $scheduleProfileCombo -Key "A11y.ScheduleProfile"
    Set-AccessibleName -Control $scheduleRiskyConsentCheckbox -Key "A11y.ScheduleRisky"
    Set-AccessibleName -Control $scheduleRulesList -Key "A11y.ScheduleRules"
    Set-AccessibleName -Control $idleDimMinutesBox -Key "A11y.IdleMinutes"
    Set-AccessibleName -Control $idleDimBrightnessBox -Key "A11y.IdleBrightness"
    Set-AccessibleName -Control $batteryBrightnessBox -Key "A11y.BatteryBrightness"
    Set-AccessibleName -Control $acBrightnessBox -Key "A11y.AcBrightness"
    Set-AccessibleName -Control $gammaSlider -Key "A11y.Gamma"
    Set-AccessibleName -Control $gammaRedSlider -Key "A11y.GammaRed"
    Set-AccessibleName -Control $gammaGreenSlider -Key "A11y.GammaGreen"
    Set-AccessibleName -Control $gammaBlueSlider -Key "A11y.GammaBlue"
    Set-AccessibleName -Control $vibranceSlider -Key "A11y.Vibrance"
    Set-AccessibleName -Control $automationBridgeBindBox -Key "A11y.BridgeBind"
    Set-AccessibleName -Control $automationBridgePortBox -Key "A11y.BridgePort"
    Set-AccessibleName -Control $automationBridgeKeyBox -Key "A11y.BridgeKey"
    Set-AccessibleName -Control $scheduleTimelineCanvas -Key "A11y.ScheduleTimeline"
    Set-AccessibleName -Control $statusBannerText -Key "A11y.ErrorBanner"
    [System.Windows.Automation.AutomationProperties]::SetLiveSetting($statusBannerText, [System.Windows.Automation.AutomationLiveSetting]::Assertive)
    [System.Windows.Automation.AutomationProperties]::SetLiveSetting($statusBannerBorder, [System.Windows.Automation.AutomationLiveSetting]::Assertive)

    foreach ($shortcut in @(
        [PSCustomObject]@{ Control = $displayTab; Text = "Alt+D" },
        [PSCustomObject]@{ Control = $monitorTab; Text = "Alt+M" },
        [PSCustomObject]@{ Control = $gpuTab; Text = "Alt+H" },
        [PSCustomObject]@{ Control = $vcpTab; Text = "Alt+V" },
        [PSCustomObject]@{ Control = $profilesTab; Text = "Alt+P" },
        [PSCustomObject]@{ Control = $scheduleTab; Text = "Alt+A" },
        [PSCustomObject]@{ Control = $systemTab; Text = "Alt+S" }
    )) {
        if ($null -ne $shortcut.Control) {
            [System.Windows.Automation.AutomationProperties]::SetHelpText($shortcut.Control, "Keyboard shortcut: $($shortcut.Text)")
        }
    }

    Set-TabOrder -Controls @(
        $applyAllCheckbox,$identifyBtn,$refreshBtn,$monitorLabelBox,$monitorLabelSaveBtn,$monitorLabelResetBtn,
        $brightnessSlider,$contrastSlider,$redSlider,$greenSlider,$blueSlider,$colorTempWarm,$colorTemp6500,$colorTempCool,$colorTempSRGB,
        $presetDay,$presetNight,$presetAutoMode,$presetAmbientMode,$presetReset,$dynamicContrastOff,$dynamicContrastOn,$pictureModeWeb,$pictureModeCinema,$pictureModeGame,
        $inputSourceCombo,$powerOffBtn,$powerStandbyBtn,$powerOnBtn,$volumeSlider,$muteCheckbox,$sharpnessSlider,$resetColorBtn,$factoryResetBtn,$allMonitorsStandbyBtn,
        $vcpCodeBox,$vcpPresetCombo,$vcpQueryBtn,$vcpSetValueBox,$vcpSetBtn,$vcpScanBtn,$vcpScanCapabilitiesOnlyCheckbox,$vcpResultBox,
        $profileNameBox,$saveProfileBtn,$loadProfileBtn,$deleteProfileBtn,$profilesList,$exportProfilesBtn,$importProfilesBtn,$profileSyncFolderBtn,$profileLocalFolderBtn,
        $appProfileEnabledCheckbox,$appProfileExeBox,$appProfileCaptureBtn,$appProfileProfileCombo,$appProfileRiskyConsentCheckbox,$appProfileAddBtn,$appProfileRemoveBtn,$appProfileRulesList,
        $scheduleEnabledCheckbox,$scheduleTimeBox,$scheduleProfileCombo,$scheduleRiskyConsentCheckbox,$scheduleAddBtn,$scheduleRemoveBtn,$scheduleRulesList,
        $idleDimEnabledCheckbox,$idleDimMinutesBox,$idleDimBrightnessBox,$idleDimRestoreCheckbox,$idleDimSaveBtn,
        $batteryProfileEnabledCheckbox,$batteryBrightnessBox,$acBrightnessBox,$batteryProfileSaveBtn,
        $displaySettingsBtn,$colorMgmtBtn,$gpuControlPanelBtn,$gammaRedSlider,$gammaGreenSlider,$gammaBlueSlider,$resetGammaBtn,$capabilitiesBox,
        $capabilitiesClearCacheBtn,$ddcTimingAdaptiveRadio,$ddcTimingManualRadio,$ddcTimingReadRetriesBox,$ddcTimingWriteRetriesBox,$ddcTimingCapabilityRetriesBox,$ddcTimingResetBtn,$ddcValuesRereadBtn,$displayRestoreEnabledCheckbox,$cpuMonitorEnabledCheckbox,$presentMonEnabledCheckbox,$optionalHelperStatusBox,$capabilitiesDiscoveryEnabledCheckbox,$capabilitiesMaximumCompatibilityCheckbox,$capabilitiesExcludeCurrentBtn,$capabilitiesClearExclusionsBtn,$riskyVcpEnabledCheckbox,
        $automationBridgeEnabledCheckbox,$automationBridgeBindBox,$automationBridgePortBox,$automationBridgeKeyBox,$automationBridgeSaveBtn,
        $ddcReportGenerateBtn,$ddcReportCopyBtn,$ddcReportBox
    )
}



























function Confirm-AutomationRuleRiskyWriteConsent {
    param([string]$RuleLabel)
    $message = @"
This rule-level permission allows '$RuleLabel' to use risky VCP values if a profile supports them in the future.

Power, input, reset, and arbitrary VCP writes can blank the display, change its input, or erase monitor settings. The target monitor must also be unlocked separately in System. Each write is still verified when the monitor supports readback.

Allow risky writes for this automation rule?
"@
    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Automation risky-write consent",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return $result -eq [System.Windows.MessageBoxResult]::Yes
}























function Request-CapabilitiesDiscoveryConsent {
    $message = @"
Monitor capability discovery asks monitor firmware for its full DDC/CI capabilities string.

Some non-compliant monitors and adapters have returned malformed data that can destabilize or crash Windows. MonitorControl Pro records a crash sentinel before each request and can exclude a failing display, but it cannot guarantee faulty firmware is safe.

Enable capability discovery? Choose No to keep controls in maximum-safety fallback mode. You can change this later in System.
"@
    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Capability discovery safety",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    $script:CapabilitiesConsentRecorded = $true
    $script:CapabilitiesDiscoveryEnabled = ($result -eq [System.Windows.MessageBoxResult]::Yes)
    Write-CapabilitySafetyState | Out-Null
    return [bool]$script:CapabilitiesDiscoveryEnabled
}



function Update-CapabilitiesBox {
    param($Monitor)
    if ($null -eq $capabilitiesBox -or $null -eq $Monitor) { return }
    if ($script:CapabilitiesMaximumCompatibility) {
        $capabilitiesBox.Text = "Capability discovery skipped by maximum compatibility mode."
    } elseif ([bool]$Monitor.CapabilitiesExcluded) {
        $capabilitiesBox.Text = "Capability discovery is excluded for this monitor identity."
    } elseif (-not $script:CapabilitiesDiscoveryEnabled) {
        $capabilitiesBox.Text = "Capability discovery is disabled. Enable it from System after reviewing the safety warning."
    } elseif ($Monitor.Capabilities) {
        $prefix = if ([bool]$Monitor.CapabilitiesKnown) { "Parsed VCP codes: $($Monitor.SupportedVcpCodes.Count)" } else { "Parsed VCP codes: unknown" }
        $capabilitiesBox.Text = "$prefix`n`n$($Monitor.Capabilities)"
    } elseif ([bool]$Monitor.CapabilitiesPending) {
        $capabilitiesBox.Text = "DDC/CI capabilities read pending"
    } else {
        $capabilitiesBox.Text = "DDC/CI capabilities not available"
    }
}

function Update-CapabilitiesWorkerOutput {
    if (-not $script:CapabilitiesWorker -or -not $script:CapabilitiesWorkerOutput -or -not $script:CapabilitiesWorkerAsyncResult) { return }
    $count = $script:CapabilitiesWorkerOutput.Count
    $completed = [bool]$script:CapabilitiesWorkerAsyncResult.IsCompleted
    $workerGeneration = [int]$script:CapabilitiesWorkerGeneration
    if ($count -ne $script:CapabilitiesWorkerLastOutputCount -and -not $completed -and $workerGeneration -eq $script:DisplayRecoveryGeneration) {
        $script:CapabilitiesWorkerLastOutputCount = $count
        Update-Status "Reading capabilities... $count"
    }
    if (-not $completed) { return }
    try { $script:CapabilitiesWorker.EndInvoke($script:CapabilitiesWorkerAsyncResult) } catch { Update-Status "Capabilities read failed: $($_.Exception.Message)" }
    $validResults = @($script:CapabilitiesWorkerOutput | Where-Object {
        Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
    })
    $cacheDirty = $false
    foreach ($result in $validResults) {
        $index = [int]$result.MonitorIndex
        $mon = $script:PhysicalMonitors[$index]
        $capabilityInfo = ConvertFrom-MonitorCapabilities -Capabilities ([string]$result.Capabilities)
        $mon.Capabilities = [string]$result.Capabilities
        $mon.CapabilitiesKnown = [bool]$capabilityInfo.Known
        $mon.SupportedVcpCodes = $capabilityInfo.Codes
        $mon.CapabilitiesPending = $false
        if (-not [bool]$result.SentinelReady) {
            $mon.CapabilitiesSafetyError = "Safety sentinel unavailable"
        } else {
            $mon.CapabilitiesSafetyError = ""
        }
        if ([bool]$result.Success) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$result.IdentityKey) -Outcome "Success" -Generation $script:DisplayRecoveryGeneration | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Capabilities)) {
                if (Set-CapabilitiesCacheEntry -Monitor $mon -Capabilities ([string]$result.Capabilities)) { $cacheDirty = $true }
            }
        }
    }
    if ($cacheDirty) { Save-CapabilitiesCache | Out-Null }
    if ($workerGeneration -eq $script:DisplayRecoveryGeneration -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $selected = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        Update-CapabilitiesBox -Monitor $selected
        Update-CapabilityControls -Monitor $selected
    }
    if ($workerGeneration -eq $script:DisplayRecoveryGeneration) {
        $sentinelFailures = @($validResults | Where-Object { -not [bool]$_.SentinelReady }).Count
        if ($sentinelFailures -gt 0) {
            Update-Status "Capability reads skipped where the crash sentinel could not be persisted"
        } else {
            Update-Status "Capabilities read complete"
        }
    }
    Stop-CapabilitiesWorker
    Sync-CapabilitySafetyUi
}

function Start-CapabilitiesWorker {
    if (Test-VerifiedVcpTransactionWorkerActive) { return }
    Stop-CapabilitiesWorker -Cancel
    $targets = @()
    for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
        $mon = $script:PhysicalMonitors[$i]
        $mon.CapabilitiesPending = $false
        $mon.CapabilitiesExcluded = (-not [string]::IsNullOrWhiteSpace([string]$mon.IdentityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey([string]$mon.IdentityKey))
        $decision = Get-CapabilityProbeDecision -Monitor $mon
        if ($decision.Action -eq "Cached") {
            # A capability string does not change for a given panel, so replay it instead of
            # re-issuing the one native call that can fault the kernel.
            $cachedInfo = ConvertFrom-MonitorCapabilities -Capabilities ([string]$decision.Capabilities)
            $mon.Capabilities = [string]$decision.Capabilities
            $mon.CapabilitiesKnown = [bool]$cachedInfo.Known
            $mon.SupportedVcpCodes = $cachedInfo.Codes
            $mon.CapabilitiesSafetyError = ""
            continue
        }
        if ($decision.Action -eq "Blocked") {
            $mon.CapabilitiesExcluded = $true
            $mon.CapabilitiesSafetyError = [string]$decision.Reason
            Update-Status "Skipped capability read: $($decision.Reason)"
            continue
        }
        if ($decision.Action -eq "Probe") {
            $mon.CapabilitiesPending = $true
            $workerTiming = Get-DdcWorkerTiming -IdentityKey ([string]$mon.IdentityKey)
            $targets += [PSCustomObject]@{
                Index = [int]$i
                MonitorIndex = [int]$i
                Handle = $mon.Handle
                HandleValue = $mon.Handle.ToInt64()
                Name = [string]$mon.Name
                IdentityKey = [string]$mon.IdentityKey
                Generation = [int]$script:DisplayRecoveryGeneration
                CapabilityRetries = [int]$workerTiming.CapabilityRetries
                DelayMilliseconds = [int]$workerTiming.DelayMilliseconds
            }
        }
    }
    if ($targets.Count -eq 0) {
        if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
            Update-CapabilitiesBox -Monitor $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        }
        Sync-CapabilitySafetyUi
        return
    }
    $workerScript = {
        param([object[]]$Targets, [string]$SentinelPath)
        foreach ($target in $Targets) {
            $capabilities = ""
            $lastError = [int]0
            $attempts = [int]0
            $sentinelReady = $false
            $sentinelTempPath = "$SentinelPath.$([guid]::NewGuid().ToString('N')).tmp"
            try {
                try {
                    $marker = [PSCustomObject]@{
                        SchemaVersion = [int]$script:CapabilitiesProbeSentinelSchemaVersion
                        IdentityKey = [string]$target.IdentityKey
                        MonitorName = [string]$target.Name
                        StartedAtUtc = [DateTime]::UtcNow.ToString("o")
                    }
                    $markerJson = $marker | ConvertTo-Json -Compress
                    $encoding = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($sentinelTempPath, ($markerJson + [Environment]::NewLine), $encoding)
                    if (Test-Path -LiteralPath $SentinelPath) { Remove-Item -LiteralPath $SentinelPath -Force }
                    [System.IO.File]::Move($sentinelTempPath, $SentinelPath)
                    $sentinelReady = Test-Path -LiteralPath $SentinelPath
                } catch {
                    $lastError = -2
                }
                if ($sentinelReady) {
                    for ($attempt = 0; $attempt -le [int]$target.CapabilityRetries; $attempt++) {
                        $attempts = $attempt + 1
                        $capLen = [uint32]0
                        if ([MonitorAPI]::GetCapabilitiesStringLength($target.Handle, [ref]$capLen) -and $capLen -gt 0) {
                            $capStr = New-Object System.Text.StringBuilder -ArgumentList ([int]$capLen)
                            if ([MonitorAPI]::CapabilitiesRequestAndCapabilitiesReply($target.Handle, $capStr, $capLen)) {
                                $capabilities = $capStr.ToString()
                                $lastError = 0
                                break
                            } else {
                                $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                            }
                        } else {
                            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        }
                        if ($attempt -lt [int]$target.CapabilityRetries) {
                            Start-Sleep -Milliseconds ([int]$target.DelayMilliseconds)
                        }
                    }
                }
            } catch {
                $lastError = -1
            } finally {
                if (Test-Path -LiteralPath $sentinelTempPath) {
                    Remove-Item -LiteralPath $sentinelTempPath -Force -ErrorAction SilentlyContinue
                }
                if ($sentinelReady -and (Test-Path -LiteralPath $SentinelPath)) {
                    Remove-Item -LiteralPath $SentinelPath -Force -ErrorAction SilentlyContinue
                }
            }
            [PSCustomObject]@{
                Index = [int]$target.Index
                MonitorIndex = [int]$target.MonitorIndex
                HandleValue = [int64]$target.HandleValue
                MonitorName = [string]$target.Name
                IdentityKey = [string]$target.IdentityKey
                Generation = [int]$target.Generation
                Capabilities = [string]$capabilities
                Success = -not [string]::IsNullOrWhiteSpace($capabilities)
                LastError = [int]$lastError
                Attempts = [int]$attempts
                RetryCount = [Math]::Max(0, $attempts - 1)
                SentinelReady = [bool]$sentinelReady
            }
        }
    }
    $script:CapabilitiesWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:CapabilitiesWorkerInput.Complete()
    $script:CapabilitiesWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:CapabilitiesWorker = [PowerShell]::Create()
    $script:CapabilitiesWorker.AddScript($workerScript.ToString()).AddArgument($targets).AddArgument($script:CapabilitiesProbeSentinelPath) | Out-Null
    $script:CapabilitiesWorkerAsyncResult = $script:CapabilitiesWorker.BeginInvoke($script:CapabilitiesWorkerInput, $script:CapabilitiesWorkerOutput)
    $script:CapabilitiesWorkerLastOutputCount = 0
    $script:CapabilitiesWorkerGeneration = [int]$script:DisplayRecoveryGeneration
    if (-not $script:CapabilitiesWorkerTimer) {
        $script:CapabilitiesWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CapabilitiesWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:CapabilitiesWorkerTimer.Add_Tick({ Update-CapabilitiesWorkerOutput })
    }
    Update-Status "Reading capabilities... 0/$($targets.Count)"
    $script:CapabilitiesWorkerTimer.Start()
}























function Update-DdcDiagnosticsText {
    if (-not $vcpResultBox -or $script:DdcRecentErrors.Count -eq 0) { return }
    if ($script:VcpWorker -and $script:VcpWorkerAsyncResult -and -not $script:VcpWorkerAsyncResult.IsCompleted) { return }
    $recent = @($script:DdcRecentErrors | Sort-Object -Property Timestamp -Descending | Select-Object -First 8)
    $vcpResultBox.Text = "DDC/CI Diagnostics (latest first)`n`n" + (($recent | ForEach-Object { $_.Summary }) -join "`n`n")
}





function Start-DdcWriteResultTimer {
    if ($script:DdcWriteResultTimer) { $script:DdcWriteResultTimer.Start(); return }
    $script:DdcWriteResultTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DdcWriteResultTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:DdcWriteResultTimer.Add_Tick({ Drain-DdcWriteResults })
    $script:DdcWriteResultTimer.Start()
}





















































function Test-VerifiedVcpTransactionWorkerActive {
    return $null -ne $script:VerifiedTransactionWorkerAsyncResult -and -not [bool]$script:VerifiedTransactionWorkerAsyncResult.IsCompleted
}

function New-VerifiedVcpWorkerOperation {
    param($Operation, [int]$Generation)
    if ($null -eq $Operation) { return $null }
    $monitorIndex = -1
    for ($index = 0; $index -lt $script:PhysicalMonitors.Count; $index++) {
        $monitor = $script:PhysicalMonitors[$index]
        if ($null -eq $monitor) { continue }
        if ([string]$monitor.IdentityKey -eq [string]$Operation.IdentityKey -and
            [int64]$monitor.Handle.ToInt64() -eq [int64]$Operation.Handle.ToInt64()) {
            $monitorIndex = $index
            break
        }
    }
    if ($monitorIndex -lt 0) { return $null }
    $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$Operation.IdentityKey)
    $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
    return [PSCustomObject]@{
        MonitorName = [string]$Operation.MonitorName
        IdentityKey = [string]$Operation.IdentityKey
        MonitorIndex = [int]$monitorIndex
        Generation = [int]$Generation
        Handle = [IntPtr]$Operation.Handle
        HandleValue = [int64]$Operation.Handle.ToInt64()
        Code = [int]$Operation.Code
        Value = [uint32]$Operation.Value
        Backend = [string]$Operation.Backend
        ReportedMaximum = [uint32]$Operation.ReportedMaximum
        VerifyPolicy = [string]$timing.VerifyPolicy
        VerificationDelayMilliseconds = [int]$timing.VerificationDelayMilliseconds
        LenientVerificationDelayMilliseconds = [int]$timing.LenientVerificationDelayMilliseconds
        ReadRetries = [int]$timing.ReadRetries
        WriteRetries = [int]$timing.WriteRetries
        DelayMilliseconds = [int]$timing.DelayMilliseconds
        StopOnNullResponse = $timingProfile.PSObject.Properties.Name -contains "NullMeansUnsupported" -and [bool]$timingProfile.NullMeansUnsupported
    }
}

function Test-VerifiedVcpTransactionTargetsCurrent {
    param([object[]]$Targets, [int]$Generation)
    $items = @($Targets)
    if ($items.Count -eq 0 -or $Generation -ne $script:DisplayRecoveryGeneration) { return $false }
    foreach ($target in $items) {
        if (-not (Test-DisplayWorkerResultCurrent -Result $target -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) { return $false }
    }
    return $true
}

function Request-VerifiedVcpTransactionCancel {
    param([string]$Reason = "user request")
    if (-not (Test-VerifiedVcpTransactionWorkerActive) -or $null -eq $script:VerifiedTransactionWorkerCancelState) { return $false }
    $script:VerifiedTransactionWorkerCancelState.Cancel = $true
    $script:VerifiedTransactionWorkerCancelState.Reason = $Reason
    if ($transactionProgressText) { $transactionProgressText.Text = "Cancelling and restoring..." }
    if ($transactionCancelBtn) { $transactionCancelBtn.IsEnabled = $false }
    Update-Status "Cancelling $script:VerifiedTransactionWorkerActionLabel; restoring applied values..."
    return $true
}

function Stop-VerifiedVcpTransactionWorker {
    param([switch]$Cancel, [switch]$WaitForCompletion, [int]$TimeoutMs = 5000)
    if ($Cancel -and $script:VerifiedTransactionWorkerCancelState) {
        $script:VerifiedTransactionWorkerCancelState.Cancel = $true
        $script:VerifiedTransactionWorkerCancelState.Reason = "worker teardown"
    }
    if ($WaitForCompletion -and $script:VerifiedTransactionWorkerAsyncResult -and -not $script:VerifiedTransactionWorkerAsyncResult.IsCompleted) {
        try { $null = $script:VerifiedTransactionWorkerAsyncResult.AsyncWaitHandle.WaitOne([Math]::Max(0, $TimeoutMs)) } catch {}
    }
    if ($script:VerifiedTransactionWorkerTimer) { $script:VerifiedTransactionWorkerTimer.Stop() }
    if ($script:VerifiedTransactionWorker) {
        if ($Cancel -and $script:VerifiedTransactionWorkerAsyncResult -and -not $script:VerifiedTransactionWorkerAsyncResult.IsCompleted) {
            try { $script:VerifiedTransactionWorker.Stop() } catch {}
        }
        try { $script:VerifiedTransactionWorker.Dispose() } catch {}
    }
    if ($script:VerifiedTransactionWorkerInput) { try { $script:VerifiedTransactionWorkerInput.Dispose() } catch {} }
    if ($script:VerifiedTransactionWorkerOutput) { try { $script:VerifiedTransactionWorkerOutput.Dispose() } catch {} }
    $script:VerifiedTransactionWorker = $null
    $script:VerifiedTransactionWorkerInput = $null
    $script:VerifiedTransactionWorkerOutput = $null
    $script:VerifiedTransactionWorkerAsyncResult = $null
    $script:VerifiedTransactionWorkerLastOutputCount = 0
    $script:VerifiedTransactionWorkerGeneration = -1
    $script:VerifiedTransactionWorkerTargets = @()
    $script:VerifiedTransactionWorkerCancelState = $null
    $script:VerifiedTransactionWorkerCompletionAction = $null
    $script:VerifiedTransactionWorkerActionLabel = ""
    $script:VerifiedTransactionWorkerTotalOperations = 0
    if ($transactionProgressPanel) { $transactionProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed }
    if ($transactionCancelBtn) { $transactionCancelBtn.IsEnabled = $true }
}

function Update-VerifiedVcpTransactionWorkerOutput {
    if (-not $script:VerifiedTransactionWorker -or -not $script:VerifiedTransactionWorkerOutput -or -not $script:VerifiedTransactionWorkerAsyncResult) { return }
    if ($script:VerifiedTransactionWorkerGeneration -ne $script:DisplayRecoveryGeneration -and $script:VerifiedTransactionWorkerCancelState) {
        $script:VerifiedTransactionWorkerCancelState.Cancel = $true
        $script:VerifiedTransactionWorkerCancelState.Reason = "display generation changed"
    }
    $count = $script:VerifiedTransactionWorkerOutput.Count
    if ($count -gt $script:VerifiedTransactionWorkerLastOutputCount) {
        $newItems = @($script:VerifiedTransactionWorkerOutput | Select-Object -Skip $script:VerifiedTransactionWorkerLastOutputCount)
        $script:VerifiedTransactionWorkerLastOutputCount = $count
        foreach ($item in @($newItems | Where-Object { [string]$_.Kind -eq "Progress" })) {
            if (-not (Test-DisplayWorkerResultCurrent -Result $item -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) { continue }
            $phase = [string]$item.Phase
            $completed = [int]$item.Completed
            $total = [Math]::Max(1, [int]$item.Total)
            if ($transactionProgressBar) { $transactionProgressBar.Maximum = $total; $transactionProgressBar.Value = [Math]::Min($total, $completed) }
            if ($transactionProgressText) { $transactionProgressText.Text = "$phase $completed/$total" }
            Update-Status "$script:VerifiedTransactionWorkerActionLabel - $phase $completed/$total"
        }
    }
    if (-not [bool]$script:VerifiedTransactionWorkerAsyncResult.IsCompleted) { return }
    $completionAction = $script:VerifiedTransactionWorkerCompletionAction
    $actionLabel = $script:VerifiedTransactionWorkerActionLabel
    $targets = @($script:VerifiedTransactionWorkerTargets)
    $generation = [int]$script:VerifiedTransactionWorkerGeneration
    $workerError = ""
    try { $script:VerifiedTransactionWorker.EndInvoke($script:VerifiedTransactionWorkerAsyncResult) } catch { $workerError = $_.Exception.Message }
    $transaction = @($script:VerifiedTransactionWorkerOutput | Where-Object {
        $_.PSObject.Properties.Name -contains "Outcome" -and $_.PSObject.Properties.Name -contains "Results"
    } | Select-Object -Last 1)
    if ($transaction.Count -eq 0) {
        $transaction = @([PSCustomObject]@{ Success = $false; Outcome = "WorkerFailed"; Results = @(); Rollback = "Partial"; Error = $workerError })
    }
    $result = $transaction[0]
    $isCurrent = Test-VerifiedVcpTransactionTargetsCurrent -Targets $targets -Generation $generation
    Stop-VerifiedVcpTransactionWorker
    if (-not $isCurrent) {
        Update-Status "$actionLabel result discarded after the display configuration changed"
        return
    }
    if ($completionAction) {
        try { & $completionAction $result } catch { Update-Status "$actionLabel completion failed: $($_.Exception.Message)" }
    } elseif ([bool]$result.Success) {
        Update-Status "$actionLabel complete ($($result.Outcome))"
    } else {
        Update-Status "$actionLabel ended $($result.Outcome); rollback: $($result.Rollback)"
    }
}

function Start-VerifiedVcpTransactionWorker {
    param(
        [object[]]$Operations,
        [string]$ActionLabel = "DDC transaction",
        [scriptblock]$CompletionAction,
        [int]$QueueWaitTimeoutMs = 2000
    )
    if (Test-VerifiedVcpTransactionWorkerActive) {
        Update-Status "$ActionLabel could not start because another verified transaction is running"
        return $false
    }
    if ($script:VerifiedTransactionWorker) { Stop-VerifiedVcpTransactionWorker }
    $generation = [int]$script:DisplayRecoveryGeneration
    $targets = @($Operations | ForEach-Object { New-VerifiedVcpWorkerOperation -Operation $_ -Generation $generation } | Where-Object { $null -ne $_ })
    if ($targets.Count -ne @($Operations).Count -or $targets.Count -eq 0) {
        Update-Status "$ActionLabel has no current monitor target"
        return $false
    }
    Stop-MonitorSettingsWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-CapabilitiesWorker -Cancel
    Stop-DdcReportWorker -Cancel
    Stop-DdcLivenessWorker -Cancel
    $cancelState = [hashtable]::Synchronized(@{ Cancel = $false; Reason = "" })
    $settingsDefinition = "function Get-DdcTransactionVerificationSettings {" + (Get-Command Get-DdcTransactionVerificationSettings).Definition + "}"
    $rangeDefinition = "function Test-VcpReadbackOutOfRange {" + (Get-Command Test-VcpReadbackOutOfRange).Definition + "}"
    $transactionDefinition = "function Invoke-VerifiedVcpTransaction {" + (Get-Command Invoke-VerifiedVcpTransaction).Definition + "}"
    $workerScript = {
        param(
            [object[]]$Targets,
            [hashtable]$CancelState,
            [int]$QueueTimeoutMs,
            [string]$SettingsDefinition,
            [string]$RangeDefinition,
            [string]$TransactionDefinition
        )
        . ([scriptblock]::Create($SettingsDefinition))
        . ([scriptblock]::Create($RangeDefinition))
        . ([scriptblock]::Create($TransactionDefinition))
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $QueueTimeoutMs))
        while (-not [bool]$CancelState.Cancel -and
            ([MonitorAPI]::IsVCPWriteWorkerActive() -or [MonitorAPI]::GetPendingVCPWriteCount() -gt 0) -and
            [DateTime]::UtcNow -lt $deadline) {
            [Threading.Thread]::Sleep(50)
        }
        if ([bool]$CancelState.Cancel) {
            [PSCustomObject]@{ Success = $false; Outcome = "Canceled"; Results = @(); Rollback = "NotNeeded" }
            return
        }
        if ([MonitorAPI]::IsVCPWriteWorkerActive() -or [MonitorAPI]::GetPendingVCPWriteCount() -gt 0) {
            [PSCustomObject]@{ Success = $false; Outcome = "Busy"; Results = @(); Rollback = "NotNeeded" }
            return
        }
        $readValue = {
            param($Operation)
            if ([string]$Operation.Backend -eq "WMI") {
                try {
                    $level = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
                    $current = if ($level -and $null -ne $level.CurrentBrightness) { [uint32]$level.CurrentBrightness } else { [uint32]0 }
                    return [PSCustomObject]@{ Success = $null -ne $level; Current = $current; Maximum = [uint32]100 }
                } catch { return [PSCustomObject]@{ Success = $false; Current = [uint32]0; Maximum = [uint32]100 } }
            }
            $vct = [uint32]0; $current = [uint32]0; $maximum = [uint32]0; $lastError = [int]0; $attempts = [int]0
            $ok = [MonitorAPI]::ReadVCPWithRetry([IntPtr]$Operation.Handle, [byte]$Operation.Code, [int]$Operation.ReadRetries, [int]$Operation.DelayMilliseconds, [bool]$Operation.StopOnNullResponse, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
            return [PSCustomObject]@{ Success = [bool]$ok; Current = $current; Maximum = $maximum; LastError = $lastError; Attempts = $attempts }
        }
        $writeValue = {
            param($Operation, [uint32]$TargetValue)
            if ([string]$Operation.Backend -eq "WMI") {
                try {
                    $methods = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
                    foreach ($method in $methods) { Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = [byte][Math]::Max(0, [Math]::Min(100, [int]$TargetValue)) } -ErrorAction Stop | Out-Null }
                    return $true
                } catch { return $false }
            }
            $lastError = [int]0; $attempts = [int]0
            return [bool][MonitorAPI]::SetVCPWithRetry([IntPtr]$Operation.Handle, [byte]$Operation.Code, $TargetValue, [int]$Operation.WriteRetries, [int]$Operation.DelayMilliseconds, [ref]$lastError, [ref]$attempts)
        }
        $delayAction = { param([int]$Milliseconds) if ($Milliseconds -gt 0) { [Threading.Thread]::Sleep($Milliseconds) } }
        $cancellationRequested = { return [bool]$CancelState.Cancel }
        $progressAction = {
            param([int]$Completed, [int]$Total, [string]$Phase, $Record)
            $operation = $Record.Operation
            [PSCustomObject]@{
                Kind = "Progress"
                Completed = $Completed
                Total = $Total
                Phase = $Phase
                Verification = [string]$Record.Verification
                Generation = [int]$operation.Generation
                MonitorIndex = [int]$operation.MonitorIndex
                IdentityKey = [string]$operation.IdentityKey
                HandleValue = [int64]$operation.HandleValue
            }
        }
        Invoke-VerifiedVcpTransaction -Operations $Targets -ReadValue $readValue -WriteValue $writeValue -RollbackOnFailure -DelayAction $delayAction -ProgressAction $progressAction -CancellationRequested $cancellationRequested
    }
    $script:VerifiedTransactionWorkerGeneration = $generation
    $script:VerifiedTransactionWorkerTargets = $targets
    $script:VerifiedTransactionWorkerCancelState = $cancelState
    $script:VerifiedTransactionWorkerCompletionAction = if ($CompletionAction) { $CompletionAction.GetNewClosure() } else { $null }
    $script:VerifiedTransactionWorkerActionLabel = $ActionLabel
    $script:VerifiedTransactionWorkerTotalOperations = $targets.Count
    $script:VerifiedTransactionWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VerifiedTransactionWorkerInput.Complete()
    $script:VerifiedTransactionWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VerifiedTransactionWorker = [PowerShell]::Create()
    $script:VerifiedTransactionWorker.AddScript($workerScript.ToString()).AddArgument($targets).AddArgument($cancelState).AddArgument($QueueWaitTimeoutMs).AddArgument($settingsDefinition).AddArgument($rangeDefinition).AddArgument($transactionDefinition) | Out-Null
    $script:VerifiedTransactionWorkerAsyncResult = $script:VerifiedTransactionWorker.BeginInvoke($script:VerifiedTransactionWorkerInput, $script:VerifiedTransactionWorkerOutput)
    $script:VerifiedTransactionWorkerLastOutputCount = 0
    if (-not $script:VerifiedTransactionWorkerTimer) {
        $script:VerifiedTransactionWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:VerifiedTransactionWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:VerifiedTransactionWorkerTimer.Add_Tick({ Update-VerifiedVcpTransactionWorkerOutput })
    }
    if ($transactionProgressPanel) { $transactionProgressPanel.Visibility = [System.Windows.Visibility]::Visible }
    if ($transactionProgressBar) { $transactionProgressBar.Minimum = 0; $transactionProgressBar.Maximum = $targets.Count; $transactionProgressBar.Value = 0 }
    if ($transactionProgressText) { $transactionProgressText.Text = "Apply 0/$($targets.Count)" }
    if ($transactionCancelBtn) { $transactionCancelBtn.IsEnabled = $true }
    Update-Status "$ActionLabel - Apply 0/$($targets.Count)"
    $script:VerifiedTransactionWorkerTimer.Start()
    return $true
}

function Invoke-ManualVcpWrite {
    param(
        [int]$Code,
        [uint32]$Value,
        [string]$ActionLabel = "Direct VCP write",
        [switch]$AllMonitors,
        [switch]$Arbitrary,
        [scriptblock]$ConfirmWrite,
        [scriptblock]$Transaction
    )
    if ($null -eq $ConfirmWrite) {
        $ConfirmWrite = {
            param([string]$Message)
            return ([System.Windows.MessageBox]::Show(
                $Message,
                "Confirm exact VCP write",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            ) -eq [System.Windows.MessageBoxResult]::Yes)
        }
    }
    $monitors = if ($AllMonitors) {
        @($script:PhysicalMonitors | Where-Object { $_.Handle -ne [IntPtr]::Zero })
    } elseif ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        @($script:PhysicalMonitors[$script:CurrentMonitorIndex])
    } else {
        @()
    }
    if ($monitors.Count -eq 0) {
        Update-Status "No DDC/CI write target"
        return [PSCustomObject]@{ Success = $false; Outcome = "NoTargets"; Results = @() }
    }
    $requiresSafety = Test-VcpWriteRequiresSafetyConsent -Code $Code -Arbitrary:$Arbitrary
    foreach ($monitor in $monitors) {
        if ($requiresSafety -and -not (Test-VcpWriteEnabledForMonitor -Monitor $monitor)) {
            Update-Status "Risky VCP writes are disabled for $(Get-MonitorDisplayLabel -Monitor $monitor)"
            return [PSCustomObject]@{ Success = $false; Outcome = "SafetyLocked"; Results = @() }
        }
        if (-not (Test-MonitorSupportsVcpValue -Monitor $monitor -Code $Code -Value ([int]$Value))) {
            Update-Status "VCP 0x$("{0:X2}" -f $Code) value $Value is not reported for $(Get-MonitorDisplayLabel -Monitor $monitor)"
            return [PSCustomObject]@{ Success = $false; Outcome = "Unsupported"; Results = @() }
        }
    }
    $operations = @($monitors | ForEach-Object { Get-VcpWriteOperation -Monitor $_ -Code $Code -Value $Value })
    $confirmation = Format-VcpWriteConfirmation -Operations $operations -ActionLabel $ActionLabel
    if (-not (& $ConfirmWrite $confirmation)) {
        Update-Status "VCP write canceled"
        return [PSCustomObject]@{ Success = $false; Outcome = "Canceled"; Results = @() }
    }
    $codeText = "0x{0:X2} = {1}" -f $Code, $Value
    if ($null -eq $Transaction) {
        $completionCode = [int]$Code
        $completion = {
            param($result)
            $rollback = [string]$result.Rollback
            switch ([string]$result.Outcome) {
                "Verified" { Update-Status "Verified VCP $codeText" }
                "VerifiedAfterRetry" { Update-Status "Verified VCP $codeText after a delayed re-read" }
                "Unverified" { Update-Status "VCP $codeText applied; readback unavailable" }
                "UnreliableReadback" { Update-Status "VCP $codeText applied; monitor returned an out-of-range readback" }
                "VerificationOff" { Update-Status "VCP $codeText applied; readback verification is off" }
                "Mismatched" { Update-Status "VCP $codeText mismatched its readback; restore: $rollback" }
                "Canceled" { Update-Status "VCP $codeText canceled; restore: $rollback" }
                default { Update-Status "VCP $codeText failed; restore: $rollback" }
            }
            if (-not [bool]$result.Success -and $completionCode -eq [int][MonitorAPI]::VCP_INPUT_SOURCE) { Load-MonitorSettings }
            if ([bool]$result.Success -and $completionCode -eq [int][MonitorAPI]::VCP_RESTORE_FACTORY_COLOR) { Invoke-DelayedMonitorSettingsRefresh -DelayMs 700 }
            if ([bool]$result.Success -and $completionCode -eq [int][MonitorAPI]::VCP_RESTORE_FACTORY_DEFAULTS) { Invoke-DelayedMonitorSettingsRefresh -DelayMs 1500 }
        }.GetNewClosure()
        if (-not (Start-VerifiedVcpTransactionWorker -Operations $operations -ActionLabel $ActionLabel -CompletionAction $completion)) {
            return [PSCustomObject]@{ Success = $false; Outcome = "Busy"; Results = @(); Rollback = "NotNeeded" }
        }
        return [PSCustomObject]@{ Success = $true; Outcome = "Started"; Results = @(); Rollback = "NotNeeded" }
    }
    $result = & $Transaction $operations
    $rollback = [string]$result.Rollback
    switch ($result.Outcome) {
        "Verified" { Update-Status "Verified VCP $codeText" }
        "VerifiedAfterRetry" { Update-Status "Verified VCP $codeText after a delayed re-read" }
        "Unverified" { Update-Status "VCP $codeText applied; readback unavailable" }
        "UnreliableReadback" { Update-Status "VCP $codeText applied; monitor returned an out-of-range readback" }
        "VerificationOff" { Update-Status "VCP $codeText applied; readback verification is off" }
        "Mismatched" { Update-Status "VCP $codeText mismatched its readback; restore: $rollback" }
        default { Update-Status "VCP $codeText failed; restore: $rollback" }
    }
    return $result
}









function Start-VcpReadWorker {
    param(
        [IntPtr]$Handle,
        [int[]]$Codes,
        [string]$Mode,
        [string]$MonitorName,
        [int]$ReadRetries = -1,
        [int]$DelayMilliseconds = -1,
        [string]$IdentityKey = "",
        [int]$MonitorIndex = -1
    )
    if (Test-VerifiedVcpTransactionWorkerActive) { Update-Status "Wait for the verified DDC transaction to finish"; return }
    Stop-VcpWorker -Cancel
    if ($Handle -eq [IntPtr]::Zero -or $Codes.Count -eq 0) { return }
    if ($MonitorIndex -lt 0 -and $script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $candidate = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if ($candidate.Handle.ToInt64() -eq $Handle.ToInt64()) {
            $MonitorIndex = [int]$script:CurrentMonitorIndex
            $IdentityKey = [string]$candidate.IdentityKey
        }
    }
    if ($MonitorIndex -lt 0 -or [string]::IsNullOrWhiteSpace($IdentityKey)) { return }
    $state = if ($script:DisplayRecoveryStates.ContainsKey($IdentityKey)) { $script:DisplayRecoveryStates[$IdentityKey] } else { $null }
    $workerTiming = Get-DdcWorkerTiming -IdentityKey $IdentityKey -ReadRetries $ReadRetries -DelayMilliseconds $DelayMilliseconds -RecoveryState $state
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    $stopOnNullResponse = $timingProfile.PSObject.Properties.Name -contains "NullMeansUnsupported" -and [bool]$timingProfile.NullMeansUnsupported
    $ReadRetries = [int]$workerTiming.ReadRetries
    $DelayMilliseconds = [int]$workerTiming.DelayMilliseconds
    $generation = [int]$script:DisplayRecoveryGeneration
    $handleValue = [int64]$Handle.ToInt64()
    $workerScript = {
        param([IntPtr]$Handle, [int[]]$Codes, [string]$MonitorName, [int]$ReadRetries, [int]$DelayMilliseconds, [bool]$StopOnNullResponse, [string]$IdentityKey, [int]$MonitorIndex, [int]$Generation, [int64]$HandleValue)
        $index = 0
        foreach ($code in $Codes) {
            $index++
            $vct = [uint32]0
            $current = [uint32]0
            $maximum = [uint32]0
            $lastError = [int]0
            $attempts = [int]0
            $ok = [MonitorAPI]::ReadVCPWithRetry($Handle, [byte]$code, $ReadRetries, $DelayMilliseconds, $StopOnNullResponse, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
            [PSCustomObject]@{
                Code = [int]$code
                Success = [bool]$ok
                Current = [uint32]$current
                Maximum = [uint32]$maximum
                Type = [uint32]$vct
                LastError = [int]$lastError
                Attempts = [int]$attempts
                RetryCount = [Math]::Max(0, $attempts - 1)
                MonitorName = [string]$MonitorName
                IdentityKey = [string]$IdentityKey
                MonitorIndex = [int]$MonitorIndex
                Generation = [int]$Generation
                HandleValue = [int64]$HandleValue
                Index = [int]$index
                Count = [int]$Codes.Count
            }
        }
    }
    $script:VcpWorkerMode = $Mode
    $script:VcpWorkerMonitorName = $MonitorName
    $script:VcpWorkerGeneration = $generation
    $script:VcpWorkerIdentityKey = $IdentityKey
    $script:VcpWorkerMonitorIndex = $MonitorIndex
    $script:VcpWorkerHandleValue = $handleValue
    $script:VcpWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VcpWorkerInput.Complete()
    $script:VcpWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VcpWorker = [PowerShell]::Create()
    $script:VcpWorker.AddScript($workerScript.ToString()).AddArgument($Handle).AddArgument($Codes).AddArgument($MonitorName).AddArgument($ReadRetries).AddArgument($DelayMilliseconds).AddArgument($stopOnNullResponse).AddArgument($IdentityKey).AddArgument($MonitorIndex).AddArgument($generation).AddArgument($handleValue) | Out-Null
    $script:VcpWorkerAsyncResult = $script:VcpWorker.BeginInvoke($script:VcpWorkerInput, $script:VcpWorkerOutput)
    $script:VcpWorkerLastOutputCount = 0
    if (-not $script:VcpWorkerTimer) {
        $script:VcpWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:VcpWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:VcpWorkerTimer.Add_Tick({ Update-VcpWorkerOutput })
    }
    $vcpQueryBtn.IsEnabled = $false
    $vcpScanBtn.IsEnabled = $false
    $vcpResultBox.Text = if ($Mode -eq "Scan") { "Scanning VCP codes 0/$($Codes.Count)..." } else { "Reading VCP..." }
    $script:VcpWorkerTimer.Start()
}

















function Copy-DdcCompatibilityReport {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    try {
        [System.Windows.Clipboard]::SetText($Text)
        return $true
    } catch {
        return $false
    }
}



function Update-DdcReportWorkerOutput {
    if (-not $script:DdcReportWorker -or -not $script:DdcReportWorkerOutput -or -not $script:DdcReportWorkerAsyncResult) { return }
    if ($script:DdcReportWorkerGeneration -ne $script:DisplayRecoveryGeneration) {
        Stop-DdcReportWorker -Cancel
        return
    }
    $probeResults = @($script:DdcReportWorkerOutput | Where-Object {
        $_.Kind -eq "Probe" -and (Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)
    })
    $count = $probeResults.Count
    $completed = [bool]$script:DdcReportWorkerAsyncResult.IsCompleted
    if ($count -ne $script:DdcReportWorkerLastOutputCount -and -not $completed) {
        $script:DdcReportWorkerLastOutputCount = $count
        $total = 0
        foreach ($target in @($script:DdcReportTargets)) { $total += @($target.ProbeCodes).Count }
        $ddcReportBox.Text = "Generating DDC compatibility report... $count/$total probes"
        Update-Status "Generating DDC report... $count/$total"
    }
    if (-not $completed) { return }
    try { $script:DdcReportWorker.EndInvoke($script:DdcReportWorkerAsyncResult) } catch { Update-Status "DDC report failed: $($_.Exception.Message)" }
    $timingDirty = $false
    foreach ($target in @($script:DdcReportTargets)) {
        $targetResults = @($probeResults | Where-Object { [int]$_.TargetIndex -eq [int]$target.Index })
        $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$target.IdentityKey)
        $otherCodesResponded = @($targetResults | Where-Object { [bool]$_.Success }).Count -gt 0 -or (Test-DdcMonitorResponded -IdentityKey ([string]$target.IdentityKey))
        foreach ($probeResult in $targetResults) {
            if (Register-DdcCodeOutcome -TimingProfile $timingProfile -Code ([int]$probeResult.Code) -Success ([bool]$probeResult.Success) -LastError ([int]$probeResult.LastError) -Attempts ([int]$probeResult.Attempts) -OtherCodesResponded $otherCodesResponded) {
                $timingDirty = $true
            }
        }
    }
    if ($timingDirty) { Save-DdcTimingSettings | Out-Null }
    $recentErrors = Get-DdcReportRecentErrors
    $report = New-DdcCompatibilityReport -Targets $script:DdcReportTargets -ProbeResults $probeResults -RecentErrors $recentErrors -IncludeRawMonitorIdentifiers:$script:DdcReportIncludeRawMonitorIdentifiers -IncludeRawNames:$script:DdcReportIncludeRawNames
    $reportJson = New-DdcCompatibilityReportJson -Targets $script:DdcReportTargets -ProbeResults $probeResults -RecentErrors $recentErrors -IncludeRawMonitorIdentifiers:$script:DdcReportIncludeRawMonitorIdentifiers -IncludeRawNames:$script:DdcReportIncludeRawNames
    $script:DdcReportLastText = $report
    $script:DdcReportLastJson = $reportJson
    $ddcReportBox.Text = $report
    $copied = Copy-DdcCompatibilityReport -Text $report
    $path = Save-DdcCompatibilityReport -Text $report -Json $reportJson -IncludeRawMonitorIdentifiers:$script:DdcReportIncludeRawMonitorIdentifiers -IncludeRawNames:$script:DdcReportIncludeRawNames
    $script:DdcReportOutputPath = $path
    $leaf = if ($path) { Split-Path -Path $path -Leaf } else { "" }
    if ($copied -and $leaf) {
        Update-Status "DDC report copied and saved as $leaf"
    } elseif ($copied) {
        Update-Status "DDC report copied; save failed"
    } elseif ($leaf) {
        Update-Status "DDC report saved as $leaf; clipboard unavailable"
    } else {
        Update-Status "DDC report ready; clipboard and save failed"
    }
    Stop-DdcReportWorker
}

function Start-DdcReportWorker {
    if (Test-VerifiedVcpTransactionWorkerActive) { Update-Status "Wait for the verified DDC transaction to finish"; return }
    Stop-DdcReportWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-MonitorSettingsWorker -Cancel
    Drain-DdcWriteResults
    $targets = @(Get-DdcReportTargets)
    if ($targets.Count -eq 0) {
        $ddcReportBox.Text = "No monitors enumerated."
        Update-Status "No monitors to report"
        return
    }
    $script:DdcReportTargets = $targets
    $script:DdcReportIncludeRawMonitorIdentifiers = [bool]$ddcReportIncludeIdentifiersCheckbox.IsChecked
    $script:DdcReportIncludeRawNames = [bool]$ddcReportIncludeNamesCheckbox.IsChecked
    $total = 0
    foreach ($target in @($targets)) { $total += @($target.ProbeCodes).Count }
    $ddcReportBox.Text = "Generating DDC compatibility report... 0/$total probes"
    if ($ddcReportGenerateBtn) { $ddcReportGenerateBtn.IsEnabled = $false }
    if ($ddcReportCopyBtn) { $ddcReportCopyBtn.IsEnabled = $false }
    if ($ddcReportIncludeIdentifiersCheckbox) { $ddcReportIncludeIdentifiersCheckbox.IsEnabled = $false }
    if ($ddcReportIncludeNamesCheckbox) { $ddcReportIncludeNamesCheckbox.IsEnabled = $false }
    $workerScript = {
        param([object[]]$Targets, [int]$ReadRetries)
        foreach ($target in $Targets) {
            if ([int64]$target.HandleValue -eq 0) { continue }
            $codes = @($target.ProbeCodes)
            $probeIndex = 0
            foreach ($code in $codes) {
                $probeIndex++
                $vct = [uint32]0
                $current = [uint32]0
                $maximum = [uint32]0
                $lastError = [int]0
                $attempts = [int]0
                $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]$code, $ReadRetries, [MonitorAPI]::VcpRetryDelayMilliseconds, [bool]$target.StopOnNullResponse, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
                [PSCustomObject]@{
                    Kind = "Probe"
                    TargetIndex = [int]$target.Index
                    MonitorIndex = [int]$target.MonitorIndex
                    IdentityKey = [string]$target.IdentityKey
                    Generation = [int]$target.Generation
                    HandleValue = [int64]$target.HandleValue
                    ProbeIndex = [int]$probeIndex
                    Code = [int]$code
                    Success = [bool]$ok
                    Current = [uint32]$current
                    Maximum = [uint32]$maximum
                    Type = [uint32]$vct
                    LastError = [int]$lastError
                    Attempts = [int]$attempts
                    RetryCount = [Math]::Max(0, $attempts - 1)
                }
            }
        }
    }
    $script:DdcReportWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:DdcReportWorkerInput.Complete()
    $script:DdcReportWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:DdcReportWorker = [PowerShell]::Create()
    $script:DdcReportWorker.AddScript($workerScript.ToString()).AddArgument($targets).AddArgument($script:DdcScanRetryCount) | Out-Null
    $script:DdcReportWorkerAsyncResult = $script:DdcReportWorker.BeginInvoke($script:DdcReportWorkerInput, $script:DdcReportWorkerOutput)
    $script:DdcReportWorkerLastOutputCount = 0
    $script:DdcReportWorkerGeneration = [int]$script:DisplayRecoveryGeneration
    if (-not $script:DdcReportWorkerTimer) {
        $script:DdcReportWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DdcReportWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:DdcReportWorkerTimer.Add_Tick({ Update-DdcReportWorkerOutput })
    }
    Update-Status "Generating DDC report... 0/$total"
    $script:DdcReportWorkerTimer.Start()
}

















function Confirm-AutomationBridgeNetworkExposure {
    param([System.Net.IPAddress]$Address)
    if ($null -eq $Address) { return $false }
    if ([System.Net.IPAddress]::IsLoopback($Address)) {
        $script:AutomationBridgeNetworkExposureApproved = $false
        $script:AutomationBridgeNetworkExposureApprovedFor = ""
        return $true
    }
    if ($script:AutomationBridgeNetworkExposureApproved -and $script:AutomationBridgeNetworkExposureApprovedFor -eq $Address.ToString()) { return $true }
    $message = @"
This bind address exposes the automation bridge beyond this PC.

All routes except the minimal health check require an API key, but the bridge uses unencrypted HTTP. A client or network observer could capture that key. Only continue on a trusted network with an appropriate Windows Firewall rule.

Expose the bridge on $($Address.ToString())?
"@
    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Expose automation bridge to the network?",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
    $script:AutomationBridgeNetworkExposureApproved = $true
    $script:AutomationBridgeNetworkExposureApprovedFor = $Address.ToString()
    return $true
}

function Read-AutomationBridgeSettingsFromUI {
    if ($null -eq $automationBridgePortBox) { return $false }
    $port = 0
    if (-not [int]::TryParse($automationBridgePortBox.Text.Trim(), [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
        Update-Status "Bridge port must be 1024-65535"
        return $false
    }
    $bind = $automationBridgeBindBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($bind)) { $bind = "127.0.0.1" }
    $resolved = Resolve-AutomationBridgeIPAddress -BindAddress $bind
    if ($null -eq $resolved) {
        $script:AutomationBridgeLastError = "Invalid bind address"
        Update-Status "Bridge bind address must be localhost or a valid IP address"
        return $false
    }
    $key = $automationBridgeKeyBox.Password.Trim()
    if ($key.Length -lt 16) {
        Update-Status "Bridge API key must be at least 16 characters"
        return $false
    }
    if ([bool]$automationBridgeEnabledCheckbox.IsChecked -and -not (Confirm-AutomationBridgeNetworkExposure -Address $resolved)) {
        $script:AutomationBridgeLastError = "Network exposure was not approved"
        Update-Status "Automation bridge remains disabled; network exposure was not approved"
        return $false
    }
    $script:AutomationBridgeBindAddress = $bind
    $script:AutomationBridgePort = $port
    $script:AutomationBridgeApiKey = $key
    $script:AutomationBridgeEnabled = [bool]$automationBridgeEnabledCheckbox.IsChecked
        $script:AutomationBridgeLastError = ""
    return $true
}

function Update-AutomationBridgeControls {
    if ($null -eq $automationBridgeEnabledCheckbox) { return }
    $script:UpdatingAutomationBridgeUI = $true
    try {
        $automationBridgeEnabledCheckbox.IsChecked = [bool]$script:AutomationBridgeEnabled
        $automationBridgeBindBox.Text = [string]$script:AutomationBridgeBindAddress
        $automationBridgePortBox.Text = ([int]$script:AutomationBridgePort).ToString()
        $automationBridgeKeyBox.Password = [string]$script:AutomationBridgeApiKey
        $running = $null -ne $script:AutomationBridgeWorker
        $state = if (-not [string]::IsNullOrWhiteSpace($script:AutomationBridgeLastError)) {
            "Error: $script:AutomationBridgeLastError"
        } elseif ($running) {
            "Listening"
        } elseif ($script:AutomationBridgeEnabled) {
            "Stopped"
        } else {
            "Off"
        }
        $automationBridgeStatusText.Text = "$state - http://$script:AutomationBridgeBindAddress`:$script:AutomationBridgePort"
    } finally {
        $script:UpdatingAutomationBridgeUI = $false
    }
}

function Update-RunAtLoginControls {
    if ($null -eq $runAtLoginEnabledCheckbox) { return }
    $script:UpdatingRunAtLoginUI = $true
    try {
        $shortcutPath = Get-RunAtLoginShortcutPath
        $enabled = Test-RunAtLoginShortcut -ShortcutPath $shortcutPath
        $runAtLoginEnabledCheckbox.IsChecked = $enabled
        $runAtLoginStatusText.Text = if ($enabled) { "On" } elseif (Test-Path -LiteralPath $shortcutPath) { "Needs repair" } else { "Off" }
    } finally {
        $script:UpdatingRunAtLoginUI = $false
    }
}

































function Start-AutomationBridgeRequestTimer {
    if ($script:AutomationBridgeTimer) { $script:AutomationBridgeTimer.Start(); return }
    $script:AutomationBridgeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutomationBridgeTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:AutomationBridgeTimer.Add_Tick({ Process-AutomationBridgeRequests })
    $script:AutomationBridgeTimer.Start()
}



function Stop-AutomationBridge {
    $script:AutomationBridgeState["Stop"] = $true
    if ($script:AutomationBridgeTimer) { $script:AutomationBridgeTimer.Stop() }
    if ($script:AutomationBridgeListener) {
        try { $script:AutomationBridgeListener.Stop() } catch { $null = $_ }
        $script:AutomationBridgeListener = $null
    }
    if ($script:AutomationBridgeWorker) {
        try {
            if ($script:AutomationBridgeAsyncResult -and -not $script:AutomationBridgeAsyncResult.AsyncWaitHandle.WaitOne(2500)) {
                try { $script:AutomationBridgeWorker.Stop() } catch {}
            }
        } catch {}
        try { $script:AutomationBridgeWorker.Dispose() } catch {}
    }
    if ($script:AutomationBridgeInput) { try { $script:AutomationBridgeInput.Dispose() } catch {} }
    if ($script:AutomationBridgeOutput) { try { $script:AutomationBridgeOutput.Dispose() } catch {} }
    $script:AutomationBridgeWorker = $null
    $script:AutomationBridgeInput = $null
    $script:AutomationBridgeOutput = $null
    $script:AutomationBridgeAsyncResult = $null
    $script:AutomationBridgeRequests = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:AutomationBridgeResponses = [hashtable]::Synchronized(@{})
    Update-AutomationBridgeControls
}

function Start-AutomationBridge {
    Stop-AutomationBridge
    if (-not $script:AutomationBridgeEnabled) { Update-AutomationBridgeControls; return }
    $ip = Resolve-AutomationBridgeIPAddress -BindAddress $script:AutomationBridgeBindAddress
    if ($null -eq $ip) {
        $script:AutomationBridgeLastError = "Invalid bind address"
        Update-Status "Bridge start failed: invalid bind address"
        Update-AutomationBridgeControls
        return
    }
    if (-not [System.Net.IPAddress]::IsLoopback($ip) -and (
        -not $script:AutomationBridgeNetworkExposureApproved -or
        $script:AutomationBridgeNetworkExposureApprovedFor -ne $ip.ToString()
    )) {
        $script:AutomationBridgeLastError = "Network exposure requires approval"
        Update-Status "Bridge start blocked until network exposure is approved"
        Update-AutomationBridgeControls
        return
    }
    try {
        $script:AutomationBridgeListener = [System.Net.Sockets.TcpListener]::new($ip, [int]$script:AutomationBridgePort)
        $script:AutomationBridgeListener.Start()
    } catch {
        $script:AutomationBridgeListener = $null
        $script:AutomationBridgeLastError = "Bind address or port is unavailable"
        Update-Status "Bridge start failed: bind address or port is unavailable"
        Update-AutomationBridgeControls
        return
    }
    $settings = [PSCustomObject]@{
        Listener = $script:AutomationBridgeListener
        ApiKey = [string]$script:AutomationBridgeApiKey
        MaxRequestLineBytes = [int]$script:AutomationBridgeMaxRequestLineBytes
        MaxHeaderBytes = [int]$script:AutomationBridgeMaxHeaderBytes
        MaxHeaderCount = [int]$script:AutomationBridgeMaxHeaderCount
        MaxQueryParameterCount = [int]$script:AutomationBridgeMaxQueryParameterCount
        MaxBodyBytes = [int]$script:AutomationBridgeMaxBodyBytes
        MaxResponseBytes = [int]$script:AutomationBridgeMaxResponseBytes
        MaxConcurrentClients = [int]$script:AutomationBridgeMaxConcurrentClients
        ReadTimeoutMs = [int]$script:AutomationBridgeReadTimeoutMs
        WriteTimeoutMs = [int]$script:AutomationBridgeWriteTimeoutMs
        RouteTimeoutMs = [int]$script:AutomationBridgeRouteTimeoutMs
    }
    $script:AutomationBridgeState = [hashtable]::Synchronized(@{
        Stop = $false
        ActiveClients = 0
        PeakActiveClients = 0
        RejectedClients = 0
        WriteFailureCount = 0
        HandlerFailureCount = 0
        LastReadTimeoutMs = 0
        LastWriteTimeoutMs = 0
    })
    $workerScript = Get-AutomationBridgeWorkerScript
    $script:AutomationBridgeInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:AutomationBridgeInput.Complete()
    $script:AutomationBridgeOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:AutomationBridgeWorker = [PowerShell]::Create()
    $script:AutomationBridgeWorker.AddScript($workerScript.ToString()).AddArgument($settings).AddArgument($script:AutomationBridgeRequests).AddArgument($script:AutomationBridgeResponses).AddArgument($script:AutomationBridgeState) | Out-Null
    $script:AutomationBridgeAsyncResult = $script:AutomationBridgeWorker.BeginInvoke($script:AutomationBridgeInput, $script:AutomationBridgeOutput)
    $script:AutomationBridgeLastError = ""
    Start-AutomationBridgeRequestTimer
    Update-AutomationBridgeControls
    Update-Status "Bridge listening on http://$script:AutomationBridgeBindAddress`:$script:AutomationBridgePort"
}



function Update-VcpMaximumCache {
    param([object[]]$Results)
    foreach ($result in @($Results)) {
        if (-not [bool]$result.Success) { continue }
        $maximum = [int]$result.Maximum
        if ($maximum -le 0) { continue }
        $identityKey = [string]$result.IdentityKey
        if ([string]::IsNullOrWhiteSpace($identityKey)) { continue }
        foreach ($monitor in @($script:PhysicalMonitors)) {
            if ([string]$monitor.IdentityKey -ne $identityKey) { continue }
            Set-VcpMaximumForMonitor -Monitor $monitor -Code ([int]$result.Code) -Maximum $maximum
            break
        }
    }
}

function ConvertTo-SelectedRawValue {
    param([int]$Percent, [int]$Code)
    return ConvertTo-VcpRawValue -Percent ([double]$Percent) -Maximum (Get-SelectedMonitorVcpMaximum -Code $Code)
}

function Get-SelectedBrightnessPercent {
    return ConvertTo-VcpPercent -RawValue ([double]$brightnessSlider.Value) -Maximum (Get-SelectedMonitorVcpMaximum -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))
}

function Set-BrightnessSliderFromPercent {
    param([int]$Percent)
    $maximum = Get-SelectedMonitorVcpMaximum -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
    $raw = ConvertTo-VcpRawValue -Percent ([double]$Percent) -Maximum $maximum
    $script:UpdatingUI = $true
    try {
        $brightnessSlider.Maximum = $maximum
        $brightnessSlider.Value = $raw
        $brightnessValue.Text = ([int]$raw).ToString()
    } finally {
        $script:UpdatingUI = $false
    }
    return $raw
}

function Set-ScaledVcpFromSlider {
    param([byte]$VCPCode, [double]$RawValue)
    $percent = ConvertTo-VcpPercent -RawValue $RawValue -Maximum (Get-SelectedMonitorVcpMaximum -Code ([int]$VCPCode))
    return Set-VCPValueWithSync -VCPCode $VCPCode -Value ([uint32]$percent) -Percent -UserInitiated
}

function Apply-MonitorSettingResult {
    param($Result)
    if (-not [bool]$Result.Success) { return }
    $code = [int]$Result.Code
    $current = [uint32]$Result.Current
    $maximum = [uint32]$Result.Maximum
    if ($code -eq [MonitorAPI]::VCP_BRIGHTNESS) {
        $brightnessSlider.Maximum = $maximum; $brightnessSlider.Value = $current; $brightnessValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_CONTRAST) {
        $contrastSlider.Maximum = $maximum; $contrastSlider.Value = $current; $contrastValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_RED_GAIN) {
        $redSlider.Maximum = $maximum; $redSlider.Value = $current; $redValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_GREEN_GAIN) {
        $greenSlider.Maximum = $maximum; $greenSlider.Value = $current; $greenValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_BLUE_GAIN) {
        $blueSlider.Maximum = $maximum; $blueSlider.Value = $current; $blueValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_VOLUME) {
        $volumeSlider.Maximum = $maximum; $volumeSlider.Value = $current; $volumeValue.Text = $current
    } elseif ($code -eq [MonitorAPI]::VCP_SHARPNESS) {
        $sharpnessSlider.Maximum = $maximum; $sharpnessSlider.Value = $current; $sharpnessValue.Text = $current
    }
}

function Update-MonitorSettingsWorkerOutput {
    if (-not $script:MonitorSettingsWorker -or -not $script:MonitorSettingsWorkerOutput -or -not $script:MonitorSettingsWorkerAsyncResult) { return }
    if ($script:MonitorSettingsWorkerGeneration -ne $script:DisplayRecoveryGeneration) {
        Stop-MonitorSettingsWorker -Cancel
        return
    }
    $count = $script:MonitorSettingsWorkerOutput.Count
    $completed = [bool]$script:MonitorSettingsWorkerAsyncResult.IsCompleted
    if ($count -ne $script:MonitorSettingsWorkerLastOutputCount -and -not $completed) {
        $script:MonitorSettingsWorkerLastOutputCount = $count
        Update-Status "Reading from $script:MonitorSettingsWorkerName... $count/$script:MonitorSettingsWorkerTotalReads"
    }
    if (-not $completed) { return }
    $workerName = $script:MonitorSettingsWorkerName
    $workerTargets = @($script:MonitorSettingsWorkerTargets)
    try { $script:MonitorSettingsWorker.EndInvoke($script:MonitorSettingsWorkerAsyncResult) } catch { Update-Status "Monitor settings read failed: $($_.Exception.Message)" }
    $results = @($script:MonitorSettingsWorkerOutput | Where-Object {
        Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
    })
    $settingResults = @($results | Where-Object { [string]$_.Kind -ne "NullProbe" })
    Update-VcpMaximumCache -Results $settingResults
    $selectedPublished = $false
    $timingDirty = $false
    foreach ($target in $workerTargets) {
        if (-not (Test-DisplayWorkerResultCurrent -Result $target -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) { continue }
        $targetResults = @($settingResults | Where-Object { [string]$_.IdentityKey -eq [string]$target.IdentityKey })
        $successes = @($targetResults | Where-Object { [bool]$_.Success })
        $failures = @($targetResults | Where-Object { -not [bool]$_.Success })
        $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$target.IdentityKey)
        $otherCodesResponded = $successes.Count -gt 0 -or (Test-DdcMonitorResponded -IdentityKey ([string]$target.IdentityKey))
        foreach ($settingResult in $targetResults) {
            if (Register-DdcCodeOutcome -TimingProfile $timingProfile -Code ([int]$settingResult.Code) -Success ([bool]$settingResult.Success) -LastError ([int]$settingResult.LastError) -Attempts ([int]$settingResult.Attempts) -OtherCodesResponded $otherCodesResponded) {
                $timingDirty = $true
            }
        }
        $nullProbeResult = @($results | Where-Object {
            [string]$_.IdentityKey -eq [string]$target.IdentityKey -and [string]$_.Kind -eq "NullProbe"
        } | Select-Object -First 1)
        if ($nullProbeResult.Count -gt 0) {
            if (Set-DdcNullSemanticsClassification -TimingProfile $timingProfile -ProbeResult $nullProbeResult[0] -OtherCodesResponded:($successes.Count -gt 0)) {
                $timingDirty = $true
            }
        }
        if ($successes.Count -gt 0) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$target.IdentityKey) -Outcome "Success" -Generation $script:DisplayRecoveryGeneration | Out-Null
        } else {
            $message = if ($targetResults.Count -eq 0) { "DDC worker returned no result" } else { "DDC health read failed" }
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$target.IdentityKey) -Outcome "Failure" -Generation $script:DisplayRecoveryGeneration -ErrorMessage $message | Out-Null
        }
        $isSelected = $script:CurrentMonitorIndex -ge 0 -and
            $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count -and
            [string]$script:PhysicalMonitors[$script:CurrentMonitorIndex].IdentityKey -eq [string]$target.IdentityKey
        if ($isSelected) {
            $selectedPublished = $true
            $script:UpdatingUI = $true
            try {
                foreach ($result in $successes) { Apply-MonitorSettingResult -Result $result }
            } finally {
                $script:UpdatingUI = $false
            }
            foreach ($failure in $failures) {
                Register-DdcDiagnostic -Operation "Read" -Monitor ([string]$target.MonitorName) -Code ([int]$failure.Code) -Value $null -LastError ([int]$failure.LastError) -Attempts ([int]$failure.Attempts) -Message "Monitor setting refresh" -SuppressStatus | Out-Null
            }
            if ($failures.Count -gt 0) {
                Update-Status ("{0} ({1}/{2} readable; DDC diagnostics captured)" -f ([string]$target.MonitorName), $successes.Count, @($target.Codes).Count)
            } else {
                Update-Status ([string]$target.MonitorName)
            }
            Update-TrayPopupState
            Update-TrayIconText
        }
    }
    if ($timingDirty) { Save-DdcTimingSettings | Out-Null }
    Invoke-DisplayStateRestore -Generation $script:DisplayRecoveryGeneration -Reason "display refresh" | Out-Null
    if (-not $selectedPublished -and $workerName -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        Update-SelectedMonitorRecoveryUi
    }
    Stop-MonitorSettingsWorker
}

function Start-MonitorSettingsWorker {
    param([IntPtr]$Handle, [int]$MonitorIndex, [string]$MonitorName)
    if (Test-VerifiedVcpTransactionWorkerActive) { return }
    Stop-MonitorSettingsWorker -Cancel
    if ($Handle -ne [IntPtr]::Zero -and $MonitorIndex -ge 0 -and $MonitorIndex -lt $script:PhysicalMonitors.Count) {
        if ($script:PhysicalMonitors[$MonitorIndex].Handle.ToInt64() -ne $Handle.ToInt64()) { return }
    }
    $selectedCodes = @(
        [int][MonitorAPI]::VCP_BRIGHTNESS,
        [int][MonitorAPI]::VCP_CONTRAST,
        [int][MonitorAPI]::VCP_RED_GAIN,
        [int][MonitorAPI]::VCP_GREEN_GAIN,
        [int][MonitorAPI]::VCP_BLUE_GAIN,
        [int][MonitorAPI]::VCP_VOLUME,
        [int][MonitorAPI]::VCP_SHARPNESS
    )
    $generation = [int]$script:DisplayRecoveryGeneration
    $targets = @()
    for ($index = 0; $index -lt $script:PhysicalMonitors.Count; $index++) {
        $monitor = $script:PhysicalMonitors[$index]
        if ($null -eq $monitor -or $monitor.Handle -eq [IntPtr]::Zero -or [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey)) { continue }
        $state = if ($script:DisplayRecoveryStates.ContainsKey([string]$monitor.IdentityKey)) { $script:DisplayRecoveryStates[[string]$monitor.IdentityKey] } else { $null }
        $codes = if ($index -eq $MonitorIndex) { $selectedCodes } else { @([int][MonitorAPI]::VCP_BRIGHTNESS) }
        $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$monitor.IdentityKey)
        $effectiveTiming = Get-DdcEffectiveTiming -TimingProfile $timingProfile
        $targets += [PSCustomObject]@{
            MonitorIndex = [int]$index
            MonitorName = [string]$monitor.Name
            IdentityKey = [string]$monitor.IdentityKey
            Handle = $monitor.Handle
            HandleValue = [int64]$monitor.Handle.ToInt64()
            Generation = $generation
            Codes = [object[]]$codes
            ReadRetries = Get-DisplayRecoveryReadRetryCount -State $state -DefaultRetries ([int]$effectiveTiming.ReadRetries)
            DelayMilliseconds = [int]$effectiveTiming.DelayMilliseconds
            SkipCodes = [object[]]@(@($timingProfile.UnsupportedCodes) | ForEach-Object { [int]$_.Code })
            StopOnNullResponse = $timingProfile.PSObject.Properties.Name -contains "NullMeansUnsupported" -and [bool]$timingProfile.NullMeansUnsupported
            ProbeNullSemantics = [string]::IsNullOrWhiteSpace([string]$timingProfile.NullSemanticsClassifiedAt)
            NullProbeRetries = [int][Math]::Max(2, [int]$effectiveTiming.ReadRetries)
        }
        Set-DisplayRecoveryOutcome -IdentityKey ([string]$monitor.IdentityKey) -Outcome "Retry" -Generation $generation | Out-Null
    }
    if ($targets.Count -eq 0) { return }
    $workerScript = {
        param([object[]]$Targets)
        foreach ($target in $Targets) {
            $index = 0
            $anySuccess = $false
            foreach ($code in @($target.Codes)) {
                $index++
                $vct = [uint32]0
                $current = [uint32]0
                $maximum = [uint32]0
                $lastError = [int]0
                $attempts = [int]0
                if (@($target.SkipCodes) -contains [int]$code) { continue }
                $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]$code, [int]$target.ReadRetries, [int]$target.DelayMilliseconds, [bool]$target.StopOnNullResponse, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
                if ($ok) { $anySuccess = $true }
                [PSCustomObject]@{
                    Kind = "Setting"
                    Code = [int]$code
                    Success = [bool]$ok
                    Current = [uint32]$current
                    Maximum = [uint32]$maximum
                    Type = [uint32]$vct
                    LastError = [int]$lastError
                    Attempts = [int]$attempts
                    RetryCount = [Math]::Max(0, $attempts - 1)
                    MonitorName = [string]$target.MonitorName
                    IdentityKey = [string]$target.IdentityKey
                    MonitorIndex = [int]$target.MonitorIndex
                    Generation = [int]$target.Generation
                    HandleValue = [int64]$target.HandleValue
                    Index = [int]$index
                    Count = [int]@($target.Codes).Count
                }
            }
            if ([bool]$target.ProbeNullSemantics -and $anySuccess) {
                $vct = [uint32]0
                $current = [uint32]0
                $maximum = [uint32]0
                $lastError = [int]0
                $attempts = [int]0
                $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]0x00, [int]$target.NullProbeRetries, [int]$target.DelayMilliseconds, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
                [PSCustomObject]@{
                    Kind = "NullProbe"
                    Code = 0
                    Success = [bool]$ok
                    Current = [uint32]$current
                    Maximum = [uint32]$maximum
                    Type = [uint32]$vct
                    LastError = [int]$lastError
                    Attempts = [int]$attempts
                    RetryCount = [Math]::Max(0, $attempts - 1)
                    MonitorName = [string]$target.MonitorName
                    IdentityKey = [string]$target.IdentityKey
                    MonitorIndex = [int]$target.MonitorIndex
                    Generation = [int]$target.Generation
                    HandleValue = [int64]$target.HandleValue
                    Index = [int](@($target.Codes).Count + 1)
                    Count = [int](@($target.Codes).Count + 1)
                }
            }
        }
    }
    $script:MonitorSettingsWorkerIndex = $MonitorIndex
    $script:MonitorSettingsWorkerName = $MonitorName
    $script:MonitorSettingsWorkerGeneration = $generation
    $script:MonitorSettingsWorkerTargets = $targets
    $script:MonitorSettingsWorkerTotalReads = [int](($targets | ForEach-Object { @($_.Codes).Count + $(if ([bool]$_.ProbeNullSemantics) { 1 } else { 0 }) } | Measure-Object -Sum).Sum)
    $script:MonitorSettingsWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:MonitorSettingsWorkerInput.Complete()
    $script:MonitorSettingsWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:MonitorSettingsWorker = [PowerShell]::Create()
    $script:MonitorSettingsWorker.AddScript($workerScript.ToString()).AddArgument($targets) | Out-Null
    $script:MonitorSettingsWorkerAsyncResult = $script:MonitorSettingsWorker.BeginInvoke($script:MonitorSettingsWorkerInput, $script:MonitorSettingsWorkerOutput)
    $script:MonitorSettingsWorkerLastOutputCount = 0
    if (-not $script:MonitorSettingsWorkerTimer) {
        $script:MonitorSettingsWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:MonitorSettingsWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:MonitorSettingsWorkerTimer.Add_Tick({ Update-MonitorSettingsWorkerOutput })
    }
    Update-Status "Reading from $MonitorName... 0/$script:MonitorSettingsWorkerTotalReads"
    $script:MonitorSettingsWorkerTimer.Start()
}





function Apply-TimeBasedSettings {
    $settings = Get-TimeBasedSettings
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $settings.Brightness -Force -Percent | Out-Null
    Set-GammaRamp -Gamma 1.0 -RedMult $settings.GammaRed -GreenMult $settings.GammaGreen -BlueMult $settings.GammaBlue
    return $settings
}











# Microsoft's adaptive-brightness guidance uses deliberately overlapping lux buckets so that a
# reading sitting on a boundary cannot flip the display. Each level is entered once the reading
# rises above RiseAbove and left only once it falls below the lower FallBelow of the level it is
# already in, which is a Schmitt trigger: the overlap between the two is the hysteresis band.
# The lowest level is floored well above zero so the screen never becomes unreadable.
$script:AmbientLuxLadder = @(
    [PSCustomObject]@{ Brightness = 15;  RiseAbove = 0;    FallBelow = 0 }
    [PSCustomObject]@{ Brightness = 25;  RiseAbove = 10;   FallBelow = 6 }
    [PSCustomObject]@{ Brightness = 40;  RiseAbove = 50;   FallBelow = 30 }
    [PSCustomObject]@{ Brightness = 55;  RiseAbove = 200;  FallBelow = 130 }
    [PSCustomObject]@{ Brightness = 70;  RiseAbove = 600;  FallBelow = 400 }
    [PSCustomObject]@{ Brightness = 85;  RiseAbove = 1500; FallBelow = 1000 }
    [PSCustomObject]@{ Brightness = 100; RiseAbove = 5000; FallBelow = 3500 }
)
$script:AmbientMaxStepPercent = 10
$script:AmbientMinWriteIntervalSeconds = 20
$script:AmbientLevelIndex = -1
$script:AmbientAppliedBrightness = -1
$script:AmbientLastWriteUtc = [DateTime]::MinValue







function Apply-AmbientLightSettings {
    $lux = Get-AmbientLux
    if ($null -eq $lux) {
        $autoModeText.Text = "Ambient unavailable"
        Update-Status "Ambient light sensor unavailable"
        return
    }
    $decision = Get-AmbientBrightnessDecision -Lux $lux -CurrentIndex $script:AmbientLevelIndex -CurrentBrightness $script:AmbientAppliedBrightness -LastWriteUtc $script:AmbientLastWriteUtc -NowUtc ([DateTime]::UtcNow)
    $script:AmbientLevelIndex = [int]$decision.LevelIndex
    $autoModeText.Text = "Ambient: $([math]::Round($lux, 0)) lx"
    if (-not [bool]$decision.ShouldWrite) {
        Update-Status "Ambient brightness held at $($script:AmbientAppliedBrightness): $($decision.Reason)"
        return
    }
    $brightness = [int]$decision.NextBrightness
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $brightness -Force -Percent
    Set-BrightnessSliderFromPercent -Percent $brightness | Out-Null
    $script:AmbientAppliedBrightness = $brightness
    $script:AmbientLastWriteUtc = [DateTime]::UtcNow
    Update-Status "Ambient brightness: $brightness"
}

function Start-AmbientLightWatcher {
    if (-not $script:AmbientLightEnabled) {
        if ($script:AmbientLightTimer) { $script:AmbientLightTimer.Stop() }
        return
    }
    if (-not (Initialize-AmbientLightSensor)) {
        $script:AmbientLightEnabled = $false
        $autoModeText.Text = ""
        Update-Status "Ambient light sensor unavailable"
        return
    }
    if (-not $script:AmbientLightTimer) {
        $script:AmbientLightTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AmbientLightTimer.Interval = [TimeSpan]::FromSeconds(30)
        $script:AmbientLightTimer.Add_Tick({ if ($script:AmbientLightEnabled) { Apply-AmbientLightSettings } })
    }
    $script:AmbientLightTimer.Start()
    Reset-AmbientBrightnessState
    Apply-AmbientLightSettings
}































function Update-DisplayStateRestoreFromUi {
    if (-not $script:DisplayStateRestoreEnabled) { return }
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if ($null -eq $monitor) { return }
    if (Set-DisplayStateRestoreValue -IdentityKey ([string]$monitor.IdentityKey) -BrightnessPercent ([int](Get-SelectedBrightnessPercent))) {
        Save-DisplayStateRestoreSettings | Out-Null
    }
}

















try {
    if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
} catch {
    $script:ProfilesPath = $script:DefaultProfilesPath
    $script:ProfileStorageOffline = $true
    $script:ProfileStorageFallbackPath = $script:DefaultProfilesPath
    $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
    $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
    $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
    $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
    $script:MonitorIdentitySettingsPath = Join-Path $script:ProfilesPath "monitor-identities.json"
    $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
    if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MonitorControl Pro" Width="1320" Height="800" MinWidth="1024" MinHeight="720"
        Background="{DynamicResource CanvasBrush}" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
<Window.Resources>
    <GridLength x:Key="SidebarWidth">228</GridLength>
    <SolidColorBrush x:Key="CanvasBrush" Color="#07111c"/>
    <SolidColorBrush x:Key="SidebarBrush" Color="#091420"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#0a1522"/>
    <SolidColorBrush x:Key="FooterBrush" Color="#08131f"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#111d2b"/>
    <SolidColorBrush x:Key="CardBrush" Color="#142235"/>
    <SolidColorBrush x:Key="CardHoverBrush" Color="#1a2c43"/>
    <SolidColorBrush x:Key="ControlBrush" Color="#0b1724"/>
    <SolidColorBrush x:Key="TrackBrush" Color="#35475a"/>
    <SolidColorBrush x:Key="BorderBrush" Color="#586e84"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#2563c7"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#2d6bcd"/>
    <SolidColorBrush x:Key="AccentPressedBrush" Color="#1e54b5"/>
    <SolidColorBrush x:Key="FocusBrush" Color="#65a2ff"/>
    <SolidColorBrush x:Key="TextBrush" Color="#f2f5f9"/>
    <SolidColorBrush x:Key="MutedTextBrush" Color="#a0adbc"/>
    <SolidColorBrush x:Key="OnAccentBrush" Color="#ffffff"/>
    <SolidColorBrush x:Key="SuccessBrush" Color="#61d683"/>
    <SolidColorBrush x:Key="WarningBrush" Color="#f2b452"/>
    <SolidColorBrush x:Key="WarningSurfaceBrush" Color="#312719"/>
    <SolidColorBrush x:Key="DangerBrush" Color="#ff6666"/>
    <SolidColorBrush x:Key="DangerSurfaceBrush" Color="#321d24"/>
    <Style TargetType="TextBlock">
        <Setter Property="FontFamily" Value="Segoe UI"/>
        <Setter Property="FontSize" Value="13"/>
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style x:Key="KeyboardFocusVisual" TargetType="Control">
        <Setter Property="Template"><Setter.Value><ControlTemplate>
            <Border BorderBrush="{DynamicResource FocusBrush}" BorderThickness="2" CornerRadius="5" Margin="-3">
                <AdornedElementPlaceholder/>
            </Border>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <ControlTemplate x:Key="ComboBoxToggleButton" TargetType="ToggleButton">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="20"/></Grid.ColumnDefinitions>
            <Border x:Name="Border" Grid.ColumnSpan="2" CornerRadius="8" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1"/>
            <Path Grid.Column="1" Fill="{DynamicResource MutedTextBrush}" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 4 4 L 8 0 Z"/>
        </Grid>
        <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Border" Property="Background" Value="{DynamicResource CardHoverBrush}"/><Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource BorderBrush}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
        </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="Height" Value="34"/>
        <Setter Property="FontSize" Value="12"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
            <ToggleButton Template="{StaticResource ComboBoxToggleButton}" Focusable="False" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press"/>
            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
            <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="{DynamicResource CardBrush}" BorderThickness="1" BorderBrush="{DynamicResource BorderBrush}" CornerRadius="8" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="240" Margin="0,3,0,0">
                    <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer></Border>
            </Popup></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Padding" Value="10,7"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6"><ContentPresenter/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentPressedBrush}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
        <Setter Property="Background" Value="{DynamicResource CardBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="15,9"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="13"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource CardHoverBrush}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource BorderBrush}"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource CardHoverBrush}"/></Trigger>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="AccBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="{DynamicResource AccentBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource FocusBrush}"/><Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentHoverBrush}"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentPressedBrush}"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="WarnBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="{DynamicResource DangerSurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource DangerBrush}"/><Setter Property="Foreground" Value="{DynamicResource DangerBrush}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource DangerSurfaceBrush}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="GreenBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="{DynamicResource AccentBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource FocusBrush}"/><Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentHoverBrush}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="OrangeBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="{DynamicResource WarningSurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource WarningBrush}"/><Setter Property="Foreground" Value="{DynamicResource WarningBrush}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource WarningSurfaceBrush}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Sld" TargetType="Slider">
        <Setter Property="Height" Value="24"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
                <Border Height="5" Background="{DynamicResource TrackBrush}" CornerRadius="3"/>
                <Track x:Name="PART_Track">
                    <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge"><RepeatButton.Template>
                        <ControlTemplate><Border Background="{Binding Tag, RelativeSource={RelativeSource AncestorType=Slider}}" CornerRadius="3" Height="5"/></ControlTemplate>
                    </RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb><Thumb.Template><ControlTemplate><Grid><Ellipse Width="18" Height="18" Fill="{DynamicResource TextBrush}" Stroke="{DynamicResource FocusBrush}" StrokeThickness="2"/><Ellipse Width="5" Height="5" Fill="{DynamicResource AccentBrush}"/></Grid></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge"><RepeatButton.Template><ControlTemplate><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TabControl">
        <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabControl">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="{StaticResource SidebarWidth}"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,1,0" Padding="12,18">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
                        <StackPanel IsItemsHost="True" KeyboardNavigation.TabIndex="1"/>
                    </ScrollViewer>
                </Border>
                <Border Grid.Column="1" Background="{DynamicResource CanvasBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,0,0" Padding="30,24,30,20">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="18"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <TextBlock Text="{Binding SelectedItem.Header, RelativeSource={RelativeSource TemplatedParent}}" FontSize="28" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}"/>
                        <TextBlock Grid.Row="1" Text="{Binding SelectedItem.ToolTip, RelativeSource={RelativeSource TemplatedParent}}" FontSize="13" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/>
                        <ScrollViewer Grid.Row="3" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"
                                      CanContentScroll="False" Focusable="False">
                            <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"
                                              HorizontalAlignment="Stretch" VerticalAlignment="Stretch" KeyboardNavigation.TabIndex="2"
                                              AutomationProperties.IsOffscreenBehavior="Onscreen"/>
                        </ScrollViewer>
                    </Grid>
                </Border>
            </Grid>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TabItem">
        <Setter Property="Foreground" Value="{DynamicResource MutedTextBrush}"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="14"/>
        <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="16,14"/><Setter Property="Margin" Value="0,0,0,5"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="9">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="Indicator" Width="3" Height="22" CornerRadius="2" Background="{DynamicResource AccentBrush}" HorizontalAlignment="Left" Margin="-18,0,0,0" Visibility="Collapsed"/>
                    <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                    <ContentPresenter Grid.Column="1" ContentSource="Header" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                </Grid>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource CardHoverBrush}"/><Setter TargetName="Indicator" Property="Visibility" Value="Visible"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource CardHoverBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
                <Border x:Name="cb" Width="18" Height="18" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="4" Margin="0,0,8,0">
                    <Path x:Name="cm" Data="M 2 5 L 5 8 L 12 1" Stroke="{DynamicResource OnAccentBrush}" StrokeThickness="2" Visibility="Collapsed" Margin="1"/></Border>
                <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True">
                <Setter TargetName="cb" Property="Background" Value="{DynamicResource AccentBrush}"/><Setter TargetName="cb" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/>
                <Setter TargetName="cm" Property="Visibility" Value="Visible"/>
            </Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ProgressBar">
        <Setter Property="Height" Value="6"/><Setter Property="Background" Value="{DynamicResource TrackBrush}"/><Setter Property="Foreground" Value="{DynamicResource FocusBrush}"/><Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar"><Grid>
            <Border Background="{TemplateBinding Background}" CornerRadius="3"/><Border x:Name="PART_Track"/>
            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="3" HorizontalAlignment="Left"/>
        </Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
        <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
                <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
                    <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False" Opacity="0"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb MinHeight="34"><Thumb.Template><ControlTemplate TargetType="Thumb">
                        <Border x:Name="ThumbBorder" Background="{DynamicResource BorderBrush}" CornerRadius="5" Margin="3,2"/>
                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="{DynamicResource FocusBrush}"/></Trigger></ControlTemplate.Triggers>
                    </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False" Opacity="0"/></Track.IncreaseRepeatButton>
                </Track>
            </Grid>
            <ControlTemplate.Triggers>
                <Trigger Property="Orientation" Value="Horizontal"><Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/><Setter Property="Width" Value="Auto"/><Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
        <Setter Property="Background" Value="{DynamicResource ControlBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="10,7"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/><Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
            <Border x:Name="TextBoxBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TextBoxBorder" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="TextBoxBorder" Property="Opacity" Value="0.48"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="PasswordBox">
        <Setter Property="Background" Value="{DynamicResource ControlBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="10,7"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/><Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="PasswordBox">
            <Border x:Name="PasswordBoxBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="PasswordBoxBorder" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="PasswordBoxBorder" Property="Opacity" Value="0.48"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal">
                <Grid Width="18" Height="18" Margin="0,0,8,0">
                    <Ellipse x:Name="RadioRing" Fill="{DynamicResource ControlBrush}" Stroke="{DynamicResource BorderBrush}" StrokeThickness="1"/>
                    <Ellipse x:Name="RadioDot" Width="8" Height="8" Fill="{DynamicResource AccentBrush}" Visibility="Collapsed"/>
                </Grid>
                <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
                <Trigger Property="IsChecked" Value="True"><Setter TargetName="RadioRing" Property="Stroke" Value="{DynamicResource FocusBrush}"/><Setter TargetName="RadioDot" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBox">
        <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
    </Style>
    <Style TargetType="ListBoxItem">
        <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
        <Setter Property="Padding" Value="8,6"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Style.Triggers>
            <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource AccentBrush}"/><Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/></Trigger>
            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource FocusBrush}"/><Setter Property="BorderThickness" Value="2"/></Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="MonitorTileBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Padding" Value="4"/>
        <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="AutomationProperties.HelpText" Value="Select this display"/>
    </Style>
    <Style x:Key="PageCard" TargetType="Border">
        <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="CornerRadius" Value="12"/>
        <Setter Property="Padding" Value="20"/>
    </Style>
    <Style x:Key="PageCardCompact" TargetType="Border" BasedOn="{StaticResource PageCard}">
        <Setter Property="Padding" Value="16"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style x:Key="MetricValue" TargetType="TextBlock">
        <Setter Property="FontSize" Value="28"/><Setter Property="FontWeight" Value="Light"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style x:Key="SettingsTabControl" TargetType="TabControl">
        <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabControl">
            <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10">
                    <UniformGrid Rows="1" IsItemsHost="True"/>
                </Border>
                <ContentPresenter Grid.Row="2" x:Name="PART_SelectedContentHost" ContentSource="SelectedContent" HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
            </Grid>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="SettingsTabItem" TargetType="TabItem">
        <Setter Property="Foreground" Value="{DynamicResource MutedTextBrush}"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Padding" Value="10,10"/><Setter Property="Margin" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Center"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
            <Border x:Name="SettingsTabBorder" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="2">
                <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="SettingsTabBorder" Property="Background" Value="{DynamicResource AccentBrush}"/><Setter TargetName="SettingsTabBorder" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/><Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SettingsTabBorder" Property="Background" Value="{DynamicResource CardHoverBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
</Window.Resources>
<ScrollViewer x:Name="ShellScrollViewer" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Disabled"
              HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch" Focusable="False">
<Grid x:Name="ShellRoot" Background="{DynamicResource CanvasBrush}" MinWidth="984" MinHeight="680">
    <Grid.LayoutTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.LayoutTransform>
    <Grid.RowDefinitions><RowDefinition Height="Auto" MinHeight="78"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="34"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="{StaticResource SidebarWidth}"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Row="0" Grid.Column="0" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,0,1,0" Padding="18,0">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="38" Height="38" CornerRadius="10" Background="{DynamicResource AccentBrush}" VerticalAlignment="Center">
                <TextBlock Text="MC" Foreground="{DynamicResource OnAccentBrush}" FontSize="14" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0,0,0">
                <TextBlock x:Name="AppTitleText" Text="MonitorControl Pro" FontSize="14" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}" TextWrapping="Wrap"/>
                <TextBlock x:Name="AppSubtitleText" Text="Version" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
        </Grid>
    </Border>
    <Border Grid.Row="0" Grid.Column="1" Background="{DynamicResource HeaderBrush}" Padding="30,10">
        <WrapPanel VerticalAlignment="Center">
            <StackPanel Width="430" VerticalAlignment="Center" Margin="0,0,20,0">
                <TextBlock x:Name="SelectedMonitorName" Text="No monitor selected" FontSize="15" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <Grid Margin="0,2,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Ellipse x:Name="SelectedMonitorHealthDot" Width="7" Height="7" Fill="{DynamicResource MutedTextBrush}" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="SelectedMonitorHealthText" Grid.Column="1" Text="Stale" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
                <Grid Margin="0,3,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="SelectedMonitorRes" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="SelectedMonitorInfo" Grid.Column="1" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="10,0,0,0" TextTrimming="CharacterEllipsis"/>
                </Grid>
            </StackPanel>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,4,0,4">
                <CheckBox x:Name="ApplyAllCheckbox" Content="All displays" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <Button x:Name="IdentifyBtn" Content="Identify" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                <Button x:Name="RefreshBtn" Content="Refresh" Style="{StaticResource Btn}"/>
            </StackPanel>
        </WrapPanel>
    </Border>
    <Border x:Name="StatusBannerBorder" Grid.Row="1" Grid.ColumnSpan="2" Visibility="Collapsed"
            Background="{DynamicResource DangerSurfaceBrush}" BorderBrush="{DynamicResource DangerBrush}" BorderThickness="0,1"
            Padding="18,8" AutomationProperties.Name="Application alert" AutomationProperties.LiveSetting="Assertive"
            AutomationProperties.IsOffscreenBehavior="Onscreen">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="!" FontSize="16" FontWeight="Bold" Foreground="{DynamicResource DangerBrush}" VerticalAlignment="Center"/>
            <TextBlock x:Name="StatusBannerText" Grid.Column="2" TextWrapping="Wrap" Foreground="{DynamicResource TextBrush}" FontSize="12" VerticalAlignment="Center"
                       AutomationProperties.Name="Application alert" AutomationProperties.LiveSetting="Assertive"
                       AutomationProperties.IsOffscreenBehavior="Onscreen"/>
            <Button x:Name="StatusBannerDismissButton" Grid.Column="4" Content="_Dismiss" Style="{StaticResource Btn}" Padding="10,5"/>
        </Grid>
    </Border>
    <TabControl x:Name="MainNavigationTabs" Grid.Row="2" Grid.ColumnSpan="2" TabStripPlacement="Left">
        <TabItem x:Name="DisplayTab" Header="Display" Tag="&#xE7F4;" ToolTip="Tune picture and color for the selected screen.">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="18">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid>
                            <TextBlock Text="Displays" FontSize="14" FontWeight="SemiBold"/>
                            <TextBlock Text="Select a display to adjust its settings" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                        <Border Grid.Row="2" Height="118" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="12">
                            <Canvas x:Name="MonitorCanvas" ClipToBounds="True"/>
                        </Border>
                    </Grid>
                </Border>
                <Grid Grid.Row="2">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="18,14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid>
                            <StackPanel><TextBlock Text="Brightness" FontSize="13" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                                <TextBlock Text="Hardware luminance" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0"/></StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                <TextBlock x:Name="BrightnessValue" Text="50" FontSize="28" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                                <TextBlock Text="%" FontSize="13" Foreground="{DynamicResource MutedTextBrush}" Margin="2,8,0,0"/>
                            </StackPanel>
                        </Grid>
                        <Slider x:Name="BrightnessSlider" Grid.Row="2" Value="50" Tag="{DynamicResource AccentBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="16,14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Contrast" FontSize="13" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/><TextBlock x:Name="ContrastValue" Text="50" FontSize="18" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="ContrastSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Red gain" FontSize="12" Foreground="{DynamicResource DangerBrush}"/><TextBlock x:Name="RedValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="RedSlider" Grid.Row="2" Value="50" Tag="{DynamicResource DangerBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Green gain" FontSize="12" Foreground="{DynamicResource SuccessBrush}"/><TextBlock x:Name="GreenValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GreenSlider" Grid.Row="2" Value="50" Tag="{DynamicResource SuccessBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="4" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Blue gain" FontSize="12" Foreground="{DynamicResource FocusBrush}"/><TextBlock x:Name="BlueValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="BlueSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="4" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="Color temperature" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                        <TextBlock Text="Choose a white-point preset" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="ColorTempWarm" Content="Warm" Style="{StaticResource Btn}" Padding="12,6" Margin="0,0,6,0" FontSize="12"/>
                        <Button x:Name="ColorTemp6500" Content="6500K" Style="{StaticResource AccBtn}" Padding="12,6" Margin="0,0,6,0" FontSize="12"/>
                        <Button x:Name="ColorTempCool" Content="Cool" Style="{StaticResource Btn}" Padding="12,6" Margin="0,0,6,0" FontSize="12"/>
                        <Button x:Name="ColorTempSRGB" Content="sRGB" Style="{StaticResource Btn}" Padding="12,6" FontSize="12"/>
                    </StackPanel>
                </Grid></Border>
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="PresetDay" Content="Day" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetNight" Grid.Column="2" Content="Night" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetAutoMode" Grid.Column="4" Content="Auto" Style="{StaticResource OrangeBtn}" Padding="5,5"/>
                    <Button x:Name="PresetAmbientMode" Grid.Column="6" Content="Ambient" Style="{StaticResource GreenBtn}" Padding="5,5"/>
                    <Button x:Name="PresetReset" Grid.Column="8" Content="Reset" Style="{StaticResource AccBtn}" Padding="5,5"/>
                </Grid>
                <Border Grid.Row="8" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Dynamic contrast" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Button x:Name="DynamicContrastOff" Grid.Column="2" Content="Off" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    <Button x:Name="DynamicContrastOn" Grid.Column="4" Content="On" Style="{StaticResource OrangeBtn}" Padding="10,4" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Picture mode" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Button x:Name="PictureModeWeb" Grid.Column="2" Content="Web" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    <Button x:Name="PictureModeCinema" Grid.Column="4" Content="Cinema" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    <Button x:Name="PictureModeGame" Grid.Column="6" Content="Game" Style="{StaticResource AccBtn}" Padding="10,4" FontSize="12"/>
                </Grid></Border>
            </Grid></Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="MonitorTab" Header="Monitor" Tag="&#xE7F8;" ToolTip="Manage identity, inputs, power, and panel-specific controls.">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Style="{StaticResource PageCard}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="72"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="&#xE7F8;" FontFamily="Segoe MDL2 Assets" FontSize="42" Foreground="{DynamicResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <StackPanel Grid.Column="2"><TextBlock Text="Label" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="MonitorLabelBox"/><TextBlock x:Name="MonitorIdentityText" Text="Identity: unknown" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                    <StackPanel Grid.Column="4" Width="130"><Button x:Name="MonitorLabelSaveBtn" Content="Save" Style="{StaticResource AccBtn}"/><Button x:Name="MonitorLabelResetBtn" Content="Reset" Style="{StaticResource Btn}" Margin="0,8,0,0"/></StackPanel>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Border Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="Input source" Style="{StaticResource SectionTitle}" Margin="0,0,0,12"/><ComboBox x:Name="InputSourceCombo"/></StackPanel></Border>
                        <Border Grid.Row="2" Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="Power control" Style="{StaticResource SectionTitle}" Margin="0,0,0,12"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="PowerOffBtn" Content="Off" Style="{StaticResource WarnBtn}"/><Button x:Name="PowerStandbyBtn" Grid.Column="2" Content="Standby" Style="{StaticResource Btn}"/><Button x:Name="PowerOnBtn" Grid.Column="4" Content="On" Style="{StaticResource AccBtn}"/>
                        </Grid></StackPanel></Border>
                        <Border Grid.Row="4" Style="{StaticResource PageCardCompact}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Grid><TextBlock Text="Volume" Style="{StaticResource SectionTitle}"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><CheckBox x:Name="MuteCheckbox" Content="Mute" Margin="0,0,14,0"/><TextBlock x:Name="VolumeValue" Text="50" Style="{StaticResource MetricValue}"/></StackPanel></Grid>
                            <Slider x:Name="VolumeSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                        </Grid></Border>
                    </Grid>
                    <Grid Grid.Column="2"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <Border Style="{StaticResource PageCardCompact}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Grid><TextBlock Text="Sharpness" Style="{StaticResource SectionTitle}"/><TextBlock x:Name="SharpnessValue" Text="50" Style="{StaticResource MetricValue}" HorizontalAlignment="Right"/></Grid>
                            <Slider x:Name="SharpnessSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                        </Grid></Border>
                        <Border Grid.Row="2" Style="{StaticResource PageCardCompact}" BorderBrush="{DynamicResource DangerBrush}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <TextBlock Text="Maintenance" Style="{StaticResource SectionTitle}"/>
                            <Button x:Name="ResetColorBtn" Grid.Row="2" Content="Reset Colors" Style="{StaticResource Btn}"/>
                            <Button x:Name="FactoryResetBtn" Grid.Row="4" Content="Factory Reset" Style="{StaticResource WarnBtn}"/>
                            <Button x:Name="AllMonitorsStandbyBtn" Grid.Row="6" Content="All Monitors to Standby" Style="{StaticResource WarnBtn}"/>
                        </Grid></Border>
                    </Grid>
                </Grid>
                <Border Grid.Row="4" Style="{StaticResource PageCardCompact}"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Text="PiP / PbP" Style="{StaticResource SectionTitle}"/>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="24"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Mode" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <Grid Grid.Column="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Button x:Name="PipPbpOffBtn" Content="Off" Style="{StaticResource AccBtn}"/><Button x:Name="PipModeBtn" Grid.Column="2" Content="PiP" Style="{StaticResource Btn}"/><Button x:Name="PbpModeBtn" Grid.Column="4" Content="PbP" Style="{StaticResource Btn}"/></Grid>
                        <TextBlock Grid.Column="4" Text="Secondary Input" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <Grid Grid.Column="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Button x:Name="PipSecondaryDpBtn" Content="DP" Style="{StaticResource Btn}"/><Button x:Name="PipSecondaryHdmi1Btn" Grid.Column="2" Content="HDMI 1" Style="{StaticResource Btn}"/><Button x:Name="PipSecondaryHdmi2Btn" Grid.Column="4" Content="HDMI 2" Style="{StaticResource Btn}"/></Grid>
                    </Grid>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="GpuTab" Header="Hardware" Tag="&#xEA86;" ToolTip="Live graphics, thermal, and presentation telemetry.">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Style="{StaticResource PageCard}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="GPU" Style="{StaticResource SectionTitle}"/>
                        <TextBlock x:Name="GpuNameText" Text="GPU" FontSize="14" Foreground="{DynamicResource MutedTextBrush}" Margin="0,8,0,0"/>
                        <TextBlock x:Name="GpuStatsText" Text="-- C | -- MHz | -- W" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/></StackPanel>
                    <Border Grid.Column="1" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="12,0">
                        <Grid><TextBlock Text="GPU temperature" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><TextBlock x:Name="GpuTempText" Text="--" FontSize="24" FontWeight="Light"/><TextBlock Text=" C" Foreground="{DynamicResource MutedTextBrush}" Margin="2,5,0,0"/></StackPanel></Grid>
                    </Border>
                    <Border Grid.Column="2" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="16,12">
                        <TextBlock x:Name="CpuTempText" Text="CPU: -- C" FontSize="13" Foreground="{DynamicResource FocusBrush}" VerticalAlignment="Center"/>
                    </Border>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="GPU Utilization" Style="{StaticResource SectionTitle}"/><TextBlock x:Name="GpuUtilText" Text="0%" Style="{StaticResource MetricValue}" Margin="0,14,0,14"/><ProgressBar x:Name="GpuUtilBar" Value="0" Foreground="{DynamicResource SuccessBrush}"/></StackPanel></Border>
                    <Border Grid.Column="2" Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="Memory Usage" Style="{StaticResource SectionTitle}"/><TextBlock x:Name="MemUsageText" Text="0 / 0 GB" Style="{StaticResource MetricValue}" Margin="0,14,0,14"/><ProgressBar x:Name="MemUtilBar" Value="0" Foreground="{DynamicResource WarningBrush}"/></StackPanel></Border>
                    <Border Grid.Column="4" Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="Fan Speed" Style="{StaticResource SectionTitle}"/><TextBlock x:Name="FanSpeedText" Text="0%" Style="{StaticResource MetricValue}" Margin="0,14,0,14"/><ProgressBar x:Name="FanSpeedBar" Value="0" Foreground="{DynamicResource FocusBrush}"/></StackPanel></Border>
                    <Border Grid.Column="6" Style="{StaticResource PageCardCompact}"><StackPanel><TextBlock Text="Power Draw" Style="{StaticResource SectionTitle}"/><TextBlock x:Name="PowerDrawText" Text="0 / 0 W" Style="{StaticResource MetricValue}" Margin="0,14,0,14"/><ProgressBar x:Name="PowerDrawBar" Value="0" Foreground="{DynamicResource DangerBrush}"/></StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><StackPanel><TextBlock Text="Digital Vibrance" Style="{StaticResource SectionTitle}"/><TextBlock Text="Adjust color intensity for the active GPU." FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/></StackPanel><TextBlock x:Name="VibranceValue" Text="50" Style="{StaticResource MetricValue}" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VibranceSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><StackPanel><TextBlock Text="Software Gamma" Style="{StaticResource SectionTitle}"/><TextBlock Text="Tune the software gamma curve." FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/></StackPanel><TextBlock x:Name="GammaValue" Text="1.00" Style="{StaticResource MetricValue}" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GammaSlider" Grid.Row="2" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Style="{StaticResource PageCardCompact}"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="FPS Overlay" Style="{StaticResource SectionTitle}"/>
                        <TextBlock x:Name="FpsOverlayStatusText" Text="PresentMon idle" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/></StackPanel>
                    <Button x:Name="FpsOverlayStartBtn" Grid.Column="2" Content="Start" Style="{StaticResource AccBtn}" MinWidth="110"/>
                    <Button x:Name="FpsOverlayStopBtn" Grid.Column="4" Content="Stop" Style="{StaticResource Btn}" MinWidth="110"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="VcpTab" Header="VCP Explorer" Tag="&#xE943;" ToolTip="Inspect and safely test monitor control codes.">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="*"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <TextBlock Text="Query a code" Style="{StaticResource SectionTitle}"/>
                        <TextBlock Grid.Row="2" Text="VCP Code:" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="VCPCodeBox" Text="0x10" VerticalAlignment="Center"/>
                            <ComboBox x:Name="VCPPresetCombo" Grid.Column="2"/>
                            <Button x:Name="VCPQueryBtn" Grid.Column="4" Content="Query" Style="{StaticResource AccBtn}" MinWidth="110"/>
                        </Grid>
                    </Grid></Border>
                    <Border Grid.Column="2" Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <TextBlock Text="Write a value" Style="{StaticResource SectionTitle}"/>
                        <TextBlock x:Name="VCPSetValueLabel" Grid.Row="2" Text="Set value" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="VCPSetValueBox" Text="50" VerticalAlignment="Center"/>
                            <ComboBox x:Name="VCPSetValueCombo" Visibility="Collapsed" VerticalAlignment="Center" AutomationProperties.Name="Advertised VCP values"/>
                            <Grid x:Name="VCPSetValueRangePanel" Visibility="Collapsed"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="54"/></Grid.ColumnDefinitions>
                                <Slider x:Name="VCPSetValueSlider" Minimum="0" Maximum="100" Value="50" TickFrequency="1" IsSnapToTickEnabled="True" AutomationProperties.Name="VCP value"/>
                                <TextBlock x:Name="VCPSetValueSliderText" Grid.Column="2" Text="50" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </Grid>
                            <Button x:Name="VCPSetBtn" Grid.Column="2" Content="Set" Style="{StaticResource OrangeBtn}" MinWidth="110"/>
                        </Grid>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="2" Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="VCP response" Style="{StaticResource SectionTitle}"/>
                    <TextBox x:Name="VCPResultBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="13" AcceptsReturn="True" MinHeight="230"/>
                </Grid></Border>
                <Border Grid.Row="4" Style="{StaticResource PageCardCompact}"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Capability scan" Style="{StaticResource SectionTitle}"/><TextBlock Text="Scan supported VCP codes and reported monitor capabilities." FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0"/></StackPanel>
                    <CheckBox x:Name="VCPScanCapabilitiesOnlyCheckbox" Grid.Column="2" Content="Caps only" IsChecked="True" VerticalAlignment="Center"/>
                    <Button x:Name="VCPScanBtn" Grid.Column="4" Content="Scan All" Style="{StaticResource AccBtn}" MinWidth="120"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="ProfilesTab" Header="Profiles" Tag="&#xE8B7;" ToolTip="Save, organize, and apply complete display configurations.">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="5*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="7*"/></Grid.ColumnDefinitions>
                    <Border Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="*"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <TextBlock Text="Saved profiles" Style="{StaticResource SectionTitle}"/>
                        <TextBlock x:Name="ProfileTrashStatusText" Grid.Row="2" Text="Trash empty" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <ListBox x:Name="ProfilesList" Grid.Row="4" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" Foreground="{DynamicResource TextBrush}" MinHeight="180"/>
                        <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="LoadProfileBtn" Content="Load" Style="{StaticResource AccBtn}"/>
                            <Button x:Name="DeleteProfileBtn" Grid.Column="2" Content="Delete" Style="{StaticResource WarnBtn}"/>
                        </Grid>
                        <Grid Grid.Row="8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="RestoreProfileBtn" Content="Restore Last" Style="{StaticResource Btn}" AutomationProperties.HelpText="Restore the most recently deleted profile and its dependent automation."/>
                            <Button x:Name="PurgeProfileTrashBtn" Grid.Column="2" Content="Empty Trash" Style="{StaticResource WarnBtn}" AutomationProperties.HelpText="Permanently delete all recoverable profile records after confirmation."/>
                        </Grid>
                    </Grid></Border>
                    <Border Grid.Column="2" Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="*"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <TextBlock Text="Profile details" Style="{StaticResource SectionTitle}"/>
                        <TextBlock Grid.Row="2" Text="Profile name" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <TextBox x:Name="ProfileNameBox" Grid.Row="4" Text="My Profile"/>
                        <Border Grid.Row="6" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="16">
                            <StackPanel><TextBlock Text="Current display configuration" FontSize="13" FontWeight="SemiBold"/><TextBlock Text="Brightness, contrast, color, input, and supported panel settings will be captured for the selected display." TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,8,0,0"/></StackPanel>
                        </Border>
                        <Button x:Name="SaveProfileBtn" Grid.Row="8" Content="Save" Style="{StaticResource AccBtn}" HorizontalAlignment="Right" MinWidth="130"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="2" Style="{StaticResource PageCardCompact}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Button x:Name="ExportProfilesBtn" Content="Export Bundle" Style="{StaticResource Btn}" MinWidth="130"/>
                    <Button x:Name="ImportProfilesBtn" Grid.Column="2" Content="Import Bundle" Style="{StaticResource Btn}" MinWidth="130"/>
                    <StackPanel Grid.Column="4" VerticalAlignment="Center"><TextBlock Text="Profile Storage" Style="{StaticResource SectionTitle}"/>
                        <TextBlock x:Name="ProfileStorageStatusText" Text="Local" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                    <Button x:Name="ProfileSyncFolderBtn" Grid.Column="6" Content="Sync Folder" Style="{StaticResource Btn}"/>
                    <Button x:Name="ProfileLocalFolderBtn" Grid.Column="8" Content="Use Local" Style="{StaticResource Btn}"/>
                </Grid></Border>
                <Border Grid.Row="4" Style="{StaticResource PageCardCompact}"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AppProfileEnabledCheckbox" Content="Per-application profiles" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AppProfileStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AppProfileExeBox" Text="app.exe"/>
                        <Button x:Name="AppProfileCaptureBtn" Grid.Column="2" Content="Capture" Style="{StaticResource Btn}"/>
                        <ComboBox x:Name="AppProfileProfileCombo" Grid.Column="4"/>
                        <CheckBox x:Name="AppProfileRiskyConsentCheckbox" Grid.Column="6" Content="Risky writes" VerticalAlignment="Center" FontSize="12" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                        <Button x:Name="AppProfileAddBtn" Grid.Column="8" Content="Add" Style="{StaticResource AccBtn}"/>
                        <Button x:Name="AppProfileRemoveBtn" Grid.Column="10" Content="Remove" Style="{StaticResource WarnBtn}"/>
                    </Grid>
                    <ListBox x:Name="AppProfileRulesList" Grid.Row="4" Height="72" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" Foreground="{DynamicResource TextBrush}" FontSize="12"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="ScheduleTab" Header="Automation" Tag="&#xE823;" ToolTip="Adapt display behavior to time, activity, and power.">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Style="{StaticResource PageCard}"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid><TextBlock Text="Scheduled profiles" Style="{StaticResource SectionTitle}"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><CheckBox x:Name="ScheduleEnabledCheckbox" Content="Enabled" VerticalAlignment="Center"/><TextBlock x:Name="ScheduleStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="12,0,0,0" VerticalAlignment="Center"/></StackPanel></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="16"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel><TextBlock Text="Time" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="ScheduleTimeBox" Text="21:00"/></StackPanel>
                        <StackPanel Grid.Column="2"><TextBlock Text="Profile" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><ComboBox x:Name="ScheduleProfileCombo"/></StackPanel>
                        <CheckBox x:Name="ScheduleRiskyConsentCheckbox" Grid.Column="4" Content="Risky writes" VerticalAlignment="Bottom" Margin="0,0,0,8" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                        <Button x:Name="ScheduleAddBtn" Grid.Column="6" Content="Add" Style="{StaticResource AccBtn}" VerticalAlignment="Bottom"/>
                        <Button x:Name="ScheduleRemoveBtn" Grid.Column="8" Content="Remove" Style="{StaticResource WarnBtn}" VerticalAlignment="Bottom"/>
                    </Grid>
                    <TextBlock Grid.Row="4" Text="Profile schedule" Style="{StaticResource SectionTitle}"/>
                    <Border Grid.Row="6" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="10">
                        <Grid><Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="10"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <Canvas x:Name="ScheduleTimelineCanvas" ClipToBounds="True"/>
                            <ListBox x:Name="ScheduleRulesList" Grid.Row="2" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource TextBrush}" FontSize="12" MinHeight="80"/>
                        </Grid>
                    </Border>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><CheckBox x:Name="IdleDimEnabledCheckbox" Content="Idle dim" VerticalAlignment="Center" FontWeight="SemiBold"/><TextBlock x:Name="IdleDimStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                        <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <StackPanel><TextBlock Text="After (min)" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="IdleDimMinutesBox" Text="10"/></StackPanel>
                            <StackPanel Grid.Column="2"><TextBlock Text="Dim to (%)" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="IdleDimBrightnessBox" Text="20"/></StackPanel>
                        </Grid>
                        <CheckBox x:Name="IdleDimRestoreCheckbox" Grid.Row="4" Content="Restore brightness after activity" VerticalAlignment="Center"/>
                        <Button x:Name="IdleDimSaveBtn" Grid.Row="6" Content="Save" Style="{StaticResource AccBtn}" HorizontalAlignment="Right" MinWidth="120"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Style="{StaticResource PageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="26"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><CheckBox x:Name="BatteryProfileEnabledCheckbox" Content="Battery profile" VerticalAlignment="Center" FontWeight="SemiBold"/><TextBlock x:Name="BatteryProfileStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                        <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <StackPanel><TextBlock Text="Battery (%)" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="BatteryBrightnessBox" Text="35"/></StackPanel>
                            <StackPanel Grid.Column="2"><TextBlock Text="AC (%)" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,6"/><TextBox x:Name="AcBrightnessBox" Text="75"/></StackPanel>
                        </Grid>
                        <Button x:Name="BatteryProfileSaveBtn" Grid.Row="4" Content="Save" Style="{StaticResource AccBtn}" HorizontalAlignment="Right" MinWidth="120"/>
                    </Grid></Border>
                </Grid>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="SystemTab" Header="System" Tag="&#xE713;" ToolTip="Configure safety, diagnostics, integrations, and recovery.">
            <TabControl x:Name="SystemCategoryTabs" Style="{StaticResource SettingsTabControl}">
                <TabItem x:Name="SystemOverviewCategory" Header="Overview" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Overview system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
                            <Border Style="{StaticResource PageCard}">
                                <StackPanel>
                                    <TextBlock Text="Windows control centers" Style="{StaticResource SectionTitle}"/>
                                    <TextBlock Text="Open a native Windows panel without leaving MonitorControl." Foreground="{DynamicResource MutedTextBrush}" Margin="0,5,0,16"/>
                                    <UniformGrid Columns="3">
                                        <Button x:Name="DisplaySettingsBtn" Content="Display settings" Style="{StaticResource Btn}" Margin="0,0,6,0"/>
                                        <Button x:Name="ColorMgmtBtn" Content="Color management" Style="{StaticResource Btn}" Margin="3,0"/>
                                        <Button x:Name="GpuControlPanelBtn" Content="GPU control panel" Style="{StaticResource Btn}" Margin="6,0,0,0"/>
                                    </UniformGrid>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Style="{StaticResource PageCard}">
                                <StackPanel>
                                    <TextBlock Text="System workspace" Style="{StaticResource SectionTitle}"/>
                                    <TextBlock Text="Display &amp; DDC" Foreground="{DynamicResource FocusBrush}" FontWeight="SemiBold" Margin="0,14,0,2"/>
                                    <TextBlock Text="Gamma, capabilities, timing, and brightness restore" Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap"/>
                                    <TextBlock Text="Safety &amp; automation" Foreground="{DynamicResource FocusBrush}" FontWeight="SemiBold" Margin="0,14,0,2"/>
                                    <TextBlock Text="Risky writes and the local API bridge" Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap"/>
                                    <TextBlock Text="Diagnostics &amp; integrations" Foreground="{DynamicResource FocusBrush}" FontWeight="SemiBold" Margin="0,14,0,2"/>
                                    <TextBlock Text="Compatibility reports and optional helpers" Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </TabItem>
                <TabItem x:Name="SystemDisplayDdcCategory" Header="Display &amp; DDC" IsSelected="True" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Display and DDC system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Border Style="{StaticResource PageCard}">
                                    <Grid>
                                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                        <Grid>
                                            <StackPanel><TextBlock Text="Software gamma" Style="{StaticResource SectionTitle}"/><TextBlock Text="Independent red, green, and blue gain" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel>
                                            <Button x:Name="ResetGammaBtn" Content="Reset" Style="{StaticResource Btn}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                        </Grid>
                                        <Grid Grid.Row="2">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <StackPanel><TextBlock Text="Red" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="GammaRedValue" Text="1.00" FontSize="17" Foreground="{DynamicResource DangerBrush}" HorizontalAlignment="Right"/><Slider x:Name="GammaRedSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource DangerBrush}" Style="{StaticResource Sld}"/></StackPanel>
                                            <StackPanel Grid.Column="2"><TextBlock Text="Green" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="GammaGreenValue" Text="1.00" FontSize="17" Foreground="{DynamicResource SuccessBrush}" HorizontalAlignment="Right"/><Slider x:Name="GammaGreenSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource SuccessBrush}" Style="{StaticResource Sld}"/></StackPanel>
                                            <StackPanel Grid.Column="4"><TextBlock Text="Blue" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="GammaBlueValue" Text="1.00" FontSize="17" Foreground="{DynamicResource FocusBrush}" HorizontalAlignment="Right"/><Slider x:Name="GammaBlueSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/></StackPanel>
                                        </Grid>
                                    </Grid>
                                </Border>
                                <Border Grid.Column="2" Style="{StaticResource PageCard}">
                                    <StackPanel>
                                        <TextBlock Text="Monitor capabilities" Style="{StaticResource SectionTitle}"/>
                                        <TextBlock Text="Raw MCCS capability data reported by the selected display" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,12"/>
                                        <TextBox x:Name="CapabilitiesBox" IsReadOnly="True" TextWrapping="Wrap" Height="116" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12"/>
                                    </StackPanel>
                                </Border>
                            </Grid>
                            <Border Grid.Row="2" Style="{StaticResource PageCard}">
                                <Grid>
                                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                    <Grid>
                                        <StackPanel><TextBlock Text="Capability discovery" Style="{StaticResource SectionTitle}"/><TextBlock Text="Control how MonitorControl probes display firmware." Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel>
                                        <TextBlock x:Name="CapabilitiesSafetyStatusText" Text="Discovery off" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                    </Grid>
                                    <StackPanel Grid.Row="2">
                                        <CheckBox x:Name="CapabilitiesDiscoveryEnabledCheckbox" Content="Allow capability discovery"/>
                                        <CheckBox x:Name="CapabilitiesMaximumCompatibilityCheckbox" Content="Maximum compatibility (never request capability strings)" Foreground="{DynamicResource MutedTextBrush}" Margin="0,9,0,0"/>
                                    </StackPanel>
                                    <Grid Grid.Row="4">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="A pending probe is recorded before every firmware call." Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,16,0"/>
                                        <WrapPanel Grid.Column="1" HorizontalAlignment="Right">
                                            <Button x:Name="CapabilitiesExcludeCurrentBtn" Content="Exclude selected" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                                            <Button x:Name="CapabilitiesClearExclusionsBtn" Content="Clear exclusions" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                                            <Button x:Name="CapabilitiesClearCacheBtn" Content="Clear cache" Style="{StaticResource Btn}"/>
                                        </WrapPanel>
                                    </Grid>
                                </Grid>
                            </Border>
                            <Grid Grid.Row="4">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
                                <Border Style="{StaticResource PageCard}">
                                    <Grid>
                                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                        <Grid>
                                            <StackPanel><TextBlock Text="DDC timing" Style="{StaticResource SectionTitle}"/><TextBlock Text="Per-monitor retry and calibration strategy" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel>
                                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                                <RadioButton x:Name="DdcTimingAdaptiveRadio" GroupName="DdcTimingMode" Content="Adaptive" IsChecked="True"/>
                                                <RadioButton x:Name="DdcTimingManualRadio" GroupName="DdcTimingMode" Content="Manual" Margin="16,0,0,0"/>
                                            </StackPanel>
                                        </Grid>
                                        <Grid Grid.Row="2">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <StackPanel><TextBlock Text="Read retries" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="DdcTimingReadRetriesBox" Margin="0,5,0,0"/></StackPanel>
                                            <StackPanel Grid.Column="2"><TextBlock Text="Write retries" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="DdcTimingWriteRetriesBox" Margin="0,5,0,0"/></StackPanel>
                                            <StackPanel Grid.Column="4"><TextBlock Text="Capability retries" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="DdcTimingCapabilityRetriesBox" Margin="0,5,0,0"/></StackPanel>
                                        </Grid>
                                        <Grid Grid.Row="4">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Text="Readback verification" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                                            <ComboBox x:Name="DdcVerifyPolicyCombo" Grid.Column="2" SelectedValuePath="Tag" AutomationProperties.Name="DDC readback verification policy">
                                                <ComboBoxItem Content="Strict - one mismatch fails" Tag="Strict"/>
                                                <ComboBoxItem Content="Lenient - re-read before failure" Tag="Lenient"/>
                                                <ComboBoxItem Content="Off - trust successful writes" Tag="Off"/>
                                            </ComboBox>
                                        </Grid>
                                        <StackPanel Grid.Row="6" Orientation="Horizontal">
                                            <Button x:Name="DdcTimingResetBtn" Content="Reset calibration" Style="{StaticResource Btn}"/>
                                            <Button x:Name="DdcValuesRereadBtn" Content="Re-read values" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
                                        </StackPanel>
                                        <TextBlock x:Name="DdcTimingEffectiveText" Grid.Row="8" Text="" TextWrapping="Wrap" Foreground="{DynamicResource TextBrush}"/>
                                        <TextBlock x:Name="DdcTimingWarningText" Grid.Row="10" Text="" TextWrapping="Wrap" Foreground="{DynamicResource WarningBrush}"/>
                                    </Grid>
                                </Border>
                                <Border Grid.Column="2" Style="{StaticResource PageCard}">
                                    <StackPanel>
                                        <Grid>
                                            <TextBlock Text="Brightness restore" Style="{StaticResource SectionTitle}"/>
                                            <TextBlock x:Name="DisplayRestoreStatusText" Text="Off" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                        </Grid>
                                        <CheckBox x:Name="DisplayRestoreEnabledCheckbox" Content="Restore brightness at launch and after resume" Margin="0,16,0,12"/>
                                        <TextBlock Text="Writes the last brightness back once per detected display change after a power or sleep cycle, using the verified DDC path." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </Grid>
                    </ScrollViewer>
                </TabItem>
                <TabItem x:Name="SystemSafetyCategory" Header="Safety" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Safety system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
                            <Border Style="{StaticResource PageCard}" BorderBrush="{DynamicResource WarningBrush}">
                                <StackPanel>
                                    <Grid><StackPanel><TextBlock Text="Risky VCP writes" Style="{StaticResource SectionTitle}"/><TextBlock Text="Per-display firmware write protection" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel><TextBlock x:Name="RiskyVcpStatusText" Text="Disabled" Foreground="{DynamicResource WarningBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                                    <CheckBox x:Name="RiskyVcpEnabledCheckbox" Content="Enable risky VCP writes for selected display" Margin="0,18,0,12"/>
                                    <TextBlock Text="Power, input, reset, PiP/PbP, and arbitrary writes require this per-identity unlock plus confirmation for every direct command." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Style="{StaticResource PageCard}">
                                <StackPanel><TextBlock Text="Guardrails" Style="{StaticResource SectionTitle}"/><TextBlock Text="Unlocks stay scoped to the stable identity of the selected display. Each direct command still asks for explicit confirmation and uses the verified write path." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}" Margin="0,12,0,0"/></StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                </TabItem>
                <TabItem x:Name="SystemAutomationCategory" Header="Automation" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Automation system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel>
                        <Border Style="{StaticResource PageCard}">
                            <Grid>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="18"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <Grid><StackPanel><TextBlock Text="Local automation bridge" Style="{StaticResource SectionTitle}"/><TextBlock Text="Expose MonitorControl to trusted local tools through an authenticated loopback endpoint." Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel><TextBlock x:Name="AutomationBridgeStatusText" Text="Off" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                                <CheckBox x:Name="AutomationBridgeEnabledCheckbox" Grid.Row="2" Content="Enable local Automation Bridge"/>
                                <Grid Grid.Row="4">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="3*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <StackPanel><TextBlock Text="Bind address" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="AutomationBridgeBindBox" Text="127.0.0.1" Margin="0,5,0,0"/></StackPanel>
                                    <StackPanel Grid.Column="2"><TextBlock Text="Port" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="AutomationBridgePortBox" Text="34291" Margin="0,5,0,0"/></StackPanel>
                                    <StackPanel Grid.Column="4"><TextBlock Text="API key" Foreground="{DynamicResource MutedTextBrush}"/><PasswordBox x:Name="AutomationBridgeKeyBox" Password="" Margin="0,5,0,0"/></StackPanel>
                                    <Button x:Name="AutomationBridgeSaveBtn" Grid.Column="6" Content="Save bridge" Style="{StaticResource GreenBtn}" VerticalAlignment="Bottom"/>
                                </Grid>
                            </Grid>
                        </Border>
                        <Border Style="{StaticResource PageCard}" Margin="0,14,0,0">
                            <Grid>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <Grid><StackPanel><TextBlock Text="Run at login" Style="{StaticResource SectionTitle}"/><TextBlock Text="Start MonitorControl directly in the notification area after you sign in." Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel><TextBlock x:Name="RunAtLoginStatusText" Text="Off" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                                <CheckBox x:Name="RunAtLoginEnabledCheckbox" Grid.Row="2" Content="Run MonitorControl at login" AutomationProperties.Name="Run MonitorControl at login"/>
                            </Grid>
                        </Border>
                        </StackPanel>
                    </ScrollViewer>
                </TabItem>
                <TabItem x:Name="SystemDiagnosticsCategory" Header="Diagnostics" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Diagnostics system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <Border Style="{StaticResource PageCard}">
                            <Grid>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <Grid>
                                    <StackPanel><TextBlock Text="DDC support bundle" Style="{StaticResource SectionTitle}"/><TextBlock Text="The preview below is the exact human-readable report saved with a structured JSON copy." Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center"><Button x:Name="DdcReportGenerateBtn" Content="Build report" Style="{StaticResource GreenBtn}" AutomationProperties.Name="Build DDC compatibility report"/><Button x:Name="DdcReportCopyBtn" Content="Copy report" Style="{StaticResource Btn}" Margin="8,0,0,0"/></StackPanel>
                                </Grid>
                                <StackPanel Grid.Row="2">
                                    <TextBlock Text="Identifiers and local names are pseudonymized by default. Addresses and credential-like values are always redacted." Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap"/>
                                    <WrapPanel Margin="0,7,0,0">
                                        <CheckBox x:Name="DdcReportIncludeIdentifiersCheckbox" Content="Include raw monitor identifiers" Margin="0,0,18,0" AutomationProperties.HelpText="Includes monitor serials, hardware IDs, stable identities, and device paths in this bundle only."/>
                                        <CheckBox x:Name="DdcReportIncludeNamesCheckbox" Content="Include raw monitor names" AutomationProperties.HelpText="Includes friendly, custom, and EDID monitor names in this bundle only."/>
                                    </WrapPanel>
                                </StackPanel>
                                <TextBox x:Name="DdcReportBox" Grid.Row="4" IsReadOnly="True" TextWrapping="Wrap" Height="360" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"/>
                            </Grid>
                        </Border>
                    </ScrollViewer>
                </TabItem>
                <TabItem x:Name="SystemIntegrationsCategory" Header="Integrations" Style="{StaticResource SettingsTabItem}" AutomationProperties.Name="Integrations system settings">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <Border Style="{StaticResource PageCard}" BorderBrush="{DynamicResource WarningBrush}">
                            <Grid>
                                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                                <StackPanel><TextBlock Text="Optional hardware helpers" Style="{StaticResource SectionTitle}"/><TextBlock Text="Explicitly opt into local libraries and executables used for extra telemetry." Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/></StackPanel>
                                <CheckBox x:Name="CpuMonitorEnabledCheckbox" Grid.Row="2" Content="Load CPU temperature library (LibreHardwareMonitorLib / OpenHardwareMonitorLib)"/>
                                <CheckBox x:Name="PresentMonEnabledCheckbox" Grid.Row="4" Content="Run PresentMon for the FPS overlay"/>
                                <StackPanel Grid.Row="6">
                                    <TextBlock Text="Every resolved binary is reported with its version and SHA-256. Helpers remain disabled until enabled here." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}" Margin="0,0,0,10"/>
                                    <TextBox x:Name="OptionalHelperStatusBox" IsReadOnly="True" TextWrapping="NoWrap" Height="300" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                    </ScrollViewer>
                </TabItem>
            </TabControl>
        </TabItem>
    </TabControl>
    <Border Grid.Row="3" Grid.ColumnSpan="2" Background="{DynamicResource FooterBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,0,0" Padding="18,0"><Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="7" Height="7" Fill="{DynamicResource SuccessBrush}" Margin="0,0,8,0"/>
            <TextBlock x:Name="StatusText" Text="Ready" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"
                       AutomationProperties.Name="Status: Ready" AutomationProperties.LiveSetting="Polite"/>
        </StackPanel>
        <StackPanel x:Name="TransactionProgressPanel" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed" AutomationProperties.Name="Verified DDC transaction progress">
            <TextBlock x:Name="TransactionProgressText" Text="Apply 0/0" FontSize="12" Foreground="{DynamicResource TextBrush}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <ProgressBar x:Name="TransactionProgressBar" Width="180" Height="6" Minimum="0" Maximum="1" Value="0" Margin="0,0,10,0"/>
            <Button x:Name="TransactionCancelBtn" Content="Cancel" Style="{StaticResource Btn}" Padding="10,4" AutomationProperties.Name="Cancel verified DDC transaction"/>
        </StackPanel>
        <TextBlock x:Name="AutoModeText" Grid.Column="2" Text="" FontSize="12" Foreground="{DynamicResource WarningBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid></Border>
</Grid>
</ScrollViewer>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$isolatedDisplayLeft = 0
$isolatedDisplayTop = 0
if ([int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_X, [ref]$isolatedDisplayLeft) -and
    [int]::TryParse([string]$env:MONITORCONTROL_ISOLATED_Y, [ref]$isolatedDisplayTop)) {
    $window.WindowStartupLocation = "Manual"
    $window.Left = $isolatedDisplayLeft + 20
    $window.Top = $isolatedDisplayTop + 20
}

try {
    $brandingIconPath = Join-Path $script:MonitorControlRoot 'icon.ico'
    if (Test-Path $brandingIconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($brandingIconPath)))
    }
} catch {}
# Get all UI elements
$shellScrollViewer = $window.FindName("ShellScrollViewer"); $shellRoot = $window.FindName("ShellRoot"); $mainNavigationTabs = $window.FindName("MainNavigationTabs")
$statusBannerBorder = $window.FindName("StatusBannerBorder"); $statusBannerText = $window.FindName("StatusBannerText"); $statusBannerDismissButton = $window.FindName("StatusBannerDismissButton")
$appTitleText = $window.FindName("AppTitleText"); $appSubtitleText = $window.FindName("AppSubtitleText")
$displayTab = $window.FindName("DisplayTab"); $monitorTab = $window.FindName("MonitorTab"); $vcpTab = $window.FindName("VcpTab")
$profilesTab = $window.FindName("ProfilesTab"); $scheduleTab = $window.FindName("ScheduleTab"); $systemTab = $window.FindName("SystemTab")
$monitorCanvas = $window.FindName("MonitorCanvas"); $selectedMonitorName = $window.FindName("SelectedMonitorName")
$selectedMonitorRes = $window.FindName("SelectedMonitorRes"); $selectedMonitorInfo = $window.FindName("SelectedMonitorInfo")
$selectedMonitorHealthDot = $window.FindName("SelectedMonitorHealthDot"); $selectedMonitorHealthText = $window.FindName("SelectedMonitorHealthText")
$monitorLabelBox = $window.FindName("MonitorLabelBox"); $monitorLabelSaveBtn = $window.FindName("MonitorLabelSaveBtn"); $monitorLabelResetBtn = $window.FindName("MonitorLabelResetBtn")
$monitorIdentityText = $window.FindName("MonitorIdentityText")
$applyAllCheckbox = $window.FindName("ApplyAllCheckbox"); $refreshBtn = $window.FindName("RefreshBtn"); $identifyBtn = $window.FindName("IdentifyBtn")
$brightnessSlider = $window.FindName("BrightnessSlider"); $brightnessValue = $window.FindName("BrightnessValue")
$contrastSlider = $window.FindName("ContrastSlider"); $contrastValue = $window.FindName("ContrastValue")
$redSlider = $window.FindName("RedSlider"); $redValue = $window.FindName("RedValue")
$greenSlider = $window.FindName("GreenSlider"); $greenValue = $window.FindName("GreenValue")
$blueSlider = $window.FindName("BlueSlider"); $blueValue = $window.FindName("BlueValue")
$colorTempWarm = $window.FindName("ColorTempWarm"); $colorTemp6500 = $window.FindName("ColorTemp6500")
$colorTempCool = $window.FindName("ColorTempCool"); $colorTempSRGB = $window.FindName("ColorTempSRGB")
$presetDay = $window.FindName("PresetDay"); $presetNight = $window.FindName("PresetNight")
$presetAutoMode = $window.FindName("PresetAutoMode"); $presetAmbientMode = $window.FindName("PresetAmbientMode"); $presetReset = $window.FindName("PresetReset")
$dynamicContrastOff = $window.FindName("DynamicContrastOff"); $dynamicContrastOn = $window.FindName("DynamicContrastOn")
$pictureModeWeb = $window.FindName("PictureModeWeb"); $pictureModeCinema = $window.FindName("PictureModeCinema"); $pictureModeGame = $window.FindName("PictureModeGame")
$inputSourceCombo = $window.FindName("InputSourceCombo")
$powerOffBtn = $window.FindName("PowerOffBtn"); $powerStandbyBtn = $window.FindName("PowerStandbyBtn"); $powerOnBtn = $window.FindName("PowerOnBtn")
$pipPbpOffBtn = $window.FindName("PipPbpOffBtn"); $pipModeBtn = $window.FindName("PipModeBtn"); $pbpModeBtn = $window.FindName("PbpModeBtn")
$pipSecondaryDpBtn = $window.FindName("PipSecondaryDpBtn"); $pipSecondaryHdmi1Btn = $window.FindName("PipSecondaryHdmi1Btn"); $pipSecondaryHdmi2Btn = $window.FindName("PipSecondaryHdmi2Btn")
$volumeSlider = $window.FindName("VolumeSlider"); $volumeValue = $window.FindName("VolumeValue"); $muteCheckbox = $window.FindName("MuteCheckbox")
$sharpnessSlider = $window.FindName("SharpnessSlider"); $sharpnessValue = $window.FindName("SharpnessValue")
$resetColorBtn = $window.FindName("ResetColorBtn"); $factoryResetBtn = $window.FindName("FactoryResetBtn")
$allMonitorsStandbyBtn = $window.FindName("AllMonitorsStandbyBtn")
$gpuTab = $window.FindName("GpuTab"); $gpuNameText = $window.FindName("GpuNameText"); $gpuStatsText = $window.FindName("GpuStatsText")
$gpuTempText = $window.FindName("GpuTempText"); $gpuUtilText = $window.FindName("GpuUtilText"); $gpuUtilBar = $window.FindName("GpuUtilBar")
$cpuTempText = $window.FindName("CpuTempText")
$memUsageText = $window.FindName("MemUsageText"); $memUtilBar = $window.FindName("MemUtilBar")
$fanSpeedText = $window.FindName("FanSpeedText"); $fanSpeedBar = $window.FindName("FanSpeedBar")
$powerDrawText = $window.FindName("PowerDrawText"); $powerDrawBar = $window.FindName("PowerDrawBar")
$vibranceSlider = $window.FindName("VibranceSlider"); $vibranceValue = $window.FindName("VibranceValue")
$fpsOverlayStatusText = $window.FindName("FpsOverlayStatusText"); $fpsOverlayStartBtn = $window.FindName("FpsOverlayStartBtn"); $fpsOverlayStopBtn = $window.FindName("FpsOverlayStopBtn")
$gammaSlider = $window.FindName("GammaSlider"); $gammaValue = $window.FindName("GammaValue")
$vcpCodeBox = $window.FindName("VCPCodeBox"); $vcpPresetCombo = $window.FindName("VCPPresetCombo"); $vcpQueryBtn = $window.FindName("VCPQueryBtn")
$vcpResultBox = $window.FindName("VCPResultBox"); $vcpSetValueLabel = $window.FindName("VCPSetValueLabel"); $vcpSetValueBox = $window.FindName("VCPSetValueBox")
$vcpSetValueCombo = $window.FindName("VCPSetValueCombo"); $vcpSetValueRangePanel = $window.FindName("VCPSetValueRangePanel")
$vcpSetValueSlider = $window.FindName("VCPSetValueSlider"); $vcpSetValueSliderText = $window.FindName("VCPSetValueSliderText")
$vcpSetBtn = $window.FindName("VCPSetBtn"); $vcpScanBtn = $window.FindName("VCPScanBtn")
$vcpScanCapabilitiesOnlyCheckbox = $window.FindName("VCPScanCapabilitiesOnlyCheckbox")
$profileNameBox = $window.FindName("ProfileNameBox"); $profilesList = $window.FindName("ProfilesList")
$saveProfileBtn = $window.FindName("SaveProfileBtn"); $loadProfileBtn = $window.FindName("LoadProfileBtn"); $deleteProfileBtn = $window.FindName("DeleteProfileBtn")
$restoreProfileBtn = $window.FindName("RestoreProfileBtn"); $purgeProfileTrashBtn = $window.FindName("PurgeProfileTrashBtn"); $profileTrashStatusText = $window.FindName("ProfileTrashStatusText")
$exportProfilesBtn = $window.FindName("ExportProfilesBtn"); $importProfilesBtn = $window.FindName("ImportProfilesBtn")
$profileStorageStatusText = $window.FindName("ProfileStorageStatusText"); $profileSyncFolderBtn = $window.FindName("ProfileSyncFolderBtn"); $profileLocalFolderBtn = $window.FindName("ProfileLocalFolderBtn")
$appProfileEnabledCheckbox = $window.FindName("AppProfileEnabledCheckbox"); $appProfileStatusText = $window.FindName("AppProfileStatusText")
$appProfileExeBox = $window.FindName("AppProfileExeBox"); $appProfileCaptureBtn = $window.FindName("AppProfileCaptureBtn")
$appProfileProfileCombo = $window.FindName("AppProfileProfileCombo"); $appProfileAddBtn = $window.FindName("AppProfileAddBtn")
$appProfileRemoveBtn = $window.FindName("AppProfileRemoveBtn"); $appProfileRulesList = $window.FindName("AppProfileRulesList"); $appProfileRiskyConsentCheckbox = $window.FindName("AppProfileRiskyConsentCheckbox")
$scheduleEnabledCheckbox = $window.FindName("ScheduleEnabledCheckbox"); $scheduleStatusText = $window.FindName("ScheduleStatusText")
$scheduleTimeBox = $window.FindName("ScheduleTimeBox"); $scheduleProfileCombo = $window.FindName("ScheduleProfileCombo")
$scheduleAddBtn = $window.FindName("ScheduleAddBtn"); $scheduleRemoveBtn = $window.FindName("ScheduleRemoveBtn"); $scheduleRulesList = $window.FindName("ScheduleRulesList"); $scheduleRiskyConsentCheckbox = $window.FindName("ScheduleRiskyConsentCheckbox")
$scheduleTimelineCanvas = $window.FindName("ScheduleTimelineCanvas")
$idleDimEnabledCheckbox = $window.FindName("IdleDimEnabledCheckbox"); $idleDimStatusText = $window.FindName("IdleDimStatusText")
$idleDimMinutesBox = $window.FindName("IdleDimMinutesBox"); $idleDimBrightnessBox = $window.FindName("IdleDimBrightnessBox")
$idleDimRestoreCheckbox = $window.FindName("IdleDimRestoreCheckbox"); $idleDimSaveBtn = $window.FindName("IdleDimSaveBtn")
$batteryProfileEnabledCheckbox = $window.FindName("BatteryProfileEnabledCheckbox"); $batteryProfileStatusText = $window.FindName("BatteryProfileStatusText")
$batteryBrightnessBox = $window.FindName("BatteryBrightnessBox"); $acBrightnessBox = $window.FindName("AcBrightnessBox"); $batteryProfileSaveBtn = $window.FindName("BatteryProfileSaveBtn")
$displaySettingsBtn = $window.FindName("DisplaySettingsBtn"); $colorMgmtBtn = $window.FindName("ColorMgmtBtn"); $gpuControlPanelBtn = $window.FindName("GpuControlPanelBtn")
$resetGammaBtn = $window.FindName("ResetGammaBtn")
$gammaRedSlider = $window.FindName("GammaRedSlider"); $gammaRedValue = $window.FindName("GammaRedValue")
$gammaGreenSlider = $window.FindName("GammaGreenSlider"); $gammaGreenValue = $window.FindName("GammaGreenValue")
$gammaBlueSlider = $window.FindName("GammaBlueSlider"); $gammaBlueValue = $window.FindName("GammaBlueValue")
$capabilitiesBox = $window.FindName("CapabilitiesBox"); $ddcReportBox = $window.FindName("DdcReportBox")
$ddcTimingAdaptiveRadio = $window.FindName("DdcTimingAdaptiveRadio"); $ddcTimingManualRadio = $window.FindName("DdcTimingManualRadio")
$ddcTimingResetBtn = $window.FindName("DdcTimingResetBtn"); $ddcValuesRereadBtn = $window.FindName("DdcValuesRereadBtn"); $ddcTimingEffectiveText = $window.FindName("DdcTimingEffectiveText")
$ddcTimingWarningText = $window.FindName("DdcTimingWarningText")
$ddcTimingReadRetriesBox = $window.FindName("DdcTimingReadRetriesBox"); $ddcTimingWriteRetriesBox = $window.FindName("DdcTimingWriteRetriesBox")
$ddcTimingCapabilityRetriesBox = $window.FindName("DdcTimingCapabilityRetriesBox"); $ddcVerifyPolicyCombo = $window.FindName("DdcVerifyPolicyCombo")
$displayRestoreEnabledCheckbox = $window.FindName("DisplayRestoreEnabledCheckbox"); $displayRestoreStatusText = $window.FindName("DisplayRestoreStatusText")
$cpuMonitorEnabledCheckbox = $window.FindName("CpuMonitorEnabledCheckbox"); $presentMonEnabledCheckbox = $window.FindName("PresentMonEnabledCheckbox"); $optionalHelperStatusBox = $window.FindName("OptionalHelperStatusBox")
$capabilitiesClearCacheBtn = $window.FindName("CapabilitiesClearCacheBtn")
$capabilitiesDiscoveryEnabledCheckbox = $window.FindName("CapabilitiesDiscoveryEnabledCheckbox"); $capabilitiesMaximumCompatibilityCheckbox = $window.FindName("CapabilitiesMaximumCompatibilityCheckbox")
$capabilitiesSafetyStatusText = $window.FindName("CapabilitiesSafetyStatusText"); $capabilitiesExcludeCurrentBtn = $window.FindName("CapabilitiesExcludeCurrentBtn"); $capabilitiesClearExclusionsBtn = $window.FindName("CapabilitiesClearExclusionsBtn")
$riskyVcpEnabledCheckbox = $window.FindName("RiskyVcpEnabledCheckbox"); $riskyVcpStatusText = $window.FindName("RiskyVcpStatusText")
$automationBridgeEnabledCheckbox = $window.FindName("AutomationBridgeEnabledCheckbox"); $automationBridgeStatusText = $window.FindName("AutomationBridgeStatusText")
$automationBridgeBindBox = $window.FindName("AutomationBridgeBindBox"); $automationBridgePortBox = $window.FindName("AutomationBridgePortBox")
$automationBridgeKeyBox = $window.FindName("AutomationBridgeKeyBox"); $automationBridgeSaveBtn = $window.FindName("AutomationBridgeSaveBtn")
$runAtLoginEnabledCheckbox = $window.FindName("RunAtLoginEnabledCheckbox"); $runAtLoginStatusText = $window.FindName("RunAtLoginStatusText")
$ddcReportGenerateBtn = $window.FindName("DdcReportGenerateBtn"); $ddcReportCopyBtn = $window.FindName("DdcReportCopyBtn")
$ddcReportIncludeIdentifiersCheckbox = $window.FindName("DdcReportIncludeIdentifiersCheckbox"); $ddcReportIncludeNamesCheckbox = $window.FindName("DdcReportIncludeNamesCheckbox")
$statusText = $window.FindName("StatusText"); $autoModeText = $window.FindName("AutoModeText")
$transactionProgressPanel = $window.FindName("TransactionProgressPanel"); $transactionProgressText = $window.FindName("TransactionProgressText")
$transactionProgressBar = $window.FindName("TransactionProgressBar"); $transactionCancelBtn = $window.FindName("TransactionCancelBtn")

function Update-Status {
    param([string]$Message)
    $statusText.Text = $Message
    [System.Windows.Automation.AutomationProperties]::SetName($statusText, "Status: $Message")
    $severity = Get-StatusMessageSeverity -Message $Message
    if ($severity -ne "Info") {
        $statusBannerText.Text = $Message
        [System.Windows.Automation.AutomationProperties]::SetName($statusBannerText, "$severity`: $Message")
        $surfaceKey = if ($severity -eq "Error") { "DangerSurfaceBrush" } else { "WarningSurfaceBrush" }
        $borderKey = if ($severity -eq "Error") { "DangerBrush" } else { "WarningBrush" }
        $statusBannerBorder.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $surfaceKey)
        $statusBannerBorder.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $borderKey)
        $statusBannerBorder.Visibility = [System.Windows.Visibility]::Visible
        Invoke-LiveRegionAnnouncement -Control $statusBannerText
    }
}
if ($script:PendingStatusMessage) { Update-Status $script:PendingStatusMessage; $script:PendingStatusMessage = "" }
Initialize-LocalizationAndAccessibility
Initialize-SystemAccessibility
Start-DdcWriteResultTimer

function Update-SelectedMonitorRecoveryUi {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates process-local WPF status controls only.')]
    param()
    if ($null -eq $selectedMonitorHealthDot -or $null -eq $selectedMonitorHealthText) { return }
    $state = "Offline"
    $lastSuccessUtc = $null
    $failures = 0
    $lastError = ""
    if ($script:PhysicalMonitors.Count -gt 0 -and $script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if ($monitor.PSObject.Properties.Name -contains "RecoveryState") { $state = [string]$monitor.RecoveryState }
        if ($monitor.PSObject.Properties.Name -contains "RecoveryLastSuccessUtc") { $lastSuccessUtc = $monitor.RecoveryLastSuccessUtc }
        if ($monitor.PSObject.Properties.Name -contains "RecoveryConsecutiveFailures") { $failures = [int]$monitor.RecoveryConsecutiveFailures }
        if ($monitor.PSObject.Properties.Name -contains "RecoveryLastError") { $lastError = [string]$monitor.RecoveryLastError }
    }
    $brushKey = switch ($state) {
        "Fresh" { "SuccessBrush" }
        "Retrying" { "WarningBrush" }
        "Stale" { "MutedTextBrush" }
        default { "DangerBrush" }
    }
    $lastSuccessText = "never"
    if ($null -ne $lastSuccessUtc) {
        try { $lastSuccessText = ([DateTime]$lastSuccessUtc).ToLocalTime().ToString("HH:mm:ss") } catch { $null = $_ }
    }
    $selectedMonitorHealthDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $brushKey)
    $selectedMonitorHealthText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brushKey)
    $selectedMonitorHealthText.Text = if ($state -eq "Fresh") { "Fresh | $lastSuccessText" } else { "$state | last success $lastSuccessText" }
    $tooltip = "Display recovery: $state`nLast successful hardware read: $lastSuccessText`nConsecutive failures: $failures"
    if (-not [string]::IsNullOrWhiteSpace($lastError)) { $tooltip += "`n$lastError" }
    $selectedMonitorHealthText.ToolTip = $tooltip
    $selectedMonitorHealthDot.ToolTip = $tooltip
}

function Get-SelectedTimingIdentityKey {
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return "" }
    $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if ($null -eq $monitor) { return "" }
    return [string]$monitor.IdentityKey
}

function Update-DdcTimingControls {
    if ($null -eq $ddcTimingAdaptiveRadio) { return }
    $identityKey = Get-SelectedTimingIdentityKey
    $timingProfile = Get-DdcTimingProfile -IdentityKey $identityKey
    $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
    $script:UpdatingDdcTimingUI = $true
    try {
        $isManual = [string]$timingProfile.Mode -eq "Manual"
        $ddcTimingAdaptiveRadio.IsChecked = -not $isManual
        $ddcTimingManualRadio.IsChecked = $isManual
        $ddcTimingReadRetriesBox.Text = [string][int]$timingProfile.ReadRetries
        $ddcTimingWriteRetriesBox.Text = [string][int]$timingProfile.WriteRetries
        $ddcTimingCapabilityRetriesBox.Text = [string][int]$timingProfile.CapabilityRetries
        if ($ddcVerifyPolicyCombo) { $ddcVerifyPolicyCombo.SelectedValue = [string]$timing.VerifyPolicy }
        $ddcTimingReadRetriesBox.IsEnabled = $true
        $ddcTimingWriteRetriesBox.IsEnabled = $true
        $ddcTimingCapabilityRetriesBox.IsEnabled = $true
        if ($ddcValuesRereadBtn) {
            $ddcValuesRereadBtn.IsEnabled = $script:CurrentMonitorIndex -ge 0 -and
                $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count -and
                $script:PhysicalMonitors[$script:CurrentMonitorIndex].Handle -ne [IntPtr]::Zero
        }
        $calibration = if ([string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { "not calibrated yet" } else { "calibrated $($timingProfile.CalibratedAt)" }
        $skipped = @($timingProfile.UnsupportedCodes)
        $skippedText = if ($skipped.Count -eq 0) { "no codes skipped" } else {
            "skipping " + (($skipped | ForEach-Object { "0x{0:X2}" -f [int]$_.Code }) -join ", ")
        }
        $ddcTimingEffectiveText.Text = "Effective: $($timing.DelayMilliseconds) ms between retries (multiplier $($timing.SleepMultiplier)), read $($timing.ReadRetries), write $($timing.WriteRetries), capability $($timing.CapabilityRetries). Verification $($timing.VerifyPolicy.ToLowerInvariant()) after $($timing.VerificationDelayMilliseconds) ms; lenient second read after $($timing.LenientVerificationDelayMilliseconds) ms. $calibration; $skippedText."
        $timingWarning = if ($isManual) {
            "Manual mode ignores the learned sleep multiplier. Switching back to Adaptive discards the stored calibration and relearns it from the next successful handshake."
        } else {
            "Adaptive mode learns the sleep multiplier from the first successful handshake with this monitor. Switching to Manual leaves that calibration unused."
        }
        $verifyWarning = switch ([string]$timing.VerifyPolicy) {
            "Lenient" { " Lenient verification waits for a second mismatch before failing or rolling back." }
            "Off" { " Verification is off: successful writes are trusted and readback mismatches cannot trigger rollback." }
            default { " Strict verification treats one in-range readback mismatch as a failure." }
        }
        $ddcTimingWarningText.Text = $timingWarning + $verifyWarning
    } finally {
        $script:UpdatingDdcTimingUI = $false
    }
}

function Set-DdcTimingRetryFromUi {
    param([string]$Field, [string]$Text)
    $identityKey = Get-SelectedTimingIdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    $value = 0
    if (-not [int]::TryParse(([string]$Text).Trim(), [ref]$value)) { Update-DdcTimingControls; return }
    $value = [Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, $value))
    $timingProfile = Get-DdcTimingProfile -IdentityKey $identityKey
    switch ($Field) {
        "Read" { $timingProfile.ReadRetries = [int]$value }
        "Write" { $timingProfile.WriteRetries = [int]$value }
        default { $timingProfile.CapabilityRetries = [int]$value }
    }
    Save-DdcTimingSettings | Out-Null
    Update-Status "DDC $($Field.ToLowerInvariant()) retry budget set to $value for this monitor"
    Update-DdcTimingControls
}

function Set-DdcVerifyPolicyFromUi {
    param([string]$Policy)
    $identityKey = Get-SelectedTimingIdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    $timingProfile = Set-DdcVerifyPolicy -IdentityKey $identityKey -Policy $Policy
    Save-DdcTimingSettings | Out-Null
    Update-Status "DDC readback verification set to $([string]$timingProfile.VerifyPolicy) for this monitor"
    Update-DdcTimingControls
}

function Update-DisplayStateRestoreControls {
    $script:UpdatingDisplayStateRestoreUI = $true
    try {
        if ($displayRestoreEnabledCheckbox) { $displayRestoreEnabledCheckbox.IsChecked = [bool]$script:DisplayStateRestoreEnabled }
        if ($displayRestoreStatusText) {
            $displayRestoreStatusText.Text = if ($script:DisplayStateRestoreEnabled) {
                "Remembering $($script:DisplayStateRestoreValues.Count) display(s)"
            } else {
                "Off"
            }
        }
    } finally {
        $script:UpdatingDisplayStateRestoreUI = $false
    }
}

function Set-DisplayStateRestoreEnabled {
    param([bool]$Enabled)
    $script:DisplayStateRestoreEnabled = $Enabled
    if ($Enabled) {
        Update-DisplayStateRestoreFromUi
        Update-Status "Brightness restore enabled"
    } else {
        Update-Status "Brightness restore disabled"
    }
    Save-DisplayStateRestoreSettings | Out-Null
    Update-DisplayStateRestoreControls
}

function Update-OptionalHelperControls {
    $script:UpdatingOptionalHelperUI = $true
    try {
        if ($cpuMonitorEnabledCheckbox) { $cpuMonitorEnabledCheckbox.IsChecked = [bool]$script:CpuMonitorEnabled }
        if ($presentMonEnabledCheckbox) { $presentMonEnabledCheckbox.IsChecked = [bool]$script:PresentMonEnabled }
        if ($optionalHelperStatusBox) { $optionalHelperStatusBox.Text = Get-OptionalHelperStatusText }
    } finally {
        $script:UpdatingOptionalHelperUI = $false
    }
}

function Update-HardwareTabVisibility {
    if (-not $gpuTab) { return }
    $available = [bool]($script:HasNvidia -or $script:HasAmd -or $script:HasCpuTempMonitor)
    $gpuTab.Visibility = if ($available) { "Visible" } else { "Collapsed" }
    if ($available) {
        if (-not $script:GpuTimer) {
            $script:GpuTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:GpuTimer.Interval = [TimeSpan]::FromSeconds(2)
            $script:GpuTimer.Add_Tick({ Update-GpuStats })
        }
        $script:GpuTimer.Start()
        Update-GpuStats
    } elseif ($script:GpuTimer) {
        $script:GpuTimer.Stop()
    }
}

function Set-CpuMonitorEnabled {
    param([bool]$Enabled)
    $script:CpuMonitorEnabled = $Enabled
    if ($Enabled) {
        Initialize-CpuMonitor
        if ($script:HasCpuTempMonitor) {
            Update-Status "CPU temperature library loaded"
        } else {
            $reason = if ($script:CpuMonitorProvenance -and $script:CpuMonitorProvenance.Reason) { $script:CpuMonitorProvenance.Reason } else { "no supported library found" }
            Update-Status "CPU temperature library not loaded: $reason"
        }
    } else {
        Stop-CpuMonitor
        Update-Status "CPU temperature library disabled"
    }
    Save-OptionalHelperSettings | Out-Null
    Update-OptionalHelperControls
    Update-HardwareTabVisibility
}

function Set-PresentMonEnabled {
    param([bool]$Enabled)
    $script:PresentMonEnabled = $Enabled
    if ($Enabled) {
        if (Initialize-PresentMon) {
            Update-Status "PresentMon resolved"
        } else {
            $reason = if ($script:PresentMonProvenance -and $script:PresentMonProvenance.Reason) { $script:PresentMonProvenance.Reason } else { "no supported PresentMon found" }
            Update-Status "PresentMon not available: $reason"
        }
    } else {
        Hide-FpsOverlay
        $script:PresentMonPath = ""
        $script:PresentMonProvenance = $null
        Update-Status "PresentMon integration disabled"
    }
    Save-OptionalHelperSettings | Out-Null
    Update-OptionalHelperControls
}

function Sync-CapabilitySafetyUi {
    if ($null -eq $capabilitiesDiscoveryEnabledCheckbox) { return }
    $script:UpdatingCapabilitiesSafetyUI = $true
    try {
        $capabilitiesDiscoveryEnabledCheckbox.IsChecked = [bool]$script:CapabilitiesDiscoveryEnabled
        $capabilitiesMaximumCompatibilityCheckbox.IsChecked = [bool]$script:CapabilitiesMaximumCompatibility
        $capabilitiesSafetyStatusText.Text = Get-CapabilitiesSafetyStatusText
        $capabilitiesClearExclusionsBtn.IsEnabled = $script:CapabilitiesExcludedIdentityKeys.Count -gt 0
        $canExclude = $false
        if ($script:PhysicalMonitors.Count -gt 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
            $selected = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
            $identityKey = [string]$selected.IdentityKey
            $canExclude = -not [string]::IsNullOrWhiteSpace($identityKey) -and -not $script:CapabilitiesExcludedIdentityKeys.ContainsKey($identityKey)
        }
        $capabilitiesExcludeCurrentBtn.IsEnabled = $canExclude
    } finally {
        $script:UpdatingCapabilitiesSafetyUI = $false
    }
}

function Sync-VcpWriteSafetyUi {
    if ($null -eq $riskyVcpEnabledCheckbox) { return }
    $monitor = if ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    } else {
        $null
    }
    $script:UpdatingVcpWriteSafetyUI = $true
    try {
        $hasStableIdentity = $null -ne $monitor -and -not [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey) -and ([string]$monitor.IdentityKey).Length -le 512
        $riskyVcpEnabledCheckbox.IsEnabled = $hasStableIdentity
        $riskyVcpEnabledCheckbox.IsChecked = $hasStableIdentity -and (Test-VcpWriteEnabledForMonitor -Monitor $monitor)
        $riskyVcpStatusText.Text = Get-VcpWriteSafetyStatusText -Monitor $monitor
    } finally {
        $script:UpdatingVcpWriteSafetyUI = $false
    }
}

function Invoke-CapabilityDiscovery {
    Stop-CapabilitiesWorker -Cancel
    foreach ($monitor in @($script:PhysicalMonitors)) {
        $monitor.Capabilities = ""
        $monitor.CapabilitiesKnown = $false
        $monitor.SupportedVcpCodes = @{}
        $monitor.CapabilitiesPending = $false
        $monitor.CapabilitiesExcluded = (-not [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey([string]$monitor.IdentityKey))
    }
    Start-CapabilitiesWorker
    if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $selected = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        Update-CapabilitiesBox -Monitor $selected
        Update-CapabilityControls -Monitor $selected
    }
    Sync-CapabilitySafetyUi
}

function Draw-MonitorLayout {
    $monitorCanvas.Children.Clear()
    if ($script:PhysicalMonitors.Count -eq 0) { return }
    $minX = ($script:PhysicalMonitors | Measure-Object -Property Left -Minimum).Minimum
    $minY = ($script:PhysicalMonitors | Measure-Object -Property Top -Minimum).Minimum
    $maxX = ($script:PhysicalMonitors | Measure-Object -Property Right -Maximum).Maximum
    $maxY = ($script:PhysicalMonitors | Measure-Object -Property Bottom -Maximum).Maximum
    $totalWidth = $maxX - $minX; $totalHeight = $maxY - $minY
    if ($totalWidth -eq 0) { $totalWidth = 1920 }; if ($totalHeight -eq 0) { $totalHeight = 1080 }
    $canvasWidth = if ($monitorCanvas.ActualWidth -gt 0) { $monitorCanvas.ActualWidth } else { 340 }
    $canvasHeight = if ($monitorCanvas.ActualHeight -gt 0) { $monitorCanvas.ActualHeight } else { 94 }
    $scale = [Math]::Min(($canvasWidth - 12) / $totalWidth, ($canvasHeight - 12) / $totalHeight)
    $offsetX = ($canvasWidth - ($totalWidth * $scale)) / 2; $offsetY = ($canvasHeight - ($totalHeight * $scale)) / 2
    foreach ($mon in $script:PhysicalMonitors) {
        $x = (($mon.Left - $minX) * $scale) + $offsetX; $y = (($mon.Top - $minY) * $scale) + $offsetY
        $w = [Math]::Max(38, ($mon.Right - $mon.Left) * $scale - 4); $h = [Math]::Max(24, ($mon.Bottom - $mon.Top) * $scale - 4)
        $isSelected = ($mon.Index - 1) -eq $script:CurrentMonitorIndex
        $button = New-Object System.Windows.Controls.Button
        $button.Width = $w; $button.Height = $h
        $button.BorderThickness = New-Object System.Windows.Thickness(2)
        $button.Style = $window.FindResource("MonitorTileBtn")
        $button.Tag = [int]($mon.Index - 1)
        if ($isSelected) {
            $button.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, "CardHoverBrush")
            $button.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, "FocusBrush")
        } else {
            $button.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, "ControlBrush")
            $button.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, "BorderBrush")
        }
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = if ($w -ge 110) { "$($mon.Index)`n$(Get-MonitorDisplayLabel -Monitor $mon)" } else { $mon.Index.ToString() }
        $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "TextBrush")
        $tb.FontSize = 12
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.TextAlignment = [System.Windows.TextAlignment]::Center
        $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
        $button.Content = $tb
        $accessibleLabel = "Display $($mon.Index): $(Get-MonitorDisplayLabel -Monitor $mon)"
        if ($isSelected) { $accessibleLabel += ", selected" }
        [System.Windows.Automation.AutomationProperties]::SetName($button, $accessibleLabel)
        [System.Windows.Automation.AutomationProperties]::SetPositionInSet($button, [int]$mon.Index)
        [System.Windows.Automation.AutomationProperties]::SetSizeOfSet($button, [int]$script:PhysicalMonitors.Count)
        [System.Windows.Controls.Canvas]::SetLeft($button, $x); [System.Windows.Controls.Canvas]::SetTop($button, $y)
        $button.Add_Click({ param($sender,$args); $script:CurrentMonitorIndex = [int]$sender.Tag; Draw-MonitorLayout; Load-MonitorSettings })
        $monitorCanvas.Children.Add($button) | Out-Null
    }
    if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        $selectedMonitorName.Text = "$($mon.Index): $(Get-MonitorDisplayLabel -Monitor $mon)"
        $selectedMonitorRes.Text = "$($mon.Width) x $($mon.Height) @ $($mon.RefreshRate)Hz"
        $selectedMonitorInfo.Text = "$($mon.DeviceName)$(if ($mon.IsPrimary) { ' (Primary)' } else { '' })"
        Update-MonitorIdentityControls
        Update-SelectedMonitorRecoveryUi
        Update-DdcTimingControls
    }
}

function Load-MonitorSettings {
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; $h = $mon.Handle
    $wmiBrightness = $null
    Update-Status "Reading from $(Get-MonitorDisplayLabel -Monitor $mon)..."
    Stop-MonitorSettingsWorker -Cancel
    $script:UpdatingUI = $true
    try {
        $inputSourceCombo.Items.Clear()
        @(@{N="HDMI 1";V=0x11},@{N="HDMI 2";V=0x12},@{N="DisplayPort 1";V=0x0F},@{N="DisplayPort 2";V=0x10},@{N="USB-C";V=0x13},@{N="DVI";V=0x03},@{N="VGA";V=0x01}) | ForEach-Object {
            $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = $_.N; $item.Tag = $_.V; $inputSourceCombo.Items.Add($item) | Out-Null
        }
        Update-CapabilitiesBox -Monitor $mon
        Update-CapabilityControls -Monitor $mon
        Sync-CapabilitySafetyUi
        if ($h -eq [IntPtr]::Zero -and $script:WmiBrightnessAvailable) {
            $wmiBrightness = Get-WmiBrightness
            if ($null -ne $wmiBrightness) {
                foreach ($control in @($contrastSlider,$redSlider,$greenSlider,$blueSlider,$volumeSlider,$muteCheckbox,$sharpnessSlider,$inputSourceCombo,$powerOffBtn,$powerStandbyBtn,$powerOnBtn,$resetColorBtn,$factoryResetBtn,$allMonitorsStandbyBtn,$colorTempWarm,$colorTemp6500,$colorTempCool,$colorTempSRGB,$dynamicContrastOff,$dynamicContrastOn,$pictureModeWeb,$pictureModeCinema,$pictureModeGame,$pipPbpOffBtn,$pipModeBtn,$pbpModeBtn,$pipSecondaryDpBtn,$pipSecondaryHdmi1Btn,$pipSecondaryHdmi2Btn)) { if ($control) { $control.IsEnabled = $false } }
                foreach ($control in @($brightnessSlider,$presetDay,$presetNight,$presetAutoMode,$presetAmbientMode,$presetReset)) { if ($control) { $control.IsEnabled = $true; $control.ToolTip = "Integrated display brightness via WMI" } }
                $brightnessSlider.Maximum = 100; $brightnessSlider.Value = $wmiBrightness; $brightnessValue.Text = $wmiBrightness
                $capabilitiesBox.Text = "Integrated display brightness via WMI"
                Set-DisplayRecoveryOutcome -IdentityKey ([string]$mon.IdentityKey) -Outcome "Success" -Generation $script:DisplayRecoveryGeneration | Out-Null
                Update-Status "$(Get-MonitorDisplayLabel -Monitor $mon) via WMI"; Update-TrayPopupState; Update-TrayIconText
            }
        }
        if ($h -eq [IntPtr]::Zero) {
            if (-not $script:WmiBrightnessAvailable -or $null -eq $wmiBrightness) {
                Set-DisplayRecoveryOutcome -IdentityKey ([string]$mon.IdentityKey) -Outcome "Failure" -Generation $script:DisplayRecoveryGeneration -ErrorMessage "No DDC/CI or WMI brightness path is available" | Out-Null
                Update-Status "$(Get-MonitorDisplayLabel -Monitor $mon)"
            }
            Update-TrayPopupState
            Update-TrayIconText
        }
    } finally {
        $script:UpdatingUI = $false
    }
    Start-MonitorSettingsWorker -Handle $h -MonitorIndex $script:CurrentMonitorIndex -MonitorName $mon.Name
}

function Refresh-Monitors {
    param([int]$Generation = 0, [string]$Reason = "manual")
    if ($Generation -le 0) {
        $script:DisplayRecoveryGeneration++
        $Generation = [int]$script:DisplayRecoveryGeneration
        foreach ($monitor in @($script:PhysicalMonitors)) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$monitor.IdentityKey) -Outcome "Stale" -Generation $Generation | Out-Null
        }
    } elseif ($Generation -ne $script:DisplayRecoveryGeneration) {
        return $false
    }
    $previousIdentity = ""
    if ($script:PhysicalMonitors.Count -gt 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $previousIdentity = [string]$script:PhysicalMonitors[$script:CurrentMonitorIndex].IdentityKey
    }
    try {
        Get-Monitors
    } catch {
        foreach ($monitor in @($script:PhysicalMonitors)) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$monitor.IdentityKey) -Outcome "Failure" -Generation $Generation -ErrorMessage $_.Exception.Message | Out-Null
        }
        Update-Status "Display refresh failed after $Reason`: $($_.Exception.Message)"
        Update-SelectedMonitorRecoveryUi
        return $false
    }
    $matchedIndex = Find-MonitorIndexByIdentity -IdentityKey $previousIdentity
    if ($matchedIndex -ge 0) {
        $script:CurrentMonitorIndex = $matchedIndex
    } elseif ($script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) {
        $script:CurrentMonitorIndex = 0
    }
    Draw-MonitorLayout
    Load-MonitorSettings
    Start-CapabilitiesWorker
    Update-ProfilesList
    $script:DdcLivenessNextProbeUtc = [DateTime]::UtcNow.AddSeconds($script:DdcLivenessProbeIntervalSeconds)
    return $true
}

function Invoke-PendingDisplayRecoveryRefresh {
    if ($script:DisplayRecoveryPendingReasons.Count -eq 0) { return }
    $generation = [int]$script:DisplayRecoveryGeneration
    $reasons = @($script:DisplayRecoveryPendingReasons.Keys | Sort-Object)
    $script:DisplayRecoveryPendingReasons = @{}
    $reasonText = $reasons -join ", "
    Refresh-Monitors -Generation $generation -Reason $reasonText | Out-Null
}

function Request-DisplayRecoveryRefresh {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Queues an in-process monitor refresh.')]
    param([string]$Reason = "display-event")
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = "display-event" }
    $script:DisplayRecoveryGeneration++
    $generation = [int]$script:DisplayRecoveryGeneration
    $script:DisplayRecoveryPendingReasons[$Reason] = $true
    foreach ($monitor in @($script:PhysicalMonitors)) {
        Set-DisplayRecoveryOutcome -IdentityKey ([string]$monitor.IdentityKey) -Outcome "Stale" -Generation $generation | Out-Null
    }
    Request-VerifiedVcpTransactionCancel -Reason "display configuration changed" | Out-Null
    Stop-MonitorSettingsWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-DdcReportWorker -Cancel
    Stop-DdcLivenessWorker -Cancel
    if (-not $script:DisplayRecoveryDebounceTimer) {
        $script:DisplayRecoveryDebounceTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DisplayRecoveryDebounceTimer.Interval = [TimeSpan]::FromMilliseconds($script:DisplayRecoveryDebounceMilliseconds)
        $script:DisplayRecoveryDebounceTimer.Add_Tick({
            $script:DisplayRecoveryDebounceTimer.Stop()
            Invoke-PendingDisplayRecoveryRefresh
        })
    }
    $script:DisplayRecoveryDebounceTimer.Stop()
    $script:DisplayRecoveryDebounceTimer.Start()
    Update-Status "Display change detected; waiting for topology to settle"
    Update-SelectedMonitorRecoveryUi
}

function Stop-DdcLivenessWorker {
    param([switch]$Cancel)
    if ($script:DdcLivenessWorker) {
        if ($Cancel -and $script:DdcLivenessWorkerAsyncResult -and -not $script:DdcLivenessWorkerAsyncResult.IsCompleted) {
            try { $script:DdcLivenessWorker.Stop() } catch {}
        }
        try { $script:DdcLivenessWorker.Dispose() } catch {}
    }
    if ($script:DdcLivenessWorkerInput) { try { $script:DdcLivenessWorkerInput.Dispose() } catch {} }
    if ($script:DdcLivenessWorkerOutput) { try { $script:DdcLivenessWorkerOutput.Dispose() } catch {} }
    $script:DdcLivenessWorker = $null
    $script:DdcLivenessWorkerInput = $null
    $script:DdcLivenessWorkerOutput = $null
    $script:DdcLivenessWorkerAsyncResult = $null
    $script:DdcLivenessWorkerGeneration = 0
    $script:DdcLivenessWorkerTargets = @()
}

function Update-DdcLivenessWorkerOutput {
    if (-not $script:DdcLivenessWorker -or -not $script:DdcLivenessWorkerAsyncResult) { return }
    if (-not $script:DdcLivenessWorkerAsyncResult.IsCompleted) { return }
    $generation = [int]$script:DdcLivenessWorkerGeneration
    try { $script:DdcLivenessWorker.EndInvoke($script:DdcLivenessWorkerAsyncResult) } catch { $null = $_ }
    $results = @($script:DdcLivenessWorkerOutput | Where-Object {
        Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $generation -Monitors $script:PhysicalMonitors
    })
    Stop-DdcLivenessWorker
    $script:DdcLivenessNextProbeUtc = [DateTime]::UtcNow.AddSeconds($script:DdcLivenessProbeIntervalSeconds)
    if ($generation -ne $script:DisplayRecoveryGeneration) { return }

    foreach ($result in $results) {
        $identityKey = [string]$result.IdentityKey
        $probeUtc = if ($result.PSObject.Properties.Name -contains "TimestampUtc") { [DateTime]$result.TimestampUtc } else { [DateTime]::UtcNow }
        foreach ($monitor in @($script:PhysicalMonitors)) {
            if ($null -eq $monitor -or [string]$monitor.IdentityKey -ne $identityKey) { continue }
            $monitor | Add-Member -NotePropertyName DdcLastProbeUtc -NotePropertyValue $probeUtc -Force
            $monitor | Add-Member -NotePropertyName DdcLastProbeSucceeded -NotePropertyValue ([bool]$result.Success) -Force
            if ([bool]$result.Success) {
                $script:DdcLivenessLastSuccessUtc[$identityKey] = $probeUtc
                $monitor | Add-Member -NotePropertyName DdcLastSuccessfulProbeUtc -NotePropertyValue $probeUtc -Force
            }
            break
        }
        if ([bool]$result.Success) {
            Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Success" -Generation $generation -NowUtc $probeUtc | Out-Null
        } else {
            Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Failure" -Generation $generation -NowUtc $probeUtc -ErrorMessage "Periodic DDC liveness read failed" | Out-Null
        }
    }

    $decision = Invoke-DdcLivenessRecovery -Results $results -CurrentGeneration $generation -RequestRecovery {
        param([object[]]$FailedIdentities)
        $failedLabels = @($FailedIdentities | ForEach-Object {
            $failedIndex = Find-MonitorIndexByIdentity -IdentityKey ([string]$_)
            if ($failedIndex -ge 0) { Get-MonitorDisplayLabel -Monitor $script:PhysicalMonitors[$failedIndex] } else { [string]$_ }
        })
        Update-Status "DDC liveness failed for $($failedLabels -join ', '); reacquiring monitor handles"
        Request-DisplayRecoveryRefresh -Reason "ddc-liveness"
    }
    if (-not [bool]$decision.RecoveryRequested -and $results.Count -gt 0) {
        Update-SelectedMonitorRecoveryUi
    }
}

function Start-DdcLivenessProbe {
    if (Test-VerifiedVcpTransactionWorkerActive) { return }
    if ($script:DdcLivenessWorker) { return }
    $generation = [int]$script:DisplayRecoveryGeneration
    $targets = @()
    for ($index = 0; $index -lt $script:PhysicalMonitors.Count; $index++) {
        $monitor = $script:PhysicalMonitors[$index]
        if ($null -eq $monitor -or $monitor.Handle -eq [IntPtr]::Zero -or [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey)) { continue }
        $probeCode = [int][MonitorAPI]::VCP_BRIGHTNESS
        if ([bool]$monitor.CapabilitiesKnown) {
            $probeCode = -1
            foreach ($candidate in @([int][MonitorAPI]::VCP_BRIGHTNESS, [int][MonitorAPI]::VCP_CONTRAST, [int][MonitorAPI]::VCP_VERSION)) {
                if (Test-MonitorSupportsVcp -Monitor $monitor -Code $candidate) { $probeCode = $candidate; break }
            }
            if ($probeCode -lt 0) { continue }
        }
        $timing = Get-DdcWorkerTiming -IdentityKey ([string]$monitor.IdentityKey)
        $targets += [PSCustomObject]@{
            MonitorIndex = [int]$index
            MonitorName = [string]$monitor.Name
            IdentityKey = [string]$monitor.IdentityKey
            Handle = $monitor.Handle
            HandleValue = [int64]$monitor.Handle.ToInt64()
            Generation = $generation
            Code = [int]$probeCode
            ReadRetries = [int]$timing.ReadRetries
            DelayMilliseconds = [int]$timing.DelayMilliseconds
        }
    }
    $script:DdcLivenessNextProbeUtc = [DateTime]::UtcNow.AddSeconds($script:DdcLivenessProbeIntervalSeconds)
    if ($targets.Count -eq 0) { return }
    $workerScript = {
        param([object[]]$Targets)
        foreach ($target in $Targets) {
            $vct = [uint32]0
            $current = [uint32]0
            $maximum = [uint32]0
            $lastError = [int]0
            $attempts = [int]0
            $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]$target.Code, [int]$target.ReadRetries, [int]$target.DelayMilliseconds, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
            [PSCustomObject]@{
                Success = [bool]$ok
                Code = [int]$target.Code
                Current = [uint32]$current
                Maximum = [uint32]$maximum
                Type = [uint32]$vct
                LastError = [int]$lastError
                Attempts = [int]$attempts
                MonitorName = [string]$target.MonitorName
                IdentityKey = [string]$target.IdentityKey
                MonitorIndex = [int]$target.MonitorIndex
                Generation = [int]$target.Generation
                HandleValue = [int64]$target.HandleValue
                TimestampUtc = [DateTime]::UtcNow
            }
        }
    }
    $script:DdcLivenessWorkerGeneration = $generation
    $script:DdcLivenessWorkerTargets = $targets
    $script:DdcLivenessWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:DdcLivenessWorkerInput.Complete()
    $script:DdcLivenessWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:DdcLivenessWorker = [PowerShell]::Create()
    $script:DdcLivenessWorker.AddScript($workerScript.ToString()).AddArgument($targets) | Out-Null
    $script:DdcLivenessWorkerAsyncResult = $script:DdcLivenessWorker.BeginInvoke($script:DdcLivenessWorkerInput, $script:DdcLivenessWorkerOutput)
}

function Invoke-DisplayRecoveryEventPump {
    Update-DdcLivenessWorkerOutput
    $reason = ""
    while ($script:DisplayRecoveryEventQueue.TryDequeue([ref]$reason)) {
        Request-DisplayRecoveryRefresh -Reason $reason
        $reason = ""
    }
    if ($script:DisplayRecoveryPendingReasons.Count -gt 0) { return }
    if ($script:MonitorSettingsWorker -and $script:MonitorSettingsWorkerAsyncResult -and -not $script:MonitorSettingsWorkerAsyncResult.IsCompleted) { return }
    $nowUtc = [DateTime]::UtcNow
    $dueIdentities = @()
    foreach ($monitor in @($script:PhysicalMonitors)) {
        $identityKey = [string]$monitor.IdentityKey
        if ([string]::IsNullOrWhiteSpace($identityKey) -or -not $script:DisplayRecoveryStates.ContainsKey($identityKey)) { continue }
        $state = $script:DisplayRecoveryStates[$identityKey]
        if ($null -ne $state.NextRetryUtc -and ([DateTime]$state.NextRetryUtc) -le $nowUtc) {
            $dueIdentities += $identityKey
        }
    }
    if ($dueIdentities.Count -gt 0) {
        foreach ($identityKey in $dueIdentities) {
            Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Retry" -Generation $script:DisplayRecoveryGeneration | Out-Null
        }
        Load-MonitorSettings
        return
    }
    if ($nowUtc -lt $script:DdcLivenessNextProbeUtc -or $script:DdcLivenessWorker) { return }
    if (($script:CapabilitiesWorker -and $script:CapabilitiesWorkerAsyncResult -and -not $script:CapabilitiesWorkerAsyncResult.IsCompleted) -or
        ($script:VcpWorker -and $script:VcpWorkerAsyncResult -and -not $script:VcpWorkerAsyncResult.IsCompleted) -or
        ($script:DdcReportWorker -and $script:DdcReportWorkerAsyncResult -and -not $script:DdcReportWorkerAsyncResult.IsCompleted) -or
        [MonitorAPI]::IsVCPWriteWorkerActive()) { return }
    Start-DdcLivenessProbe
}

function Initialize-DisplayRecoveryEventPipeline {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Registers process-local Windows event listeners.')]
    param()
    if (-not $script:DisplayRecoveryEventPumpTimer) {
        $script:DisplayRecoveryEventPumpTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DisplayRecoveryEventPumpTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $script:DisplayRecoveryEventPumpTimer.Add_Tick({ Invoke-DisplayRecoveryEventPump })
        $script:DisplayRecoveryEventPumpTimer.Start()
    }
    if ($null -eq $script:DisplayRecoveryHwndSource) {
        try {
            $interop = New-Object System.Windows.Interop.WindowInteropHelper($window)
            $script:DisplayRecoveryHwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interop.Handle)
            $script:DisplayRecoveryWindowHook = [System.Windows.Interop.HwndSourceHook]{
                param([IntPtr]$hwnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
                $null = $hwnd
                $null = $lParam
                $handled.Value = $false
                $reason = ""
                switch ($message) {
                    0x007E { $reason = "display-change" }
                    0x0219 { $reason = "device-change" }
                    0x0218 {
                        $powerEvent = [int]$wParam.ToInt64()
                        if ($powerEvent -in @(0x0006, 0x0007, 0x0012)) { $reason = "resume" }
                    }
                }
                if ($reason) { Request-DisplayRecoveryRefresh -Reason $reason }
                return [IntPtr]::Zero
            }
            if ($script:DisplayRecoveryHwndSource) {
                $script:DisplayRecoveryHwndSource.AddHook($script:DisplayRecoveryWindowHook)
            }
        } catch {
            $script:DisplayRecoveryHwndSource = $null
            $script:DisplayRecoveryWindowHook = $null
        }
    }
    if ($null -eq $script:WmiBrightnessEventWatcher) {
        $watcher = $null
        try {
            Unregister-Event -SourceIdentifier $script:DisplayRecoveryEventSourceIdentifier -ErrorAction SilentlyContinue
            $scope = New-Object System.Management.ManagementScope("\\.\root\WMI")
            $query = New-Object System.Management.WqlEventQuery("SELECT * FROM WmiMonitorBrightnessEvent")
            $watcher = New-Object System.Management.ManagementEventWatcher($scope, $query)
            $script:WmiBrightnessEventSubscription = Register-ObjectEvent -InputObject $watcher -EventName EventArrived -SourceIdentifier $script:DisplayRecoveryEventSourceIdentifier -MessageData $script:DisplayRecoveryEventQueue -Action {
                $event.MessageData.Enqueue("wmi-brightness")
            }
            $watcher.Start()
            $script:WmiBrightnessEventWatcher = $watcher
        } catch {
            if ($watcher) { try { $watcher.Dispose() } catch { $null = $_ } }
            $script:WmiBrightnessEventWatcher = $null
            $script:WmiBrightnessEventSubscription = $null
        }
    }
}

function Stop-DisplayRecoveryEventPipeline {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Disposes process-local Windows event listeners.')]
    param()
    if ($script:DisplayRecoveryDebounceTimer) { $script:DisplayRecoveryDebounceTimer.Stop() }
    if ($script:DisplayRecoveryEventPumpTimer) { $script:DisplayRecoveryEventPumpTimer.Stop() }
    Stop-DdcLivenessWorker -Cancel
    if ($script:DisplayRecoveryHwndSource -and $script:DisplayRecoveryWindowHook) {
        try { $script:DisplayRecoveryHwndSource.RemoveHook($script:DisplayRecoveryWindowHook) } catch { $null = $_ }
    }
    $script:DisplayRecoveryHwndSource = $null
    $script:DisplayRecoveryWindowHook = $null
    if ($script:WmiBrightnessEventWatcher) {
        try { $script:WmiBrightnessEventWatcher.Stop() } catch { $null = $_ }
        try { $script:WmiBrightnessEventWatcher.Dispose() } catch { $null = $_ }
    }
    try { Unregister-Event -SourceIdentifier $script:DisplayRecoveryEventSourceIdentifier -ErrorAction SilentlyContinue } catch { $null = $_ }
    if ($script:WmiBrightnessEventSubscription) {
        try { Remove-Job -Job $script:WmiBrightnessEventSubscription -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
    $script:WmiBrightnessEventWatcher = $null
    $script:WmiBrightnessEventSubscription = $null
    $script:DisplayRecoveryPendingReasons = @{}
}

function Invoke-DelayedMonitorSettingsRefresh {
    param([int]$DelayMs = 750, [int]$MonitorIndex = $script:CurrentMonitorIndex)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(100, $DelayMs))
    $targetIndex = $MonitorIndex
    $targetIdentity = if ($targetIndex -ge 0 -and $targetIndex -lt $script:PhysicalMonitors.Count) {
        [string]$script:PhysicalMonitors[$targetIndex].IdentityKey
    } else {
        ""
    }
    $timer.Add_Tick({
        param($sender, $args)
        $sender.Stop()
        $script:DeferredRefreshTimers = @($script:DeferredRefreshTimers | Where-Object { $_ -ne $sender })
        if ($targetIndex -eq $script:CurrentMonitorIndex -and
            $script:PhysicalMonitors.Count -gt $targetIndex -and
            -not [string]::IsNullOrWhiteSpace($targetIdentity) -and
            [string]$script:PhysicalMonitors[$targetIndex].IdentityKey -eq $targetIdentity) {
            Load-MonitorSettings
        }
    }.GetNewClosure())
    $script:DeferredRefreshTimers += $timer
    $timer.Start()
}

function Get-UserProfileFiles {
    if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { return @() }
    return @(Get-ChildItem -Path $script:ProfilesPath -Filter "*.json" -File |
        Where-Object { $script:ProfileMetadataFiles -notcontains $_.Name } |
        Sort-Object -Property BaseName)
}

function Update-ProfilesList {
    $profilesList.Items.Clear()
    Get-UserProfileFiles | ForEach-Object { $profilesList.Items.Add($_.BaseName) | Out-Null }
    Update-AppProfileProfileCombo
    Update-ProfileTrashControls
}

function Test-ProfileTrashRecordPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace([string]$script:ProfileTrashPath)) { return $false }
    $root = [System.IO.Path]::GetFullPath($script:ProfileTrashPath).TrimEnd([char[]]@('\', '/'))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath).TrimEnd([char[]]@('\', '/'))
    return [string]::Equals($root, $parent, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($fullPath) -like "profile-trash-*.json"
}

function Get-ProfileTrashRecords {
    if (-not (Test-Path -LiteralPath $script:ProfileTrashPath -PathType Container)) { return @() }
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $script:ProfileTrashPath -File -Filter "profile-trash-*.json" | Sort-Object LastWriteTimeUtc, Name -Descending)) {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-ProfileTrashRecordPath -Path $file.FullName)) { continue }
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not (Test-SettingsDocumentSupported -Name "ProfileTrash" -Document $record -Label "Profile trash")) { continue }
            $safeName = Get-SafeProfileName -Name ([string]$record.ProfileName)
            if ([string]::IsNullOrWhiteSpace($safeName) -or [string]::IsNullOrWhiteSpace([string]$record.ProfileContentBase64)) { continue }
            $records += [PSCustomObject]@{
                Path = $file.FullName
                TrashId = [string]$record.TrashId
                ProfileName = $safeName
                DeletedAtUtc = [string]$record.DeletedAtUtc
                Length = [long]$file.Length
            }
        } catch { $null = $_ }
    }
    return $records
}

function Remove-OldProfileTrashRecords {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Prunes only validated profile-trash records in the exact local trash directory.')]
    param()
    if (-not (Test-Path -LiteralPath $script:ProfileTrashPath -PathType Container)) { return 0 }
    $keptCount = 0
    [long]$keptBytes = 0
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $script:ProfileTrashPath -File -Filter "profile-trash-*.json" | Sort-Object LastWriteTimeUtc, Name -Descending)) {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Test-ProfileTrashRecordPath -Path $file.FullName)) { continue }
        $keep = $keptCount -lt [int]$script:ProfileTrashMaxRecords -and ($keptBytes + [long]$file.Length) -le [long]$script:ProfileTrashMaxBytes
        if ($keep) {
            $keptCount++
            $keptBytes += [long]$file.Length
        } else {
            Remove-Item -LiteralPath $file.FullName -Force
            $removed++
        }
    }
    return $removed
}

function Save-ProfileTrashRecord {
    param([string]$Name, [byte[]]$ProfileBytes, [object[]]$AppRules, [object[]]$Schedules)
    if ([string]::IsNullOrWhiteSpace($Name) -or $null -eq $ProfileBytes) { return "" }
    try {
        if (-not (Test-Path -LiteralPath $script:ProfileTrashPath)) { New-Item -ItemType Directory -Path $script:ProfileTrashPath -Force | Out-Null }
        $trashId = [guid]::NewGuid().ToString("N")
        $path = Join-Path $script:ProfileTrashPath "profile-trash-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))-$trashId.json"
        if (-not (Test-ProfileTrashRecordPath -Path $path)) { throw "Profile trash target escaped the local trash directory." }
        $record = [PSCustomObject]@{
            SchemaVersion = [int]$script:ProfileTrashSchemaVersion
            TrashId = $trashId
            DeletedAtUtc = [datetime]::UtcNow.ToString("o")
            ProfileName = $Name
            ProfileSha256 = Get-ByteSha256Hex -Bytes $ProfileBytes
            ProfileContentBase64 = [Convert]::ToBase64String($ProfileBytes)
            AppRules = @($AppRules)
            Schedules = @($Schedules)
        }
        if (-not (Write-JsonFileSafely -Path $path -Data $record -Depth 8)) { return "" }
        Remove-OldProfileTrashRecords | Out-Null
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
        return $path
    } catch {
        return ""
    }
}

function Remove-ProfileTrashRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes one exact validated local trash record after rollback or restore.')]
    param([string]$Path)
    if (-not (Test-ProfileTrashRecordPath -Path $Path)) { return $false }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
        return (-not (Test-Path -LiteralPath $Path))
    } catch {
        return $false
    }
}

function Restore-ProfileFromTrash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Restores an explicitly selected local trash record through transactional profile and automation persistence.')]
    param(
        [string]$RecordPath,
        [scriptblock]$SaveAppRulesAction,
        [scriptblock]$SaveSchedulesAction
    )
    if (-not (Test-ProfileStorageWriteAllowed -Operation "profile restore")) { return $false }
    if (-not (Test-ProfileTrashRecordPath -Path $RecordPath) -or -not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        Update-Status "Deleted profile record is no longer available"
        return $false
    }
    try {
        $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
        if (-not (Test-SettingsDocumentSupported -Name "ProfileTrash" -Document $record -Label "Profile trash")) { return $false }
        $name = Get-SafeProfileName -Name ([string]$record.ProfileName)
        if ([string]::IsNullOrWhiteSpace($name)) { throw "invalid profile name" }
        $profileBytes = [Convert]::FromBase64String([string]$record.ProfileContentBase64)
        if ((Get-ByteSha256Hex -Bytes $profileBytes) -ne [string]$record.ProfileSha256) { throw "profile checksum mismatch" }
    } catch {
        Update-Status "Deleted profile record is invalid: $($_.Exception.Message)"
        return $false
    }
    $profilePath = Join-Path $script:ProfilesPath "$name.json"
    if (Test-Path -LiteralPath $profilePath) {
        Update-Status "Cannot restore '$name' because a profile with that name already exists"
        return $false
    }
    $originalAppRules = @($script:AppProfileRules)
    $originalSchedules = @($script:ProfileSchedules)
    $restoredAppRules = @($record.AppRules | ForEach-Object { $_ })
    $restoredSchedules = @($record.Schedules | ForEach-Object { $_ })
    $script:AppProfileRules = @($originalAppRules)
    foreach ($rule in $restoredAppRules) {
        if (@($script:AppProfileRules | Where-Object { [string]$_.Exe -eq [string]$rule.Exe -and [string]$_.Profile -eq [string]$rule.Profile }).Count -eq 0) { $script:AppProfileRules += $rule }
    }
    $script:ProfileSchedules = @($originalSchedules)
    foreach ($rule in $restoredSchedules) {
        if (@($script:ProfileSchedules | Where-Object { [string]$_.Time -eq [string]$rule.Time -and [string]$_.Profile -eq [string]$rule.Profile }).Count -eq 0) { $script:ProfileSchedules += $rule }
    }
    if ($null -eq $SaveAppRulesAction) { $SaveAppRulesAction = { Save-AppProfileRules } }
    if ($null -eq $SaveSchedulesAction) { $SaveSchedulesAction = { Save-ProfileSchedules } }
    $appRulesSaved = $false
    $schedulesSaved = $false
    try {
        [System.IO.File]::WriteAllBytes($profilePath, $profileBytes)
        $appRulesSaved = [bool](& $SaveAppRulesAction)
        if (-not $appRulesSaved) { throw "application rules could not be saved" }
        $schedulesSaved = [bool](& $SaveSchedulesAction)
        if (-not $schedulesSaved) { throw "profile schedules could not be saved" }
    } catch {
        $failure = $_.Exception.Message
        $script:AppProfileRules = $originalAppRules
        $script:ProfileSchedules = $originalSchedules
        if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue }
        if ($appRulesSaved) { try { & $SaveAppRulesAction | Out-Null } catch { $null = $_ } }
        if ($schedulesSaved) { try { & $SaveSchedulesAction | Out-Null } catch { $null = $_ } }
        Update-Status "Restore of '$name' failed; no profile or automation change was kept: $failure"
        return $false
    }
    $recordRemoved = Remove-ProfileTrashRecord -Path $RecordPath
    Update-Status $(if ($recordRemoved) { "Restored '$name' and its dependent automation" } else { "Restored '$name'; its duplicate trash record could not be removed" })
    return $true
}

function Restore-LatestProfileFromTrash {
    $latest = @(Get-ProfileTrashRecords | Select-Object -First 1)
    if ($latest.Count -eq 0) { Update-Status "No deleted profile is available to restore"; return $false }
    return (Restore-ProfileFromTrash -RecordPath $latest[0].Path)
}

function Clear-ProfileTrash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only after a separate explicit permanent-delete confirmation in the UI.')]
    param()
    $removed = 0
    foreach ($record in @(Get-ProfileTrashRecords)) {
        if (Remove-ProfileTrashRecord -Path $record.Path) { $removed++ }
    }
    return $removed
}

function Update-ProfileTrashControls {
    $records = @(Get-ProfileTrashRecords)
    if ($restoreProfileBtn) { $restoreProfileBtn.IsEnabled = $records.Count -gt 0 -and -not $script:ProfileStorageOffline }
    if ($purgeProfileTrashBtn) { $purgeProfileTrashBtn.IsEnabled = $records.Count -gt 0 }
    if ($profileTrashStatusText) {
        $profileTrashStatusText.Text = if ($records.Count -eq 0) { "Trash empty" } elseif ($records.Count -eq 1) { "1 deleted profile available" } else { "$($records.Count) deleted profiles available" }
    }
}

function Remove-ProfileAndDependencies {
    param(
        [string]$Name,
        [scriptblock]$DeleteProfileFile,
        [scriptblock]$SaveAppRulesAction,
        [scriptblock]$SaveSchedulesAction,
        [scriptblock]$SaveTrashAction,
        [scriptblock]$RemoveTrashAction
    )
    if (-not (Test-ProfileStorageWriteAllowed -Operation "profile deletion")) { return $false }
    $safeName = Get-SafeProfileName -Name $Name
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        Update-Status "Profile deletion failed: '$Name' is not a valid profile name"
        return $false
    }
    $profilePath = Join-Path $script:ProfilesPath "$safeName.json"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Update-Status "Profile '$Name' was not found; application rules and schedules were not changed"
        return $false
    }
    try {
        $profileBytes = [System.IO.File]::ReadAllBytes($profilePath)
    } catch {
        Update-Status "Profile '$Name' could not be read before deletion; application rules and schedules were not changed: $($_.Exception.Message)"
        return $false
    }
    $removedAppRules = @($script:AppProfileRules | Where-Object { $_.Profile -eq $safeName })
    $removedSchedules = @($script:ProfileSchedules | Where-Object { $_.Profile -eq $safeName })
    if ($null -eq $SaveTrashAction) { $SaveTrashAction = { param($ProfileName, $Bytes, $AppRules, $Schedules) Save-ProfileTrashRecord -Name $ProfileName -ProfileBytes $Bytes -AppRules $AppRules -Schedules $Schedules } }
    if ($null -eq $RemoveTrashAction) { $RemoveTrashAction = { param($Path) Remove-ProfileTrashRecord -Path $Path } }
    $trashPath = [string](& $SaveTrashAction $safeName $profileBytes $removedAppRules $removedSchedules)
    if ([string]::IsNullOrWhiteSpace($trashPath) -or -not (Test-Path -LiteralPath $trashPath -PathType Leaf)) {
        Update-Status "Profile '$Name' could not be moved to local Trash; nothing was deleted"
        return $false
    }
    if ($null -eq $DeleteProfileFile) {
        $DeleteProfileFile = { param([string]$Path) Remove-Item -LiteralPath $Path -ErrorAction Stop }
    }
    $deleteError = $null
    try { & $DeleteProfileFile $profilePath } catch { $deleteError = $_.Exception }
    if (Test-Path -LiteralPath $profilePath) {
        & $RemoveTrashAction $trashPath | Out-Null
        $detail = if ($null -ne $deleteError) { $deleteError.Message } else { "the file still exists after the delete operation" }
        Update-Status "Profile '$Name' could not be deleted; application rules and schedules were not changed: $detail"
        return $false
    }

    $originalAppRules = @($script:AppProfileRules)
    $originalSchedules = @($script:ProfileSchedules)
    $script:AppProfileRules = @($originalAppRules | Where-Object { $_.Profile -ne $Name })
    $script:ProfileSchedules = @($originalSchedules | Where-Object { $_.Profile -ne $Name })
    if ($null -eq $SaveAppRulesAction) { $SaveAppRulesAction = { Save-AppProfileRules } }
    if ($null -eq $SaveSchedulesAction) { $SaveSchedulesAction = { Save-ProfileSchedules } }
    $appRulesSaved = $false
    $schedulesSaved = $false
    $saveFailure = ""
    try {
        $appRulesSaved = [bool](& $SaveAppRulesAction)
        if (-not $appRulesSaved) { throw "application rules could not be saved" }
        $schedulesSaved = [bool](& $SaveSchedulesAction)
        if (-not $schedulesSaved) { throw "profile schedules could not be saved" }
    } catch {
        $saveFailure = $_.Exception.Message
    }
    if (-not $appRulesSaved -or -not $schedulesSaved) {
        $script:AppProfileRules = $originalAppRules
        $script:ProfileSchedules = $originalSchedules
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        try { [System.IO.File]::WriteAllBytes($profilePath, $profileBytes) } catch { $rollbackFailures.Add("profile file: $($_.Exception.Message)") }
        if ($appRulesSaved) {
            try { if (-not [bool](& $SaveAppRulesAction)) { $rollbackFailures.Add("application rules") } } catch { $rollbackFailures.Add("application rules: $($_.Exception.Message)") }
        }
        if ($schedulesSaved) {
            try { if (-not [bool](& $SaveSchedulesAction)) { $rollbackFailures.Add("profile schedules") } } catch { $rollbackFailures.Add("profile schedules: $($_.Exception.Message)") }
        }
        if ($rollbackFailures.Count -eq 0) {
            & $RemoveTrashAction $trashPath | Out-Null
            Update-Status "Profile deletion failed while saving dependencies ($saveFailure); '$Name' and its automation were restored"
        } else {
            Update-Status "Profile deletion failed and rollback was incomplete ($saveFailure): $($rollbackFailures -join '; ')"
        }
        return $false
    }
    Update-Status "Moved '$Name' and its dependent automation to Trash"
    return $true
}

function Get-ProfilePropertyValue {
    param($Object, [string]$Property, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Property -and $null -ne $Object.$Property) { return $Object.$Property }
    return $Default
}

function Get-ProfileIntValue {
    param($Object, [string]$Property, [int]$Default = 0)
    $value = Get-ProfilePropertyValue -Object $Object -Property $Property -Default $null
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
    return [int]$value
}

# Schema v4 stores every scaled DDC value as a percentage. Profiles written before v4 held
# a raw value captured on whatever range the source monitor reported, so clamp them into
# the percentage domain rather than replaying an out-of-range number to the hardware.
function Get-ProfilePercentValue {
    param($Object, [string]$Property, [int]$Default = 50)
    $value = Get-ProfileIntValue -Object $Object -Property $Property -Default $Default
    if ($value -lt 0) { return 0 }
    if ($value -gt 100) { return 100 }
    return [int]$value
}

function New-ProfileSettingsObject {
    param($Monitor)
    return [PSCustomObject]@{
        IdentityKey = if ($Monitor) { [string]$Monitor.IdentityKey } else { "" }
        MonitorLabel = if ($Monitor) { Get-MonitorDisplayLabel -Monitor $Monitor } else { "" }
        MonitorName = if ($Monitor) { [string]$Monitor.Name } else { "" }
        DevicePath = if ($Monitor) { [string]$Monitor.DevicePath } else { "" }
        Brightness = [int](ConvertTo-VcpPercent -RawValue ([double]$brightnessSlider.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $Monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)))
        Contrast = [int](ConvertTo-VcpPercent -RawValue ([double]$contrastSlider.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $Monitor -Code ([int][MonitorAPI]::VCP_CONTRAST)))
        Red = [int](ConvertTo-VcpPercent -RawValue ([double]$redSlider.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $Monitor -Code ([int][MonitorAPI]::VCP_RED_GAIN)))
        Green = [int](ConvertTo-VcpPercent -RawValue ([double]$greenSlider.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $Monitor -Code ([int][MonitorAPI]::VCP_GREEN_GAIN)))
        Blue = [int](ConvertTo-VcpPercent -RawValue ([double]$blueSlider.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $Monitor -Code ([int][MonitorAPI]::VCP_BLUE_GAIN)))
        Gamma = [int]$gammaSlider.Value
        GammaRed = [int]$gammaRedSlider.Value
        GammaGreen = [int]$gammaGreenSlider.Value
        GammaBlue = [int]$gammaBlueSlider.Value
    }
}

function New-ProfileObject {
    param([string]$Name)
    $monitor = if ($script:PhysicalMonitors.Count -gt 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) { $script:PhysicalMonitors[$script:CurrentMonitorIndex] } else { $null }
    $setting = New-ProfileSettingsObject -Monitor $monitor
    return [PSCustomObject]@{
        SchemaVersion = $script:ProfileSchemaVersion
        Name = $Name
        MonitorIdentityKey = [string]$setting.IdentityKey
        MonitorLabel = [string]$setting.MonitorLabel
        MonitorName = [string]$setting.MonitorName
        MonitorDevicePath = [string]$setting.DevicePath
        MonitorSettings = @($setting)
        Brightness = [int]$setting.Brightness
        Contrast = [int]$setting.Contrast
        Red = [int]$setting.Red
        Green = [int]$setting.Green
        Blue = [int]$setting.Blue
        Gamma = [int]$setting.Gamma
        GammaRed = [int]$setting.GammaRed
        GammaGreen = [int]$setting.GammaGreen
        GammaBlue = [int]$setting.GammaBlue
        UpdatedAt = (Get-Date).ToString("o")
    }
}

function Resolve-ProfileMonitorReference {
    param([string]$IdentityKey, [string]$DevicePath = "")
    $index = Find-MonitorIndexByIdentity -IdentityKey $IdentityKey
    if ($index -lt 0) {
        return [PSCustomObject]@{ IdentityKey = $IdentityKey; DevicePath = $DevicePath }
    }
    $monitor = $script:PhysicalMonitors[$index]
    return [PSCustomObject]@{
        IdentityKey = [string]$monitor.IdentityKey
        DevicePath = [string]$monitor.DevicePath
    }
}

function Test-ProfileIdentityMigrationRequired {
    param($Profile)
    if ($null -eq $Profile) { return $false }
    $topKey = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorIdentityKey" -Default "")
    $topPath = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorDevicePath" -Default "")
    $topCurrent = Resolve-ProfileMonitorReference -IdentityKey $topKey -DevicePath $topPath
    if ([string]$topCurrent.IdentityKey -ne $topKey -or [string]$topCurrent.DevicePath -ne $topPath) { return $true }
    foreach ($setting in @((Get-ProfilePropertyValue -Object $Profile -Property "MonitorSettings" -Default @()))) {
        if ($null -eq $setting) { continue }
        $key = [string](Get-ProfilePropertyValue -Object $setting -Property "IdentityKey" -Default "")
        $path = [string](Get-ProfilePropertyValue -Object $setting -Property "DevicePath" -Default "")
        $current = Resolve-ProfileMonitorReference -IdentityKey $key -DevicePath $path
        if ([string]$current.IdentityKey -ne $key -or [string]$current.DevicePath -ne $path) { return $true }
    }
    return $false
}

function ConvertTo-CurrentProfileSchema {
    param($Profile, [string]$FallbackName)
    $schema = if ($Profile.PSObject.Properties.Name -contains "SchemaVersion") { [int]$Profile.SchemaVersion } else { 1 }
    if ($schema -lt 1) { throw "Profile schema version must be at least 1" }
    if ($schema -gt $script:ProfileSchemaVersion) { throw "Profile schema v$schema is newer than this app" }
    $name = if (Get-ProfilePropertyValue -Object $Profile -Property "Name" -Default "") { [string]$Profile.Name } else { $FallbackName }
    $topIdentityKey = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorIdentityKey" -Default "")
    $topDevicePath = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorDevicePath" -Default "")
    $topReference = Resolve-ProfileMonitorReference -IdentityKey $topIdentityKey -DevicePath $topDevicePath
    $topSetting = [PSCustomObject]@{
        IdentityKey = [string]$topReference.IdentityKey
        MonitorLabel = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorLabel" -Default "")
        MonitorName = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorName" -Default "")
        DevicePath = [string]$topReference.DevicePath
        Brightness = Get-ProfilePercentValue -Object $Profile -Property "Brightness" -Default 50
        Contrast = Get-ProfilePercentValue -Object $Profile -Property "Contrast" -Default 50
        Red = Get-ProfileIntValue -Object $Profile -Property "Red" -Default 50
        Green = Get-ProfileIntValue -Object $Profile -Property "Green" -Default 50
        Blue = Get-ProfileIntValue -Object $Profile -Property "Blue" -Default 50
        Gamma = Get-ProfileIntValue -Object $Profile -Property "Gamma" -Default 100
        GammaRed = Get-ProfileIntValue -Object $Profile -Property "GammaRed" -Default 100
        GammaGreen = Get-ProfileIntValue -Object $Profile -Property "GammaGreen" -Default 100
        GammaBlue = Get-ProfileIntValue -Object $Profile -Property "GammaBlue" -Default 100
    }
    $settings = @()
    foreach ($setting in @((Get-ProfilePropertyValue -Object $Profile -Property "MonitorSettings" -Default @()))) {
        if ($null -eq $setting) { continue }
        $settingIdentityKey = [string](Get-ProfilePropertyValue -Object $setting -Property "IdentityKey" -Default "")
        $settingDevicePath = [string](Get-ProfilePropertyValue -Object $setting -Property "DevicePath" -Default "")
        $settingReference = Resolve-ProfileMonitorReference -IdentityKey $settingIdentityKey -DevicePath $settingDevicePath
        $settings += [PSCustomObject]@{
            IdentityKey = [string]$settingReference.IdentityKey
            MonitorLabel = [string](Get-ProfilePropertyValue -Object $setting -Property "MonitorLabel" -Default "")
            MonitorName = [string](Get-ProfilePropertyValue -Object $setting -Property "MonitorName" -Default "")
            DevicePath = [string]$settingReference.DevicePath
            Brightness = Get-ProfilePercentValue -Object $setting -Property "Brightness" -Default $topSetting.Brightness
            Contrast = Get-ProfilePercentValue -Object $setting -Property "Contrast" -Default $topSetting.Contrast
            Red = Get-ProfilePercentValue -Object $setting -Property "Red" -Default $topSetting.Red
            Green = Get-ProfilePercentValue -Object $setting -Property "Green" -Default $topSetting.Green
            Blue = Get-ProfilePercentValue -Object $setting -Property "Blue" -Default $topSetting.Blue
            Gamma = Get-ProfileIntValue -Object $setting -Property "Gamma" -Default $topSetting.Gamma
            GammaRed = Get-ProfileIntValue -Object $setting -Property "GammaRed" -Default $topSetting.GammaRed
            GammaGreen = Get-ProfileIntValue -Object $setting -Property "GammaGreen" -Default $topSetting.GammaGreen
            GammaBlue = Get-ProfileIntValue -Object $setting -Property "GammaBlue" -Default $topSetting.GammaBlue
        }
    }
    if ($settings.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$topSetting.IdentityKey)) { $settings += $topSetting }
    return [PSCustomObject]@{
        SchemaVersion = $script:ProfileSchemaVersion
        Name = $name
        MonitorIdentityKey = [string]$topSetting.IdentityKey
        MonitorLabel = [string]$topSetting.MonitorLabel
        MonitorName = [string]$topSetting.MonitorName
        MonitorDevicePath = [string]$topSetting.DevicePath
        MonitorSettings = @($settings)
        Brightness = [int]$topSetting.Brightness
        Contrast = [int]$topSetting.Contrast
        Red = [int]$topSetting.Red
        Green = [int]$topSetting.Green
        Blue = [int]$topSetting.Blue
        Gamma = [int]$topSetting.Gamma
        GammaRed = [int]$topSetting.GammaRed
        GammaGreen = [int]$topSetting.GammaGreen
        GammaBlue = [int]$topSetting.GammaBlue
        UpdatedAt = if (Get-ProfilePropertyValue -Object $Profile -Property "UpdatedAt" -Default "") { [string]$Profile.UpdatedAt } else { (Get-Date).ToString("o") }
    }
}

function Save-ProfileObject {
    param($Profile)
    if (-not (Test-ProfileStorageWriteAllowed -Operation "profile saves")) { return $false }
    $safeName = Get-SafeProfileName -Name ([string]$Profile.Name)
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        Update-Status "Invalid profile name"
        return $false
    }
    try { $Profile.Name = $safeName } catch {}
    $path = Join-Path $script:ProfilesPath "$safeName.json"
    return (Write-JsonFileSafely -Path $path -Data $Profile -Depth 6)
}

function Read-ProfileObject {
    param([string]$Name)
    $safeName = Get-SafeProfileName -Name $Name
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        Update-Status "Invalid profile name"
        return $null
    }
    $path = Join-Path $script:ProfilesPath "$safeName.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
        $profileObject = Read-JsonFileSafely -Path $path -Label "Profile '$safeName'" -ReadOnly:$script:ProfileStorageOffline
    if ($null -eq $profileObject) { return $null }
    try {
        $schema = if ($profileObject.PSObject.Properties.Name -contains "SchemaVersion") { [int]$profileObject.SchemaVersion } else { 1 }
        $identityMigrationRequired = Test-ProfileIdentityMigrationRequired -Profile $profileObject
        $converted = ConvertTo-CurrentProfileSchema -Profile $profileObject -FallbackName $safeName
        if ($schema -lt $script:ProfileSchemaVersion -or $identityMigrationRequired) {
            if ($script:ProfileStorageOffline) {
                Update-Status "Profile '$safeName' was converted in memory while storage is offline"
            } else {
                Save-ProfileObject -Profile $converted | Out-Null
                $migrationReason = if ($schema -lt $script:ProfileSchemaVersion) { "schema v$script:ProfileSchemaVersion" } else { "the current monitor identity" }
                Update-Status "Migrated profile '$safeName' to $migrationReason"
            }
        }
        return $converted
    } catch {
        if ($script:ProfileStorageOffline) {
            Update-Status "Profile '$safeName' is invalid; read-only fallback left untouched"
        } else {
            $quarantinePath = Move-CorruptJsonFile -Path $path
            $leaf = if ($quarantinePath) { Split-Path -Path $quarantinePath -Leaf } else { "quarantine failed" }
            Update-Status "Profile '$safeName' invalid; quarantined to $leaf"
        }
        $backupPath = "$path.bak"
        if (Test-Path -LiteralPath $backupPath) {
            $backupProfile = Read-JsonFileSafely -Path $backupPath -Label "Profile '$safeName' backup" -ReadOnly:$script:ProfileStorageOffline
            if ($null -ne $backupProfile) {
                try { return (ConvertTo-CurrentProfileSchema -Profile $backupProfile -FallbackName $safeName) } catch {}
            }
        }
        return $null
    }
}

function Test-ProfileBundleEntryPath {
    param([string]$EntryPath)
    if ([string]::IsNullOrWhiteSpace($EntryPath) -or $EntryPath.Contains("\") -or $EntryPath.StartsWith("/") -or $EntryPath.Contains(":") -or $EntryPath.Contains([char]0)) {
        return $false
    }
    $segments = $EntryPath.Split("/")
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $segment = $segments[$i]
        if ($segment -eq "." -or $segment -eq "..") { return $false }
        if ([string]::IsNullOrEmpty($segment) -and $i -ne ($segments.Count - 1)) { return $false }
    }
    return $true
}

function Read-ProfileBundleEntryContent {
    param($Entry, [int]$MaxBytes)
    if ($null -eq $Entry -or [long]$Entry.Length -lt 0 -or [long]$Entry.Length -gt $MaxBytes) { return $null }
    $stream = $null
    $memory = $null
    try {
        $stream = $Entry.Open()
        $memory = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 8192
        $total = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { return $null }
            $memory.Write($buffer, 0, $read)
        }
        return ,$memory.ToArray()
    } finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-ByteSha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([string]$Path)
    $stream = $null
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Test-ProfileBundleIntegerValue {
    param($Value, [int]$Minimum, [int]$Maximum)
    if ($null -eq $Value) { return $false }
    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [System.TypeCode]::Byte,
        [System.TypeCode]::SByte,
        [System.TypeCode]::Int16,
        [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32,
        [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64,
        [System.TypeCode]::UInt64,
        [System.TypeCode]::Single,
        [System.TypeCode]::Double,
        [System.TypeCode]::Decimal
    )) {
        return $false
    }
    try {
        $number = [decimal]$Value
        return ($number -eq [decimal]::Truncate($number) -and $number -ge $Minimum -and $number -le $Maximum)
    } catch {
        return $false
    }
}

function Test-ProfileBundleTextValue {
    param($Object, [string]$Property, [int]$MaxLength, [switch]$Required)
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Property) { return (-not $Required) }
    $value = $Object.$Property
    if ($null -eq $value -or $value -isnot [string]) { return $false }
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) { return $false }
    return $value.Length -le $MaxLength
}

function Test-ProfileBundleNumberProperty {
    param($Object, [string]$Property, [int]$Minimum, [int]$Maximum, [switch]$Required)
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Property) { return (-not $Required) }
    return (Test-ProfileBundleIntegerValue -Value $Object.$Property -Minimum $Minimum -Maximum $Maximum)
}

function Test-ImportedProfileObject {
    param($RawProfile, [string]$ExpectedName)
    $failure = {
        param([string]$Message)
        return [PSCustomObject]@{ Valid = $false; Error = $Message; Profile = $null }
    }
    if ($null -eq $RawProfile -or $RawProfile -is [Array] -or $RawProfile -is [string]) { return (& $failure "Profile root must be a JSON object") }
    $schema = 1
    if ($RawProfile.PSObject.Properties.Name -contains "SchemaVersion") {
        if (-not (Test-ProfileBundleIntegerValue -Value $RawProfile.SchemaVersion -Minimum 1 -Maximum $script:ProfileSchemaVersion)) {
            return (& $failure "Profile schema is unsupported")
        }
        $schema = [int]$RawProfile.SchemaVersion
    }
    if (-not (Test-ProfileBundleTextValue -Object $RawProfile -Property "Name" -MaxLength 128)) {
        return (& $failure "Profile name has an invalid type or length")
    }
    if ($RawProfile.PSObject.Properties.Name -contains "Name" -and -not [string]::IsNullOrWhiteSpace([string]$RawProfile.Name) -and [string]$RawProfile.Name -cne $ExpectedName) {
        return (& $failure "Profile name does not match its declared destination")
    }
    $safeName = Get-SafeProfileName -Name $ExpectedName
    if ([string]::IsNullOrWhiteSpace($safeName) -or $safeName -cne $ExpectedName -or $safeName.Length -gt 128) {
        return (& $failure "Declared profile name is invalid")
    }
    foreach ($property in @("MonitorIdentityKey", "MonitorLabel", "MonitorName", "MonitorDevicePath")) {
        $maxLength = if ($property -eq "MonitorDevicePath") { 1024 } elseif ($property -eq "MonitorIdentityKey") { 512 } else { 256 }
        if (-not (Test-ProfileBundleTextValue -Object $RawProfile -Property $property -MaxLength $maxLength)) {
            return (& $failure "Profile text field '$property' is invalid")
        }
    }
    if ($RawProfile.PSObject.Properties.Name -contains "UpdatedAt") {
        if (-not (Test-ProfileBundleTextValue -Object $RawProfile -Property "UpdatedAt" -MaxLength 64)) {
            return (& $failure "Profile timestamp is invalid")
        }
        $timestamp = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$RawProfile.UpdatedAt, [ref]$timestamp)) {
            return (& $failure "Profile timestamp is invalid")
        }
    }
    $requiredNumbers = $schema -ge $script:ProfileSchemaVersion
    foreach ($property in @("Brightness", "Contrast", "Red", "Green", "Blue")) {
        if (-not (Test-ProfileBundleNumberProperty -Object $RawProfile -Property $property -Minimum 0 -Maximum 100 -Required:$requiredNumbers)) {
            return (& $failure "Profile numeric field '$property' is invalid")
        }
    }
    foreach ($property in @("Gamma", "GammaRed", "GammaGreen", "GammaBlue")) {
        if (-not (Test-ProfileBundleNumberProperty -Object $RawProfile -Property $property -Minimum 50 -Maximum 150 -Required:$requiredNumbers)) {
            return (& $failure "Profile numeric field '$property' is invalid")
        }
    }
    if ($RawProfile.PSObject.Properties.Name -contains "MonitorSettings") {
        if ($null -eq $RawProfile.MonitorSettings -or $RawProfile.MonitorSettings -is [string]) {
            return (& $failure "MonitorSettings must be an array of objects")
        }
        $monitorSettings = @($RawProfile.MonitorSettings)
        if ($monitorSettings.Count -gt $script:ProfileBundleMaxMonitorSettings) {
            return (& $failure "Profile has too many monitor settings")
        }
        $seenIdentityKeys = @{}
        foreach ($setting in $monitorSettings) {
            if ($null -eq $setting -or $setting -is [Array] -or $setting -is [string]) {
                return (& $failure "Monitor setting must be a JSON object")
            }
            foreach ($property in @("IdentityKey", "MonitorLabel", "MonitorName", "DevicePath")) {
                $maxLength = if ($property -eq "DevicePath") { 1024 } elseif ($property -eq "IdentityKey") { 512 } else { 256 }
                if (-not (Test-ProfileBundleTextValue -Object $setting -Property $property -MaxLength $maxLength)) {
                    return (& $failure "Monitor setting text field '$property' is invalid")
                }
            }
            $identityKey = if ($setting.PSObject.Properties.Name -contains "IdentityKey") { [string]$setting.IdentityKey } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($identityKey)) {
                if ($seenIdentityKeys.ContainsKey($identityKey)) { return (& $failure "Monitor setting identities must be unique") }
                $seenIdentityKeys[$identityKey] = $true
            }
            foreach ($property in @("Brightness", "Contrast", "Red", "Green", "Blue")) {
                if (-not (Test-ProfileBundleNumberProperty -Object $setting -Property $property -Minimum 0 -Maximum 100 -Required)) {
                    return (& $failure "Monitor setting numeric field '$property' is invalid")
                }
            }
            foreach ($property in @("Gamma", "GammaRed", "GammaGreen", "GammaBlue")) {
                if (-not (Test-ProfileBundleNumberProperty -Object $setting -Property $property -Minimum 50 -Maximum 150 -Required)) {
                    return (& $failure "Monitor setting numeric field '$property' is invalid")
                }
            }
        }
    }
    try {
        $converted = ConvertTo-CurrentProfileSchema -Profile $RawProfile -FallbackName $ExpectedName
        $converted.Name = $ExpectedName
        return [PSCustomObject]@{ Valid = $true; Error = ""; Profile = $converted }
    } catch {
        return (& $failure "Profile could not be normalized")
    }
}

function Get-ProfileBundleImportPlan {
    param([string]$BundlePath)
    $failure = {
        param([string]$Code, [string]$Message)
        return [PSCustomObject]@{ Valid = $false; ErrorCode = $Code; Message = $Message; Items = @(); BundlePath = $BundlePath }
    }
    if ([string]::IsNullOrWhiteSpace($BundlePath) -or -not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        return (& $failure "bundle_not_found" "Profile bundle was not found")
    }
    $bundleFile = Get-Item -LiteralPath $BundlePath
    if ($bundleFile.Length -gt $script:ProfileBundleMaxArchiveBytes) {
        return (& $failure "archive_too_large" "Profile bundle exceeds the archive size limit")
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($bundleFile.FullName)
        $entries = @($archive.Entries)
        if ($entries.Count -gt ($script:ProfileBundleMaxProfiles + 2)) {
            return (& $failure "too_many_entries" "Profile bundle contains too many entries")
        }
        $entryMap = @{}
        $totalBytes = [long]0
        foreach ($entry in $entries) {
            $entryPath = [string]$entry.FullName
            if (-not (Test-ProfileBundleEntryPath -EntryPath $entryPath)) {
                return (& $failure "unsafe_entry_path" "Profile bundle contains an unsafe entry path")
            }
            if ($entryMap.ContainsKey($entryPath)) {
                return (& $failure "duplicate_entry" "Profile bundle contains duplicate entry paths")
            }
            $entryMap[$entryPath] = $entry
            $unixType = (([int64]$entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000 -or (([int]$entry.ExternalAttributes -band 0x400) -ne 0)) {
                return (& $failure "unsafe_entry_type" "Profile bundle contains a link or reparse entry")
            }
            if ([string]::IsNullOrEmpty([string]$entry.Name)) {
                if ($entryPath -cne "profiles/") { return (& $failure "undeclared_entry" "Profile bundle contains an undeclared directory") }
                continue
            }
            $totalBytes += [long]$entry.Length
            if ($totalBytes -gt $script:ProfileBundleMaxTotalBytes) {
                return (& $failure "entry_limit" "Profile bundle exceeds the total expanded size limit")
            }
            if ([long]$entry.Length -gt 0) {
                $ratio = [double]$entry.Length / [double][Math]::Max(1, [long]$entry.CompressedLength)
                if ($ratio -gt $script:ProfileBundleMaxCompressionRatio) {
                    return (& $failure "entry_limit" "Profile bundle exceeds the compression-ratio limit")
                }
            }
        }
        if (-not $entryMap.ContainsKey("manifest.json") -or [string]$entryMap["manifest.json"].FullName -cne "manifest.json") {
            return (& $failure "manifest_missing" "Profile bundle manifest is missing")
        }
        $manifestEntry = $entryMap["manifest.json"]
        $manifestBytes = Read-ProfileBundleEntryContent -Entry $manifestEntry -MaxBytes $script:ProfileBundleMaxManifestBytes
        if ($null -eq $manifestBytes) { return (& $failure "manifest_invalid" "Profile bundle manifest exceeds its size limit") }
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $manifestText = $utf8.GetString([byte[]]$manifestBytes).TrimStart([char]0xFEFF)
            $manifest = $manifestText | ConvertFrom-Json
        } catch {
            return (& $failure "manifest_invalid" "Profile bundle manifest is not valid UTF-8 JSON")
        }
        if (
            $null -eq $manifest -or
            $manifest.PSObject.Properties.Name -notcontains "BundleSchemaVersion" -or
            -not (Test-ProfileBundleIntegerValue -Value $manifest.BundleSchemaVersion -Minimum 1 -Maximum $script:ProfileBundleSchemaVersion)
        ) {
            return (& $failure "unsupported_bundle_schema" "Profile bundle schema is unsupported")
        }
        $bundleSchema = [int]$manifest.BundleSchemaVersion
        if (
            $manifest.PSObject.Properties.Name -notcontains "ProfileSchemaVersion" -or
            -not (Test-ProfileBundleIntegerValue -Value $manifest.ProfileSchemaVersion -Minimum 1 -Maximum $script:ProfileSchemaVersion)
        ) {
            return (& $failure "unsupported_profile_schema" "Profile schema is unsupported")
        }
        $declaredProfileSchemaVersion = [int]$manifest.ProfileSchemaVersion
        if ($manifest.PSObject.Properties.Name -notcontains "Profiles") {
            return (& $failure "manifest_invalid" "Profile bundle manifest has no profile declarations")
        }
        $profileDeclarations = @($manifest.Profiles)
        if ($profileDeclarations.Count -gt $script:ProfileBundleMaxProfiles) {
            return (& $failure "too_many_entries" "Profile bundle declares too many profiles")
        }
        if (
            $manifest.PSObject.Properties.Name -notcontains "ProfileCount" -or
            -not (Test-ProfileBundleIntegerValue -Value $manifest.ProfileCount -Minimum 0 -Maximum $script:ProfileBundleMaxProfiles) -or
            [int]$manifest.ProfileCount -ne $profileDeclarations.Count
        ) {
            return (& $failure "manifest_mismatch" "Profile bundle count does not match its declarations")
        }

        $declarations = @()
        $declaredNames = @{}
        $declaredFiles = @{}
        foreach ($declaration in $profileDeclarations) {
            if ($bundleSchema -eq 1) {
                if ($declaration -isnot [string]) { return (& $failure "manifest_invalid" "Legacy profile declarations must be names") }
                $name = [string]$declaration
                $file = "profiles/$name.json"
                $declaredHash = ""
                $declaredLength = -1
            } else {
                if ($null -eq $declaration -or $declaration -is [string] -or $declaration -is [Array]) {
                    return (& $failure "manifest_invalid" "Profile declarations must be objects")
                }
                if (
                    -not (Test-ProfileBundleTextValue -Object $declaration -Property "Name" -MaxLength 128 -Required) -or
                    -not (Test-ProfileBundleTextValue -Object $declaration -Property "File" -MaxLength 256 -Required) -or
                    -not (Test-ProfileBundleTextValue -Object $declaration -Property "Sha256" -MaxLength 64 -Required) -or
                    -not (Test-ProfileBundleNumberProperty -Object $declaration -Property "UncompressedBytes" -Minimum 1 -Maximum $script:ProfileBundleMaxEntryBytes -Required)
                ) {
                    return (& $failure "manifest_invalid" "Profile declaration fields are invalid")
                }
                $name = [string]$declaration.Name
                $file = [string]$declaration.File
                $declaredHash = ([string]$declaration.Sha256).ToLowerInvariant()
                $declaredLength = [int]$declaration.UncompressedBytes
                if ($declaredHash -notmatch '^[0-9a-f]{64}$') {
                    return (& $failure "manifest_invalid" "Profile declaration checksum is invalid")
                }
            }
            $safeName = Get-SafeProfileName -Name $name
            if ([string]::IsNullOrWhiteSpace($safeName) -or $safeName -cne $name -or $safeName.Length -gt 128) {
                return (& $failure "manifest_invalid" "Profile declaration name is invalid")
            }
            $expectedFile = "profiles/$safeName.json"
            if ($file -cne $expectedFile -or -not (Test-ProfileBundleEntryPath -EntryPath $file)) {
                return (& $failure "unsafe_entry_path" "Profile declaration path is invalid")
            }
            if ($declaredNames.ContainsKey($safeName) -or $declaredFiles.ContainsKey($file)) {
                return (& $failure "duplicate_destination" "Profile bundle contains duplicate destinations")
            }
            $declaredNames[$safeName] = $true
            $declaredFiles[$file] = $true
            $declarations += [PSCustomObject]@{
                Name = $safeName
                File = $file
                Sha256 = $declaredHash
                UncompressedBytes = $declaredLength
            }
        }

        foreach ($entry in $entries) {
            if ([string]::IsNullOrEmpty([string]$entry.Name)) { continue }
            if ([string]$entry.FullName -ceq "manifest.json") { continue }
            if (-not $declaredFiles.ContainsKey([string]$entry.FullName)) {
                return (& $failure "undeclared_entry" "Profile bundle contains an undeclared file")
            }
        }

        $items = @()
        foreach ($declaration in $declarations) {
            if (-not $entryMap.ContainsKey($declaration.File)) {
                return (& $failure "declared_entry_missing" "Profile bundle is missing a declared profile")
            }
            $entry = $entryMap[$declaration.File]
            if ([long]$entry.Length -le 0 -or [long]$entry.Length -gt $script:ProfileBundleMaxEntryBytes) {
                return (& $failure "entry_limit" "A profile entry exceeds its size limit")
            }
            if ($bundleSchema -ge 2 -and [long]$entry.Length -ne [long]$declaration.UncompressedBytes) {
                return (& $failure "manifest_mismatch" "A profile entry length does not match its declaration")
            }
            $profileBytes = Read-ProfileBundleEntryContent -Entry $entry -MaxBytes $script:ProfileBundleMaxEntryBytes
            if ($null -eq $profileBytes) { return (& $failure "entry_limit" "A profile entry exceeds its read limit") }
            $actualHash = Get-ByteSha256Hex -Bytes ([byte[]]$profileBytes)
            if ($bundleSchema -ge 2 -and $actualHash -cne $declaration.Sha256) {
                return (& $failure "checksum_mismatch" "A profile entry checksum does not match its declaration")
            }
            try {
                $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
                $profileText = $utf8.GetString([byte[]]$profileBytes).TrimStart([char]0xFEFF)
                $rawProfile = $profileText | ConvertFrom-Json
            } catch {
                return (& $failure "invalid_profile" "A profile entry is not valid UTF-8 JSON")
            }
            if ($null -eq $rawProfile -or $rawProfile -is [Array] -or $rawProfile -is [string]) {
                return (& $failure "invalid_profile" "Profile root must be a JSON object")
            }
            $rawProfileSchema = if ($rawProfile.PSObject.Properties.Name -contains "SchemaVersion") { $rawProfile.SchemaVersion } else { 1 }
            if (
                -not (Test-ProfileBundleIntegerValue -Value $rawProfileSchema -Minimum 1 -Maximum $script:ProfileSchemaVersion) -or
                [int]$rawProfileSchema -gt $declaredProfileSchemaVersion
            ) {
                return (& $failure "manifest_mismatch" "A profile schema exceeds the manifest declaration")
            }
            $validation = Test-ImportedProfileObject -RawProfile $rawProfile -ExpectedName $declaration.Name
            if (-not $validation.Valid) {
                return (& $failure "invalid_profile" $validation.Error)
            }
            $canonicalText = (($validation.Profile | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
            $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalText)
            if ($canonicalBytes.Length -gt $script:ProfileBundleMaxEntryBytes) {
                return (& $failure "entry_limit" "A normalized profile exceeds its size limit")
            }
            $destinationPath = Join-Path $script:ProfilesPath "$($declaration.Name).json"
            $exists = Test-Path -LiteralPath $destinationPath -PathType Leaf
            $existingHash = if ($exists) { Get-FileSha256Hex -Path $destinationPath } else { "" }
            $items += [PSCustomObject]@{
                Name = [string]$declaration.Name
                File = [string]$declaration.File
                DestinationPath = $destinationPath
                Action = if ($exists) { "Replace" } else { "Create" }
                ExistingHash = $existingHash
                Content = [byte[]]$canonicalBytes
            }
        }
        return [PSCustomObject]@{
            Valid = $true
            ErrorCode = ""
            Message = ""
            Items = @($items)
            BundlePath = $bundleFile.FullName
            BundleSchemaVersion = $bundleSchema
        }
    } catch {
        return (& $failure "archive_invalid" "Profile bundle could not be safely read")
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Format-ProfileBundleImportPreview {
    param($Plan, [ValidateSet("Replace", "Skip")] [string]$ConflictMode = "Replace")
    if ($null -eq $Plan -or -not $Plan.Valid) { return "Profile bundle is invalid." }
    $creates = @($Plan.Items | Where-Object Action -eq "Create")
    $replaces = @($Plan.Items | Where-Object Action -eq "Replace")
    $skips = @(if ($ConflictMode -eq "Skip") { $replaces })
    if ($ConflictMode -eq "Skip") { $replaces = @() }
    $lines = @(
        "Create ($($creates.Count)): $(if ($creates.Count) { ($creates.Name | Select-Object -First 12) -join ', ' } else { 'none' })",
        "Replace ($($replaces.Count)): $(if ($replaces.Count) { ($replaces.Name | Select-Object -First 12) -join ', ' } else { 'none' })",
        "Skip ($($skips.Count)): $(if ($skips.Count) { ($skips.Name | Select-Object -First 12) -join ', ' } else { 'none' })"
    )
    return ($lines -join [Environment]::NewLine)
}

function Invoke-ProfileBundleImportCommit {
    param(
        $Plan,
        [ValidateSet("Replace", "Skip")] [string]$ConflictMode = "Replace",
        [scriptblock]$AfterCommit
    )
    if ($null -eq $Plan -or -not $Plan.Valid) {
        return [PSCustomObject]@{ Success = $false; Count = 0; Skipped = 0; ErrorCode = "invalid_plan" }
    }
    if (-not (Test-ProfileStorageWriteAllowed -Operation "profile imports")) {
        return [PSCustomObject]@{ Success = $false; Count = 0; Skipped = 0; ErrorCode = "storage_offline" }
    }
    $accepted = @($Plan.Items | Where-Object { $_.Action -eq "Create" -or ($_.Action -eq "Replace" -and $ConflictMode -eq "Replace") })
    $skipped = @($Plan.Items | Where-Object { $_.Action -eq "Replace" -and $ConflictMode -eq "Skip" }).Count
    if ($accepted.Count -eq 0) {
        return [PSCustomObject]@{ Success = $true; Count = 0; Skipped = $skipped; ErrorCode = "" }
    }
    if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
    $stageRoot = Join-Path $script:ProfilesPath (".profile-import-" + [guid]::NewGuid().ToString("N"))
    $stageProfiles = Join-Path $stageRoot "profiles"
    $rollbackRoot = Join-Path $stageRoot "rollback"
    $committed = New-Object System.Collections.Generic.List[object]
    $rollbackFailed = $false
    $preserveStage = $false
    try {
        New-Item -ItemType Directory -Path $stageProfiles -Force | Out-Null
        New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
        foreach ($item in $accepted) {
            $stagePath = Join-Path $stageProfiles "$($item.Name).json"
            [System.IO.File]::WriteAllBytes($stagePath, [byte[]]$item.Content)
            $item | Add-Member -NotePropertyName StagePath -NotePropertyValue $stagePath -Force
            $item | Add-Member -NotePropertyName RollbackPath -NotePropertyValue (Join-Path $rollbackRoot "$($item.Name).json") -Force
        }
        foreach ($item in $accepted) {
            $exists = Test-Path -LiteralPath $item.DestinationPath -PathType Leaf
            if ($item.Action -eq "Create" -and $exists) { throw "destination_changed" }
            if ($item.Action -eq "Replace") {
                if (-not $exists -or (Get-FileSha256Hex -Path $item.DestinationPath) -cne [string]$item.ExistingHash) {
                    throw "destination_changed"
                }
            }
        }
        foreach ($item in $accepted) {
            if ($item.Action -eq "Replace") {
                [System.IO.File]::Replace($item.StagePath, $item.DestinationPath, $item.RollbackPath, $true)
            } else {
                [System.IO.File]::Move($item.StagePath, $item.DestinationPath)
            }
            $committed.Add($item)
            if ($AfterCommit) { & $AfterCommit $committed.Count $item }
        }
        return [PSCustomObject]@{ Success = $true; Count = $accepted.Count; Skipped = $skipped; ErrorCode = "" }
    } catch {
        for ($i = $committed.Count - 1; $i -ge 0; $i--) {
            $item = $committed[$i]
            try {
                if ($item.Action -eq "Replace") {
                    if (-not (Test-Path -LiteralPath $item.RollbackPath -PathType Leaf)) { throw "rollback_missing" }
                    $failedImportPath = "$($item.RollbackPath).failed"
                    $restoredAtomically = $false
                    try {
                        [System.IO.File]::Replace($item.RollbackPath, $item.DestinationPath, $failedImportPath, $true)
                        $restoredAtomically = $true
                    } catch {
                        [System.IO.File]::Copy($item.RollbackPath, $item.DestinationPath, $true)
                    }
                    if ($restoredAtomically -and (Test-Path -LiteralPath $failedImportPath)) {
                        Remove-Item -LiteralPath $failedImportPath -Force -ErrorAction SilentlyContinue
                    }
                } elseif (Test-Path -LiteralPath $item.DestinationPath) {
                    Remove-Item -LiteralPath $item.DestinationPath -Force
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        foreach ($item in $committed) {
            if ($item.Action -eq "Replace") {
                try {
                    if ((Get-FileSha256Hex -Path $item.DestinationPath) -cne [string]$item.ExistingHash) { $rollbackFailed = $true }
                } catch {
                    $rollbackFailed = $true
                }
            } elseif (Test-Path -LiteralPath $item.DestinationPath) {
                $rollbackFailed = $true
            }
        }
        $preserveStage = $rollbackFailed
        return [PSCustomObject]@{
            Success = $false
            Count = 0
            Skipped = $skipped
            ErrorCode = if ($rollbackFailed) { "rollback_failed" } else { "commit_failed" }
            RecoveryPath = if ($rollbackFailed) { $stageRoot } else { "" }
        }
    } finally {
        if (-not $preserveStage -and (Test-Path -LiteralPath $stageRoot)) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Export-ProfileBundle {
    param([string]$OutputPath)
    $profileFiles = @(Get-UserProfileFiles)
    if ($profileFiles.Count -eq 0) {
        Update-Status "No profiles to export"
        return $null
    }
    if ($profileFiles.Count -gt $script:ProfileBundleMaxProfiles) {
        Update-Status "Profile export exceeds the $script:ProfileBundleMaxProfiles-profile bundle limit"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if (-not (Test-Path -LiteralPath $script:ProfileExportsPath)) { New-Item -ItemType Directory -Path $script:ProfileExportsPath -Force | Out-Null }
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = Join-Path $script:ProfileExportsPath "monitorcontrol-profiles-$timestamp.zip"
    } else {
        $parent = Split-Path -Path $OutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MonitorControlProfileExport-" + [guid]::NewGuid())
    $tempProfiles = Join-Path $tempRoot "profiles"
    try {
        New-Item -ItemType Directory -Path $tempProfiles -Force | Out-Null
        $exportedProfiles = @()
        foreach ($profileFile in $profileFiles) {
            $profileObject = Read-ProfileObject -Name $profileFile.BaseName
            if ($null -eq $profileObject) { continue }
            $safeName = $profileFile.BaseName
            $validation = Test-ImportedProfileObject -RawProfile $profileObject -ExpectedName $safeName
            if (-not $validation.Valid) {
                Update-Status "Profile export stopped because '$safeName' is invalid"
                return $null
            }
            $profileText = (($validation.Profile | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
            $profileBytes = [System.Text.Encoding]::UTF8.GetBytes($profileText)
            if ($profileBytes.Length -gt $script:ProfileBundleMaxEntryBytes) {
                Update-Status "Profile export stopped because '$safeName' exceeds the entry size limit"
                return $null
            }
            $relativeFile = "profiles/$safeName.json"
            [System.IO.File]::WriteAllBytes((Join-Path $tempProfiles "$safeName.json"), $profileBytes)
            $exportedProfiles += [PSCustomObject]@{
                Name = $safeName
                File = $relativeFile
                Sha256 = Get-ByteSha256Hex -Bytes $profileBytes
                UncompressedBytes = $profileBytes.Length
            }
        }

        if ($exportedProfiles.Count -eq 0) {
            Update-Status "No profiles to export"
            return $null
        }

        $manifest = [PSCustomObject]@{
            BundleSchemaVersion = $script:ProfileBundleSchemaVersion
            AppVersion = [string]$script:AppVersion
            ProfileSchemaVersion = $script:ProfileSchemaVersion
            ExportedAt = (Get-Date).ToString("o")
            ProfileCount = $exportedProfiles.Count
            Profiles = @($exportedProfiles)
        }
        $manifestText = (($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestText)
        if ($manifestBytes.Length -gt $script:ProfileBundleMaxManifestBytes) {
            Update-Status "Profile bundle manifest exceeds its size limit"
            return $null
        }
        [System.IO.File]::WriteAllBytes((Join-Path $tempRoot "manifest.json"), $manifestBytes)
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        $archive = [System.IO.Compression.ZipFile]::Open($OutputPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($declaration in $exportedProfiles) {
                $entry = $archive.CreateEntry([string]$declaration.File, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $tempProfiles "$($declaration.Name).json"))
                    $entryStream.Write($bytes, 0, $bytes.Length)
                } finally {
                    $entryStream.Dispose()
                }
            }
            $manifestEntry = $archive.CreateEntry("manifest.json", [System.IO.Compression.CompressionLevel]::Optimal)
            $manifestStream = $manifestEntry.Open()
            try {
                $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length)
            } finally {
                $manifestStream.Dispose()
            }
        } finally {
            $archive.Dispose()
        }
        Update-Status "Exported $($exportedProfiles.Count) profiles to $(Split-Path -Path $OutputPath -Leaf)"
        return $OutputPath
    } catch {
        Update-Status "Profile export failed"
        return $null
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Import-ProfileBundle {
    param(
        [string]$BundlePath,
        [ValidateSet("Prompt", "Replace", "Skip")] [string]$ConflictMode = "Prompt"
    )
    $plan = Get-ProfileBundleImportPlan -BundlePath $BundlePath
    if (-not $plan.Valid) {
        Update-Status "Profile bundle rejected: $($plan.Message)"
        return 0
    }

    $replaceCount = @($plan.Items | Where-Object Action -eq "Replace").Count
    if ($ConflictMode -eq "Prompt") {
        $replacePreview = Format-ProfileBundleImportPreview -Plan $plan -ConflictMode "Replace"
        if ($replaceCount -gt 0) {
            $skipPreview = Format-ProfileBundleImportPreview -Plan $plan -ConflictMode "Skip"
            $message = @"
Replace-conflicts plan:
$replacePreview

Skip-conflicts plan:
$skipPreview

Yes: create new profiles and replace conflicts.
No: create new profiles and skip conflicts.
Cancel: import nothing.

All accepted profiles are staged and committed together.
"@
            $choice = [System.Windows.MessageBox]::Show(
                $message,
                "Preview profile bundle import",
                [System.Windows.MessageBoxButton]::YesNoCancel,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($choice -eq [System.Windows.MessageBoxResult]::Cancel) {
                Update-Status "Profile bundle import cancelled"
                return 0
            }
            $ConflictMode = if ($choice -eq [System.Windows.MessageBoxResult]::Yes) { "Replace" } else { "Skip" }
        } else {
            $choice = [System.Windows.MessageBox]::Show(
                "$replacePreview`n`nImport these profiles as one transaction?",
                "Preview profile bundle import",
                [System.Windows.MessageBoxButton]::OKCancel,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($choice -ne [System.Windows.MessageBoxResult]::OK) {
                Update-Status "Profile bundle import cancelled"
                return 0
            }
            $ConflictMode = "Replace"
        }
    }
    $result = Invoke-ProfileBundleImportCommit -Plan $plan -ConflictMode $ConflictMode
    if (-not $result.Success) {
        if ($result.ErrorCode -eq "rollback_failed") {
            Update-Status "Profile import failed and rollback needs manual recovery"
        } else {
            Update-Status "Profile import failed; existing profiles were restored"
        }
        return 0
    }
    if ($result.Count -gt 0) {
        Update-ProfilesList
    }
    $status = if ($result.Count -gt 0) {
        "Imported $($result.Count) profiles from $(Split-Path -Path $BundlePath -Leaf)"
    } else {
        "No profiles imported"
    }
    if ($result.Skipped -gt 0) { $status = "$status ($($result.Skipped) conflicts skipped)" }
    Update-Status $status
    return [int]$result.Count
}

function Set-ProfileStoragePathBinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates process-local path bindings after a transactional cutover.')]
    param(
        [string]$Path,
        [string]$Mode,
        [string]$FallbackPath,
        [string]$PreviousPath,
        [switch]$Offline
    )
    $script:ProfilesPath = [System.IO.Path]::GetFullPath($Path)
    $script:ProfileStorageConfiguredPath = if ($Offline) { [System.IO.Path]::GetFullPath($script:ProfileStorageConfiguredPath) } else { $script:ProfilesPath }
    $script:ProfileStorageFallbackPath = if ([string]::IsNullOrWhiteSpace($FallbackPath)) { $script:ProfilesPath } else { [System.IO.Path]::GetFullPath($FallbackPath) }
    $script:ProfileStoragePreviousPath = [string]$PreviousPath
    $script:ProfileStorageMode = [string]$Mode
    $script:ProfileStorageOffline = [bool]$Offline
    $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
    $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
    $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
    $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
    $script:MonitorIdentitySettingsPath = Join-Path $script:ProfilesPath "monitor-identities.json"
    $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
}

function Set-ProfileStorageRoot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates path bindings only after callers validate storage.')]
    param([string]$Path, [string]$Mode = "Sync", [string]$FallbackPath = "", [string]$PreviousPath = "")
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Update-Status "Profile storage path is empty"
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            Update-Status "Profile storage is unavailable: $fullPath"
            return $false
        }
        Set-ProfileStoragePathBinding -Path $fullPath -Mode $Mode -FallbackPath $FallbackPath -PreviousPath $PreviousPath
        return $true
    } catch {
        Update-Status "Profile storage failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-ProfileStoragePointer {
    param(
        [string]$Mode,
        [string]$ProfilePath,
        [string]$FallbackPath,
        [string]$PreviousPath
    )
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:ProfileStorageSchemaVersion
        Mode = [string]$Mode
        ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath)
        FallbackPath = [System.IO.Path]::GetFullPath($FallbackPath)
        PreviousPath = [string]$PreviousPath
        UpdatedAt = [DateTime]::UtcNow.ToString("o")
    }
}

function Write-ProfileStoragePointer {
    param(
        [string]$Mode,
        [string]$ProfilePath,
        [string]$FallbackPath,
        [string]$PreviousPath
    )
    if (-not (Test-Path -LiteralPath $script:DefaultProfilesPath)) {
        New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null
    }
    $pointer = Get-ProfileStoragePointer -Mode $Mode -ProfilePath $ProfilePath -FallbackPath $FallbackPath -PreviousPath $PreviousPath
    return (Write-JsonFileSafely -Path $script:ProfileStorageSettingsPath -Data $pointer -Depth 4)
}

function Save-ProfileStorageSettings {
    $configuredPath = if ($script:ProfileStorageOffline) { $script:ProfileStorageConfiguredPath } else { $script:ProfilesPath }
    return (Write-ProfileStoragePointer -Mode $script:ProfileStorageMode -ProfilePath $configuredPath -FallbackPath $script:ProfileStorageFallbackPath -PreviousPath $script:ProfileStoragePreviousPath)
}

function Test-ProfileStorageWriteAllowed {
    param([string]$Operation = "change profile storage", [switch]$SuppressStatus)
    if (-not $script:ProfileStorageOffline) { return $true }
    if (-not $SuppressStatus) {
        Update-Status "Profile storage is offline; $Operation is read-only until storage is reconnected or migrated"
    }
    return $false
}

function Get-ProfileStorageMigrationPlan {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [ValidateSet("Copy", "Merge")] [string]$ConflictMode,
        [string]$MigrationId = ""
    )
    $failure = {
        param([string]$Code, [string]$Message)
        return [PSCustomObject]@{
            Valid = $false
            ErrorCode = $Code
            Message = $Message
            Items = @()
            Conflicts = @()
        }
    }
    try {
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($DestinationRoot)) {
            return (& $failure "invalid_path" "Source and destination storage paths are required")
        }
        $sourceFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($SourceRoot))
        $destinationFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DestinationRoot))
        if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Container)) {
            return (& $failure "source_unavailable" "Source profile storage is unavailable")
        }
        if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Container)) {
            return (& $failure "destination_unavailable" "Destination profile storage is unavailable")
        }
        if ([string]::IsNullOrWhiteSpace($MigrationId)) {
            $MigrationId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), [guid]::NewGuid().ToString("N").Substring(0, 8)
        }
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceFullPath -File -Filter "*.json" -ErrorAction Stop |
            Where-Object { $_.Name -ne "profile-storage.json" } |
            Sort-Object -Property Name)
        $destinationFiles = @(Get-ChildItem -LiteralPath $destinationFullPath -File -Filter "*.json" -ErrorAction Stop |
            Where-Object { $_.Name -ne "profile-storage.json" } |
            Sort-Object -Property Name)
        if ($sourceFiles.Count -gt 500 -or $destinationFiles.Count -gt 500) {
            return (& $failure "too_many_files" "Profile storage exceeds the 500-file migration limit")
        }
        $sourceBytes = [int64](($sourceFiles | Measure-Object -Property Length -Sum).Sum)
        $destinationBytes = [int64](($destinationFiles | Measure-Object -Property Length -Sum).Sum)
        if ($sourceBytes -gt 67108864 -or $destinationBytes -gt 67108864) {
            return (& $failure "storage_too_large" "Profile storage exceeds the 64 MiB migration limit")
        }
        $sourceByName = @{}
        $destinationByName = @{}
        foreach ($sourceFile in $sourceFiles) { $sourceByName[[string]$sourceFile.Name] = $sourceFile }
        foreach ($destinationFile in $destinationFiles) { $destinationByName[[string]$destinationFile.Name] = $destinationFile }
        $items = @()
        foreach ($sourceFile in $sourceFiles) {
            $relativePath = [string]$sourceFile.Name
            $sourceHash = Get-FileSha256Hex -Path $sourceFile.FullName
            $destinationFile = if ($destinationByName.ContainsKey($relativePath)) { $destinationByName[$relativePath] } else { $null }
            if ($null -eq $destinationFile) {
                $items += [PSCustomObject]@{
                    RelativePath = $relativePath; Action = "Copy"; SourcePath = $sourceFile.FullName
                    DestinationPath = Join-Path $destinationFullPath $relativePath; SourceHash = $sourceHash
                    DestinationHash = ""; DestinationExists = $false; ConflictCopyRelativePath = ""
                }
                continue
            }
            $destinationHash = Get-FileSha256Hex -Path $destinationFile.FullName
            if ($sourceHash -ceq $destinationHash) {
                $items += [PSCustomObject]@{
                    RelativePath = $relativePath; Action = "Same"; SourcePath = $sourceFile.FullName
                    DestinationPath = $destinationFile.FullName; SourceHash = $sourceHash
                    DestinationHash = $destinationHash; DestinationExists = $true; ConflictCopyRelativePath = ""
                }
                continue
            }
            $conflictRole = if ($ConflictMode -eq "Copy") { "destination" } else { "source" }
            $conflictRelativePath = Join-Path (Join-Path (Join-Path "conflicts" $MigrationId) $conflictRole) $relativePath
            $items += [PSCustomObject]@{
                RelativePath = $relativePath; Action = "Conflict"; SourcePath = $sourceFile.FullName
                DestinationPath = $destinationFile.FullName; SourceHash = $sourceHash
                DestinationHash = $destinationHash; DestinationExists = $true
                ConflictCopyRelativePath = $conflictRelativePath
            }
        }
        foreach ($destinationFile in $destinationFiles) {
            if ($sourceByName.ContainsKey([string]$destinationFile.Name)) { continue }
            $items += [PSCustomObject]@{
                RelativePath = [string]$destinationFile.Name; Action = "Keep"; SourcePath = ""
                DestinationPath = $destinationFile.FullName; SourceHash = ""
                DestinationHash = Get-FileSha256Hex -Path $destinationFile.FullName
                DestinationExists = $true; ConflictCopyRelativePath = ""
            }
        }
        return [PSCustomObject]@{
            Valid = $true
            ErrorCode = ""
            Message = ""
            SourceRoot = $sourceFullPath
            DestinationRoot = $destinationFullPath
            ConflictMode = $ConflictMode
            MigrationId = $MigrationId
            Items = @($items)
            Conflicts = @($items | Where-Object Action -eq "Conflict")
        }
    } catch {
        return (& $failure "inspection_failed" "Profile storage could not be inspected safely")
    }
}

function Format-ProfileStorageMigrationPreview {
    param($Plan)
    if ($null -eq $Plan -or -not $Plan.Valid) {
        return "Migration unavailable: $(if ($Plan) { $Plan.Message } else { 'invalid plan' })"
    }
    $copies = @($Plan.Items | Where-Object Action -eq "Copy")
    $same = @($Plan.Items | Where-Object Action -eq "Same")
    $kept = @($Plan.Items | Where-Object Action -eq "Keep")
    $conflicts = @($Plan.Conflicts)
    $modeText = if ($Plan.ConflictMode -eq "Copy") {
        "COPY: source files become canonical; conflicting destination files are preserved."
    } else {
        "MERGE: destination files stay canonical; conflicting source files are preserved."
    }
    $lines = @(
        $modeText,
        "Copy missing: $($copies.Count)",
        "Identical: $($same.Count)",
        "Destination-only kept: $($kept.Count)",
        "Conflicts: $($conflicts.Count)"
    )
    foreach ($conflict in $conflicts) {
        $lines += "  $($conflict.RelativePath) -> $($conflict.ConflictCopyRelativePath)"
    }
    return ($lines -join [Environment]::NewLine)
}

function Invoke-ProfileStorageMigrationCommit {
    param(
        $Plan,
        [string]$DestinationMode,
        [scriptblock]$AfterDataCommit,
        [scriptblock]$AfterPointerWrite
    )
    if ($null -eq $Plan -or -not $Plan.Valid) {
        return [PSCustomObject]@{ Success = $false; ErrorCode = "invalid_plan"; ConflictCount = 0; RecoveryPath = "" }
    }
    $previousBinding = [PSCustomObject]@{
        ProfilesPath = [string]$script:ProfilesPath
        ConfiguredPath = [string]$script:ProfileStorageConfiguredPath
        FallbackPath = [string]$script:ProfileStorageFallbackPath
        PreviousPath = [string]$script:ProfileStoragePreviousPath
        Mode = [string]$script:ProfileStorageMode
        Offline = [bool]$script:ProfileStorageOffline
    }
    $stageRoot = Join-Path $Plan.DestinationRoot (".monitorcontrol-storage-" + [guid]::NewGuid().ToString("N"))
    $payloadRoot = Join-Path $stageRoot "payload"
    $rollbackRoot = Join-Path $stageRoot "rollback"
    $committed = New-Object System.Collections.Generic.List[object]
    $rollbackFailed = $false
    $preserveStage = $false
    $pointerPath = [string]$script:ProfileStorageSettingsPath
    $pointerBackupPath = "$pointerPath.bak"
    $pointerSnapshot = [PSCustomObject]@{
        Path = $pointerPath
        Existed = Test-Path -LiteralPath $pointerPath -PathType Leaf
        Bytes = if (Test-Path -LiteralPath $pointerPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($pointerPath) } else { [byte[]]@() }
    }
    $pointerBackupSnapshot = [PSCustomObject]@{
        Path = $pointerBackupPath
        Existed = Test-Path -LiteralPath $pointerBackupPath -PathType Leaf
        Bytes = if (Test-Path -LiteralPath $pointerBackupPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($pointerBackupPath) } else { [byte[]]@() }
    }
    $restoreSnapshot = {
        param($Snapshot)
        if ([bool]$Snapshot.Existed) {
            $restoreTemp = "$($Snapshot.Path).restore-$([guid]::NewGuid().ToString('N')).tmp"
            [System.IO.File]::WriteAllBytes($restoreTemp, [byte[]]$Snapshot.Bytes)
            if (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) {
                $replacedBytesPath = "$($Snapshot.Path).replaced-$([guid]::NewGuid().ToString('N')).tmp"
                [System.IO.File]::Replace($restoreTemp, $Snapshot.Path, $replacedBytesPath, $true)
                if (Test-Path -LiteralPath $replacedBytesPath) { Remove-Item -LiteralPath $replacedBytesPath -Force }
            } else {
                [System.IO.File]::Move($restoreTemp, $Snapshot.Path)
            }
        } elseif (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) {
            Remove-Item -LiteralPath $Snapshot.Path -Force
        }
    }
    try {
        if (-not (Test-Path -LiteralPath $Plan.SourceRoot -PathType Container) -or -not (Test-Path -LiteralPath $Plan.DestinationRoot -PathType Container)) {
            throw "storage_unavailable"
        }
        foreach ($item in @($Plan.Items)) {
            if ($item.SourcePath) {
                if (-not (Test-Path -LiteralPath $item.SourcePath -PathType Leaf) -or (Get-FileSha256Hex -Path $item.SourcePath) -cne [string]$item.SourceHash) {
                    throw "source_changed"
                }
            }
            $destinationExists = Test-Path -LiteralPath $item.DestinationPath -PathType Leaf
            if ([bool]$item.DestinationExists -ne $destinationExists) { throw "destination_changed" }
            if ($destinationExists -and (Get-FileSha256Hex -Path $item.DestinationPath) -cne [string]$item.DestinationHash) {
                throw "destination_changed"
            }
        }
        New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
        $payloads = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($Plan.Items)) {
            if ($item.Action -eq "Copy" -or ($item.Action -eq "Conflict" -and $Plan.ConflictMode -eq "Copy")) {
                $payloads.Add([PSCustomObject]@{
                    SourcePath = [string]$item.SourcePath
                    DestinationPath = [string]$item.DestinationPath
                    SourceHash = [string]$item.SourceHash
                    ExpectedDestinationHash = [string]$item.DestinationHash
                    ExpectedDestinationExists = [bool]$item.DestinationExists
                    RelativePath = [string]$item.RelativePath
                })
            }
            if ($item.Action -eq "Conflict") {
                $conflictSourcePath = if ($Plan.ConflictMode -eq "Copy") { [string]$item.DestinationPath } else { [string]$item.SourcePath }
                $conflictSourceHash = if ($Plan.ConflictMode -eq "Copy") { [string]$item.DestinationHash } else { [string]$item.SourceHash }
                $payloads.Add([PSCustomObject]@{
                    SourcePath = $conflictSourcePath
                    DestinationPath = Join-Path $Plan.DestinationRoot ([string]$item.ConflictCopyRelativePath)
                    SourceHash = $conflictSourceHash
                    ExpectedDestinationHash = ""
                    ExpectedDestinationExists = $false
                    RelativePath = [string]$item.ConflictCopyRelativePath
                })
            }
        }
        $stageIndex = 0
        foreach ($payload in $payloads) {
            $stageIndex++
            $stagePath = Join-Path $payloadRoot ("{0:D4}.payload" -f $stageIndex)
            [System.IO.File]::Copy($payload.SourcePath, $stagePath, $false)
            if ((Get-FileSha256Hex -Path $stagePath) -cne [string]$payload.SourceHash) { throw "stage_verification_failed" }
            $payload | Add-Member -NotePropertyName StagePath -NotePropertyValue $stagePath -Force
        }
        $commitIndex = 0
        foreach ($payload in $payloads) {
            $commitIndex++
            $destinationDirectory = Split-Path -Path $payload.DestinationPath -Parent
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }
            $adjacentTemp = Join-Path $destinationDirectory (".$([System.IO.Path]::GetFileName($payload.DestinationPath)).$([guid]::NewGuid().ToString('N')).tmp")
            [System.IO.File]::Copy($payload.StagePath, $adjacentTemp, $false)
            $rollbackPath = Join-Path $rollbackRoot ("{0:D4}.rollback" -f $commitIndex)
            if ([bool]$payload.ExpectedDestinationExists) {
                if (-not (Test-Path -LiteralPath $payload.DestinationPath -PathType Leaf) -or
                    (Get-FileSha256Hex -Path $payload.DestinationPath) -cne [string]$payload.ExpectedDestinationHash) {
                    Remove-Item -LiteralPath $adjacentTemp -Force -ErrorAction SilentlyContinue
                    throw "destination_changed"
                }
                [System.IO.File]::Replace($adjacentTemp, $payload.DestinationPath, $rollbackPath, $true)
                $journalAction = "Replace"
            } else {
                if (Test-Path -LiteralPath $payload.DestinationPath) {
                    Remove-Item -LiteralPath $adjacentTemp -Force -ErrorAction SilentlyContinue
                    throw "destination_changed"
                }
                [System.IO.File]::Move($adjacentTemp, $payload.DestinationPath)
                $journalAction = "Create"
            }
            $committed.Add([PSCustomObject]@{
                Action = $journalAction
                DestinationPath = [string]$payload.DestinationPath
                RollbackPath = $rollbackPath
                ExistingHash = [string]$payload.ExpectedDestinationHash
            })
            if ($AfterDataCommit) { & $AfterDataCommit $committed.Count $payload }
        }
        if (-not (Write-ProfileStoragePointer -Mode $DestinationMode -ProfilePath $Plan.DestinationRoot -FallbackPath $Plan.SourceRoot -PreviousPath $Plan.SourceRoot)) {
            throw "pointer_write_failed"
        }
        if ($AfterPointerWrite) { & $AfterPointerWrite }
        if (-not (Set-ProfileStorageRoot -Path $Plan.DestinationRoot -Mode $DestinationMode -FallbackPath $Plan.SourceRoot -PreviousPath $Plan.SourceRoot)) {
            throw "binding_failed"
        }
        return [PSCustomObject]@{
            Success = $true
            ErrorCode = ""
            ConflictCount = @($Plan.Conflicts).Count
            CopiedCount = $payloads.Count
            RecoveryPath = ""
        }
    } catch {
        try { & $restoreSnapshot $pointerSnapshot } catch { $rollbackFailed = $true }
        try { & $restoreSnapshot $pointerBackupSnapshot } catch { $rollbackFailed = $true }
        for ($index = $committed.Count - 1; $index -ge 0; $index--) {
            $entry = $committed[$index]
            try {
                if ($entry.Action -eq "Replace") {
                    if (-not (Test-Path -LiteralPath $entry.RollbackPath -PathType Leaf)) { throw "rollback_missing" }
                    $failedPath = "$($entry.RollbackPath).failed"
                    try {
                        [System.IO.File]::Replace($entry.RollbackPath, $entry.DestinationPath, $failedPath, $true)
                        if (Test-Path -LiteralPath $failedPath) { Remove-Item -LiteralPath $failedPath -Force }
                    } catch {
                        [System.IO.File]::Copy($entry.RollbackPath, $entry.DestinationPath, $true)
                    }
                } elseif (Test-Path -LiteralPath $entry.DestinationPath -PathType Leaf) {
                    Remove-Item -LiteralPath $entry.DestinationPath -Force
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        Set-ProfileStoragePathBinding -Path $previousBinding.ProfilesPath -Mode $previousBinding.Mode -FallbackPath $previousBinding.FallbackPath -PreviousPath $previousBinding.PreviousPath -Offline:$previousBinding.Offline
        $script:ProfileStorageConfiguredPath = $previousBinding.ConfiguredPath
        foreach ($entry in $committed) {
            if ($entry.Action -eq "Replace") {
                if (-not (Test-Path -LiteralPath $entry.DestinationPath -PathType Leaf) -or
                    (Get-FileSha256Hex -Path $entry.DestinationPath) -cne [string]$entry.ExistingHash) {
                    $rollbackFailed = $true
                }
            } elseif (Test-Path -LiteralPath $entry.DestinationPath -PathType Leaf) {
                $rollbackFailed = $true
            }
        }
        $preserveStage = $rollbackFailed
        return [PSCustomObject]@{
            Success = $false
            ErrorCode = if ($rollbackFailed) { "rollback_failed" } else { "commit_failed" }
            ConflictCount = @($Plan.Conflicts).Count
            CopiedCount = 0
            RecoveryPath = if ($rollbackFailed) { $stageRoot } else { "" }
        }
    } finally {
        if (-not $preserveStage -and (Test-Path -LiteralPath $stageRoot -PathType Container)) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ProfileStorageMigration {
    param(
        [string]$DestinationRoot,
        [string]$DestinationMode,
        [ValidateSet("Prompt", "Copy", "Merge")] [string]$ConflictMode = "Prompt"
    )
    $migrationId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), [guid]::NewGuid().ToString("N").Substring(0, 8)
    $copyPlan = Get-ProfileStorageMigrationPlan -SourceRoot $script:ProfilesPath -DestinationRoot $DestinationRoot -ConflictMode "Copy" -MigrationId $migrationId
    $mergePlan = Get-ProfileStorageMigrationPlan -SourceRoot $script:ProfilesPath -DestinationRoot $DestinationRoot -ConflictMode "Merge" -MigrationId $migrationId
    if (-not $copyPlan.Valid -or -not $mergePlan.Valid) {
        $message = if (-not $copyPlan.Valid) { $copyPlan.Message } else { $mergePlan.Message }
        Update-Status "Profile storage migration unavailable: $message"
        return [PSCustomObject]@{ Success = $false; ErrorCode = "invalid_plan"; Cancelled = $false }
    }
    if ($ConflictMode -eq "Prompt") {
        $copyPreview = Format-ProfileStorageMigrationPreview -Plan $copyPlan
        $mergePreview = Format-ProfileStorageMigrationPreview -Plan $mergePlan
        $choice = [System.Windows.MessageBox]::Show(
            "Source: $($copyPlan.SourceRoot)`nDestination: $($copyPlan.DestinationRoot)`n`n$copyPreview`n`n$mergePreview`n`nYes: Copy`nNo: Merge`nCancel: no changes",
            "Preview profile storage migration",
            [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($choice -eq [System.Windows.MessageBoxResult]::Cancel) {
            Update-Status "Profile storage migration cancelled"
            return [PSCustomObject]@{ Success = $false; ErrorCode = "cancelled"; Cancelled = $true }
        }
        $ConflictMode = if ($choice -eq [System.Windows.MessageBoxResult]::Yes) { "Copy" } else { "Merge" }
    }
    $selectedPlan = if ($ConflictMode -eq "Copy") { $copyPlan } else { $mergePlan }
    $result = Invoke-ProfileStorageMigrationCommit -Plan $selectedPlan -DestinationMode $DestinationMode
    if ($result.Success) {
        Reload-ProfileStorageState
        Update-Status "Profile storage migrated ($($result.CopiedCount) files, $($result.ConflictCount) conflict copies)"
    } elseif ($result.ErrorCode -eq "rollback_failed") {
        Update-Status "Profile storage migration failed; rollback needs manual recovery at $($result.RecoveryPath)"
    } else {
        Update-Status "Profile storage migration failed; the previous library was restored"
    }
    return $result
}

function Reset-ProfileBackedAutomationState {
    $script:AppProfileEnabled = $false
    $script:AppProfileRules = @()
    $script:LastForegroundExe = $null
    $script:LastAppliedAppProfileKey = $null
    $script:ProfileScheduleEnabled = $false
    $script:ProfileSchedules = @()
    $script:LastAppliedScheduleKey = $null
    $script:IdleDimEnabled = $false
    $script:IdleDimMinutes = 10
    $script:IdleDimBrightness = 20
    $script:IdleDimRestoreOnActivity = $true
    $script:IdleDimActive = $false
    $script:IdleDimPreviousBrightness = $null
    $script:BatteryProfileEnabled = $false
    $script:BatteryBrightness = 35
    $script:AcBrightness = 75
    $script:LastPowerLineStatus = $null
    $script:ProfileCycleIndex = -1
    $script:MonitorIdentityRecords = @{}
}

function Update-ProfileStorageControls {
    if ($null -eq $profileStorageStatusText) { return }
    $mode = if ($script:ProfileStorageMode -eq "Local") { "Local" } else { "Sync" }
    if ($script:ProfileStorageOffline) {
        $profileStorageStatusText.Text = "Offline - $script:ProfileStorageConfiguredPath"
        $profileStorageStatusText.ToolTip = "Configured: $script:ProfileStorageConfiguredPath`nShowing read-only fallback: $script:ProfilesPath"
        $profileStorageStatusText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "DangerBrush")
    } else {
        $profileStorageStatusText.Text = "$mode - $script:ProfilesPath"
        $profileStorageStatusText.ToolTip = $script:ProfilesPath
        $profileStorageStatusText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "MutedTextBrush")
    }
    $writeEnabled = -not $script:ProfileStorageOffline
    foreach ($control in @(
        $profileNameBox, $saveProfileBtn, $deleteProfileBtn, $importProfilesBtn,
        $monitorLabelBox, $monitorLabelSaveBtn, $monitorLabelResetBtn,
        $appProfileEnabledCheckbox, $appProfileExeBox, $appProfileCaptureBtn, $appProfileProfileCombo, $appProfileRiskyConsentCheckbox, $appProfileAddBtn, $appProfileRemoveBtn,
        $scheduleEnabledCheckbox, $scheduleTimeBox, $scheduleProfileCombo, $scheduleRiskyConsentCheckbox, $scheduleAddBtn, $scheduleRemoveBtn,
        $idleDimEnabledCheckbox, $idleDimMinutesBox, $idleDimBrightnessBox, $idleDimRestoreCheckbox, $idleDimSaveBtn,
        $batteryProfileEnabledCheckbox, $batteryBrightnessBox, $acBrightnessBox, $batteryProfileSaveBtn
    )) {
        if ($null -ne $control) { $control.IsEnabled = $writeEnabled }
    }
}

function Reload-ProfileStorageState {
    Reset-ProfileBackedAutomationState
    Load-AppProfileRules
    Load-ProfileSchedules
    Load-IdleDimSettings
    Load-BatteryProfileSettings
    Load-MonitorIdentitySettings
    Update-MonitorIdentityAssignments
    Update-ProfilesList
    Update-AppProfileControls
    Update-ScheduleControls
    Update-IdleDimControls
    Update-BatteryProfileControls
    Draw-MonitorLayout
    Load-MonitorSettings
    Start-AppProfileWatcher
    Start-ProfileScheduleWatcher
    Start-IdleDimWatcher
    Start-BatteryProfileWatcher
    Update-ProfileStorageControls
}

function Normalize-AppExeName {
    param([string]$ExeName)
    $name = $ExeName.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
    $name = [System.IO.Path]::GetFileName($name)
    if ($name -notmatch '\.exe$') { $name = "$name.exe" }
    return $name.ToLowerInvariant()
}

function Get-ForegroundProcessExe {
    $hwnd = [MonitorAPI]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $processId = [uint32]0
    [MonitorAPI]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
    if ($processId -eq 0) { return $null }
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        return (Normalize-AppExeName -ExeName "$($process.ProcessName).exe")
    } catch {
        return $null
    }
}

function Load-AppProfileRules {
    $script:AppProfileEnabled = $false
    $script:AppProfileRules = @()
    if (-not (Test-Path -LiteralPath $script:AppProfileRulesPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:AppProfileRulesPath -Label "App profile rules" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        if (-not (Test-SettingsDocumentSupported -Name "AppProfileRules" -Document $data -Label "App profile rules")) { return }
        $script:AppProfileEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $exe = Normalize-AppExeName -ExeName ([string]$rule.Exe)
            $profileObject = ([string]$rule.Profile).Trim()
            $allowRiskyVcp = $rule.PSObject.Properties.Name -contains "AllowRiskyVcp" -and [bool]$rule.AllowRiskyVcp
            if ($exe -and $profileObject) { $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profileObject; AllowRiskyVcp = $allowRiskyVcp } }
        }
    } catch {
        Update-Status "App profile rules could not be loaded"
    }
}

function Save-AppProfileRules {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "application rule changes")) { return $false }
    $payload = [PSCustomObject]@{
        SchemaVersion = [int]$script:AppProfileRulesSchemaVersion
        Enabled = [bool]$script:AppProfileEnabled
        Rules = @($script:AppProfileRules)
    }
    return (Write-JsonFileSafely -Path $script:AppProfileRulesPath -Data $payload -Depth 4)
}

function Update-ProfileCombo {
    param($Combo)
    if ($null -eq $Combo) { return }
    $selected = if ($Combo.SelectedItem) { [string]$Combo.SelectedItem } else { $null }
    $Combo.Items.Clear()
    foreach ($profileObject in @($profilesList.Items)) { $Combo.Items.Add([string]$profileObject) | Out-Null }
    if ($selected -and $Combo.Items.Contains($selected)) {
        $Combo.SelectedItem = $selected
    } elseif ($Combo.Items.Count -gt 0) {
        $Combo.SelectedIndex = 0
    }
}

function Update-AppProfileProfileCombo {
    Update-ProfileCombo -Combo $appProfileProfileCombo
    Update-ProfileCombo -Combo $scheduleProfileCombo
}

function Update-AppProfileControls {
    if ($null -eq $appProfileEnabledCheckbox) { return }
    $script:UpdatingAppProfileUI = $true
    try {
        $appProfileRulesList.Items.Clear()
        foreach ($rule in ($script:AppProfileRules | Sort-Object -Property Exe)) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $consentSuffix = if ([bool]$rule.AllowRiskyVcp) { " [risky writes allowed]" } else { "" }
            $item.Content = "$($rule.Exe) -> $($rule.Profile)$consentSuffix"
            $item.Tag = $rule.Exe
            $appProfileRulesList.Items.Add($item) | Out-Null
        }
        $appProfileEnabledCheckbox.IsChecked = [bool]$script:AppProfileEnabled
        $appProfileStatusText.Text = if ($script:AppProfileEnabled) { "Watching" } else { "Off" }
        Update-AppProfileProfileCombo
    } finally {
        $script:UpdatingAppProfileUI = $false
    }
}

function Get-ProfileVcpWritePlan {
    param($ProfileData, $ActiveProfile)
    $values = [PSCustomObject]@{
        Brightness = Get-ProfileIntValue -Object $ActiveProfile -Property "Brightness" -Default $ProfileData.Brightness
        Contrast = Get-ProfileIntValue -Object $ActiveProfile -Property "Contrast" -Default $ProfileData.Contrast
        Red = Get-ProfileIntValue -Object $ActiveProfile -Property "Red" -Default $ProfileData.Red
        Green = Get-ProfileIntValue -Object $ActiveProfile -Property "Green" -Default $ProfileData.Green
        Blue = Get-ProfileIntValue -Object $ActiveProfile -Property "Blue" -Default $ProfileData.Blue
        Gamma = Get-ProfileIntValue -Object $ActiveProfile -Property "Gamma" -Default $ProfileData.Gamma
        GammaRed = Get-ProfileIntValue -Object $ActiveProfile -Property "GammaRed" -Default $ProfileData.GammaRed
        GammaGreen = Get-ProfileIntValue -Object $ActiveProfile -Property "GammaGreen" -Default $ProfileData.GammaGreen
        GammaBlue = Get-ProfileIntValue -Object $ActiveProfile -Property "GammaBlue" -Default $ProfileData.GammaBlue
    }
    $codeValues = @(
        [PSCustomObject]@{ Code = [int][MonitorAPI]::VCP_BRIGHTNESS; Value = [uint32]$values.Brightness },
        [PSCustomObject]@{ Code = [int][MonitorAPI]::VCP_CONTRAST; Value = [uint32]$values.Contrast },
        [PSCustomObject]@{ Code = [int][MonitorAPI]::VCP_RED_GAIN; Value = [uint32]$values.Red },
        [PSCustomObject]@{ Code = [int][MonitorAPI]::VCP_GREEN_GAIN; Value = [uint32]$values.Green },
        [PSCustomObject]@{ Code = [int][MonitorAPI]::VCP_BLUE_GAIN; Value = [uint32]$values.Blue }
    )
    $targets = if ($script:ApplyToAll) {
        @($script:PhysicalMonitors)
    } elseif ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        @($script:PhysicalMonitors[$script:CurrentMonitorIndex])
    } else {
        @()
    }
    $operations = @()
    $skippedUnsupported = 0
    $wmiIncluded = $false
    foreach ($monitor in $targets) {
        if ($monitor.Handle -eq [IntPtr]::Zero) {
            if (-not $wmiIncluded -and $script:WmiBrightnessAvailable) {
                $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32][Math]::Max(0, [Math]::Min(100, [int]$values.Brightness))) -Backend "WMI"
                $wmiIncluded = $true
            }
            continue
        }
        foreach ($codeValue in $codeValues) {
            $rawValue = [uint32](ConvertTo-VcpRawValue -Percent ([double]$codeValue.Value) -Maximum (Get-VcpMaximumForMonitor -Monitor $monitor -Code ([int]$codeValue.Code)))
            if (Test-MonitorSupportsVcpValue -Monitor $monitor -Code ([int]$codeValue.Code) -Value ([int]$rawValue)) {
                $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([int]$codeValue.Code) -Value $rawValue
            } else {
                $skippedUnsupported++
            }
        }
    }
    return [PSCustomObject]@{
        Values = $values
        Operations = @($operations)
        SkippedUnsupported = $skippedUnsupported
    }
}

function Complete-ProfileApply {
    param($Transaction, $Plan, [string]$Name, [string]$Reason, [int]$TargetIndex, [bool]$TargetMissing)
    if (-not [bool]$Transaction.Success) {
        Update-Status "Profile '$Name' failed ($($Transaction.Outcome)); rollback: $($Transaction.Rollback)"
        return $false
    }
    try {
        $script:UpdatingUI = $true
        $brightnessRaw = ConvertTo-SelectedRawValue -Percent $Plan.Values.Brightness -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
        $contrastRaw = ConvertTo-SelectedRawValue -Percent $Plan.Values.Contrast -Code ([int][MonitorAPI]::VCP_CONTRAST)
        $redRaw = ConvertTo-SelectedRawValue -Percent $Plan.Values.Red -Code ([int][MonitorAPI]::VCP_RED_GAIN)
        $greenRaw = ConvertTo-SelectedRawValue -Percent $Plan.Values.Green -Code ([int][MonitorAPI]::VCP_GREEN_GAIN)
        $blueRaw = ConvertTo-SelectedRawValue -Percent $Plan.Values.Blue -Code ([int][MonitorAPI]::VCP_BLUE_GAIN)
        $brightnessSlider.Value = $brightnessRaw; $brightnessValue.Text = $brightnessRaw
        $contrastSlider.Value = $contrastRaw; $contrastValue.Text = $contrastRaw
        $redSlider.Value = $redRaw; $redValue.Text = $redRaw
        $greenSlider.Value = $greenRaw; $greenValue.Text = $greenRaw
        $blueSlider.Value = $blueRaw; $blueValue.Text = $blueRaw
        if ($Plan.Values.Gamma) { $gammaSlider.Value = $Plan.Values.Gamma; $gammaValue.Text = ($Plan.Values.Gamma / 100).ToString("F2") }
        if ($Plan.Values.GammaRed) {
            $gammaRedSlider.Value = $Plan.Values.GammaRed
            $gammaGreenSlider.Value = $Plan.Values.GammaGreen
            $gammaBlueSlider.Value = $Plan.Values.GammaBlue
            Set-GammaRamp -Gamma ($Plan.Values.Gamma/100) -RedMult ($Plan.Values.GammaRed/100) -GreenMult ($Plan.Values.GammaGreen/100) -BlueMult ($Plan.Values.GammaBlue/100)
        }
    } catch {
        Update-Status "Profile '$Name' completed its hardware writes but the UI refresh failed"
        return $false
    } finally {
        $script:UpdatingUI = $false
    }
    $profilesList.SelectedItem = $Name
    $verificationSuffix = switch ([string]$Transaction.Outcome) {
        "Unverified" { " (write applied; some readbacks unavailable)" }
        "UnreliableReadback" { " (write applied; monitor readback is unreliable)" }
        "VerificationOff" { " (write applied; verification off)" }
        "VerifiedAfterRetry" { " (verified after delayed re-read)" }
        default { " (verified)" }
    }
    $capabilitySuffix = if ($Plan.SkippedUnsupported -gt 0) { "; $($Plan.SkippedUnsupported) unsupported values skipped" } else { "" }
    if ($TargetIndex -ge 0 -and $TargetIndex -lt $script:PhysicalMonitors.Count) {
        Update-Status "$Reason '$Name' -> $(Get-MonitorDisplayLabel -Monitor $script:PhysicalMonitors[$TargetIndex])$verificationSuffix$capabilitySuffix"
    } elseif ($TargetMissing) {
        Update-Status "$Reason '$Name' (saved monitor missing; current monitor used)$verificationSuffix$capabilitySuffix"
    } else {
        Update-Status "$Reason '$Name'$verificationSuffix$capabilitySuffix"
    }
    Update-TrayPopupState
    Update-TrayIconText
    return $true
}

function Apply-ProfileByName {
    param(
        [string]$Name,
        [string]$Reason = "Loaded",
        [string]$AutomationRuleId = "",
        [switch]$AllowRiskyAutomation
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $p = Read-ProfileObject -Name $Name
    if (-not $p) {
        Update-Status "Profile '$Name' not found"
        return $false
    }
    $active = $p
    $targetIndex = -1
    $targetMissing = $false
    if (-not $script:ApplyToAll) {
        foreach ($setting in @($p.MonitorSettings)) {
            $candidateIndex = Find-MonitorIndexByIdentity -IdentityKey ([string]$setting.IdentityKey)
            if ($candidateIndex -ge 0) {
                $active = $setting
                $targetIndex = $candidateIndex
                break
            }
        }
        if ($targetIndex -lt 0 -and -not [string]::IsNullOrWhiteSpace([string]$p.MonitorIdentityKey)) { $targetMissing = $true }
        if ($targetIndex -ge 0 -and $targetIndex -ne $script:CurrentMonitorIndex) {
            $script:CurrentMonitorIndex = $targetIndex
            Draw-MonitorLayout
            Update-CapabilityControls -Monitor $script:PhysicalMonitors[$targetIndex]
        }
    }
    $plan = Get-ProfileVcpWritePlan -ProfileData $p -ActiveProfile $active
    $riskyOperations = @($plan.Operations | Where-Object { Test-VcpWriteRequiresSafetyConsent -Code ([int]$_.Code) })
    if ($riskyOperations.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($AutomationRuleId) -and -not $AllowRiskyAutomation) {
            Update-Status "Automation rule '$AutomationRuleId' has no risky-write consent"
            return $false
        }
        foreach ($operation in $riskyOperations) {
            if (-not (Test-VcpWriteEnabledForMonitor -Monitor $operation.Monitor)) {
                Update-Status "Risky profile write blocked for $($operation.MonitorName)"
                return $false
            }
        }
    }
    if ($plan.Operations.Count -eq 0) {
        Update-Status "Profile '$Name' has no compatible hardware write target"
        return $false
    }
    $completionPlan = $plan
    $completionName = $Name
    $completionReason = $Reason
    $completionTargetIndex = $targetIndex
    $completionTargetMissing = $targetMissing
    $completion = {
        param($transaction)
        Complete-ProfileApply -Transaction $transaction -Plan $completionPlan -Name $completionName -Reason $completionReason -TargetIndex $completionTargetIndex -TargetMissing $completionTargetMissing | Out-Null
    }.GetNewClosure()
    return (Start-VerifiedVcpTransactionWorker -Operations $plan.Operations -ActionLabel "Apply profile '$Name'" -CompletionAction $completion)
}

function Invoke-AppProfileCheck {
    if (-not $script:AppProfileEnabled -or $script:AppProfileRules.Count -eq 0) { return }
    $exe = Get-ForegroundProcessExe
    if (-not $exe) { return }
    if ($exe -eq $script:LastForegroundExe) { return }
    $script:LastForegroundExe = $exe
    $rule = $script:AppProfileRules | Where-Object { $_.Exe -eq $exe } | Select-Object -First 1
    if ($null -eq $rule) { return }
    $key = "$($rule.Exe)|$($rule.Profile)"
    if ($script:LastAppliedAppProfileKey -eq $key) { return }
    if (Apply-ProfileByName -Name $rule.Profile -Reason "App profile $exe ->" -AutomationRuleId "app:$key" -AllowRiskyAutomation:([bool]$rule.AllowRiskyVcp)) {
        $script:LastAppliedAppProfileKey = $key
    }
}

function Start-AppProfileWatcher {
    if ($null -eq $script:AppProfileTimer) {
        $script:AppProfileTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AppProfileTimer.Interval = [TimeSpan]::FromSeconds(5)
        $script:AppProfileTimer.Add_Tick({ Invoke-AppProfileCheck })
    }
    if ($script:AppProfileEnabled) { $script:AppProfileTimer.Start() } else { $script:AppProfileTimer.Stop() }
}

function Normalize-ScheduleTime {
    param([string]$TimeText)
    $text = $TimeText.Trim()
    if ($text -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') { return "" }
    $hour = [int]$matches[1]
    $minute = [int]$matches[2]
    return "{0:D2}:{1:D2}" -f $hour, $minute
}

function Get-ScheduleMinutes {
    param([string]$TimeText)
    $time = Normalize-ScheduleTime -TimeText $TimeText
    if (-not $time) { return -1 }
    $parts = $time.Split(':')
    return ([int]$parts[0] * 60) + [int]$parts[1]
}

function Update-ScheduleTimeline {
    if ($null -eq $scheduleTimelineCanvas) { return }
    $scheduleTimelineCanvas.Children.Clear()
    $width = [double]$scheduleTimelineCanvas.ActualWidth
    $height = [double]$scheduleTimelineCanvas.ActualHeight
    if ($width -lt 80) { $width = 540 }
    if ($height -lt 40) { $height = 56 }
    $leftPad = 10
    $rightPad = 10
    $plotWidth = [Math]::Max(1, $width - $leftPad - $rightPad)
    $axisY = 26
    $axisBrush = $window.FindResource("BorderBrush")
    $tickBrush = $window.FindResource("BorderBrush")
    $textBrush = $window.FindResource("MutedTextBrush")
    $markerBrush = $window.FindResource("FocusBrush")

    $axis = New-Object System.Windows.Shapes.Line
    $axis.X1 = $leftPad; $axis.X2 = $width - $rightPad; $axis.Y1 = $axisY; $axis.Y2 = $axisY
    $axis.Stroke = $axisBrush; $axis.StrokeThickness = 1
    $scheduleTimelineCanvas.Children.Add($axis) | Out-Null

    foreach ($hour in @(0, 6, 12, 18, 24)) {
        $x = $leftPad + (($hour * 60) / 1440.0) * $plotWidth
        $tick = New-Object System.Windows.Shapes.Line
        $tick.X1 = $x; $tick.X2 = $x; $tick.Y1 = $axisY - 5; $tick.Y2 = $axisY + 5
        $tick.Stroke = $tickBrush; $tick.StrokeThickness = 1
        $scheduleTimelineCanvas.Children.Add($tick) | Out-Null

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = if ($hour -eq 24) { "24:00" } else { "{0:D2}:00" -f $hour }
        $label.FontSize = 8; $label.Foreground = $textBrush
        [System.Windows.Controls.Canvas]::SetLeft($label, [Math]::Min([Math]::Max(0, $x - 14), $width - 34))
        [System.Windows.Controls.Canvas]::SetTop($label, $axisY + 8)
        $scheduleTimelineCanvas.Children.Add($label) | Out-Null
    }

    $rules = @($script:ProfileSchedules | Sort-Object @{ Expression = { Get-ScheduleMinutes -TimeText $_.Time } })
    if ($rules.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = "No schedule rules"
        $empty.FontSize = 9; $empty.Foreground = $textBrush
        [System.Windows.Controls.Canvas]::SetLeft($empty, 12)
        [System.Windows.Controls.Canvas]::SetTop($empty, 6)
        $scheduleTimelineCanvas.Children.Add($empty) | Out-Null
        return
    }

    foreach ($rule in $rules) {
        $minutes = Get-ScheduleMinutes -TimeText $rule.Time
        if ($minutes -lt 0) { continue }
        $x = $leftPad + ($minutes / 1440.0) * $plotWidth
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $x; $line.X2 = $x; $line.Y1 = 8; $line.Y2 = $axisY + 5
        $line.Stroke = $markerBrush; $line.StrokeThickness = 1
        $line.Opacity = 0.75
        $line.ToolTip = "$($rule.Time) - $($rule.Profile)"
        $scheduleTimelineCanvas.Children.Add($line) | Out-Null

        $marker = New-Object System.Windows.Shapes.Ellipse
        $marker.Width = 8; $marker.Height = 8; $marker.Fill = $markerBrush
        $marker.Stroke = Get-ThemeBrush -Key "TextBrush"; $marker.StrokeThickness = 1
        $marker.ToolTip = "$($rule.Time) - $($rule.Profile)"
        [System.Windows.Controls.Canvas]::SetLeft($marker, $x - 4)
        [System.Windows.Controls.Canvas]::SetTop($marker, $axisY - 4)
        $scheduleTimelineCanvas.Children.Add($marker) | Out-Null

        $timeLabel = New-Object System.Windows.Controls.TextBlock
        $timeLabel.Text = $rule.Time
        $timeLabel.FontSize = 8; $timeLabel.Foreground = $textBrush
        $timeLabel.ToolTip = "$($rule.Time) - $($rule.Profile)"
        [System.Windows.Controls.Canvas]::SetLeft($timeLabel, [Math]::Min([Math]::Max(0, $x - 18), $width - 38))
        [System.Windows.Controls.Canvas]::SetTop($timeLabel, 4)
        $scheduleTimelineCanvas.Children.Add($timeLabel) | Out-Null
    }
}

function Load-ProfileSchedules {
    $script:ProfileScheduleEnabled = $false
    $script:ProfileSchedules = @()
    if (-not (Test-Path -LiteralPath $script:ProfileScheduleRulesPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:ProfileScheduleRulesPath -Label "Profile schedule" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        if (-not (Test-SettingsDocumentSupported -Name "ProfileSchedules" -Document $data -Label "Profile schedule")) { return }
        $script:ProfileScheduleEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $time = Normalize-ScheduleTime -TimeText ([string]$rule.Time)
            $profileObject = ([string]$rule.Profile).Trim()
            $allowRiskyVcp = $rule.PSObject.Properties.Name -contains "AllowRiskyVcp" -and [bool]$rule.AllowRiskyVcp
            if ($time -and $profileObject) { $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profileObject; AllowRiskyVcp = $allowRiskyVcp } }
        }
    } catch {
        Update-Status "Profile schedule could not be loaded"
    }
}

function Save-ProfileSchedules {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "schedule changes")) { return $false }
    $payload = [PSCustomObject]@{
        SchemaVersion = [int]$script:ProfileSchedulesSchemaVersion
        Enabled = [bool]$script:ProfileScheduleEnabled
        Rules = @($script:ProfileSchedules | Sort-Object -Property Time)
    }
    return (Write-JsonFileSafely -Path $script:ProfileScheduleRulesPath -Data $payload -Depth 4)
}

function Update-ScheduleControls {
    if ($null -eq $scheduleEnabledCheckbox) { return }
    $script:UpdatingScheduleUI = $true
    try {
        $scheduleRulesList.Items.Clear()
        foreach ($rule in ($script:ProfileSchedules | Sort-Object -Property Time)) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $consentSuffix = if ([bool]$rule.AllowRiskyVcp) { " [risky writes allowed]" } else { "" }
            $item.Content = "$($rule.Time) -> $($rule.Profile)$consentSuffix"
            $item.Tag = $rule.Time
            $scheduleRulesList.Items.Add($item) | Out-Null
        }
        $scheduleEnabledCheckbox.IsChecked = [bool]$script:ProfileScheduleEnabled
        $scheduleStatusText.Text = if ($script:ProfileScheduleEnabled) { "Watching" } else { "Off" }
        Update-ProfileCombo -Combo $scheduleProfileCombo
        Update-ScheduleTimeline
    } finally {
        $script:UpdatingScheduleUI = $false
    }
}

function Get-ActiveScheduleRule {
    param([datetime]$Now = (Get-Date))
    if ($script:ProfileSchedules.Count -eq 0) { return $null }
    $now = $Now
    $nowMinutes = ($now.Hour * 60) + $now.Minute
    $indexed = @(
        for ($index = 0; $index -lt $script:ProfileSchedules.Count; $index++) {
            [PSCustomObject]@{
                Rule = $script:ProfileSchedules[$index]
                Minutes = Get-ScheduleMinutes -TimeText $script:ProfileSchedules[$index].Time
                DeclarationOrder = $index
            }
        }
    )
    $ordered = @($indexed | Sort-Object Minutes, DeclarationOrder)
    $due = @($ordered | Where-Object { $_.Minutes -le $nowMinutes })
    $selected = if ($due.Count -gt 0) { $due[-1] } else { $ordered[-1] }
    $rule = $selected.Rule
    $effectiveDate = if ($due.Count -gt 0) { $now.ToString("yyyy-MM-dd") } else { $now.AddDays(-1).ToString("yyyy-MM-dd") }
    return [PSCustomObject]@{ Rule = $rule; Key = "$effectiveDate $($rule.Time)|$($rule.Profile)" }
}

function Invoke-ScheduleCheck {
    if (-not $script:ProfileScheduleEnabled -or $script:ProfileSchedules.Count -eq 0) { return }
    $active = Get-ActiveScheduleRule
    if ($null -eq $active -or $null -eq $active.Rule) { return }
    if ($script:LastAppliedScheduleKey -eq $active.Key) { return }
    if (Apply-ProfileByName -Name $active.Rule.Profile -Reason "Schedule $($active.Rule.Time) ->" -AutomationRuleId "schedule:$($active.Rule.Time)|$($active.Rule.Profile)" -AllowRiskyAutomation:([bool]$active.Rule.AllowRiskyVcp)) {
        $script:LastAppliedScheduleKey = $active.Key
    }
}

function Start-ProfileScheduleWatcher {
    if ($null -eq $script:ProfileScheduleTimer) {
        $script:ProfileScheduleTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ProfileScheduleTimer.Interval = [TimeSpan]::FromSeconds(30)
        $script:ProfileScheduleTimer.Add_Tick({ Invoke-ScheduleCheck })
    }
    if ($script:ProfileScheduleEnabled) {
        $script:ProfileScheduleTimer.Start()
        Invoke-ScheduleCheck
    } else {
        $script:ProfileScheduleTimer.Stop()
    }
}

function Load-IdleDimSettings {
    if (-not (Test-Path -LiteralPath $script:IdleDimSettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:IdleDimSettingsPath -Label "Idle dim settings" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        if (-not (Test-SettingsDocumentSupported -Name "IdleDim" -Document $data -Label "Idle dim settings")) { return }
        $script:IdleDimEnabled = [bool]$data.Enabled
        $script:IdleDimMinutes = [Math]::Max(1, [Math]::Min(240, [int]$data.Minutes))
        $script:IdleDimBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.Brightness))
        $script:IdleDimRestoreOnActivity = [bool]$data.RestoreOnActivity
    } catch {
        Update-Status "Idle dim settings could not be loaded"
    }
}

function Save-IdleDimSettings {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "idle dim changes")) { return $false }
    $payload = [PSCustomObject]@{
        SchemaVersion = [int]$script:IdleDimSchemaVersion
        Enabled = [bool]$script:IdleDimEnabled
        Minutes = [int]$script:IdleDimMinutes
        Brightness = [int]$script:IdleDimBrightness
        RestoreOnActivity = [bool]$script:IdleDimRestoreOnActivity
    }
    return (Write-JsonFileSafely -Path $script:IdleDimSettingsPath -Data $payload -Depth 4)
}

function Update-IdleDimControls {
    if ($null -eq $idleDimEnabledCheckbox) { return }
    $script:UpdatingIdleDimUI = $true
    try {
        $idleDimEnabledCheckbox.IsChecked = [bool]$script:IdleDimEnabled
        $idleDimMinutesBox.Text = ([int]$script:IdleDimMinutes).ToString()
        $idleDimBrightnessBox.Text = ([int]$script:IdleDimBrightness).ToString()
        $idleDimRestoreCheckbox.IsChecked = [bool]$script:IdleDimRestoreOnActivity
        $idleDimStatusText.Text = if ($script:IdleDimEnabled) { if ($script:IdleDimActive) { "Dimmed" } else { "Watching" } } else { "Off" }
    } finally {
        $script:UpdatingIdleDimUI = $false
    }
}

function Read-IdleDimSettingsFromUI {
    $minutes = 0
    $brightness = 0
    if (-not [int]::TryParse($idleDimMinutesBox.Text.Trim(), [ref]$minutes)) { Update-Status "Idle minutes must be a number"; return $false }
    if (-not [int]::TryParse($idleDimBrightnessBox.Text.Trim(), [ref]$brightness)) { Update-Status "Idle brightness must be a number"; return $false }
    $script:IdleDimMinutes = [Math]::Max(1, [Math]::Min(240, $minutes))
    $script:IdleDimBrightness = [Math]::Max(0, [Math]::Min(100, $brightness))
    $script:IdleDimRestoreOnActivity = [bool]$idleDimRestoreCheckbox.IsChecked
    Update-IdleDimControls
    return $true
}

function Get-IdleSecondsFromTicks {
    param([uint32]$CurrentTick, [uint32]$LastInputTick)
    $current = [uint64]$CurrentTick
    $last = [uint64]$LastInputTick
    $elapsedMs = if ($current -ge $last) {
        $current - $last
    } else {
        ([uint64][uint32]::MaxValue - $last) + $current + 1
    }
    return [int][Math]::Floor($elapsedMs / 1000)
}

function Get-IdleSeconds {
    $info = New-Object MonitorAPI+LASTINPUTINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
    if (-not [MonitorAPI]::GetLastInputInfo([ref]$info)) { return 0 }
    return Get-IdleSecondsFromTicks -CurrentTick ([MonitorAPI]::GetTickCount()) -LastInputTick $info.dwTime
}

function Invoke-IdleDimCheck {
    if (-not $script:IdleDimEnabled) { return }
    $idleSeconds = Get-IdleSeconds
    $thresholdSeconds = [Math]::Max(1, [int]$script:IdleDimMinutes) * 60
    if (-not $script:IdleDimActive -and $idleSeconds -ge $thresholdSeconds) {
        $script:IdleDimPreviousBrightness = [int](Get-SelectedBrightnessPercent)
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$script:IdleDimBrightness) -Force -Percent
        Set-BrightnessSliderFromPercent -Percent ([int]$script:IdleDimBrightness) | Out-Null
        $script:IdleDimActive = $true
        Update-IdleDimControls
        Update-TrayPopupState
        Update-TrayIconText
        Update-Status "Idle dim active"
    } elseif ($script:IdleDimActive -and $idleSeconds -lt 5) {
        if ($script:IdleDimRestoreOnActivity -and $null -ne $script:IdleDimPreviousBrightness) {
            Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$script:IdleDimPreviousBrightness) -Force -Percent
            Set-BrightnessSliderFromPercent -Percent ([int]$script:IdleDimPreviousBrightness) | Out-Null
        }
        $script:IdleDimActive = $false
        $script:IdleDimPreviousBrightness = $null
        Update-IdleDimControls
        Update-TrayPopupState
        Update-TrayIconText
        Update-Status "Idle dim restored"
    }
}

function Start-IdleDimWatcher {
    if ($null -eq $script:IdleDimTimer) {
        $script:IdleDimTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:IdleDimTimer.Interval = [TimeSpan]::FromSeconds(15)
        $script:IdleDimTimer.Add_Tick({ Invoke-IdleDimCheck })
    }
    if ($script:IdleDimEnabled) { $script:IdleDimTimer.Start() } else { $script:IdleDimTimer.Stop() }
}

function Load-BatteryProfileSettings {
    if (-not (Test-Path -LiteralPath $script:BatteryProfileSettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:BatteryProfileSettingsPath -Label "Battery profile settings" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        if (-not (Test-SettingsDocumentSupported -Name "BatteryProfile" -Document $data -Label "Battery profile settings")) { return }
        $script:BatteryProfileEnabled = [bool]$data.Enabled
        $script:BatteryBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.BatteryBrightness))
        $script:AcBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.AcBrightness))
    } catch {
        Update-Status "Battery profile settings could not be loaded"
    }
}

function Save-BatteryProfileSettings {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "battery profile changes")) { return $false }
    $payload = [PSCustomObject]@{
        SchemaVersion = [int]$script:BatteryProfileSchemaVersion
        Enabled = [bool]$script:BatteryProfileEnabled
        BatteryBrightness = [int]$script:BatteryBrightness
        AcBrightness = [int]$script:AcBrightness
    }
    return (Write-JsonFileSafely -Path $script:BatteryProfileSettingsPath -Data $payload -Depth 4)
}

function Read-BatteryProfileSettingsFromUI {
    $batteryValue = 0; $acValue = 0
    if (-not [int]::TryParse($batteryBrightnessBox.Text, [ref]$batteryValue) -or $batteryValue -lt 0 -or $batteryValue -gt 100) {
        Update-Status "Battery brightness must be 0-100"
        return $false
    }
    if (-not [int]::TryParse($acBrightnessBox.Text, [ref]$acValue) -or $acValue -lt 0 -or $acValue -gt 100) {
        Update-Status "AC brightness must be 0-100"
        return $false
    }
    $script:BatteryBrightness = $batteryValue
    $script:AcBrightness = $acValue
    return $true
}

function Update-BatteryProfileControls {
    $script:UpdatingBatteryProfileUI = $true
    try {
        $batteryProfileEnabledCheckbox.IsChecked = [bool]$script:BatteryProfileEnabled
        $batteryBrightnessBox.Text = $script:BatteryBrightness.ToString()
        $acBrightnessBox.Text = $script:AcBrightness.ToString()
        $batteryProfileStatusText.Text = if ($script:BatteryProfileEnabled) { "Watching" } else { "Off" }
    } finally {
        $script:UpdatingBatteryProfileUI = $false
    }
}

function Invoke-BatteryProfileCheck {
    if (-not $script:BatteryProfileEnabled) { return }
    $status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus.ToString()
    if ($script:LastPowerLineStatus -eq $status) { return }
    $script:LastPowerLineStatus = $status
    if ($status -eq "Offline") {
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $script:BatteryBrightness -Force -Percent
        Update-Status "Battery profile: $($script:BatteryBrightness)%"
        $batteryProfileStatusText.Text = "Battery"
    } elseif ($status -eq "Online") {
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $script:AcBrightness -Force -Percent
        Update-Status "AC profile: $($script:AcBrightness)%"
        $batteryProfileStatusText.Text = "AC"
    } else {
        $batteryProfileStatusText.Text = "Unknown"
    }
}

function Start-BatteryProfileWatcher {
    if ($null -eq $script:BatteryProfileTimer) {
        $script:BatteryProfileTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:BatteryProfileTimer.Interval = [TimeSpan]::FromSeconds(30)
        $script:BatteryProfileTimer.Add_Tick({ Invoke-BatteryProfileCheck })
    }
    if ($script:BatteryProfileEnabled) {
        $script:BatteryProfileTimer.Start()
        $script:LastPowerLineStatus = $null
        Invoke-BatteryProfileCheck
    } else {
        $script:BatteryProfileTimer.Stop()
        $script:LastPowerLineStatus = $null
    }
}

function Get-CurrentMonitorLabel {
    if ($script:ApplyToAll) { return "All monitors" }
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return "No monitor" }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    return "$($mon.Index): $(Get-MonitorDisplayLabel -Monitor $mon)"
}

function Update-TrayIconText {
    if ($null -eq $script:TrayIcon) { return }
    $brightness = [int](Get-SelectedBrightnessPercent)
    $text = "MonitorControl Pro - $(Get-CurrentMonitorLabel) - $brightness%"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:TrayIcon.Text = $text
}

function Show-TrayNotification {
    param([string]$Message)
    if ($null -eq $script:TrayIcon -or -not $script:TrayIcon.Visible) { return }
    $script:TrayIcon.BalloonTipTitle = "MonitorControl Pro"
    $script:TrayIcon.BalloonTipText = $Message
    $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $script:TrayIcon.ShowBalloonTip(1500)
}

function Set-ApplyToAllMode {
    param([bool]$Enabled)
    $script:ApplyToAll = $Enabled
    if ($applyAllCheckbox -and $applyAllCheckbox.IsChecked -ne $Enabled) { $applyAllCheckbox.IsChecked = $Enabled }
    if ($script:TrayLinkMenuItem -and $script:TrayLinkMenuItem.Checked -ne $Enabled) { $script:TrayLinkMenuItem.Checked = $Enabled }
    if ($script:TrayLinkCheckbox -and $script:TrayLinkCheckbox.IsChecked -ne $Enabled) { $script:TrayLinkCheckbox.IsChecked = $Enabled }
    Update-TrayPopupState
    Update-TrayIconText
}

function Update-TrayPopupState {
    if ($null -eq $script:TrayPopup -or $null -eq $script:TrayBrightnessSlider) { return }
    $script:TrayPopupUpdating = $true
    try {
        $script:TrayBrightnessSlider.Minimum = $brightnessSlider.Minimum
        $script:TrayBrightnessSlider.Maximum = $brightnessSlider.Maximum
        $value = [Math]::Min($brightnessSlider.Maximum, [Math]::Max($brightnessSlider.Minimum, [double]$brightnessSlider.Value))
        $script:TrayBrightnessSlider.Value = $value
        $script:TrayBrightnessValue.Text = ([int]$value).ToString()
        $script:TrayMonitorText.Text = Get-CurrentMonitorLabel
        $script:TrayLinkCheckbox.IsChecked = [bool]$script:ApplyToAll
    } finally {
        $script:TrayPopupUpdating = $false
    }
}

function New-TrayPopup {
    if ($script:TrayPopup) { return }
    [xml]$trayPopupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="300" Height="172" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True">
    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="12">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="10"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="8"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="10"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid>
                <TextBlock x:Name="TrayMonitorText" Text="Monitor" FontSize="12" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI" FontWeight="SemiBold"/>
                <TextBlock x:Name="TrayBrightnessValue" Text="50" FontSize="12" Foreground="{DynamicResource WarningBrush}" FontFamily="Segoe UI" FontWeight="SemiBold" HorizontalAlignment="Right"/>
            </Grid>
            <Slider x:Name="TrayBrightnessSlider" Grid.Row="2" Minimum="0" Maximum="100" Value="50" Height="24"/>
            <CheckBox x:Name="TrayLinkCheckbox" Grid.Row="4" Content="Link monitors" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI" FontSize="12"/>
            <Grid Grid.Row="6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="TrayOpenButton" Content="Open" Padding="8,5" Background="{DynamicResource CardBrush}" Foreground="{DynamicResource TextBrush}" BorderBrush="{DynamicResource BorderBrush}"/>
                <Button x:Name="TrayProfileButton" Grid.Column="2" Content="Profile" Padding="8,5" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource OnAccentBrush}" BorderBrush="{DynamicResource AccentBrush}"/>
                <Button x:Name="TrayHideButton" Grid.Column="4" Content="Hide" Padding="8,5" Background="{DynamicResource CardBrush}" Foreground="{DynamicResource TextBrush}" BorderBrush="{DynamicResource BorderBrush}"/>
            </Grid>
        </Grid>
    </Border>
</Window>
"@
    $trayReader = New-Object System.Xml.XmlNodeReader $trayPopupXaml
    $script:TrayPopup = [System.Windows.Markup.XamlReader]::Load($trayReader)
    Register-DetachedThemedWindow -Target $script:TrayPopup
    $script:TrayBrightnessSlider = $script:TrayPopup.FindName("TrayBrightnessSlider")
    $script:TrayBrightnessValue = $script:TrayPopup.FindName("TrayBrightnessValue")
    $script:TrayMonitorText = $script:TrayPopup.FindName("TrayMonitorText")
    $script:TrayLinkCheckbox = $script:TrayPopup.FindName("TrayLinkCheckbox")
    $trayOpenButton = $script:TrayPopup.FindName("TrayOpenButton")
    $trayProfileButton = $script:TrayPopup.FindName("TrayProfileButton")
    $trayHideButton = $script:TrayPopup.FindName("TrayHideButton")

    $script:TrayBrightnessSlider.Add_ValueChanged({
        if ($script:TrayPopupUpdating) { return }
        $value = [int]$script:TrayBrightnessSlider.Value
        $script:TrayBrightnessValue.Text = $value.ToString()
        $script:UpdatingUI = $true
        try {
            $brightnessSlider.Value = $value
            $brightnessValue.Text = $value.ToString()
        } finally {
            $script:UpdatingUI = $false
        }
        Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -RawValue $value | Out-Null
        Update-Status "Brightness: $value"
        Update-TrayIconText
    })
    $script:TrayLinkCheckbox.Add_Checked({ if (-not $script:TrayPopupUpdating) { Set-ApplyToAllMode -Enabled $true } })
    $script:TrayLinkCheckbox.Add_Unchecked({ if (-not $script:TrayPopupUpdating) { Set-ApplyToAllMode -Enabled $false } })
    $trayOpenButton.Add_Click({ Show-MainWindow })
    $trayProfileButton.Add_Click({ Invoke-NextProfile })
    $trayHideButton.Add_Click({ if ($script:TrayPopup -and $script:TrayPopup.IsVisible) { $script:TrayPopup.Hide() } })
    $script:TrayPopup.Add_Deactivated({ if ($script:TrayPopup -and $script:TrayPopup.IsVisible) { $script:TrayPopup.Hide() } })
}

function Show-TrayPopup {
    New-TrayPopup
    Update-TrayPopupState
    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $cursorPoint = [System.Windows.Point]::new($cursor.X, $cursor.Y)
    $workTopLeft = [System.Windows.Point]::new($screen.WorkingArea.Left, $screen.WorkingArea.Top)
    $workBottomRight = [System.Windows.Point]::new($screen.WorkingArea.Right, $screen.WorkingArea.Bottom)
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    if ($source -and $source.CompositionTarget) {
        $transform = $source.CompositionTarget.TransformFromDevice
        $cursorPoint = $transform.Transform($cursorPoint)
        $workTopLeft = $transform.Transform($workTopLeft)
        $workBottomRight = $transform.Transform($workBottomRight)
    }
    $left = [Math]::Min($cursorPoint.X - $script:TrayPopup.Width + 24, $workBottomRight.X - $script:TrayPopup.Width - 8)
    $left = [Math]::Max($workTopLeft.X + 8, $left)
    $top = $cursorPoint.Y - $script:TrayPopup.Height - 12
    if ($top -lt ($workTopLeft.Y + 8)) { $top = $cursorPoint.Y + 12 }
    $top = [Math]::Min($top, $workBottomRight.Y - $script:TrayPopup.Height - 8)
    $top = [Math]::Max($workTopLeft.Y + 8, $top)
    $script:TrayPopup.Left = $left
    $script:TrayPopup.Top = $top
    $script:TrayPopup.Show()
    $script:TrayPopup.Activate() | Out-Null
}

function Show-MainWindow {
    if ($script:TrayPopup) { $script:TrayPopup.Hide() }
    $window.Show()
    $window.ShowInTaskbar = $true
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate() | Out-Null
}

function Hide-MainWindowToTray {
    $window.ShowInTaskbar = $false
    $window.Hide()
    if (-not $script:TrayHasShownMinimizeTip) {
        Show-TrayNotification -Message "MonitorControl is running in the notification area."
        $script:TrayHasShownMinimizeTip = $true
    }
}

function Invoke-NextProfile {
    $profiles = @(Get-UserProfileFiles)
    if ($profiles.Count -eq 0) {
        Update-Status "No profiles saved"
        Show-TrayNotification -Message "No saved profiles are available to cycle."
        return
    }

    $names = @($profiles | ForEach-Object { $_.BaseName })
    if ($profilesList.SelectedItem -and $names -contains [string]$profilesList.SelectedItem) {
        $script:ProfileCycleIndex = [Array]::IndexOf($names, [string]$profilesList.SelectedItem)
    }
    $script:ProfileCycleIndex = ($script:ProfileCycleIndex + 1) % $names.Count
    $profileName = $names[$script:ProfileCycleIndex]
    $profilesList.SelectedItem = $profileName
    $loadProfileBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    Show-TrayNotification -Message "Loaded profile: $profileName"
    Update-TrayPopupState
    Update-TrayIconText
}

function Initialize-TrayIcon {
    if ($script:TrayIcon) { return }
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIconPath = Join-Path $script:MonitorControlRoot 'icon.ico'
    if (Test-Path $trayIconPath) {
        $script:TrayIcon.Icon = New-Object System.Drawing.Icon($trayIconPath)
    } else {
        $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
    $script:TrayIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open MonitorControl")
    $brightnessItem = New-Object System.Windows.Forms.ToolStripMenuItem("Brightness Slider")
    $script:TrayLinkMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Link Monitors")
    $profileItem = New-Object System.Windows.Forms.ToolStripMenuItem("Next Profile")
    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh Monitors")
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

    $script:TrayLinkMenuItem.CheckOnClick = $true
    $script:TrayLinkMenuItem.Checked = [bool]$script:ApplyToAll
    $openItem.Add_Click({ Show-MainWindow })
    $brightnessItem.Add_Click({ Show-TrayPopup })
    $script:TrayLinkMenuItem.Add_CheckedChanged({ Set-ApplyToAllMode -Enabled $script:TrayLinkMenuItem.Checked })
    $profileItem.Add_Click({ Invoke-NextProfile })
    $refreshItem.Add_Click({ Request-DisplayRecoveryRefresh -Reason "tray-refresh" })
    $exitItem.Add_Click({
        $script:IsQuitting = $true
        if ($script:TrayPopup -and $script:TrayPopup.IsVisible) { $script:TrayPopup.Hide() }
        $window.Close()
    })

    $menu.Items.Add($openItem) | Out-Null
    $menu.Items.Add($brightnessItem) | Out-Null
    $menu.Items.Add($script:TrayLinkMenuItem) | Out-Null
    $menu.Items.Add($profileItem) | Out-Null
    $menu.Items.Add($refreshItem) | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $menu.Items.Add($exitItem) | Out-Null
    $script:TrayIcon.ContextMenuStrip = $menu

    $script:TrayIcon.Add_MouseUp({
        param($sender, $args)
        if ($args.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-TrayPopup }
    })
    $script:TrayIcon.Add_MouseDoubleClick({
        param($sender, $args)
        if ($args.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-NextProfile }
    })
    Update-TrayIconText
}

function Dispose-TrayMode {
    if ($script:TrayPopup) {
        try { $script:TrayPopup.Close() } catch {}
        $script:TrayPopup = $null
    }
    if ($script:TrayIcon) {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
        $script:TrayIcon = $null
    }
}

function Show-IdentifyOverlays {
    foreach ($mon in $script:PhysicalMonitors) {
        $overlay = New-Object System.Windows.Window; $overlay.WindowStyle = "None"; $overlay.AllowsTransparency = $true
        $overlay.Background = [System.Windows.Media.Brushes]::Transparent; $overlay.Topmost = $true; $overlay.ShowInTaskbar = $false
        $overlay.Left = $mon.Left + 30; $overlay.Top = $mon.Top + 30; $overlay.Width = 100; $overlay.Height = 100
        $border = New-Object System.Windows.Controls.Border
        $border.Background = Get-ThemeBrush -Key "AccentBrush"
        $border.BorderBrush = Get-ThemeBrush -Key "BorderBrush"
        $border.BorderThickness = New-Object System.Windows.Thickness(2)
        $border.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $mon.Index.ToString(); $tb.FontSize = 44; $tb.FontWeight = "Bold"
        $tb.Foreground = Get-ThemeBrush -Key "OnAccentBrush"; $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
        $border.Child = $tb; $overlay.Content = $border; $overlay.Show()
        $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(2)
        $currentOverlay = $overlay; $currentTimer = $timer
        $timer.Add_Tick({ $currentTimer.Stop(); $currentOverlay.Close() }.GetNewClosure()); $timer.Start()
    }
}

function Initialize-PresentMon {
    if (-not $script:PresentMonEnabled) {
        $script:PresentMonPath = ""
        return $false
    }
    if ($script:PresentMonPath -and (Test-Path -LiteralPath $script:PresentMonPath -PathType Leaf)) { return $true }
    $script:PresentMonPath = ""
    $rejected = $null
    foreach ($candidate in (Get-PresentMonCandidatePaths)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $provenance = Get-OptionalHelperProvenance -Path $candidate -Kind "PresentMon"
        if (-not $provenance.Supported) {
            if ($null -eq $rejected) { $rejected = $provenance }
            continue
        }
        $script:PresentMonPath = $provenance.Path
        $script:PresentMonProvenance = $provenance
        return $true
    }
    $script:PresentMonProvenance = $rejected
    return $false
}

function Invoke-BoundedPresentMon {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutMs, [int]$MaxChars)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = ($Arguments -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($Path)
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $process) { return @{ TimedOut = $false; Truncated = $false; Output = @() } }
        $reader = $process.StandardOutput
        $builder = New-Object System.Text.StringBuilder
        $truncated = $false
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        $buffer = New-Object char[] 4096
        while (-not $process.HasExited -or -not $reader.EndOfStream) {
            if ([DateTime]::UtcNow -gt $deadline) { break }
            if ($reader.EndOfStream) { Start-Sleep -Milliseconds 25; continue }
            $read = $reader.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { continue }
            if ($builder.Length + $read -gt $MaxChars) {
                [void]$builder.Append($buffer, 0, [Math]::Max(0, $MaxChars - $builder.Length))
                $truncated = $true
                break
            }
            [void]$builder.Append($buffer, 0, $read)
        }
        $timedOut = -not $process.HasExited
        if ($timedOut -or $truncated) {
            try { $process.Kill() } catch {}
        }
        try { $process.WaitForExit(2000) | Out-Null } catch {}
        return @{
            TimedOut = $timedOut
            Truncated = $truncated
            Output = @($builder.ToString() -split "`r?`n")
        }
    } finally {
        if ($process) { try { $process.Dispose() } catch {} }
    }
}

function Get-PresentMonFpsSnapshot {
    if (-not $script:PresentMonEnabled) { return @{ Success = $false; Text = "FPS --"; Status = "PresentMon integration is disabled" } }
    if (-not (Initialize-PresentMon)) {
        $reason = if ($script:PresentMonProvenance -and $script:PresentMonProvenance.Reason) { $script:PresentMonProvenance.Reason } else { "PresentMon.exe not found" }
        return @{ Success = $false; Text = "FPS --"; Status = $reason }
    }
    try {
        $run = Invoke-BoundedPresentMon -Path $script:PresentMonPath -Arguments @(
            "--output_stdout", "--no_console_stats", "--timed", "1", "--terminate_after_timed", "--stop_existing_session"
        ) -TimeoutMs $script:PresentMonTimeoutMs -MaxChars $script:PresentMonMaxOutputChars
        if ($run.TimedOut) { return @{ Success = $false; Text = "FPS --"; Status = "PresentMon timed out and was stopped" } }
        $csvLines = @($run.Output) | Where-Object { $_ -and $_.Contains(",") }
        if ($csvLines.Count -lt 2) { return @{ Success = $false; Text = "FPS --"; Status = "No PresentMon samples" } }
        $rows = $csvLines | ConvertFrom-Csv
        if (-not $rows -or $rows.Count -eq 0) { return @{ Success = $false; Text = "FPS --"; Status = "PresentMon CSV parse failed" } }
        $headers = @($rows[0].PSObject.Properties.Name)
        $msColumn = $headers | Where-Object { $_ -match "MsBetweenPresents|MsBetweenDisplayChange|MsUntilDisplayed|msBetweenPresents" } | Select-Object -First 1
        if (-not $msColumn) { return @{ Success = $false; Text = "FPS --"; Status = "PresentMon frame-time column missing" } }
        $appColumn = $headers | Where-Object { $_ -match "Application|ProcessName|Process" } | Select-Object -First 1
        $frameTimes = @()
        foreach ($row in $rows) {
            $value = $row.$msColumn
            $parsed = 0.0
            if ([double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
                $frameTimes += $parsed
            }
        }
        if ($frameTimes.Count -eq 0) { return @{ Success = $false; Text = "FPS --"; Status = "No active PresentMon frames" } }
        $avgMs = ($frameTimes | Measure-Object -Average).Average
        $fps = [math]::Round(1000 / $avgMs, 1)
        $appName = "Active app"
        if ($appColumn) {
            $topApp = $rows | Where-Object { $_.$appColumn } | Group-Object -Property $appColumn | Sort-Object Count -Descending | Select-Object -First 1
            if ($topApp) { $appName = [string]$topApp.Name }
        }
        return @{ Success = $true; Text = "$fps FPS`n$appName"; Status = "$fps FPS - $appName" }
    } catch {
        return @{ Success = $false; Text = "FPS --"; Status = "PresentMon error: $_" }
    }
}

function Update-FpsOverlay {
    $snapshot = Get-PresentMonFpsSnapshot
    if ($script:FpsOverlayText) { $script:FpsOverlayText.Text = $snapshot.Text }
    $fpsOverlayStatusText.Text = $snapshot.Status
    Update-Status $snapshot.Status
}

function Show-FpsOverlay {
    if (-not $script:PresentMonEnabled) {
        $fpsOverlayStatusText.Text = "Enable PresentMon in System"
        Update-Status "PresentMon integration is disabled; enable it in System"
        return
    }
    if (-not (Initialize-PresentMon)) {
        $reason = if ($script:PresentMonProvenance -and $script:PresentMonProvenance.Reason) { $script:PresentMonProvenance.Reason } else { "PresentMon.exe not found" }
        $fpsOverlayStatusText.Text = $reason
        Update-Status $reason
        return
    }
    if (-not $script:FpsOverlayWindow) {
        $overlay = New-Object System.Windows.Window
        $overlay.WindowStyle = "None"; $overlay.AllowsTransparency = $true; $overlay.Background = [System.Windows.Media.Brushes]::Transparent
        $overlay.Topmost = $true; $overlay.ShowInTaskbar = $false; $overlay.ResizeMode = "NoResize"; $overlay.Width = 190; $overlay.Height = 74
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $overlay.Left = $workArea.Right - 210; $overlay.Top = $workArea.Top + 20
        $border = New-Object System.Windows.Controls.Border
        $border.Background = Get-ThemeBrush -Key "SurfaceBrush"
        $border.BorderBrush = Get-ThemeBrush -Key "SuccessBrush"
        $border.BorderThickness = New-Object System.Windows.Thickness(1); $border.CornerRadius = New-Object System.Windows.CornerRadius(6); $border.Padding = New-Object System.Windows.Thickness(12, 8, 12, 8)
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = "FPS --"; $text.Foreground = Get-ThemeBrush -Key "TextBrush"; $text.FontFamily = "Segoe UI"; $text.FontSize = 14; $text.FontWeight = "SemiBold"
        $border.Child = $text; $overlay.Content = $border
        $script:FpsOverlayWindow = $overlay; $script:FpsOverlayText = $text
    }
    $script:FpsOverlayWindow.Show()
    if (-not $script:FpsOverlayTimer) {
        $script:FpsOverlayTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:FpsOverlayTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:FpsOverlayTimer.Add_Tick({ Update-FpsOverlay })
    }
    $script:FpsOverlayTimer.Start()
    Update-FpsOverlay
}

function Hide-FpsOverlay {
    if ($script:FpsOverlayTimer) { $script:FpsOverlayTimer.Stop() }
    if ($script:FpsOverlayWindow) { $script:FpsOverlayWindow.Hide() }
    $fpsOverlayStatusText.Text = "PresentMon idle"
    Update-Status "FPS overlay stopped"
}

Update-VcpPresetItems -Monitor $null
Update-VcpValueEditorForCurrentCode

# Event handlers
$applyAllCheckbox.Add_Checked({ Set-ApplyToAllMode -Enabled $true }); $applyAllCheckbox.Add_Unchecked({ Set-ApplyToAllMode -Enabled $false })
$refreshBtn.Add_Click({ Request-DisplayRecoveryRefresh -Reason "manual-refresh" }); $identifyBtn.Add_Click({ Show-IdentifyOverlays })
$statusBannerDismissButton.Add_Click({
    $statusBannerBorder.Visibility = [System.Windows.Visibility]::Collapsed
    $selectedTab = @($displayTab,$monitorTab,$gpuTab,$vcpTab,$profilesTab,$scheduleTab,$systemTab) |
        Where-Object IsSelected |
        Select-Object -First 1
    if ($null -ne $selectedTab) { $selectedTab.Focus() | Out-Null }
})
$window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $key = if ($eventArgs.Key -eq [System.Windows.Input.Key]::System) { $eventArgs.SystemKey } else { $eventArgs.Key }
    $modifiers = [System.Windows.Input.Keyboard]::Modifiers
    if ($key -eq [System.Windows.Input.Key]::Escape -and $statusBannerBorder.Visibility -eq [System.Windows.Visibility]::Visible) {
        $statusBannerBorder.Visibility = [System.Windows.Visibility]::Collapsed
        $eventArgs.Handled = $true
        return
    }
    if (($modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and $key -eq [System.Windows.Input.Key]::R) {
        Request-DisplayRecoveryRefresh -Reason "keyboard-refresh"
        $eventArgs.Handled = $true
        return
    }
    if (-not ($modifiers -band [System.Windows.Input.ModifierKeys]::Alt)) { return }
    $target = Get-NavigationShortcutTarget -Key $key.ToString()
    $targetTab = switch ($target) {
        "Display" { $displayTab }
        "Monitor" { $monitorTab }
        "Hardware" { $gpuTab }
        "VCP Explorer" { $vcpTab }
        "Profiles" { $profilesTab }
        "Automation" { $scheduleTab }
        "System" { $systemTab }
        default { $null }
    }
    if ($null -ne $targetTab -and $targetTab.Visibility -eq [System.Windows.Visibility]::Visible) {
        $targetTab.IsSelected = $true
        $targetTab.Focus() | Out-Null
        $eventArgs.Handled = $true
    }
})
$monitorLabelSaveBtn.Add_Click({
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if (Set-MonitorUserLabel -Monitor $mon -Label $monitorLabelBox.Text) {
        $label = Get-MonitorDisplayLabel -Monitor $mon
        Update-Status "Monitor label saved: $label"
    }
})
$monitorLabelResetBtn.Add_Click({
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if (Set-MonitorUserLabel -Monitor $mon -Label "") {
        Update-Status "Monitor label reset: $(Get-MonitorDisplayLabel -Monitor $mon)"
    }
})

$brightnessSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$brightnessSlider.Value; $brightnessValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -RawValue $v | Out-Null; Update-DisplayStateRestoreFromUi; Update-TrayPopupState; Update-TrayIconText })
$contrastSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$contrastSlider.Value; $contrastValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_CONTRAST) -RawValue $v | Out-Null })
$redSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$redSlider.Value; $redValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_RED_GAIN) -RawValue $v | Out-Null })
$greenSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$greenSlider.Value; $greenValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_GREEN_GAIN) -RawValue $v | Out-Null })
$blueSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$blueSlider.Value; $blueValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_BLUE_GAIN) -RawValue $v | Out-Null })
$volumeSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$volumeSlider.Value; $volumeValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_VOLUME) -RawValue $v | Out-Null })
$sharpnessSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$sharpnessSlider.Value; $sharpnessValue.Text = $v; Set-ScaledVcpFromSlider -VCPCode ([MonitorAPI]::VCP_SHARPNESS) -RawValue $v | Out-Null })
$muteCheckbox.Add_Checked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 1 -UserInitiated }); $muteCheckbox.Add_Unchecked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 2 -UserInitiated })

$colorTempWarm.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_5000K) -ActionLabel "Set color temperature to 5000K (Warm)" | Out-Null })
$colorTemp6500.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_6500K) -ActionLabel "Set color temperature to 6500K" | Out-Null })
$colorTempCool.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_9300K) -ActionLabel "Set color temperature to 9300K (Cool)" | Out-Null })
$colorTempSRGB.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_SRGB) -ActionLabel "Set color temperature to sRGB" | Out-Null })

$dynamicContrastOff.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_STANDARD) -UserInitiated; Update-Status "Dynamic contrast off" })
$dynamicContrastOn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_DYNAMIC_CONTRAST) -UserInitiated; Update-Status "Dynamic contrast on" })
$pictureModeWeb.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_PRODUCTIVITY) -UserInitiated; Update-Status "Picture mode: Web" })
$pictureModeCinema.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_MOVIE) -UserInitiated; Update-Status "Picture mode: Cinema" })
$pictureModeGame.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_GAMES) -UserInitiated; Update-Status "Picture mode: Game" })

$presetDay.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 80 -Force -Percent -UserInitiated; Set-GammaRamp -Gamma 1.0; Set-BrightnessSliderFromPercent -Percent 80 | Out-Null; Update-Status "Day Mode" })
$presetNight.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 40 -Force -Percent -UserInitiated; Set-GammaRamp -Gamma 1.0 -RedMult 1.0 -GreenMult 0.9 -BlueMult 0.75; Set-BrightnessSliderFromPercent -Percent 40 | Out-Null; Update-Status "Night Mode" })
$presetAutoMode.Add_Click({
    $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher
    $script:AutoModeEnabled = -not $script:AutoModeEnabled
    if ($script:AutoModeEnabled) {
        $s = Apply-TimeBasedSettings; $autoModeText.Text = "Auto: $($s.Mode)"; Set-BrightnessSliderFromPercent -Percent ([int]$s.Brightness) | Out-Null
        if ($null -eq $script:AutoModeTimer) { $script:AutoModeTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:AutoModeTimer.Interval = [TimeSpan]::FromMinutes(15); $script:AutoModeTimer.Add_Tick({ if ($script:AutoModeEnabled) { $s = Apply-TimeBasedSettings; $autoModeText.Text = "Auto: $($s.Mode)" } }) }
        $script:AutoModeTimer.Start()
    } else { if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; $autoModeText.Text = ""; Update-Status "Auto Mode Off" }
})
$presetAmbientMode.Add_Click({
    $script:AutoModeEnabled = $false
    if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }
    $script:AmbientLightEnabled = -not $script:AmbientLightEnabled
    if ($script:AmbientLightEnabled) { Start-AmbientLightWatcher } else { Start-AmbientLightWatcher; $autoModeText.Text = ""; Update-Status "Ambient mode off" }
})
$presetReset.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 50 -Force -Percent -UserInitiated; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value 50 -Force -Percent -UserInitiated; Set-GammaRamp -Gamma 1.0; Load-MonitorSettings; Update-Status "Reset" })

$inputSourceCombo.Add_SelectionChanged({
    if ($script:UpdatingUI -or $inputSourceCombo.SelectedItem -eq $null) { return }
    Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_INPUT_SOURCE) -Value ([uint32]$inputSourceCombo.SelectedItem.Tag) -ActionLabel "Change monitor input to $($inputSourceCombo.SelectedItem.Content)" | Out-Null
})
$powerOffBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_OFF) -ActionLabel "Power off the selected monitor" | Out-Null })
$powerStandbyBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) -ActionLabel "Put the selected monitor in standby" | Out-Null })
$powerOnBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_ON) -ActionLabel "Power on the selected monitor" | Out-Null })
$pipPbpOffBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_OFF) -ActionLabel "Disable PiP/PbP" | Out-Null })
$pipModeBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_UPPER_RIGHT) -ActionLabel "Enable PiP mode" | Out-Null })
$pbpModeBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_PBP_SPLIT) -ActionLabel "Enable PbP split mode" | Out-Null })
$pipSecondaryDpBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_DISPLAYPORT) -ActionLabel "Set the PiP/PbP secondary input to DisplayPort" | Out-Null })
$pipSecondaryHdmi1Btn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI1) -ActionLabel "Set the PiP/PbP secondary input to HDMI 1" | Out-Null })
$pipSecondaryHdmi2Btn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI2) -ActionLabel "Set the PiP/PbP secondary input to HDMI 2" | Out-Null })
$resetColorBtn.Add_Click({
    Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_COLOR) -Value 1 -ActionLabel "Reset the selected monitor's color settings" | Out-Null
})
$factoryResetBtn.Add_Click({
    Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_DEFAULTS) -Value 1 -ActionLabel "Restore the selected monitor to factory defaults" | Out-Null
})
$allMonitorsStandbyBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) -ActionLabel "Put every DDC/CI monitor in standby" -AllMonitors | Out-Null })

$vcpPresetCombo.Add_SelectionChanged({
    if ($vcpPresetCombo.SelectedItem -ne $null) { $vcpCodeBox.Text = "0x{0:X2}" -f $vcpPresetCombo.SelectedItem.Tag }
    Update-VcpValueEditorForCurrentCode
    $monitor = if ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) { $script:PhysicalMonitors[$script:CurrentMonitorIndex] } else { $null }
    Update-RiskyVcpControlState -Monitor $monitor
})
$vcpCodeBox.Add_TextChanged({
    Update-VcpValueEditorForCurrentCode
    $monitor = if ($script:CurrentMonitorIndex -ge 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) { $script:PhysicalMonitors[$script:CurrentMonitorIndex] } else { $null }
    Update-RiskyVcpControlState -Monitor $monitor
})
$vcpSetValueSlider.Add_ValueChanged({
    if (-not $script:UpdatingVcpValueEditor) { $vcpSetValueSliderText.Text = ([uint32]$vcpSetValueSlider.Value).ToString() }
})
$vcpQueryBtn.Add_Click({
    try {
        $code = ConvertTo-VcpCode -Text $vcpCodeBox.Text
        if ($null -eq $code) {
            $vcpResultBox.Text = "Invalid VCP code"
            Update-Status "Invalid VCP code"
            return
        }
        if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) {
            $vcpResultBox.Text = "No monitor selected"
            Update-Status "No monitor selected"
            return
        }
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if ($mon.Handle -eq [IntPtr]::Zero) {
            $vcpResultBox.Text = "No DDC/CI"
            Update-Status "No DDC/CI read target"
            return
        }
        Start-VcpReadWorker -Handle $mon.Handle -Codes @($code) -Mode "Query" -MonitorName $mon.Name -IdentityKey $mon.IdentityKey -MonitorIndex $script:CurrentMonitorIndex
    } catch {
        $vcpResultBox.Text = "Query failed"
        Update-Status "VCP query failed"
    }
})
$vcpSetBtn.Add_Click({
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { Update-Status "No monitor selected"; return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { return }
    try {
        $code = ConvertTo-VcpCode -Text $vcpCodeBox.Text
        $value = Get-VcpValueEditorValue
        if ($null -eq $code -or $null -eq $value) { Update-Status "VCP code/value invalid"; return }
        Invoke-ManualVcpWrite -Code $code -Value $value -ActionLabel "VCP Explorer direct write" -Arbitrary | Out-Null
    } catch { Update-Status "Error: $_" }
})
$vcpScanBtn.Add_Click({
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { $vcpResultBox.Text = "No DDC/CI"; return }
    $capabilitiesOnly = [bool]$vcpScanCapabilitiesOnlyCheckbox.IsChecked
    if ($capabilitiesOnly) {
        if (-not [bool]$mon.CapabilitiesKnown -or $mon.SupportedVcpCodes.Count -eq 0) {
            $vcpResultBox.Text = "Capabilities VCP list is not available for $($mon.Name). Clear Caps only to probe the full table."
            Update-Status "Capabilities VCP list unavailable"
            return
        }
        $codes = @($mon.SupportedVcpCodes.Keys | Sort-Object)
    } else {
        $codes = @($script:VCPCodeDescriptions.Keys | Sort-Object)
    }
    Start-VcpReadWorker -Handle $mon.Handle -Codes $codes -Mode "Scan" -MonitorName $mon.Name -IdentityKey $mon.IdentityKey -MonitorIndex $script:CurrentMonitorIndex
})

$saveProfileBtn.Add_Click({
    $name = $profileNameBox.Text.Trim(); if ([string]::IsNullOrEmpty($name)) { return }
    $profileObject = New-ProfileObject -Name $name
    if (Save-ProfileObject -Profile $profileObject) { Update-ProfilesList; Update-Status "Saved '$name'" }
})
$loadProfileBtn.Add_Click({
    if ($profilesList.SelectedItem -eq $null) { return }
    Apply-ProfileByName -Name ([string]$profilesList.SelectedItem) | Out-Null
})
$deleteProfileBtn.Add_Click({
    if (-not (Test-ProfileStorageWriteAllowed -Operation "profile deletion")) { return }
    if ($profilesList.SelectedItem -ne $null -and [System.Windows.MessageBox]::Show("Move '$($profilesList.SelectedItem)' and its dependent automation to local Trash?", "Move profile to Trash", "YesNo", "Question") -eq "Yes") {
        $deletedProfile = [string]$profilesList.SelectedItem
        if (Remove-ProfileAndDependencies -Name $deletedProfile) {
            Update-ProfilesList
            Update-AppProfileControls
            Update-ScheduleControls
        }
    }
})
$restoreProfileBtn.Add_Click({
    if (Restore-LatestProfileFromTrash) {
        Update-ProfilesList
        Update-AppProfileControls
        Update-ScheduleControls
    }
})
$purgeProfileTrashBtn.Add_Click({
    $count = @(Get-ProfileTrashRecords).Count
    if ($count -le 0) { Update-ProfileTrashControls; return }
    $message = "Permanently delete all $count recoverable profile record$(if ($count -eq 1) { '' } else { 's' })? This cannot be undone."
    if ([System.Windows.MessageBox]::Show($message, "Empty Profile Trash", "YesNo", "Warning") -eq "Yes") {
        $removed = Clear-ProfileTrash
        Update-ProfileTrashControls
        Update-Status "Permanently deleted $removed profile trash record$(if ($removed -eq 1) { '' } else { 's' })"
    }
})
$exportProfilesBtn.Add_Click({
    Export-ProfileBundle | Out-Null
})
$importProfilesBtn.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Import profile bundle"
    $dialog.Filter = "MonitorControl profile bundles (*.zip)|*.zip|All files (*.*)|*.*"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    $dialog.InitialDirectory = if (Test-Path $script:ProfileExportsPath) { $script:ProfileExportsPath } else { $script:ProfilesPath }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Import-ProfileBundle -BundlePath $dialog.FileName | Out-Null
    }
})
$profileSyncFolderBtn.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select a OneDrive or Dropbox folder for MonitorControl profiles"
    $dialog.ShowNewFolderButton = $true
    $dialog.SelectedPath = if (Test-Path $script:ProfileStorageConfiguredPath) { $script:ProfileStorageConfiguredPath } elseif (Test-Path $script:ProfilesPath) { $script:ProfilesPath } else { $script:DefaultProfilesPath }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Invoke-ProfileStorageMigration -DestinationRoot $dialog.SelectedPath -DestinationMode "Sync" | Out-Null
    }
})
$profileLocalFolderBtn.Add_Click({
    Invoke-ProfileStorageMigration -DestinationRoot $script:DefaultProfilesPath -DestinationMode "Local" | Out-Null
})

$appProfileEnabledCheckbox.Add_Checked({
    if ($script:UpdatingAppProfileUI) { return }
    $script:AppProfileEnabled = $true
    Save-AppProfileRules
    Start-AppProfileWatcher
    Update-AppProfileControls
    Update-Status "Per-application profiles on"
})
$appProfileEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingAppProfileUI) { return }
    $script:AppProfileEnabled = $false
    Save-AppProfileRules
    Start-AppProfileWatcher
    Update-AppProfileControls
    Update-Status "Per-application profiles off"
})
$appProfileCaptureBtn.Add_Click({
    $appProfileStatusText.Text = "Switch apps..."
    if ($script:AppProfileCaptureTimer) { $script:AppProfileCaptureTimer.Stop() }
    $script:AppProfileCaptureTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AppProfileCaptureTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:AppProfileCaptureTimer.Add_Tick({
        $script:AppProfileCaptureTimer.Stop()
        $exe = Get-ForegroundProcessExe
        if ($exe) {
            $appProfileExeBox.Text = $exe
            $appProfileStatusText.Text = "Captured $exe"
        } else {
            $appProfileStatusText.Text = "Capture failed"
        }
        $script:AppProfileCaptureTimer = $null
    })
    $script:AppProfileCaptureTimer.Start()
})
$appProfileAddBtn.Add_Click({
    $exe = Normalize-AppExeName -ExeName $appProfileExeBox.Text
    $profileObject = if ($appProfileProfileCombo.SelectedItem) { [string]$appProfileProfileCombo.SelectedItem } else { "" }
    if (-not $exe -or -not $profileObject) { Update-Status "Choose an app and profile"; return }
    $allowRiskyVcp = [bool]$appProfileRiskyConsentCheckbox.IsChecked
    if ($allowRiskyVcp -and -not (Confirm-AutomationRuleRiskyWriteConsent -RuleLabel "$exe -> $profileObject")) {
        Update-Status "Application rule not added"
        return
    }
    $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Exe -ne $exe })
    $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profileObject; AllowRiskyVcp = $allowRiskyVcp }
    Save-AppProfileRules
    Update-AppProfileControls
    Update-Status "Mapped $exe to '$profileObject'$(if ($allowRiskyVcp) { ' with risky-write consent' } else { '' })"
})
$appProfileRemoveBtn.Add_Click({
    if ($appProfileRulesList.SelectedItem -eq $null) { return }
    $exe = [string]$appProfileRulesList.SelectedItem.Tag
    $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Exe -ne $exe })
    Save-AppProfileRules
    Update-AppProfileControls
    Update-Status "Removed app profile for $exe"
})

if ($scheduleTimelineCanvas) {
    $scheduleTimelineCanvas.Add_SizeChanged({ Update-ScheduleTimeline })
}
$scheduleEnabledCheckbox.Add_Checked({
    if ($script:UpdatingScheduleUI) { return }
    $script:ProfileScheduleEnabled = $true
    Save-ProfileSchedules
    Start-ProfileScheduleWatcher
    Update-ScheduleControls
    Update-Status "Scheduled profiles on"
})
$scheduleEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingScheduleUI) { return }
    $script:ProfileScheduleEnabled = $false
    Save-ProfileSchedules
    Start-ProfileScheduleWatcher
    Update-ScheduleControls
    Update-Status "Scheduled profiles off"
})
$scheduleAddBtn.Add_Click({
    $time = Normalize-ScheduleTime -TimeText $scheduleTimeBox.Text
    $profileObject = if ($scheduleProfileCombo.SelectedItem) { [string]$scheduleProfileCombo.SelectedItem } else { "" }
    if (-not $time -or -not $profileObject) { Update-Status "Use HH:mm and choose a profile"; return }
    $allowRiskyVcp = [bool]$scheduleRiskyConsentCheckbox.IsChecked
    if ($allowRiskyVcp -and -not (Confirm-AutomationRuleRiskyWriteConsent -RuleLabel "$time -> $profileObject")) {
        Update-Status "Schedule rule not added"
        return
    }
    $script:ProfileSchedules = @($script:ProfileSchedules | Where-Object { $_.Time -ne $time })
    $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profileObject; AllowRiskyVcp = $allowRiskyVcp }
    Save-ProfileSchedules
    Update-ScheduleControls
    Update-Status "Scheduled $profileObject at $time$(if ($allowRiskyVcp) { ' with risky-write consent' } else { '' })"
    Invoke-ScheduleCheck
})
$scheduleRemoveBtn.Add_Click({
    if ($scheduleRulesList.SelectedItem -eq $null) { return }
    $time = [string]$scheduleRulesList.SelectedItem.Tag
    $script:ProfileSchedules = @($script:ProfileSchedules | Where-Object { $_.Time -ne $time })
    Save-ProfileSchedules
    Update-ScheduleControls
    Update-Status "Removed schedule at $time"
})

$idleDimEnabledCheckbox.Add_Checked({
    if ($script:UpdatingIdleDimUI) { return }
    if (-not (Read-IdleDimSettingsFromUI)) { return }
    $script:IdleDimEnabled = $true
    Save-IdleDimSettings
    Start-IdleDimWatcher
    Update-IdleDimControls
    Update-Status "Idle dim on"
})
$idleDimEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingIdleDimUI) { return }
    $script:IdleDimEnabled = $false
    Save-IdleDimSettings
    Start-IdleDimWatcher
    Update-IdleDimControls
    Update-Status "Idle dim off"
})
$idleDimSaveBtn.Add_Click({
    if (-not (Read-IdleDimSettingsFromUI)) { return }
    Save-IdleDimSettings
    Start-IdleDimWatcher
    Update-Status "Idle dim settings saved"
})
$batteryProfileEnabledCheckbox.Add_Checked({
    if ($script:UpdatingBatteryProfileUI) { return }
    if (-not (Read-BatteryProfileSettingsFromUI)) { return }
    $script:BatteryProfileEnabled = $true
    Save-BatteryProfileSettings
    Start-BatteryProfileWatcher
    Update-BatteryProfileControls
    Update-Status "Battery profile on"
})
$batteryProfileEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingBatteryProfileUI) { return }
    $script:BatteryProfileEnabled = $false
    Save-BatteryProfileSettings
    Start-BatteryProfileWatcher
    Update-BatteryProfileControls
    Update-Status "Battery profile off"
})
$batteryProfileSaveBtn.Add_Click({
    if (-not (Read-BatteryProfileSettingsFromUI)) { return }
    Save-BatteryProfileSettings
    Start-BatteryProfileWatcher
    Update-Status "Battery profile settings saved"
})

$transactionCancelBtn.Add_Click({ Request-VerifiedVcpTransactionCancel -Reason "user request" | Out-Null })
$displaySettingsBtn.Add_Click({ Start-Process "ms-settings:display" }); $colorMgmtBtn.Add_Click({ Start-Process "colorcpl.exe" })
$gpuControlPanelBtn.Add_Click({ if ($script:HasNvidia) { Start-Process "nvidia-settings" -ErrorAction SilentlyContinue } else { Start-Process "ms-settings:display" } })
$capabilitiesClearCacheBtn.Add_Click({ Clear-CapabilitiesCache; Start-CapabilitiesWorker })
$ddcTimingAdaptiveRadio.Add_Checked({
    if ($script:UpdatingDdcTimingUI) { return }
    $identityKey = Get-SelectedTimingIdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    Set-DdcTimingMode -IdentityKey $identityKey -Mode "Adaptive" | Out-Null
    Save-DdcTimingSettings | Out-Null
    Update-Status "DDC timing set to adaptive; the stored calibration was discarded"
    Update-DdcTimingControls
})
$ddcTimingManualRadio.Add_Checked({
    if ($script:UpdatingDdcTimingUI) { return }
    $identityKey = Get-SelectedTimingIdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    Set-DdcTimingMode -IdentityKey $identityKey -Mode "Manual" | Out-Null
    Save-DdcTimingSettings | Out-Null
    Update-Status "DDC timing set to manual; the learned sleep multiplier is no longer applied"
    Update-DdcTimingControls
})
$ddcTimingResetBtn.Add_Click({
    $identityKey = Get-SelectedTimingIdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    Clear-DdcTimingCalibration -IdentityKey $identityKey | Out-Null
    Save-DdcTimingSettings | Out-Null
    Update-Status "DDC timing calibration and skipped-code list cleared for this monitor"
    Update-DdcTimingControls
})
$ddcValuesRereadBtn.Add_Click({ Invoke-SelectedMonitorVcpReread | Out-Null })
$ddcTimingReadRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Read" -Text $ddcTimingReadRetriesBox.Text } })
$ddcTimingWriteRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Write" -Text $ddcTimingWriteRetriesBox.Text } })
$ddcTimingCapabilityRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Capability" -Text $ddcTimingCapabilityRetriesBox.Text } })
$ddcVerifyPolicyCombo.Add_SelectionChanged({
    if ($script:UpdatingDdcTimingUI -or $null -eq $ddcVerifyPolicyCombo.SelectedValue) { return }
    Set-DdcVerifyPolicyFromUi -Policy ([string]$ddcVerifyPolicyCombo.SelectedValue)
})
$displayRestoreEnabledCheckbox.Add_Checked({
    if ($script:UpdatingDisplayStateRestoreUI) { return }
    Set-DisplayStateRestoreEnabled -Enabled $true
})
$displayRestoreEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingDisplayStateRestoreUI) { return }
    Set-DisplayStateRestoreEnabled -Enabled $false
})
$cpuMonitorEnabledCheckbox.Add_Checked({
    if ($script:UpdatingOptionalHelperUI) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "MonitorControl Pro will load a CPU temperature library from disk into this process." + [Environment]::NewLine + [Environment]::NewLine +
        "It looks beside this script, in Program Files, and reports the resolved path, version, and SHA-256 in System. Only enable this if you placed that DLL there yourself." + [Environment]::NewLine + [Environment]::NewLine +
        "Load the CPU temperature library?",
        "Optional hardware helper",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        Update-OptionalHelperControls
        Update-Status "CPU temperature library stays disabled"
        return
    }
    Set-CpuMonitorEnabled -Enabled $true
})
$cpuMonitorEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingOptionalHelperUI) { return }
    Set-CpuMonitorEnabled -Enabled $false
})
$presentMonEnabledCheckbox.Add_Checked({
    if ($script:UpdatingOptionalHelperUI) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "MonitorControl Pro will run PresentMon.exe as a child process to sample frame times." + [Environment]::NewLine + [Environment]::NewLine +
        "It prefers a copy beside this script or in Program Files over one found on PATH, and reports the resolved path, version, and SHA-256 in System. Only enable this if you installed PresentMon yourself." + [Environment]::NewLine + [Environment]::NewLine +
        "Allow PresentMon to run?",
        "Optional hardware helper",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        Update-OptionalHelperControls
        Update-Status "PresentMon stays disabled"
        return
    }
    Set-PresentMonEnabled -Enabled $true
})
$presentMonEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingOptionalHelperUI) { return }
    Set-PresentMonEnabled -Enabled $false
})
$capabilitiesDiscoveryEnabledCheckbox.Add_Checked({
    if ($script:UpdatingCapabilitiesSafetyUI) { return }
    if (-not (Request-CapabilitiesDiscoveryConsent)) {
        Sync-CapabilitySafetyUi
        Update-Status "Capability discovery remains disabled"
        return
    }
    $script:CapabilitiesMaximumCompatibility = $false
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Capability discovery enabled"
})
$capabilitiesDiscoveryEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingCapabilitiesSafetyUI) { return }
    $script:CapabilitiesDiscoveryEnabled = $false
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Capability discovery disabled"
})
$capabilitiesMaximumCompatibilityCheckbox.Add_Checked({
    if ($script:UpdatingCapabilitiesSafetyUI) { return }
    $script:CapabilitiesMaximumCompatibility = $true
    $script:CapabilitiesDiscoveryEnabled = $false
    $script:CapabilitiesConsentRecorded = $true
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Maximum compatibility enabled; capability strings will not be requested"
})
$capabilitiesMaximumCompatibilityCheckbox.Add_Unchecked({
    if ($script:UpdatingCapabilitiesSafetyUI) { return }
    $script:CapabilitiesMaximumCompatibility = $false
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Maximum compatibility disabled; capability discovery remains off"
})
$capabilitiesExcludeCurrentBtn.Add_Click({
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $selected = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    $identityKey = [string]$selected.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return }
    $script:CapabilitiesExcludedIdentityKeys[$identityKey] = $true
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Capability discovery excluded for $(Get-MonitorDisplayLabel -Monitor $selected)"
})
$capabilitiesClearExclusionsBtn.Add_Click({
    if ($script:CapabilitiesExcludedIdentityKeys.Count -eq 0) { return }
    $result = [System.Windows.MessageBox]::Show(
        "Clear all capability-discovery exclusions? Previously failing monitors may be probed again if discovery is enabled.",
        "Clear capability exclusions",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $script:CapabilitiesExcludedIdentityKeys = @{}
    $script:CapabilitiesLastIncidentIdentityKey = ""
    $script:CapabilitiesLastIncidentAt = ""
    Write-CapabilitySafetyState | Out-Null
    Invoke-CapabilityDiscovery
    Update-Status "Capability exclusions cleared"
})
$riskyVcpEnabledCheckbox.Add_Checked({
    if ($script:UpdatingVcpWriteSafetyUI) { return }
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { Sync-VcpWriteSafetyUi; return }
    $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    if ([string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey)) { Sync-VcpWriteSafetyUi; return }
    $message = @"
Enable risky VCP writes for $(Get-MonitorDisplayLabel -Monitor $monitor)?

This unlock is stored only for this stable monitor identity. Power, input, reset, PiP/PbP, and arbitrary writes can blank the display, switch away from this computer, or erase monitor settings.

Every direct command will still show its exact VCP code and value for confirmation. Automation rules require separate rule-level consent.
"@
    $choice = [System.Windows.MessageBox]::Show(
        $message,
        "Enable risky VCP writes",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
        Sync-VcpWriteSafetyUi
        Update-Status "Risky VCP writes remain disabled"
        return
    }
    if (-not (Set-VcpWriteEnabledForMonitor -Monitor $monitor -Enabled $true)) {
        $null = $script:RiskyVcpEnabledIdentityKeys.Remove([string]$monitor.IdentityKey)
        Sync-VcpWriteSafetyUi
        Update-Status "Risky VCP write permission could not be saved"
        return
    }
    Update-CapabilityControls -Monitor $monitor
    Update-Status "Risky VCP writes enabled for $(Get-MonitorDisplayLabel -Monitor $monitor)"
})
$riskyVcpEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingVcpWriteSafetyUI) { return }
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { Sync-VcpWriteSafetyUi; return }
    $monitor = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
    $wasEnabled = Test-VcpWriteEnabledForMonitor -Monitor $monitor
    if (-not (Set-VcpWriteEnabledForMonitor -Monitor $monitor -Enabled $false)) {
        if ($wasEnabled) { $script:RiskyVcpEnabledIdentityKeys[[string]$monitor.IdentityKey] = $true }
        Sync-VcpWriteSafetyUi
        Update-Status "Risky VCP write permission could not be disabled"
        return
    }
    Update-CapabilityControls -Monitor $monitor
    Update-Status "Risky VCP writes disabled for $(Get-MonitorDisplayLabel -Monitor $monitor)"
})
$automationBridgeEnabledCheckbox.Add_Checked({
    if ($script:UpdatingAutomationBridgeUI) { return }
    if (-not (Read-AutomationBridgeSettingsFromUI)) { $automationBridgeEnabledCheckbox.IsChecked = $false; return }
    $script:AutomationBridgeEnabled = $true
    if (-not (Save-AutomationBridgeSettings)) {
        $script:AutomationBridgeEnabled = $false
        Update-AutomationBridgeControls
        return
    }
    Start-AutomationBridge
})
$automationBridgeEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingAutomationBridgeUI) { return }
    if ($null -eq $automationBridgeStatusText) { return }
    Read-AutomationBridgeSettingsFromUI | Out-Null
    $script:AutomationBridgeEnabled = $false
    $saved = Save-AutomationBridgeSettings
    Stop-AutomationBridge
    if ($saved) { Update-Status "Bridge off" } else { Update-Status "Bridge stopped, but the disabled state could not be saved" }
})
$automationBridgeSaveBtn.Add_Click({
    if (-not (Read-AutomationBridgeSettingsFromUI)) { return }
    if (-not (Save-AutomationBridgeSettings)) { Update-AutomationBridgeControls; return }
    if ($script:AutomationBridgeEnabled) { Start-AutomationBridge } else { Stop-AutomationBridge }
    Update-Status "Bridge settings saved"
})
$runAtLoginEnabledCheckbox.Add_Checked({
    if ($script:UpdatingRunAtLoginUI) { return }
    try {
        Set-RunAtLoginEnabled -Enabled $true | Out-Null
        Update-Status "MonitorControl will run at login"
    } catch {
        Update-Status "Run at login could not be enabled: $($_.Exception.Message)"
    }
    Update-RunAtLoginControls
})
$runAtLoginEnabledCheckbox.Add_Unchecked({
    if ($script:UpdatingRunAtLoginUI) { return }
    try {
        Set-RunAtLoginEnabled -Enabled $false | Out-Null
        Update-Status "Run at login disabled"
    } catch {
        Update-Status "Run at login could not be disabled: $($_.Exception.Message)"
    }
    Update-RunAtLoginControls
})
$ddcReportGenerateBtn.Add_Click({ Start-DdcReportWorker })
$ddcReportCopyBtn.Add_Click({
    $text = if ($script:DdcReportLastText) { $script:DdcReportLastText } else { $ddcReportBox.Text }
    if (Copy-DdcCompatibilityReport -Text $text) { Update-Status "DDC report copied" } else { Update-Status "No DDC report to copy" }
})
$fpsOverlayStartBtn.Add_Click({ Show-FpsOverlay })
$fpsOverlayStopBtn.Add_Click({ Hide-FpsOverlay })
$vibranceSlider.Add_ValueChanged({
    if ($script:UpdatingUI) { return }
    $level = [int]$vibranceSlider.Value
    $vibranceValue.Text = $level.ToString()
    $message = ""
    [NvApiInterop]::SetDigitalVibrance($level, [ref]$message) | Out-Null
    Update-Status $message
})
$resetGammaBtn.Add_Click({ Set-GammaRamp -Gamma 1.0; $script:UpdatingUI = $true; $gammaSlider.Value = 100; $gammaValue.Text = "1.00"; $gammaRedSlider.Value = 100; $gammaRedValue.Text = "1.00"; $gammaGreenSlider.Value = 100; $gammaGreenValue.Text = "1.00"; $gammaBlueSlider.Value = 100; $gammaBlueValue.Text = "1.00"; $script:UpdatingUI = $false; Update-Status "Gamma Reset" })
$gammaSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $g = $gammaSlider.Value / 100; $gammaValue.Text = $g.ToString("F2"); Set-GammaRamp -Gamma $g -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaRedSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaRedValue.Text = ($gammaRedSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaGreenSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaGreenValue.Text = ($gammaGreenSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaBlueSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaBlueValue.Text = ($gammaBlueSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })

function Update-GpuStats {
    if ($script:HasNvidia -or $script:HasAmd) {
        $stats = if ($script:HasNvidia) { Get-NvidiaStats } else { $null }
        if (-not $stats -and $script:HasAmd) { $stats = Get-AmdStats }
        if ($stats) {
            $gpuNameText.Text = $stats.Name; $gpuTempText.Text = $stats.Temp.ToString(); $gpuStatsText.Text = "$($stats.Temp) C | $($stats.Clock) MHz | $($stats.Power) W"
            $gpuUtilText.Text = "$($stats.Util)%"; $gpuUtilBar.Value = $stats.Util; $memUsageText.Text = "$($stats.MemUsed) / $($stats.MemTotal) GB"
            $memUtilBar.Value = if ($stats.MemTotal -gt 0) { ($stats.MemUsed / $stats.MemTotal) * 100 } else { 0 }
            $fanSpeedText.Text = "$($stats.Fan)%"; $fanSpeedBar.Value = $stats.Fan; $powerDrawText.Text = "$($stats.Power) / $($stats.PowerLimit) W"
            $powerDrawBar.Value = if ($stats.PowerLimit -gt 0) { ($stats.Power / $stats.PowerLimit) * 100 } else { 0 }
            if ($stats.Message) { Update-Status $stats.Message }
        }
    }
    if ($script:HasCpuTempMonitor) {
        $cpuTemp = Get-CpuTemperature
        $cpuTempText.Text = if ($null -ne $cpuTemp) { "CPU: $cpuTemp C ($script:HardwareMonitorKind)" } else { "CPU: sensor unavailable" }
    }
}

function Save-NavigationRenderFrame {
    param($Page, [string]$RenderRoot)
    $window.UpdateLayout()
    $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($shellRoot.ActualWidth))
    $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($shellRoot.ActualHeight))
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $pixelWidth,
        $pixelHeight,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($shellRoot)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $outputPath = Join-Path $RenderRoot $Page.Name
    $stream = New-Object System.IO.FileStream(
        $outputPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Export-NavigationRenders {
    param([string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }

    $script:NavigationRenderRoot = [System.IO.Path]::GetFullPath($Directory)
    [System.IO.Directory]::CreateDirectory($script:NavigationRenderRoot) | Out-Null
    $completePath = Join-Path $script:NavigationRenderRoot "render.complete"
    $errorPath = Join-Path $script:NavigationRenderRoot "render.error.txt"
    if ([System.IO.File]::Exists($completePath)) { [System.IO.File]::Delete($completePath) }
    if ([System.IO.File]::Exists($errorPath)) { [System.IO.File]::Delete($errorPath) }

    $script:NavigationRenderSelectedTab = @($displayTab,$monitorTab,$gpuTab,$vcpTab,$profilesTab,$scheduleTab,$systemTab) |
        Where-Object { $_ -and $_.IsSelected } |
        Select-Object -First 1
    $script:NavigationRenderPages = @(
        [PSCustomObject]@{ Name = "display.png"; Tab = $displayTab },
        [PSCustomObject]@{ Name = "monitor.png"; Tab = $monitorTab },
        [PSCustomObject]@{ Name = "hardware.png"; Tab = $gpuTab },
        [PSCustomObject]@{ Name = "vcp-explorer.png"; Tab = $vcpTab },
        [PSCustomObject]@{ Name = "profiles.png"; Tab = $profilesTab },
        [PSCustomObject]@{ Name = "automation.png"; Tab = $scheduleTab },
        [PSCustomObject]@{ Name = "system.png"; Tab = $systemTab }
    ) | Where-Object { $_.Tab -and $_.Tab.Visibility -eq [System.Windows.Visibility]::Visible }
    $script:NavigationRenderIndex = 0
    $script:NavigationRenderReady = $false
    $script:NavigationRenderTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:NavigationRenderTimer.Interval = [TimeSpan]::FromMilliseconds(175)
    $script:NavigationRenderTimer.Add_Tick({
        try {
            if (-not $script:NavigationRenderReady) {
                $script:NavigationRenderPages[0].Tab.IsSelected = $true
                $window.UpdateLayout()
                $script:NavigationRenderReady = $true
                return
            }

            $page = $script:NavigationRenderPages[$script:NavigationRenderIndex]
            Save-NavigationRenderFrame -Page $page -RenderRoot $script:NavigationRenderRoot
            $script:NavigationRenderIndex++
            if ($script:NavigationRenderIndex -ge $script:NavigationRenderPages.Count) {
                $script:NavigationRenderTimer.Stop()
                if ($script:NavigationRenderSelectedTab) {
                    $script:NavigationRenderSelectedTab.IsSelected = $true
                    $window.UpdateLayout()
                }
                [System.IO.File]::WriteAllText(
                    (Join-Path $script:NavigationRenderRoot "render.complete"),
                    [string]$script:NavigationRenderPages.Count,
                    (New-Object System.Text.UTF8Encoding($false))
                )
                return
            }
            $script:NavigationRenderPages[$script:NavigationRenderIndex].Tab.IsSelected = $true
            $window.UpdateLayout()
        } catch {
            $script:NavigationRenderTimer.Stop()
            [System.IO.File]::WriteAllText(
                (Join-Path $script:NavigationRenderRoot "render.error.txt"),
                $_.Exception.ToString(),
                (New-Object System.Text.UTF8Encoding($false))
            )
        }
    })
    $script:NavigationRenderTimer.Start()
}

# Initialize
Initialize-WmiBrightness; Load-MonitorIdentitySettings; Import-CapabilitySafetyState; Import-VcpWriteSafetyState; Import-OptionalHelperSettings; Import-DisplayStateRestoreSettings; Import-CapabilitiesCache; Import-DdcTimingSettings; Get-Monitors; Initialize-GPU; Initialize-CpuMonitor; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList
Load-AppProfileRules; Update-AppProfileControls; Start-AppProfileWatcher
Load-ProfileSchedules; Update-ScheduleControls; Start-ProfileScheduleWatcher
Load-IdleDimSettings; Update-IdleDimControls; Start-IdleDimWatcher
Load-BatteryProfileSettings; Update-BatteryProfileControls; Start-BatteryProfileWatcher
Load-AutomationBridgeSettings; Update-AutomationBridgeControls; Start-AutomationBridge
Update-RunAtLoginControls
Update-ProfileStorageControls
Sync-CapabilitySafetyUi
Sync-VcpWriteSafetyUi
Update-OptionalHelperControls
Update-DisplayStateRestoreControls
Update-DdcTimingControls
Update-HardwareTabVisibility

Initialize-TrayIcon

$mainNavigationTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if (-not [object]::ReferenceEquals($eventArgs.OriginalSource, $sender)) { return }
    $anchorShell = [Action]{
        if ($shellScrollViewer) {
            $shellScrollViewer.ScrollToHorizontalOffset(0)
            $shellScrollViewer.ScrollToVerticalOffset(0)
        }
    }
    $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ContextIdle,
        $anchorShell
    ) | Out-Null
})

$window.Add_SourceInitialized({
    Initialize-DisplayRecoveryEventPipeline
})

$window.Add_ContentRendered({
    if ($script:CapabilitiesConsentPromptHandled) { return }
    $script:CapabilitiesConsentPromptHandled = $true
    if (-not $script:CapabilitiesConsentRecorded -and -not $script:CapabilitiesMaximumCompatibility) {
        Request-CapabilitiesDiscoveryConsent | Out-Null
    }
    Sync-CapabilitySafetyUi
    Start-CapabilitiesWorker
})

if (-not [string]::IsNullOrWhiteSpace($RenderDirectory)) {
    $script:NavigationRenderExported = $false
    $window.Add_ContentRendered({
        if ($script:NavigationRenderExported) { return }
        $script:NavigationRenderExported = $true
        try {
            Export-NavigationRenders -Directory $RenderDirectory
        } catch {
            [System.Diagnostics.Trace]::TraceError("Navigation render export failed: $($_.Exception.Message)")
        }
    })
}

$window.Add_StateChanged({
    if ($script:TraySuppressWindowStateEvent -or $script:IsQuitting) { return }
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { Hide-MainWindowToTray }
})

$window.Add_Closed({ Stop-SystemAccessibility; if ($script:NavigationRenderTimer) { $script:NavigationRenderTimer.Stop() }; if ($script:GpuTimer) { $script:GpuTimer.Stop() }; if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; if ($script:AmbientLightTimer) { $script:AmbientLightTimer.Stop() }; if ($script:AppProfileTimer) { $script:AppProfileTimer.Stop() }; if ($script:AppProfileCaptureTimer) { $script:AppProfileCaptureTimer.Stop() }; if ($script:ProfileScheduleTimer) { $script:ProfileScheduleTimer.Stop() }; if ($script:IdleDimTimer) { $script:IdleDimTimer.Stop() }; if ($script:BatteryProfileTimer) { $script:BatteryProfileTimer.Stop() }; if ($script:FpsOverlayTimer) { $script:FpsOverlayTimer.Stop() }; if ($script:DdcWriteResultTimer) { $script:DdcWriteResultTimer.Stop() }; foreach ($timer in @($script:DeferredRefreshTimers)) { try { $timer.Stop() } catch {} }; $script:DeferredRefreshTimers = @(); Stop-DisplayRecoveryEventPipeline; Stop-AutomationBridge; Stop-VerifiedVcpTransactionWorker -Cancel -WaitForCompletion; Stop-VcpWorker -Cancel; Stop-MonitorSettingsWorker -Cancel; Stop-CapabilitiesWorker -Cancel; Stop-DdcReportWorker -Cancel
    if ($script:FpsOverlayWindow) { try { $script:FpsOverlayWindow.Close() } catch {} }
    if ($script:HardwareMonitorComputer) { try { $script:HardwareMonitorComputer.Close() } catch {} }
    Dispose-TrayMode
    if (-not (Clear-PhysicalMonitorHandles -ClearList -KeepWritesCancelled)) {
        [System.Diagnostics.Trace]::TraceError("MonitorControl closed before the DDC write worker released its physical monitor handles; native destruction was skipped.")
    }
})

if ($StartMinimized) {
    $window.Add_ContentRendered({
        $script:TraySuppressWindowStateEvent = $true
        try {
            $window.WindowState = [System.Windows.WindowState]::Minimized
            Hide-MainWindowToTray
        } finally {
            $script:TraySuppressWindowStateEvent = $false
        }
    })
}
if ($LoadProfile) {
    $safeLoadProfile = Get-SafeProfileName -Name $LoadProfile
    if ($safeLoadProfile -and (Test-Path -LiteralPath (Join-Path $script:ProfilesPath "$safeLoadProfile.json"))) {
        $profilesList.SelectedItem = $safeLoadProfile
        $loadProfileBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
}

$window.ShowDialog() | Out-Null
