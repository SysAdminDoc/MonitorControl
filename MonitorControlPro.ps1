<#
.SYNOPSIS
    MonitorControl Pro v3.36.0 - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version: 3.36.0 - Cached capability strings and a known-bad monitor model list
#>

param(
    [switch]$StartMinimized,
    [string]$LoadProfile,
    [ValidateSet("System", "Dark", "HighContrast")]
    [string]$Theme = "System",
    [ValidateRange(0, 200)]
    [int]$TextScalePercent = 0
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationTypes, UIAutomationProvider, System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem, System.Management

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
    }

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
    private static readonly Dictionary<string, uint> VcpValueCache = new Dictionary<string, uint>();
    private static long SuppressedVcpWrites = 0;

    private static string VcpCacheKey(IntPtr hMonitor, byte bVCPCode)
    {
        return hMonitor.ToInt64().ToString("X") + ":" + bVCPCode.ToString("X2");
    }

    public static void RecordVcpValue(IntPtr hMonitor, byte bVCPCode, uint value)
    {
        if (hMonitor == IntPtr.Zero) { return; }
        lock (VcpValueCacheLock) { VcpValueCache[VcpCacheKey(hMonitor, bVCPCode)] = value; }
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
        lock (VcpValueCacheLock) { return VcpValueCache.TryGetValue(VcpCacheKey(hMonitor, bVCPCode), out value); }
    }

    // Handles are destroyed and reissued on every re-enumeration, so a stale entry could be
    // matched against an unrelated monitor. Any topology change must drop the whole cache.
    public static void InvalidateVcpValueCache()
    {
        lock (VcpValueCacheLock) { VcpValueCache.Clear(); }
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
    public const int VcpReadRetryCount = 2;
    public const int VcpWriteRetryCount = 2;
    public const int VcpRetryDelayMilliseconds = 60;
    public const int VcpRetryDelayCeilingMilliseconds = 2000;

    public static void QueueVCPWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, string coalesceKey, string monitorName)
    {
        QueueVCPWrite(hMonitor, bVCPCode, dwNewValue, coalesceKey, monitorName, false);
    }

    // Pure predicate so the decision can be exercised without touching hardware.
    public static bool ShouldSuppressVcpWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, bool force)
    {
        if (force || hMonitor == IntPtr.Zero) { return false; }
        uint known;
        return TryGetVcpValue(hMonitor, bVCPCode, out known) && known == dwNewValue;
    }

    public static void QueueVCPWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, string coalesceKey, string monitorName, bool force)
    {
        if (hMonitor == IntPtr.Zero) { return; }
        if (ShouldSuppressVcpWrite(hMonitor, bVCPCode, dwNewValue, force))
        {
            Interlocked.Increment(ref SuppressedVcpWrites);
            return;
        }
        string key = String.IsNullOrEmpty(coalesceKey) ? hMonitor.ToInt64().ToString("X") + ":" + bVCPCode.ToString("X2") : coalesceKey;
        lock (VcpWriteQueueLock)
        {
            QueuedVcpWrites[key] = new QueuedVcpWrite { Handle = hMonitor, Code = bVCPCode, Value = dwNewValue, Key = key, MonitorName = monitorName };
            if (!VcpWriteWorkerActive)
            {
                VcpWriteWorkerActive = true;
                ThreadPool.QueueUserWorkItem(ProcessQueuedVcpWrites);
            }
        }
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
            bool ok = SetVCPFeature(hMonitor, bVCPCode, dwNewValue);
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

try { Add-Type -TypeDefinition $nativeCode -ErrorAction SilentlyContinue } catch {}
try { [MonitorAPI]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch {}

function Set-DeferredStatus {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    try {
        if ($statusText) { Update-Status $Message; return }
    } catch {}
    $script:PendingStatusMessage = $Message
}

function Test-JsonFileValid {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Move-CorruptJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $dir "$leaf.corrupt-$stamp"
    $suffix = 0
    while (Test-Path -LiteralPath $target) {
        $suffix++
        $target = Join-Path $dir "$leaf.corrupt-$stamp-$suffix"
    }
    try {
        Move-Item -LiteralPath $fullPath -Destination $target -Force
        return $target
    } catch {
        return ""
    }
}

function Read-JsonFileSafely {
    param([string]$Path, [string]$Label = "JSON", [switch]$ReadOnly)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        $backupPath = "$Path.bak"
        if ($ReadOnly) {
            if (Test-Path -LiteralPath $backupPath) {
                try {
                    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
                    Set-DeferredStatus "$Label JSON corrupt; read-only fallback left untouched and backup loaded"
                    return $backup
                } catch { $null = $_ }
            }
            Set-DeferredStatus "$Label JSON corrupt; read-only fallback left untouched"
            return $null
        }
        $quarantinePath = Move-CorruptJsonFile -Path $Path
        $leaf = if ($quarantinePath) { Split-Path -Path $quarantinePath -Leaf } else { "quarantine failed" }
        if (Test-Path -LiteralPath $backupPath) {
            try {
                $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
                Set-DeferredStatus "$Label JSON corrupt; quarantined to $leaf and loaded backup"
                return $backup
            } catch {}
        }
        Set-DeferredStatus "$Label JSON corrupt; quarantined to $leaf"
        return $null
    }
}

function Write-JsonFileSafely {
    param([string]$Path, $Data, [int]$Depth = 4)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    $tempPath = Join-Path $dir ".$leaf.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Data | ConvertTo-Json -Depth $Depth
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, ($json + [Environment]::NewLine), $encoding)
        $backupPath = "$fullPath.bak"
        if (Test-Path -LiteralPath $fullPath) {
            if (Test-JsonFileValid -Path $fullPath) {
                [System.IO.File]::Replace($tempPath, $fullPath, $backupPath)
            } else {
                Move-CorruptJsonFile -Path $fullPath | Out-Null
                [System.IO.File]::Move($tempPath, $fullPath)
            }
        } else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
        return $true
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Set-DeferredStatus "JSON write failed: $($_.Exception.Message)"
        return $false
    }
}

function Resolve-ProfileStorageRootState {
    param(
        $Settings,
        [string]$DefaultPath,
        [int]$CurrentSchemaVersion = 2
    )
    $defaultFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DefaultPath))
    $configuredPath = $defaultFullPath
    $fallbackPath = $defaultFullPath
    $previousPath = ""
    $mode = "Local"
    $offline = $false
    $message = ""
    if ($null -ne $Settings) {
        $schemaVersion = if ($Settings.PSObject.Properties.Name -contains "SchemaVersion") { [int]$Settings.SchemaVersion } else { 1 }
        if ($schemaVersion -gt $CurrentSchemaVersion) {
            $offline = $true
            $message = "Profile storage settings are newer than this app; showing the local library read-only"
        } else {
            if ($Settings.PSObject.Properties.Name -contains "ProfilePath" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.ProfilePath)) {
                $configuredPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Settings.ProfilePath))
            }
            if ($Settings.PSObject.Properties.Name -contains "FallbackPath" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.FallbackPath)) {
                $fallbackPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Settings.FallbackPath))
            }
            if ($Settings.PSObject.Properties.Name -contains "PreviousPath") { $previousPath = [string]$Settings.PreviousPath }
            if ($Settings.PSObject.Properties.Name -contains "Mode" -and -not [string]::IsNullOrWhiteSpace([string]$Settings.Mode)) {
                $mode = [string]$Settings.Mode
            }
            if (-not (Test-Path -LiteralPath $configuredPath -PathType Container)) {
                $offline = $true
                $message = "Profile storage is offline; showing the last available library read-only"
            }
        }
    }
    $activePath = if (-not $offline) {
        $configuredPath
    } elseif (Test-Path -LiteralPath $fallbackPath -PathType Container) {
        $fallbackPath
    } else {
        $defaultFullPath
    }
    return [PSCustomObject]@{
        ProfilesPath = [string]$activePath
        ConfiguredPath = [string]$configuredPath
        FallbackPath = [string]$fallbackPath
        PreviousPath = [string]$previousPath
        Mode = [string]$mode
        Offline = [bool]$offline
        Message = [string]$message
    }
}

function Get-SafeProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $trimmed = $Name.Trim()
    if ([System.IO.Path]::GetFileName($trimmed) -ne $trimmed) { return "" }
    if ($trimmed.TrimEnd(" ", ".") -ne $trimmed) { return "" }
    $safeName = [System.IO.Path]::GetFileNameWithoutExtension($trimmed)
    if ([string]::IsNullOrWhiteSpace($safeName)) { return "" }
    if ($safeName.TrimEnd(" ", ".") -ne $safeName) { return "" }
    if ($safeName -eq "." -or $safeName -eq "..") { return "" }
    if ($safeName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return "" }
    if ($safeName.ToUpperInvariant() -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return "" }
    if ($script:ProfileMetadataFiles -and $script:ProfileMetadataFiles -contains "$safeName.json") { return "" }
    return $safeName
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
$script:CapabilitiesWorker = $null
$script:CapabilitiesWorkerInput = $null
$script:CapabilitiesWorkerOutput = $null
$script:CapabilitiesWorkerAsyncResult = $null
$script:CapabilitiesWorkerTimer = $null
$script:CapabilitiesWorkerLastOutputCount = 0
$script:CapabilitiesWorkerGeneration = -1
$script:CapabilitiesSafetySettingsPath = ""
$script:CapabilitiesProbeSentinelPath = ""
$script:CapabilitiesSafetySchemaVersion = 1
$script:CapabilitiesConsentRecorded = $false
$script:CapabilitiesDiscoveryEnabled = $false
$script:CapabilitiesMaximumCompatibility = $false
$script:CapabilitiesExcludedIdentityKeys = @{}
$script:CapabilitiesLastIncidentIdentityKey = ""
$script:CapabilitiesLastIncidentAt = ""
$script:UpdatingCapabilitiesSafetyUI = $false
$script:CapabilitiesConsentPromptHandled = $false
$script:VcpWriteSafetySettingsPath = ""
$script:VcpWriteSafetySchemaVersion = 1
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
$script:DdcReportOutputPath = ""
$script:AutomationBridgeSettingsPath = ""
$script:AutomationBridgeWriteLogPath = ""
$script:AutomationBridgeEnabled = $false
$script:AutomationBridgeBindAddress = "127.0.0.1"
$script:AutomationBridgePort = 34291
$script:AutomationBridgeApiKey = ""
$script:AutomationBridgeMqttEnabled = $false
$script:AutomationBridgeSettingsSchemaVersion = 2
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
$script:DdcTimingSchemaVersion = 1
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
$script:AutomationBridgeWriteLogPath = Join-Path $script:DefaultProfilesPath "automation-bridge-writes.jsonl"
$script:CapabilitiesCachePath = Join-Path $script:DefaultProfilesPath "capabilities-cache.json"
$script:DdcTimingSettingsPath = Join-Path $script:DefaultProfilesPath "ddc-timing.json"
$script:CapabilitiesCacheSchemaVersion = 1
$script:CapabilitiesCache = @{}
# Reading a capability string is the one call Microsoft documents as able to bring down
# Windows on a monitor with a malformed EDID, so a model known to do that is never asked.
# Keyed on the EDID manufacturer + product code. Entries cite the upstream report.
$script:CapabilitiesKnownBadModels = @(
    [PSCustomObject]@{ EdidId = "LTM2C02"; Note = "Counterfeit-EDID LG 27MR400; kernel fault in win32kfull (PowerToys 47556)" }
    [PSCustomObject]@{ EdidId = "GSM7714"; Note = "LG UltraWide HDR WFHD; kernel fault in win32kfull (PowerToys 47968)" }
)
$script:DisplayStateRestoreSettingsPath = Join-Path $script:DefaultProfilesPath "display-restore.json"
$script:DisplayStateRestoreSchemaVersion = 1
# Monitors commonly reset themselves to full brightness after a power cycle or a sleep
# cycle. Restoring is opt-in because it writes to hardware without the user asking.
$script:DisplayStateRestoreEnabled = $false
$script:DisplayStateRestoreValues = @{}
$script:DisplayStateRestoreGeneration = -1
$script:UpdatingDisplayStateRestoreUI = $false
$script:UpdatingDdcTimingUI = $false
$script:OptionalHelperSettingsPath = Join-Path $script:DefaultProfilesPath "optional-helpers.json"
$script:OptionalHelperSchemaVersion = 1
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
$script:ProfileStorageSchemaVersion = 2
$script:ProfileStorageOffline = $false
$script:ProfileStorageConfiguredPath = $script:DefaultProfilesPath
$script:ProfileStorageFallbackPath = $script:DefaultProfilesPath
$script:ProfileStoragePreviousPath = ""
if (-not (Test-Path -LiteralPath $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
if (Test-Path -LiteralPath $script:ProfileStorageSettingsPath) {
    try {
        $profileStorage = Read-JsonFileSafely -Path $script:ProfileStorageSettingsPath -Label "Profile storage"
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
$script:ProfileSchemaVersion = 4
$script:ProfileBundleSchemaVersion = 2
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
    "App.Subtitle" = "Version 3.36.0"
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

$script:VCPCodeDescriptions = @{
    0x04 = "Factory Reset"; 0x08 = "Reset Color"; 0x10 = "Brightness"; 0x12 = "Contrast"
    0x14 = "Color Preset"; 0x16 = "Red Gain"; 0x18 = "Green Gain"; 0x1A = "Blue Gain"
    0x60 = "Input Source"; 0x62 = "Volume"; 0x72 = "Gamma"; 0x87 = "Sharpness"; 0x8D = "Mute"
    0xC0 = "Display Usage Time"; 0xC6 = "Application Enable Key"; 0xCA = "OSD/Button Control"; 0xCC = "OSD Language"
    0xCD = "Status Indicators / LED"; 0xD6 = "Power Mode"; 0xD7 = "Aux Power Output"; 0xDC = "Display Mode"; 0xDF = "VCP Version"
    0xE8 = "Secondary Input Source"; 0xE9 = "PiP/PbP Mode"
}

function Get-CapabilitiesSection {
    param([string]$Capabilities, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Capabilities) -or [string]::IsNullOrWhiteSpace($Name)) { return "" }
    $match = [regex]::Match($Capabilities, "(?i)\b$([regex]::Escape($Name))\s*\(")
    if (-not $match.Success) { return "" }
    $start = $match.Index + $match.Length
    $depth = 1
    for ($i = $start; $i -lt $Capabilities.Length; $i++) {
        $ch = $Capabilities[$i]
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $Capabilities.Substring($start, $i - $start) }
        }
    }
    return ""
}

function Get-HexTokens {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @([regex]::Matches($Text, '(?i)\b(?:0x)?[0-9a-f]{1,2}\b') | ForEach-Object {
        $token = $_.Value
        if ($token.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) { $token = $token.Substring(2) }
        [Convert]::ToInt32($token, 16)
    })
}

function ConvertFrom-MonitorCapabilities {
    param([string]$Capabilities)
    $map = @{}
    $section = Get-CapabilitiesSection -Capabilities $Capabilities -Name "vcp"
    if ([string]::IsNullOrWhiteSpace($section)) {
        return [PSCustomObject]@{ Known = $false; Codes = $map; Count = 0 }
    }
    $i = 0
    while ($i -lt $section.Length) {
        while ($i -lt $section.Length -and [char]::IsWhiteSpace($section[$i])) { $i++ }
        if ($i -ge $section.Length) { break }
        $start = $i
        while ($i -lt $section.Length -and $section[$i] -match '[0-9A-Fa-fxX]') { $i++ }
        if ($i -eq $start) { $i++; continue }
        $token = $section.Substring($start, $i - $start)
        if ($token.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) { $token = $token.Substring(2) }
        if ($token -notmatch '^[0-9A-Fa-f]{1,2}$') { continue }
        $code = [Convert]::ToInt32($token, 16)
        while ($i -lt $section.Length -and [char]::IsWhiteSpace($section[$i])) { $i++ }
        $values = @()
        if ($i -lt $section.Length -and $section[$i] -eq '(') {
            $i++
            $valueStart = $i
            $depth = 1
            while ($i -lt $section.Length -and $depth -gt 0) {
                if ($section[$i] -eq '(') { $depth++ }
                elseif ($section[$i] -eq ')') { $depth-- }
                if ($depth -gt 0) { $i++ }
            }
            $valueText = $section.Substring($valueStart, [Math]::Max(0, $i - $valueStart))
            $values = Get-HexTokens -Text $valueText
            if ($i -lt $section.Length -and $section[$i] -eq ')') { $i++ }
        }
        $map[$code] = @($values)
    }
    return [PSCustomObject]@{ Known = $true; Codes = $map; Count = $map.Count }
}

function Test-MonitorSupportsVcp {
    param($Monitor, [int]$Code)
    if ($null -eq $Monitor -or -not [bool]$Monitor.CapabilitiesKnown) { return $true }
    return $Monitor.SupportedVcpCodes.ContainsKey($Code)
}

function Test-MonitorSupportsVcpValue {
    param($Monitor, [int]$Code, [int]$Value)
    if (-not (Test-MonitorSupportsVcp -Monitor $Monitor -Code $Code)) { return $false }
    if ($null -eq $Monitor -or -not [bool]$Monitor.CapabilitiesKnown) { return $true }
    $values = @($Monitor.SupportedVcpCodes[$Code])
    if ($values.Count -eq 0) { return $true }
    return $values -contains $Value
}

function ConvertTo-VcpCode {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $inputText = $Text.Trim()
    $style = [System.Globalization.NumberStyles]::Integer
    if ($inputText.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
        $inputText = $inputText.Substring(2)
        $style = [System.Globalization.NumberStyles]::HexNumber
    }
    if ([string]::IsNullOrWhiteSpace($inputText)) { return $null }
    $value = 0
    if (-not [int]::TryParse($inputText, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    if ($value -lt 0 -or $value -gt 255) { return $null }
    return $value
}

function ConvertTo-VcpValue {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = [uint32]0
    if (-not [uint32]::TryParse($Text.Trim(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    return $value
}

function Test-VcpCodeIsScaled {
    param([int]$Code)
    return $script:VcpScaledCodes -contains $Code
}

function Get-VcpMaximumForMonitor {
    param($Monitor, [int]$Code)
    if ($null -ne $Monitor -and $null -ne $Monitor.PSObject.Properties["VcpMaximums"] -and $null -ne $Monitor.VcpMaximums) {
        if ($Monitor.VcpMaximums.ContainsKey($Code)) {
            $cached = [int]$Monitor.VcpMaximums[$Code]
            if ($cached -gt 0) { return $cached }
        }
    }
    return $script:VcpDefaultMaximum
}

function Set-VcpMaximumForMonitor {
    param($Monitor, [int]$Code, [int]$Maximum)
    if ($null -eq $Monitor -or $Maximum -le 0) { return }
    if ($null -eq $Monitor.PSObject.Properties["VcpMaximums"] -or $null -eq $Monitor.VcpMaximums) { return }
    $Monitor.VcpMaximums[$Code] = [int]$Maximum
}

function Get-SelectedMonitorVcpMaximum {
    param([int]$Code)
    if ($script:CurrentMonitorIndex -lt 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return $script:VcpDefaultMaximum }
    return Get-VcpMaximumForMonitor -Monitor $script:PhysicalMonitors[$script:CurrentMonitorIndex] -Code $Code
}

function ConvertTo-VcpPercent {
    param([double]$RawValue, [int]$Maximum)
    if ($Maximum -le 0) { return 0 }
    $percent = [Math]::Round(($RawValue * 100.0) / [double]$Maximum, [System.MidpointRounding]::AwayFromZero)
    if ($percent -lt 0) { return 0 }
    if ($percent -gt 100) { return 100 }
    return [int]$percent
}

function ConvertTo-VcpRawValue {
    param([double]$Percent, [int]$Maximum)
    if ($Maximum -le 0) { return 0 }
    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $raw = [Math]::Round(($clamped * [double]$Maximum) / 100.0, [System.MidpointRounding]::AwayFromZero)
    if ($raw -lt 0) { return 0 }
    if ($raw -gt $Maximum) { return [int]$Maximum }
    return [int]$raw
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
}

function Get-StableHash {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
    if ($vcpSetBtn) {
        $vcpSetBtn.IsEnabled = Test-VcpWriteEnabledForMonitor -Monitor $Monitor
        $vcpSetBtn.ToolTip = if ($vcpSetBtn.IsEnabled) { "Every direct write requires an exact code/value confirmation." } else { "Arbitrary VCP writes require the selected stable monitor identity to be enabled in System." }
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
    if (Get-Command Sync-VcpWriteSafetyUi -ErrorAction SilentlyContinue) { Sync-VcpWriteSafetyUi }
}

function Convert-EdidManufacturerId {
    param([byte[]]$Edid)
    if ($null -eq $Edid -or $Edid.Length -lt 10) { return "" }
    $word = (([int]$Edid[8]) -shl 8) -bor [int]$Edid[9]
    $chars = foreach ($shift in 10,5,0) {
        $code = ($word -shr $shift) -band 31
        if ($code -lt 1 -or $code -gt 26) { return "" }
        [char](64 + $code)
    }
    return (-join $chars)
}

function Get-EdidTextDescriptor {
    param([byte[]]$Edid, [byte]$Tag)
    if ($null -eq $Edid -or $Edid.Length -lt 128) { return "" }
    for ($offset = 54; $offset -le 108; $offset += 18) {
        if ($Edid[$offset] -eq 0 -and $Edid[$offset + 1] -eq 0 -and $Edid[$offset + 2] -eq 0 -and $Edid[$offset + 3] -eq $Tag) {
            $text = [System.Text.Encoding]::ASCII.GetString($Edid, $offset + 5, 13)
            return $text.Trim([char[]]@(0, 10, 13, 32))
        }
    }
    return ""
}

function Read-MonitorEdidFromDeviceId {
    param([string]$MonitorDeviceId)
    $result = [ordered]@{
        DeviceId = $MonitorDeviceId
        HardwareId = ""
        Manufacturer = ""
        Model = ""
        Serial = ""
        Name = ""
    }
    if ([string]::IsNullOrWhiteSpace($MonitorDeviceId)) { return [PSCustomObject]$result }
    $hardwareId = ""
    $instanceId = ""
    if ($MonitorDeviceId -match '^MONITOR\\([^\\]+)\\([^\\]+)') {
        $hardwareId = $Matches[1]
        $instanceId = $Matches[2]
        $result.HardwareId = $hardwareId
    }
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
    $candidatePaths = @()
    if ($hardwareId -and $instanceId) {
        $candidatePaths += (Join-Path (Join-Path (Join-Path $basePath $hardwareId) $instanceId) "Device Parameters")
    }
    if ($hardwareId) {
        try {
            $candidatePaths += @(Get-ChildItem -LiteralPath (Join-Path $basePath $hardwareId) -ErrorAction Stop | ForEach-Object { Join-Path $_.PSPath "Device Parameters" })
        } catch {}
    }
    $edid = $null
    foreach ($path in ($candidatePaths | Select-Object -Unique)) {
        try {
            if (Test-Path -LiteralPath $path) {
                $prop = Get-ItemProperty -LiteralPath $path -Name EDID -ErrorAction Stop
                if ($prop.EDID -and $prop.EDID.Length -ge 128) {
                    $edid = [byte[]]@($prop.EDID | ForEach-Object { [byte]$_ })
                    break
                }
            }
        } catch {}
    }
    if ($null -eq $edid -or $edid.Length -lt 128) { return [PSCustomObject]$result }
    $result.Manufacturer = Convert-EdidManufacturerId -Edid $edid
    $productCode = (([int]$edid[11]) -shl 8) -bor [int]$edid[10]
    $result.Model = "{0:X4}" -f $productCode
    $numericSerial = [BitConverter]::ToUInt32($edid, 12)
    $serialText = Get-EdidTextDescriptor -Edid $edid -Tag 0xFF
    $result.Serial = if (-not [string]::IsNullOrWhiteSpace($serialText)) { $serialText } elseif ($numericSerial -ne 0) { $numericSerial.ToString() } else { "" }
    $result.Name = Get-EdidTextDescriptor -Edid $edid -Tag 0xFC
    return [PSCustomObject]$result
}

function Get-MonitorDisplayDevice {
    param([string]$DisplayDeviceName)
    if ([string]::IsNullOrWhiteSpace($DisplayDeviceName)) { return $null }
    $monitorDevice = New-Object MonitorAPI+DISPLAY_DEVICE
    $monitorDevice.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($monitorDevice)
    if ([MonitorAPI]::EnumDisplayDevices($DisplayDeviceName, 0, [ref]$monitorDevice, 0)) {
        return [PSCustomObject]@{
            DeviceName = $monitorDevice.DeviceName
            DeviceString = $monitorDevice.DeviceString
            DeviceID = $monitorDevice.DeviceID
            DeviceKey = $monitorDevice.DeviceKey
        }
    }
    return $null
}

function New-MonitorIdentity {
    param([string]$DisplayDeviceName, [string]$FriendlyName, [int]$Width, [int]$Height, [int]$MonitorIndex)
    $displayDevice = Get-MonitorDisplayDevice -DisplayDeviceName $DisplayDeviceName
    $devicePath = if ($displayDevice) { [string]$displayDevice.DeviceID } else { "" }
    $deviceString = if ($displayDevice) { [string]$displayDevice.DeviceString } else { "" }
    $edid = Read-MonitorEdidFromDeviceId -MonitorDeviceId $devicePath
    $defaultLabel = if (-not [string]::IsNullOrWhiteSpace($edid.Name)) {
        [string]$edid.Name
    } elseif (-not [string]::IsNullOrWhiteSpace($deviceString)) {
        $deviceString
    } elseif (-not [string]::IsNullOrWhiteSpace($FriendlyName)) {
        $FriendlyName
    } else {
        "Monitor $MonitorIndex"
    }
    $source = "display"
    $keySeed = @($DisplayDeviceName, $FriendlyName, $Width, $Height, $MonitorIndex) -join "|"
    if (-not [string]::IsNullOrWhiteSpace($edid.Manufacturer) -and -not [string]::IsNullOrWhiteSpace($edid.Model) -and -not [string]::IsNullOrWhiteSpace($edid.Serial)) {
        $source = "edid"
        $keySeed = @($edid.Manufacturer, $edid.Model, $edid.Serial) -join "|"
    } elseif (-not [string]::IsNullOrWhiteSpace($devicePath)) {
        $source = if (-not [string]::IsNullOrWhiteSpace($edid.Manufacturer)) { "edid-device" } else { "device" }
        $keySeed = @($devicePath, $edid.Manufacturer, $edid.Model, $edid.Name) -join "|"
    }
    return [PSCustomObject]@{
        Key = "{0}:{1}" -f $source, (Get-StableHash -Text $keySeed)
        Source = $source
        DevicePath = $devicePath
        DeviceString = $deviceString
        HardwareId = [string]$edid.HardwareId
        Manufacturer = [string]$edid.Manufacturer
        Model = [string]$edid.Model
        Serial = [string]$edid.Serial
        EdidName = [string]$edid.Name
        DefaultLabel = $defaultLabel
    }
}

function Load-MonitorIdentitySettings {
    $script:MonitorIdentityRecords = @{}
    if (-not (Test-Path -LiteralPath $script:MonitorIdentitySettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:MonitorIdentitySettingsPath -Label "Monitor identities" -ReadOnly:$script:ProfileStorageOffline
        if ($null -eq $data) { return }
        foreach ($entry in @($data.Monitors)) {
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Key)) { continue }
            $script:MonitorIdentityRecords[[string]$entry.Key] = [PSCustomObject]@{
                Key = [string]$entry.Key
                Label = if ($entry.PSObject.Properties.Name -contains "Label") { [string]$entry.Label } else { "" }
                DefaultLabel = if ($entry.PSObject.Properties.Name -contains "DefaultLabel") { [string]$entry.DefaultLabel } else { "" }
                Source = if ($entry.PSObject.Properties.Name -contains "Source") { [string]$entry.Source } else { "" }
                DevicePath = if ($entry.PSObject.Properties.Name -contains "DevicePath") { [string]$entry.DevicePath } else { "" }
                HardwareId = if ($entry.PSObject.Properties.Name -contains "HardwareId") { [string]$entry.HardwareId } else { "" }
                Manufacturer = if ($entry.PSObject.Properties.Name -contains "Manufacturer") { [string]$entry.Manufacturer } else { "" }
                Model = if ($entry.PSObject.Properties.Name -contains "Model") { [string]$entry.Model } else { "" }
                Serial = if ($entry.PSObject.Properties.Name -contains "Serial") { [string]$entry.Serial } else { "" }
                EdidName = if ($entry.PSObject.Properties.Name -contains "EdidName") { [string]$entry.EdidName } else { "" }
                UpdatedAt = if ($entry.PSObject.Properties.Name -contains "UpdatedAt") { [string]$entry.UpdatedAt } else { "" }
            }
        }
    } catch {
        Update-Status "Monitor labels could not be loaded"
    }
}

function Save-MonitorIdentitySettings {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "monitor label changes")) { return $false }
    $entries = @($script:MonitorIdentityRecords.Values | Sort-Object -Property Label, Key)
    $payload = [PSCustomObject]@{
        SchemaVersion = 1
        UpdatedAt = (Get-Date).ToString("o")
        Monitors = $entries
    }
    return (Write-JsonFileSafely -Path $script:MonitorIdentitySettingsPath -Data $payload -Depth 5)
}

function Get-MonitorIdentityRecord {
    param($Monitor)
    if ($null -eq $Monitor -or [string]::IsNullOrWhiteSpace([string]$Monitor.IdentityKey)) { return $null }
    if ($script:MonitorIdentityRecords.ContainsKey([string]$Monitor.IdentityKey)) { return $script:MonitorIdentityRecords[[string]$Monitor.IdentityKey] }
    return $null
}

function Get-MonitorDisplayLabel {
    param($Monitor)
    if ($null -eq $Monitor) { return "No monitor" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.UserLabel)) { return [string]$Monitor.UserLabel }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.IdentityDefaultLabel)) { return [string]$Monitor.IdentityDefaultLabel }
    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.Name)) { return [string]$Monitor.Name }
    return "Monitor $($Monitor.Index)"
}

function Apply-MonitorIdentity {
    param($Monitor)
    if ($null -eq $Monitor) { return }
    $record = Get-MonitorIdentityRecord -Monitor $Monitor
    $label = if ($record -and -not [string]::IsNullOrWhiteSpace([string]$record.Label)) { [string]$record.Label } else { "" }
    $Monitor | Add-Member -NotePropertyName UserLabel -NotePropertyValue $label -Force
    $Monitor | Add-Member -NotePropertyName DisplayLabel -NotePropertyValue (Get-MonitorDisplayLabel -Monitor $Monitor) -Force
}

function Update-MonitorIdentityAssignments {
    foreach ($mon in @($script:PhysicalMonitors)) { Apply-MonitorIdentity -Monitor $mon }
}

function Find-MonitorIndexByIdentity {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return -1 }
    for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
        if ([string]$script:PhysicalMonitors[$i].IdentityKey -eq $IdentityKey) { return $i }
    }
    return -1
}

function Get-DisplayRecoveryBackoffDelay {
    param([int]$FailureCount)
    if ($FailureCount -le 0) { return 0 }
    $exponent = [Math]::Min(6, $FailureCount - 1)
    return [int][Math]::Min(30000, 750 * [Math]::Pow(2, $exponent))
}

function Get-DisplayRecoveryReadRetryCount {
    param($State, [int]$DefaultRetries = 2)
    $failureCount = if ($null -ne $State -and $State.PSObject.Properties.Name -contains "ConsecutiveFailures") {
        [Math]::Max(0, [int]$State.ConsecutiveFailures)
    } else {
        0
    }
    return [int][Math]::Min(5, [Math]::Max(0, $DefaultRetries) + [Math]::Floor($failureCount / 2))
}

function Get-DisplayRecoveryTransition {
    param(
        [string]$IdentityKey,
        $PreviousState,
        [ValidateSet("Enumerated", "Stale", "Retry", "Success", "Failure", "Missing")]
        [string]$Outcome,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$Generation = 0,
        [string]$ErrorMessage = ""
    )
    $previousFailures = 0
    $lastSuccessUtc = $null
    if ($null -ne $PreviousState) {
        if ($PreviousState.PSObject.Properties.Name -contains "ConsecutiveFailures") {
            $previousFailures = [Math]::Max(0, [int]$PreviousState.ConsecutiveFailures)
        }
        if ($PreviousState.PSObject.Properties.Name -contains "LastSuccessUtc") {
            $lastSuccessUtc = $PreviousState.LastSuccessUtc
        }
    }
    $status = "Retrying"
    $failures = $previousFailures
    $nextRetryUtc = $null
    $lastError = $ErrorMessage
    switch ($Outcome) {
        "Success" {
            $status = "Fresh"
            $failures = 0
            $lastSuccessUtc = $NowUtc
            $lastError = ""
        }
        "Failure" {
            $failures++
            $offlineThreshold = if ($script:DisplayRecoveryOfflineThreshold -gt 0) { [int]$script:DisplayRecoveryOfflineThreshold } else { 4 }
            $status = if ($failures -ge $offlineThreshold) { "Offline" } else { "Retrying" }
            $nextRetryUtc = $NowUtc.AddMilliseconds((Get-DisplayRecoveryBackoffDelay -FailureCount $failures))
        }
        "Stale" {
            $status = "Stale"
            $lastError = ""
        }
        "Retry" {
            $status = "Retrying"
            $lastError = ""
        }
        "Missing" {
            $status = "Offline"
            $lastError = if ($ErrorMessage) { $ErrorMessage } else { "Display is not currently enumerated" }
        }
        default {
            $status = "Retrying"
            $lastError = ""
        }
    }
    return [PSCustomObject]@{
        IdentityKey = [string]$IdentityKey
        Status = [string]$status
        LastSuccessUtc = $lastSuccessUtc
        ConsecutiveFailures = [int]$failures
        NextRetryUtc = $nextRetryUtc
        LastError = [string]$lastError
        Generation = [int]$Generation
    }
}

function Test-DisplayWorkerResultCurrent {
    param($Result, [int]$CurrentGeneration, [object[]]$Monitors)
    if ($null -eq $Result) { return $false }
    $properties = @($Result.PSObject.Properties.Name)
    if ($properties -notcontains "Generation" -or [int]$Result.Generation -ne $CurrentGeneration) { return $false }
    if ($properties -notcontains "MonitorIndex") { return $false }
    $monitorIndex = [int]$Result.MonitorIndex
    if ($monitorIndex -lt 0 -or $monitorIndex -ge @($Monitors).Count) { return $false }
    $monitor = @($Monitors)[$monitorIndex]
    if ($null -eq $monitor -or $properties -notcontains "IdentityKey") { return $false }
    $resultIdentity = [string]$Result.IdentityKey
    if ([string]::IsNullOrWhiteSpace($resultIdentity) -or $resultIdentity -ne [string]$monitor.IdentityKey) { return $false }
    if ($properties -contains "HandleValue") {
        if ($monitor.PSObject.Properties.Name -notcontains "Handle") { return $false }
        if ([int64]$Result.HandleValue -ne [int64]$monitor.Handle.ToInt64()) { return $false }
    }
    return $true
}

function Set-DisplayRecoveryOutcome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates in-memory recovery state only.')]
    param(
        [string]$IdentityKey,
        [ValidateSet("Enumerated", "Stale", "Retry", "Success", "Failure", "Missing")]
        [string]$Outcome,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [int]$Generation = $script:DisplayRecoveryGeneration,
        [string]$ErrorMessage = ""
    )
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $null }
    $previous = if ($script:DisplayRecoveryStates.ContainsKey($IdentityKey)) { $script:DisplayRecoveryStates[$IdentityKey] } else { $null }
    $next = Get-DisplayRecoveryTransition -IdentityKey $IdentityKey -PreviousState $previous -Outcome $Outcome -NowUtc $NowUtc -Generation $Generation -ErrorMessage $ErrorMessage
    $script:DisplayRecoveryStates[$IdentityKey] = $next
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -eq $monitor -or [string]$monitor.IdentityKey -ne $IdentityKey) { continue }
        $monitor | Add-Member -NotePropertyName RecoveryState -NotePropertyValue ([string]$next.Status) -Force
        $monitor | Add-Member -NotePropertyName RecoveryLastSuccessUtc -NotePropertyValue $next.LastSuccessUtc -Force
        $monitor | Add-Member -NotePropertyName RecoveryConsecutiveFailures -NotePropertyValue ([int]$next.ConsecutiveFailures) -Force
        $monitor | Add-Member -NotePropertyName RecoveryNextRetryUtc -NotePropertyValue $next.NextRetryUtc -Force
        $monitor | Add-Member -NotePropertyName RecoveryLastError -NotePropertyValue ([string]$next.LastError) -Force
        $monitor | Add-Member -NotePropertyName RecoveryGeneration -NotePropertyValue ([int]$next.Generation) -Force
    }
    try { Update-SelectedMonitorRecoveryUi } catch { $null = $_ }
    return $next
}

function Sync-DisplayRecoveryInventory {
    $present = @{}
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -eq $monitor -or [string]::IsNullOrWhiteSpace([string]$monitor.IdentityKey)) { continue }
        $identityKey = [string]$monitor.IdentityKey
        $present[$identityKey] = $true
        Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Enumerated" -Generation $script:DisplayRecoveryGeneration | Out-Null
    }
    foreach ($identityKey in @($script:DisplayRecoveryStates.Keys)) {
        if (-not $present.ContainsKey([string]$identityKey)) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$identityKey) -Outcome "Missing" -Generation $script:DisplayRecoveryGeneration | Out-Null
        }
    }
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
        Canvas = "#08111D"
        Sidebar = "#0A1422"
        Header = "#0B1625"
        Footer = "#091320"
        Surface = "#101B2B"
        Card = "#142235"
        CardHover = "#192B42"
        Control = "#0D1928"
        Track = "#526985"
        Border = "#5F7794"
        Accent = "#2F6FCF"
        AccentHover = "#2864C7"
        AccentPressed = "#1F5BB8"
        Focus = "#75A9FF"
        Text = "#E8EEF7"
        MutedText = "#9AABC0"
        OnAccent = "#FFFFFF"
        Success = "#62D891"
        Warning = "#FFD18A"
        WarningSurface = "#3A2F1E"
        Danger = "#F46969"
        DangerSurface = "#40212A"
    }
}

function Get-WcagRelativeLuminance {
    param([string]$Color)
    if ($Color -notmatch '^#[0-9A-Fa-f]{6}$') { throw "Color must use #RRGGBB format" }
    $channels = @()
    for ($offset = 1; $offset -le 5; $offset += 2) {
        $channel = [Convert]::ToInt32($Color.Substring($offset, 2), 16) / 255.0
        $channels += if ($channel -le 0.04045) {
            $channel / 12.92
        } else {
            [Math]::Pow((($channel + 0.055) / 1.055), 2.4)
        }
    }
    return (0.2126 * $channels[0]) + (0.7152 * $channels[1]) + (0.0722 * $channels[2])
}

function Get-WcagContrastRatio {
    param([string]$Foreground, [string]$Background)
    $foregroundLuminance = Get-WcagRelativeLuminance -Color $Foreground
    $backgroundLuminance = Get-WcagRelativeLuminance -Color $Background
    $lighter = [Math]::Max($foregroundLuminance, $backgroundLuminance)
    $darker = [Math]::Min($foregroundLuminance, $backgroundLuminance)
    return ($lighter + 0.05) / ($darker + 0.05)
}

function Resolve-TextScaleFactor {
    param(
        [int]$SystemPercent = 100,
        [int]$OverridePercent = 0
    )
    $percent = if ($OverridePercent -gt 0) { $OverridePercent } else { $SystemPercent }
    $percent = [Math]::Max(100, [Math]::Min(200, $percent))
    return [Math]::Round(($percent / 100.0), 2)
}

function Get-SystemTextScalePercent {
    try {
        $settings = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Accessibility" -Name "TextScaleFactor" -ErrorAction Stop
        return [int]$settings.TextScaleFactor
    } catch {
        return 100
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

function Get-StatusMessageSeverity {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return "Info" }
    if ($Message -match '(?i)\b(fail(?:ed|ure)?|error|invalid|denied|blocked|offline|corrupt|mismatch(?:ed)?|newer than|not found|unavailable|could not|no (?:DDC/CI )?(?:write )?target)\b') {
        return "Error"
    }
    if ($Message -match '(?i)\b(warn(?:ing)?|cancel(?:ed|led)?|busy|waiting|unsupported|stale|retry(?:ing)?|disabled|partly|partial(?:ly)?)\b') {
        return "Warning"
    }
    return "Info"
}

function Get-NavigationShortcutTarget {
    param([string]$Key)
    switch ($Key.ToUpperInvariant()) {
        "D" { return "Display" }
        "M" { return "Monitor" }
        "H" { return "Hardware" }
        "V" { return "VCP Explorer" }
        "P" { return "Profiles" }
        "A" { return "Automation" }
        "S" { return "System" }
        default { return "" }
    }
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

function Get-UiString {
    param([string]$Key)
    if ($script:UiStrings.ContainsKey($Key)) { return [string]$script:UiStrings[$Key] }
    return $Key
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
        $window.Title = "$(Get-UiString -Key 'App.Title') v3.36.0"
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
        $capabilitiesClearCacheBtn,$ddcTimingAdaptiveRadio,$ddcTimingManualRadio,$ddcTimingReadRetriesBox,$ddcTimingWriteRetriesBox,$ddcTimingCapabilityRetriesBox,$ddcTimingResetBtn,$displayRestoreEnabledCheckbox,$cpuMonitorEnabledCheckbox,$presentMonEnabledCheckbox,$optionalHelperStatusBox,$capabilitiesDiscoveryEnabledCheckbox,$capabilitiesMaximumCompatibilityCheckbox,$capabilitiesExcludeCurrentBtn,$capabilitiesClearExclusionsBtn,$riskyVcpEnabledCheckbox,
        $automationBridgeEnabledCheckbox,$automationBridgeBindBox,$automationBridgePortBox,$automationBridgeKeyBox,$automationBridgeSaveBtn,
        $ddcReportGenerateBtn,$ddcReportCopyBtn,$ddcReportBox
    )
}

function Wait-DdcWriteQueueIdle {
    param([int]$TimeoutMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        Drain-DdcWriteResults
        if (-not [MonitorAPI]::IsVCPWriteWorkerActive() -and [MonitorAPI]::GetPendingVCPWriteCount() -eq 0) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Clear-PhysicalMonitorHandles {
    param(
        [switch]$ClearList,
        [scriptblock]$DestroyHandle
    )
    if ($null -eq $DestroyHandle) {
        $DestroyHandle = {
            param([IntPtr]$Handle)
            [MonitorAPI]::DestroyPhysicalMonitor($Handle) | Out-Null
        }
    }
    $seen = @{}
    foreach ($mon in @($script:PhysicalMonitors)) {
        if ($null -eq $mon -or $mon.Handle -eq [IntPtr]::Zero) { continue }
        $key = $mon.Handle.ToInt64()
        if (-not $seen.ContainsKey($key)) {
            try { & $DestroyHandle $mon.Handle } catch {}
            $seen[$key] = $true
        }
        try { $mon.Handle = [IntPtr]::Zero } catch {}
    }
    try { [MonitorAPI]::InvalidateVcpValueCache() } catch {}
    if ($ClearList) { $script:PhysicalMonitors = @() }
}

function Get-CapabilitiesSafetySettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:CapabilitiesSafetySchemaVersion
        ConsentRecorded = [bool]$script:CapabilitiesConsentRecorded
        DiscoveryEnabled = [bool]$script:CapabilitiesDiscoveryEnabled
        MaximumCompatibility = [bool]$script:CapabilitiesMaximumCompatibility
        ExcludedIdentityKeys = @($script:CapabilitiesExcludedIdentityKeys.Keys | Sort-Object)
        LastIncidentIdentityKey = [string]$script:CapabilitiesLastIncidentIdentityKey
        LastIncidentAt = [string]$script:CapabilitiesLastIncidentAt
    }
}

function Write-CapabilitySafetyState {
    return (Write-JsonFileSafely -Path $script:CapabilitiesSafetySettingsPath -Data (Get-CapabilitiesSafetySettingsObject) -Depth 5)
}

function Import-CapabilitySafetyState {
    $script:CapabilitiesConsentRecorded = $false
    $script:CapabilitiesDiscoveryEnabled = $false
    $script:CapabilitiesMaximumCompatibility = $false
    $script:CapabilitiesExcludedIdentityKeys = @{}
    $script:CapabilitiesLastIncidentIdentityKey = ""
    $script:CapabilitiesLastIncidentAt = ""

    if (Test-Path -LiteralPath $script:CapabilitiesSafetySettingsPath) {
        $data = Read-JsonFileSafely -Path $script:CapabilitiesSafetySettingsPath -Label "Capability safety settings"
        if ($null -ne $data) {
            $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
            if ($schema -gt $script:CapabilitiesSafetySchemaVersion) {
                $script:CapabilitiesConsentRecorded = $true
                $script:CapabilitiesMaximumCompatibility = $true
                Set-DeferredStatus "Capability safety settings are newer than this app; maximum compatibility enabled"
            } else {
                if ($data.PSObject.Properties.Name -contains "ConsentRecorded") { $script:CapabilitiesConsentRecorded = [bool]$data.ConsentRecorded }
                if ($data.PSObject.Properties.Name -contains "DiscoveryEnabled") { $script:CapabilitiesDiscoveryEnabled = [bool]$data.DiscoveryEnabled }
                if ($data.PSObject.Properties.Name -contains "MaximumCompatibility") { $script:CapabilitiesMaximumCompatibility = [bool]$data.MaximumCompatibility }
                foreach ($identityKey in @($data.ExcludedIdentityKeys)) {
                    $key = [string]$identityKey
                    if (-not [string]::IsNullOrWhiteSpace($key)) { $script:CapabilitiesExcludedIdentityKeys[$key] = $true }
                }
                if ($data.PSObject.Properties.Name -contains "LastIncidentIdentityKey") { $script:CapabilitiesLastIncidentIdentityKey = [string]$data.LastIncidentIdentityKey }
                if ($data.PSObject.Properties.Name -contains "LastIncidentAt") { $script:CapabilitiesLastIncidentAt = [string]$data.LastIncidentAt }
            }
        }
    }

    if (Test-Path -LiteralPath $script:CapabilitiesProbeSentinelPath) {
        $pendingIdentity = ""
        $pendingAt = [DateTime]::UtcNow.ToString("o")
        try {
            $pending = Get-Content -LiteralPath $script:CapabilitiesProbeSentinelPath -Raw | ConvertFrom-Json
            $pendingIdentity = [string]$pending.IdentityKey
            if ($pending.PSObject.Properties.Name -contains "StartedAtUtc" -and -not [string]::IsNullOrWhiteSpace([string]$pending.StartedAtUtc)) {
                $pendingAt = [string]$pending.StartedAtUtc
            }
        } catch {
            Move-CorruptJsonFile -Path $script:CapabilitiesProbeSentinelPath | Out-Null
        }
        if (Test-Path -LiteralPath $script:CapabilitiesProbeSentinelPath) {
            Remove-Item -LiteralPath $script:CapabilitiesProbeSentinelPath -Force -ErrorAction SilentlyContinue
        }
        $script:CapabilitiesDiscoveryEnabled = $false
        $script:CapabilitiesConsentRecorded = $true
        $script:CapabilitiesLastIncidentIdentityKey = $pendingIdentity
        $script:CapabilitiesLastIncidentAt = $pendingAt
        if (-not [string]::IsNullOrWhiteSpace($pendingIdentity)) {
            $script:CapabilitiesExcludedIdentityKeys[$pendingIdentity] = $true
            Set-DeferredStatus "Capability discovery disabled after an interrupted probe; the affected monitor was excluded"
        } else {
            $script:CapabilitiesMaximumCompatibility = $true
            Set-DeferredStatus "Capability discovery disabled after an unreadable probe sentinel"
        }
        Write-CapabilitySafetyState | Out-Null
    }
}

function Test-VcpWriteRequiresSafetyConsent {
    param([int]$Code, [switch]$Arbitrary)
    if ($Arbitrary) { return $true }
    return $script:RiskyVcpCodes -contains $Code
}

function Get-VcpWriteSafetySettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:VcpWriteSafetySchemaVersion
        EnabledIdentityKeys = @($script:RiskyVcpEnabledIdentityKeys.Keys | Sort-Object)
    }
}

function Write-VcpWriteSafetyState {
    return (Write-JsonFileSafely -Path $script:VcpWriteSafetySettingsPath -Data (Get-VcpWriteSafetySettingsObject) -Depth 4)
}

function Import-VcpWriteSafetyState {
    $script:RiskyVcpEnabledIdentityKeys = @{}
    if (-not (Test-Path -LiteralPath $script:VcpWriteSafetySettingsPath)) { return }
    try {
        $data = Read-JsonFileSafely -Path $script:VcpWriteSafetySettingsPath -Label "Risky VCP write settings"
        if ($null -eq $data) { return }
        $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
        if ($schema -gt $script:VcpWriteSafetySchemaVersion) {
            Set-DeferredStatus "Risky VCP write settings are newer than this app; dangerous writes remain disabled"
            return
        }
        if ($schema -lt 1) {
            Set-DeferredStatus "Risky VCP write settings were invalid; dangerous writes remain disabled"
            return
        }
        foreach ($identityKey in @($data.EnabledIdentityKeys)) {
            $key = [string]$identityKey
            if (-not [string]::IsNullOrWhiteSpace($key) -and $key.Length -le 512) {
                $script:RiskyVcpEnabledIdentityKeys[$key] = $true
            }
        }
    } catch {
        $script:RiskyVcpEnabledIdentityKeys = @{}
        Set-DeferredStatus "Risky VCP write settings were invalid; dangerous writes remain disabled"
    }
}

function Test-VcpWriteEnabledForMonitor {
    param($Monitor)
    if ($null -eq $Monitor) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey) -or $identityKey.Length -gt 512) { return $false }
    return $script:RiskyVcpEnabledIdentityKeys.ContainsKey($identityKey)
}

function Set-VcpWriteEnabledForMonitor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "The calling UI owns explicit confirmation and this helper persists only that confirmed choice.")]
    param($Monitor, [bool]$Enabled)
    if ($null -eq $Monitor) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey) -or $identityKey.Length -gt 512) { return $false }
    if ($Enabled) {
        $script:RiskyVcpEnabledIdentityKeys[$identityKey] = $true
    } else {
        $null = $script:RiskyVcpEnabledIdentityKeys.Remove($identityKey)
    }
    return (Write-VcpWriteSafetyState)
}

function Get-VcpWriteSafetyStatusText {
    param($Monitor)
    if ($null -eq $Monitor) { return "No display selected" }
    if ([string]::IsNullOrWhiteSpace([string]$Monitor.IdentityKey) -or ([string]$Monitor.IdentityKey).Length -gt 512) { return "Unavailable: stable identity required" }
    if (Test-VcpWriteEnabledForMonitor -Monitor $Monitor) { return "Enabled for selected identity" }
    return "Disabled for selected identity"
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

function Get-MonitorEdidModelId {
    param($Monitor)
    if ($null -eq $Monitor) { return "" }
    $manufacturer = [string]$Monitor.Manufacturer
    $model = [string]$Monitor.EdidModel
    if ([string]::IsNullOrWhiteSpace($manufacturer) -or [string]::IsNullOrWhiteSpace($model)) { return "" }
    return ($manufacturer + $model).ToUpperInvariant()
}

function Get-CapabilitiesBlocklistEntry {
    param($Monitor)
    $edidId = Get-MonitorEdidModelId -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($edidId)) { return $null }
    foreach ($entry in @($script:CapabilitiesKnownBadModels)) {
        if ([string]$entry.EdidId -eq $edidId) { return $entry }
    }
    return $null
}

function Get-CapabilitiesCacheKey {
    param($Monitor)
    if ($null -eq $Monitor) { return "" }
    $identityKey = [string]$Monitor.IdentityKey
    if ([string]::IsNullOrWhiteSpace($identityKey)) { return "" }
    return $identityKey
}

function Save-CapabilitiesCache {
    $records = @()
    foreach ($key in @($script:CapabilitiesCache.Keys)) {
        $entry = $script:CapabilitiesCache[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            EdidId = [string]$entry.EdidId
            Capabilities = [string]$entry.Capabilities
            ReadAt = [string]$entry.ReadAt
        }
    }
    $document = [PSCustomObject]@{
        SchemaVersion = [int]$script:CapabilitiesCacheSchemaVersion
        Monitors = @($records)
    }
    return (Write-JsonFileSafely -Path $script:CapabilitiesCachePath -Data $document -Depth 5)
}

function Import-CapabilitiesCache {
    $script:CapabilitiesCache = @{}
    if (-not (Test-Path -LiteralPath $script:CapabilitiesCachePath)) { return }
    $data = Read-JsonFileSafely -Path $script:CapabilitiesCachePath -Label "Capability cache"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:CapabilitiesCacheSchemaVersion) {
        Update-Status "Capability cache uses schema v$schema; it will be re-read instead"
        return
    }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        $capabilities = [string](Get-ProfilePropertyValue -Object $record -Property "Capabilities" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey) -or [string]::IsNullOrWhiteSpace($capabilities)) { continue }
        $script:CapabilitiesCache[$identityKey] = [PSCustomObject]@{
            EdidId = [string](Get-ProfilePropertyValue -Object $record -Property "EdidId" -Default "")
            Capabilities = $capabilities
            ReadAt = [string](Get-ProfilePropertyValue -Object $record -Property "ReadAt" -Default "")
        }
    }
}

function Set-CapabilitiesCacheEntry {
    param($Monitor, [string]$Capabilities, [string]$ReadAt = "")
    $key = Get-CapabilitiesCacheKey -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($Capabilities)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ReadAt)) { $ReadAt = (Get-Date).ToString("o") }
    $script:CapabilitiesCache[$key] = [PSCustomObject]@{
        EdidId = Get-MonitorEdidModelId -Monitor $Monitor
        Capabilities = [string]$Capabilities
        ReadAt = [string]$ReadAt
    }
    return $true
}

function Get-CapabilitiesCacheEntry {
    param($Monitor)
    $key = Get-CapabilitiesCacheKey -Monitor $Monitor
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }
    if (-not $script:CapabilitiesCache.ContainsKey($key)) { return $null }
    return $script:CapabilitiesCache[$key]
}

function Clear-CapabilitiesCache {
    $script:CapabilitiesCache = @{}
    Save-CapabilitiesCache | Out-Null
    Update-Status "Capability cache cleared; capabilities will be read again"
}

function Get-CapabilityProbeDecision {
    param($Monitor)
    if ($null -eq $Monitor -or $Monitor.Handle -eq [IntPtr]::Zero) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "no DDC/CI handle" }
    }
    if (-not $script:CapabilitiesDiscoveryEnabled) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "discovery disabled" }
    }
    if ($script:CapabilitiesMaximumCompatibility) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "maximum compatibility" }
    }
    $identityKey = [string]$Monitor.IdentityKey
    if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey($identityKey)) {
        return [PSCustomObject]@{ Action = "Skip"; Reason = "excluded after an interrupted probe" }
    }
    $blocked = Get-CapabilitiesBlocklistEntry -Monitor $Monitor
    if ($null -ne $blocked) {
        return [PSCustomObject]@{ Action = "Blocked"; Reason = "known-bad model $($blocked.EdidId): $($blocked.Note)" }
    }
    $cached = Get-CapabilitiesCacheEntry -Monitor $Monitor
    if ($null -ne $cached) {
        return [PSCustomObject]@{ Action = "Cached"; Reason = "cached from $($cached.ReadAt)"; Capabilities = [string]$cached.Capabilities }
    }
    return [PSCustomObject]@{ Action = "Probe"; Reason = "not cached" }
}

function Test-CapabilityProbeAllowed {
    param($Monitor)
    if ($null -eq $Monitor -or $Monitor.Handle -eq [IntPtr]::Zero) { return $false }
    if (-not $script:CapabilitiesDiscoveryEnabled -or $script:CapabilitiesMaximumCompatibility) { return $false }
    $identityKey = [string]$Monitor.IdentityKey
    if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $script:CapabilitiesExcludedIdentityKeys.ContainsKey($identityKey)) { return $false }
    return $true
}

function Get-CapabilitiesSafetyStatusText {
    $excludedCount = [int]$script:CapabilitiesExcludedIdentityKeys.Count
    $suffix = if ($excludedCount -eq 1) { "1 exclusion" } else { "$excludedCount exclusions" }
    if ($script:CapabilitiesMaximumCompatibility) { return "Maximum compatibility - reads disabled ($suffix)" }
    if (-not $script:CapabilitiesDiscoveryEnabled) { return "Discovery off ($suffix)" }
    return "Discovery on ($suffix)"
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

function Stop-CapabilitiesWorker {
    param([switch]$Cancel)
    if ($script:CapabilitiesWorkerTimer) { $script:CapabilitiesWorkerTimer.Stop() }
    if ($script:CapabilitiesWorker) {
        if ($Cancel -and $script:CapabilitiesWorkerAsyncResult -and -not $script:CapabilitiesWorkerAsyncResult.IsCompleted) {
            try { $script:CapabilitiesWorker.Stop() } catch {}
        }
        try { $script:CapabilitiesWorker.Dispose() } catch {}
    }
    if ($script:CapabilitiesWorkerInput) { try { $script:CapabilitiesWorkerInput.Dispose() } catch {} }
    if ($script:CapabilitiesWorkerOutput) { try { $script:CapabilitiesWorkerOutput.Dispose() } catch {} }
    $script:CapabilitiesWorker = $null
    $script:CapabilitiesWorkerInput = $null
    $script:CapabilitiesWorkerOutput = $null
    $script:CapabilitiesWorkerAsyncResult = $null
    $script:CapabilitiesWorkerLastOutputCount = 0
    $script:CapabilitiesWorkerGeneration = -1
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
            $targets += [PSCustomObject]@{
                Index = [int]$i
                MonitorIndex = [int]$i
                Handle = $mon.Handle
                HandleValue = $mon.Handle.ToInt64()
                Name = [string]$mon.Name
                IdentityKey = [string]$mon.IdentityKey
                Generation = [int]$script:DisplayRecoveryGeneration
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
            $sentinelReady = $false
            $sentinelTempPath = "$SentinelPath.$([guid]::NewGuid().ToString('N')).tmp"
            try {
                try {
                    $marker = [PSCustomObject]@{
                        SchemaVersion = 1
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
                    $capLen = [uint32]0
                    if ([MonitorAPI]::GetCapabilitiesStringLength($target.Handle, [ref]$capLen) -and $capLen -gt 0) {
                        $capStr = New-Object System.Text.StringBuilder -ArgumentList ([int]$capLen)
                        if ([MonitorAPI]::CapabilitiesRequestAndCapabilitiesReply($target.Handle, $capStr, $capLen)) {
                            $capabilities = $capStr.ToString()
                        } else {
                            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        }
                    } else {
                        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
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

function ConvertTo-DriverVersionParts {
    param([string]$Version)
    $parts = @()
    foreach ($token in @(([string]$Version).Trim().Split(@(".", "-", " "), [StringSplitOptions]::RemoveEmptyEntries))) {
        $number = 0
        if ([int]::TryParse($token, [ref]$number)) { $parts += $number } else { $parts += 0 }
    }
    return $parts
}

function Compare-DisplayDriverVersion {
    param([string]$Left, [string]$Right)
    $leftParts = @(ConvertTo-DriverVersionParts -Version $Left)
    $rightParts = @(ConvertTo-DriverVersionParts -Version $Right)
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $leftValue = if ($i -lt $leftParts.Count) { [int]$leftParts[$i] } else { 0 }
        $rightValue = if ($i -lt $rightParts.Count) { [int]$rightParts[$i] } else { 0 }
        if ($leftValue -lt $rightValue) { return -1 }
        if ($leftValue -gt $rightValue) { return 1 }
    }
    return 0
}

function Test-DisplayDriverVersionInRange {
    param([string]$Version, [string]$From, [string]$Through)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($From) -and (Compare-DisplayDriverVersion -Left $Version -Right $From) -lt 0) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Through) -and (Compare-DisplayDriverVersion -Left $Version -Right $Through) -gt 0) { return $false }
    return $true
}

function Get-GpuDriverAdvisory {
    param([object[]]$Gpus, [hashtable]$BrandingVersions, [object[]]$Table)
    if ($null -eq $Table) { $Table = @($script:KnownBadGpuDrivers) }
    if ($null -eq $BrandingVersions) { $BrandingVersions = @{} }
    $advisories = @()
    foreach ($entry in @($Table)) {
        foreach ($gpu in @($Gpus)) {
            if ($null -eq $gpu) { continue }
            $name = [string]$gpu.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch [string]$entry.NamePattern) { continue }
            $valueName = [string]$entry.BrandingValueName
            $observed = ""
            $source = ""
            if (-not [string]::IsNullOrWhiteSpace($valueName) -and $BrandingVersions.ContainsKey($valueName)) {
                $observed = [string]$BrandingVersions[$valueName]
                $source = $valueName
            }
            $matched = $false
            if (-not [string]::IsNullOrWhiteSpace($observed)) {
                $matched = Test-DisplayDriverVersionInRange -Version $observed -From ([string]$entry.AffectedFrom) -Through ([string]$entry.AffectedThrough)
            }
            if (-not $matched -and -not [string]::IsNullOrWhiteSpace([string]$entry.AffectedDriverFrom)) {
                $observed = [string]$gpu.DriverVersion
                $source = "DriverVersion"
                $matched = Test-DisplayDriverVersionInRange -Version $observed -From ([string]$entry.AffectedDriverFrom) -Through ([string]$entry.AffectedDriverThrough)
            }
            if (-not $matched) { continue }
            $advisories += [PSCustomObject]@{
                Gpu = $name
                Observed = $observed
                ObservedSource = $source
                FixedIn = [string]$entry.FixedIn
                Issue = [string]$entry.Issue
                Reference = [string]$entry.Reference
            }
        }
    }
    return @($advisories)
}

function Get-GpuBrandingVersions {
    param([object[]]$Table)
    if ($null -eq $Table) { $Table = @($script:KnownBadGpuDrivers) }
    $versions = @{}
    $names = @()
    foreach ($entry in @($Table)) {
        $valueName = [string]$entry.BrandingValueName
        if (-not [string]::IsNullOrWhiteSpace($valueName) -and $names -notcontains $valueName) { $names += $valueName }
    }
    if ($names.Count -eq 0) { return $versions }
    # The vendor control panel writes its branded release into the display
    # adapter class key; Win32_VideoController only carries the file version.
    $classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $classRoot -ErrorAction Stop)) {
            foreach ($valueName in $names) {
                if ($versions.ContainsKey($valueName)) { continue }
                $value = $null
                try { $value = (Get-ItemProperty -LiteralPath $key.PSPath -Name $valueName -ErrorAction Stop).$valueName } catch {}
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $versions[$valueName] = [string]$value }
            }
        }
    } catch {}
    return $versions
}

function Get-KnownBadGpuDriverAdvisory {
    $gpus = @()
    try { $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch {}
    if ($gpus.Count -eq 0) { return @() }
    return @(Get-GpuDriverAdvisory -Gpus $gpus -BrandingVersions (Get-GpuBrandingVersions) -Table @($script:KnownBadGpuDrivers))
}

function Get-DisplayPathClassification {
    param([string]$DeviceString, [string]$HardwareId, [string]$AdapterName, [object[]]$Signatures)
    if ($null -eq $Signatures) { $Signatures = @($script:DisplayPathSignatures) }
    $haystack = (@($DeviceString, $HardwareId, $AdapterName) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " "
    foreach ($signature in @($Signatures)) {
        if (-not [string]::IsNullOrWhiteSpace($haystack) -and $haystack -match [string]$signature.Pattern) {
            return [PSCustomObject]@{
                Kind = [string]$signature.Kind
                HasControlChannel = $false
                Reason = [string]$signature.Reason
                Fix = [string]$signature.Fix
            }
        }
    }
    return [PSCustomObject]@{ Kind = "Direct"; HasControlChannel = $true; Reason = ""; Fix = "" }
}

function Get-DisplayPathInventory {
    param([string[]]$DdcCapableDeviceNames)
    $capable = @{}
    foreach ($deviceName in @($DdcCapableDeviceNames)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$deviceName)) { $capable[[string]$deviceName] = $true }
    }
    $inventory = @()
    $devNum = 0
    $device = New-Object MonitorAPI+DISPLAY_DEVICE
    $device.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($device)
    while ([MonitorAPI]::EnumDisplayDevices([NullString]::Value, $devNum, [ref]$device, 0)) {
        $devNum++
        if (($device.StateFlags -band [MonitorAPI]::DISPLAY_DEVICE_ACTIVE) -eq 0) { continue }
        $deviceName = [string]$device.DeviceName
        $adapterName = [string]$device.DeviceString
        $monitorDevice = Get-MonitorDisplayDevice -DisplayDeviceName $deviceName
        $monitorString = if ($monitorDevice) { [string]$monitorDevice.DeviceString } else { "" }
        $monitorId = if ($monitorDevice) { [string]$monitorDevice.DeviceID } else { "" }
        $classification = Get-DisplayPathClassification -DeviceString $monitorString -HardwareId $monitorId -AdapterName $adapterName
        $hasChannel = $capable.ContainsKey($deviceName)
        $inventory += [PSCustomObject]@{
            DeviceName = $deviceName
            Name = if ([string]::IsNullOrWhiteSpace($monitorString)) { $adapterName } else { $monitorString }
            Adapter = $adapterName
            Kind = if ($hasChannel) { "Direct" } else { [string]$classification.Kind }
            HasControlChannel = $hasChannel
            Reason = if ($hasChannel) { "" } else { [string]$classification.Reason }
            Fix = if ($hasChannel) { "" } else { [string]$classification.Fix }
        }
    }
    return @($inventory)
}

function Get-DdcAvailabilityDiagnosis {
    param([object[]]$Paths, [object[]]$GpuAdvisories, [bool]$WmiBrightnessAvailable)
    $displayCount = @($Paths).Count
    $capableCount = @(@($Paths) | Where-Object { $null -ne $_ -and [bool]$_.HasControlChannel }).Count
    $causes = @()
    foreach ($advisory in @($GpuAdvisories)) {
        if ($null -eq $advisory) { continue }
        $causes += [PSCustomObject]@{
            Kind = "GpuDriver"
            Title = "$($advisory.Gpu) driver $($advisory.Observed) is a release known to break DDC/CI"
            Detail = "$($advisory.Issue). Reported in $($advisory.Reference)."
            Fix = "Update the display driver to $($advisory.FixedIn) or newer, or roll back to the release in use before the problem started."
        }
    }
    $named = 0
    $groups = @{}
    $order = @()
    foreach ($path in @($Paths)) {
        if ($null -eq $path -or [bool]$path.HasControlChannel) { continue }
        $kind = [string]$path.Kind
        if ($kind -eq "Direct") { continue }
        $named++
        if (-not $groups.ContainsKey($kind)) {
            $groups[$kind] = [PSCustomObject]@{ Count = 0; Reason = [string]$path.Reason; Fix = [string]$path.Fix; Displays = @() }
            $order += $kind
        }
        $groups[$kind].Count = [int]$groups[$kind].Count + 1
        $groups[$kind].Displays = @(@($groups[$kind].Displays) + [string]$path.Name)
    }
    foreach ($kind in $order) {
        $group = $groups[$kind]
        $causes += [PSCustomObject]@{
            Kind = $kind
            Title = "$([int]$group.Count) display(s) on a $kind path have no control channel: $(@($group.Displays) -join ', ')"
            Detail = [string]$group.Reason
            Fix = [string]$group.Fix
        }
    }
    $unexplained = [Math]::Max(0, $displayCount - $capableCount - $named)
    if ($unexplained -gt 0) {
        $causes += [PSCustomObject]@{
            Kind = "Unclassified"
            Title = "$unexplained display(s) answer no DDC/CI request on a path this app cannot identify"
            Detail = "An MST hub, a passive or active adapter, a KVM, or a cable that omits the DDC pins all terminate DDC/CI without reporting an error, and many monitors ship with DDC/CI switched off in the OSD."
            Fix = "Switch DDC/CI on in the monitor OSD, connect the monitor straight to a GPU output with a certified cable, and retest with no hub, dock, or KVM in the path."
        }
    }
    if ($capableCount -eq 0 -and $WmiBrightnessAvailable) {
        $causes += [PSCustomObject]@{
            Kind = "InternalPanel"
            Title = "The internal laptop panel is controlled through WMI instead"
            Detail = "Integrated panels are driven by the graphics driver, not by DDC/CI, so brightness works while every other VCP feature does not."
            Fix = "Use an external monitor for contrast, input switching, and colour controls."
        }
    }
    $severity = if ($displayCount -gt 0 -and $capableCount -eq 0) { "Error" } elseif (@($causes).Count -gt 0) { "Warning" } else { "None" }
    $summary = "$displayCount display(s) detected, $capableCount with a DDC/CI control channel"
    $headline = switch ($severity) {
        "Error" { "DDC/CI control is unavailable: $summary. " + $(if (@($causes).Count -gt 0) { [string]@($causes)[0].Title } else { "No cause identified." }) }
        "Warning" { "DDC/CI is partly available: $summary. " + [string]@($causes)[0].Title }
        default { $summary }
    }
    if ($severity -ne "None") { $headline = "$headline See System, DDC Compatibility Report." }
    return [PSCustomObject]@{
        DisplayCount = [int]$displayCount
        DdcCapableCount = [int]$capableCount
        Severity = [string]$severity
        Summary = [string]$summary
        Headline = [string]$headline
        Causes = @($causes)
    }
}

function Get-Monitors {
    Stop-MonitorSettingsWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-CapabilitiesWorker -Cancel
    Stop-DdcReportWorker -Cancel
    Wait-DdcWriteQueueIdle -TimeoutMs 1000 | Out-Null
    Clear-PhysicalMonitorHandles -ClearList
    $monitorHandles = [MonitorAPI]::GetAllMonitorHandles()
    $monitorIndex = 1
    $displayDevices = @{}
    $devNum = 0
    $device = New-Object MonitorAPI+DISPLAY_DEVICE
    $device.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($device)
    while ([MonitorAPI]::EnumDisplayDevices([NullString]::Value, $devNum, [ref]$device, 0)) {
        if ($device.StateFlags -band [MonitorAPI]::DISPLAY_DEVICE_ACTIVE) { $displayDevices[$device.DeviceName] = $device.DeviceString }
        $devNum++
    }
    foreach ($hMonitor in $monitorHandles) {
        $numMons = [uint32]0
        if ([MonitorAPI]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$numMons) -and $numMons -gt 0) {
            $physMons = New-Object MonitorAPI+PHYSICAL_MONITOR[] $numMons
            if ([MonitorAPI]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $numMons, $physMons)) {
                foreach ($pm in $physMons) {
                    $monInfo = New-Object MonitorAPI+MONITORINFOEX
                    $monInfo.Size = [System.Runtime.InteropServices.Marshal]::SizeOf($monInfo)
                    if ([MonitorAPI]::GetMonitorInfo($hMonitor, [ref]$monInfo)) {
                        $devMode = New-Object MonitorAPI+DEVMODE
                        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
                        [MonitorAPI]::EnumDisplaySettingsEx($monInfo.DeviceName, [MonitorAPI]::ENUM_CURRENT_SETTINGS, [ref]$devMode, 0) | Out-Null
                        $name = if ($pm.szPhysicalMonitorDescription) { $pm.szPhysicalMonitorDescription } else {
                            if ($displayDevices.ContainsKey($monInfo.DeviceName)) { $displayDevices[$monInfo.DeviceName] } else { "Monitor $monitorIndex" }
                        }
                        $identity = New-MonitorIdentity -DisplayDeviceName $monInfo.DeviceName -FriendlyName $name -Width $devMode.dmPelsWidth -Height $devMode.dmPelsHeight -MonitorIndex $monitorIndex
                        $monitorObject = [PSCustomObject]@{
                            Handle = $pm.hPhysicalMonitor; HMonitor = $hMonitor; Name = $name; Index = $monitorIndex
                            DeviceName = $monInfo.DeviceName; Width = $devMode.dmPelsWidth; Height = $devMode.dmPelsHeight
                            RefreshRate = $devMode.dmDisplayFrequency; IsPrimary = ($monInfo.Flags -band [MonitorAPI]::MONITORINFOF_PRIMARY) -ne 0
                            Left = $monInfo.Monitor.Left; Top = $monInfo.Monitor.Top; Right = $monInfo.Monitor.Right
                            Bottom = $monInfo.Monitor.Bottom; Capabilities = ""
                            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false; VcpMaximums = @{}
                            CapabilitiesExcluded = $false; CapabilitiesSafetyError = ""
                            IdentityKey = $identity.Key; IdentitySource = $identity.Source; IdentityDefaultLabel = $identity.DefaultLabel
                            DevicePath = $identity.DevicePath; MonitorDeviceString = $identity.DeviceString; HardwareId = $identity.HardwareId
                            Manufacturer = $identity.Manufacturer; EdidModel = $identity.Model; EdidSerial = $identity.Serial; EdidName = $identity.EdidName
                            UserLabel = ""; DisplayLabel = $identity.DefaultLabel
                        }
                        Apply-MonitorIdentity -Monitor $monitorObject
                        $script:PhysicalMonitors += $monitorObject
                        $monitorIndex++
                    }
                }
            }
        }
    }
    $capableDeviceNames = @(@($script:PhysicalMonitors) | Where-Object { $_.Handle -ne [IntPtr]::Zero } | ForEach-Object { [string]$_.DeviceName })
    $script:DisplayPathInventory = @(Get-DisplayPathInventory -DdcCapableDeviceNames $capableDeviceNames)
    $script:GpuDriverAdvisories = @(Get-KnownBadGpuDriverAdvisory)
    $script:DdcAvailabilityDiagnosis = Get-DdcAvailabilityDiagnosis -Paths $script:DisplayPathInventory -GpuAdvisories $script:GpuDriverAdvisories -WmiBrightnessAvailable $script:WmiBrightnessAvailable
    if ($script:PhysicalMonitors.Count -eq 0) {
        $fallbackName = if ($script:WmiBrightnessAvailable) { "Integrated Laptop Display" } else { "No DDC/CI Monitor" }
        $fallbackDevice = if ($script:WmiBrightnessAvailable) { "WMI" } else { "" }
        $identity = New-MonitorIdentity -DisplayDeviceName $fallbackDevice -FriendlyName $fallbackName -Width 1920 -Height 1080 -MonitorIndex 1
        $fallbackObject = [PSCustomObject]@{
            Handle = [IntPtr]::Zero; HMonitor = [IntPtr]::Zero; Name = $fallbackName; Index = 1
            DeviceName = $fallbackDevice; Width = 1920; Height = 1080; RefreshRate = 60; IsPrimary = $true
            Left = 0; Top = 0; Right = 1920; Bottom = 1080; Capabilities = ""
            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false; VcpMaximums = @{}
            CapabilitiesExcluded = $false; CapabilitiesSafetyError = ""
            IdentityKey = $identity.Key; IdentitySource = $identity.Source; IdentityDefaultLabel = $identity.DefaultLabel
            DevicePath = $identity.DevicePath; MonitorDeviceString = $identity.DeviceString; HardwareId = $identity.HardwareId
            Manufacturer = $identity.Manufacturer; EdidModel = $identity.Model; EdidSerial = $identity.Serial; EdidName = $identity.EdidName
            UserLabel = ""; DisplayLabel = $identity.DefaultLabel
        }
        Apply-MonitorIdentity -Monitor $fallbackObject
        $script:PhysicalMonitors += $fallbackObject
    }
    Sync-DisplayRecoveryInventory
    if ($script:DdcAvailabilityDiagnosis -and [string]$script:DdcAvailabilityDiagnosis.Severity -ne "None") {
        Update-Status ([string]$script:DdcAvailabilityDiagnosis.Headline)
    }
}

function Format-DdcDiagnostic {
    param([string]$Operation, [string]$Monitor, [int]$Code, $Value, [int]$LastError, [int]$Attempts, [string]$Message)
    $desc = Get-VcpDescription -Code $Code
    $monitorText = if ([string]::IsNullOrWhiteSpace($Monitor)) { "Unknown monitor" } else { $Monitor }
    $attemptedValue = if ($null -eq $Value) { "read" } else { [string]$Value }
    $retryCount = [Math]::Max(0, $Attempts - 1)
    $messageText = if ([string]::IsNullOrWhiteSpace($Message)) { "" } else { "`nMessage: $Message" }
    return "DDC/CI $Operation failed`nMonitor: $monitorText`nVCP: 0x$("{0:X2}" -f $Code) ($desc)`nAttempted value: $attemptedValue`nWin32 error: $LastError`nRetries: $retryCount$messageText"
}

function Update-DdcDiagnosticsText {
    if (-not $vcpResultBox -or $script:DdcRecentErrors.Count -eq 0) { return }
    if ($script:VcpWorker -and $script:VcpWorkerAsyncResult -and -not $script:VcpWorkerAsyncResult.IsCompleted) { return }
    $recent = @($script:DdcRecentErrors | Sort-Object -Property Timestamp -Descending | Select-Object -First 8)
    $vcpResultBox.Text = "DDC/CI Diagnostics (latest first)`n`n" + (($recent | ForEach-Object { $_.Summary }) -join "`n`n")
}

function Register-DdcDiagnostic {
    param([string]$Operation, [string]$Monitor, [int]$Code, $Value, [int]$LastError, [int]$Attempts, [string]$Message, [switch]$SuppressStatus)
    $summary = Format-DdcDiagnostic -Operation $Operation -Monitor $Monitor -Code $Code -Value $Value -LastError $LastError -Attempts $Attempts -Message $Message
    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Operation = $Operation
        Monitor = $Monitor
        Code = $Code
        Value = $Value
        LastError = $LastError
        Attempts = $Attempts
        Message = $Message
        Summary = $summary
    }
    $script:DdcRecentErrors.Add($entry)
    while ($script:DdcRecentErrors.Count -gt $script:DdcRecentErrorLimit) { $script:DdcRecentErrors.RemoveAt(0) }
    Update-DdcDiagnosticsText
    if (-not $SuppressStatus) {
        Update-Status ("DDC/CI {0} failed: {1} 0x{2:X2} Win32 {3}" -f $Operation.ToLowerInvariant(), $Monitor, $Code, $LastError)
    }
    return $entry
}

function Drain-DdcWriteResults {
    $results = @([MonitorAPI]::DrainVCPWriteResults())
    foreach ($result in $results) {
        if (-not [bool]$result.Success) {
            Register-DdcDiagnostic -Operation "Write" -Monitor ([string]$result.MonitorName) -Code ([int]$result.Code) -Value ([uint32]$result.Value) -LastError ([int]$result.LastError) -Attempts ([int]$result.Attempts) -Message ([string]$result.ErrorMessage) | Out-Null
        }
    }
}

function Start-DdcWriteResultTimer {
    if ($script:DdcWriteResultTimer) { $script:DdcWriteResultTimer.Start(); return }
    $script:DdcWriteResultTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:DdcWriteResultTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:DdcWriteResultTimer.Add_Tick({ Drain-DdcWriteResults })
    $script:DdcWriteResultTimer.Start()
}

function New-DdcTimingProfile {
    param([string]$IdentityKey)
    return [PSCustomObject]@{
        IdentityKey = [string]$IdentityKey
        Mode = "Adaptive"
        SleepMultiplier = 1.0
        CalibratedAt = ""
        ReadRetries = [int][MonitorAPI]::VcpReadRetryCount
        WriteRetries = [int][MonitorAPI]::VcpWriteRetryCount
        CapabilityRetries = [int][MonitorAPI]::VcpReadRetryCount
        UnsupportedCodes = @()
    }
}

function Get-DdcTimingProfile {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return (New-DdcTimingProfile -IdentityKey "") }
    if (-not $script:DdcTimingProfiles.ContainsKey([string]$IdentityKey)) {
        $script:DdcTimingProfiles[[string]$IdentityKey] = New-DdcTimingProfile -IdentityKey ([string]$IdentityKey)
    }
    return $script:DdcTimingProfiles[[string]$IdentityKey]
}

function Get-DdcEffectiveTiming {
    param($TimingProfile)
    if ($null -eq $TimingProfile) { $TimingProfile = New-DdcTimingProfile -IdentityKey "" }
    $mode = [string]$TimingProfile.Mode
    # Manual is an override, not a modifier: an operator-set delay is used verbatim so the
    # calibration cannot quietly move it underneath them.
    $multiplier = if ($mode -eq "Manual") { 1.0 } else {
        [Math]::Min($script:DdcTimingMaxMultiplier, [Math]::Max($script:DdcTimingMinMultiplier, [double]$TimingProfile.SleepMultiplier))
    }
    $delay = [int][Math]::Round([MonitorAPI]::VcpRetryDelayMilliseconds * $multiplier, [System.MidpointRounding]::AwayFromZero)
    return [PSCustomObject]@{
        Mode = $mode
        SleepMultiplier = [double]$multiplier
        DelayMilliseconds = [int][MonitorAPI]::ClampRetryDelay($delay)
        ReadRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.ReadRetries))
        WriteRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.WriteRetries))
        CapabilityRetries = [int][Math]::Min($script:DdcTimingMaxRetries, [Math]::Max(0, [int]$TimingProfile.CapabilityRetries))
    }
}

function Get-DdcCalibratedSleepMultiplier {
    param([int]$Attempts, [bool]$Success, [double]$Current = 1.0)
    # The delay only ever runs between retries, so a first-attempt success proves nothing
    # about it and leaves the multiplier alone. Every extra attempt the panel needed scales
    # the delay by that many times, bounded so one bad handshake cannot stall the app.
    if (-not $Success) { return [double]$Current }
    $attemptCount = [Math]::Max(1, $Attempts)
    if ($attemptCount -le 1) { return [double]$Current }
    $target = [double]$attemptCount
    if ($target -lt $script:DdcTimingMinMultiplier) { $target = $script:DdcTimingMinMultiplier }
    if ($target -gt $script:DdcTimingMaxMultiplier) { $target = $script:DdcTimingMaxMultiplier }
    return [double]$target
}

function Test-DdcCodeUnsupported {
    param($TimingProfile, [int]$Code)
    if ($null -eq $TimingProfile) { return $false }
    foreach ($entry in @($TimingProfile.UnsupportedCodes)) {
        if ($null -ne $entry -and [int]$entry.Code -eq [int]$Code) { return $true }
    }
    return $false
}

function Register-DdcCodeOutcome {
    param($TimingProfile, [int]$Code, [bool]$Success, [int]$LastError = 0, [int]$Attempts = 0, [bool]$OtherCodesResponded = $false)
    if ($null -eq $TimingProfile) { return $false }
    if ($Success) {
        $remaining = @(@($TimingProfile.UnsupportedCodes) | Where-Object { $null -ne $_ -and [int]$_.Code -ne [int]$Code })
        $changed = @($remaining).Count -ne @($TimingProfile.UnsupportedCodes).Count
        $TimingProfile.UnsupportedCodes = $remaining
        return $changed
    }
    # A code that fails every retry on a monitor that answers other codes is signalling
    # "not supported", not "not ready". ddcutil documents panels that use the DDC Null
    # Message for both, and burning the full retry budget on each of them is what makes a
    # scan look like the app has hung.
    if (-not $OtherCodesResponded) { return $false }
    if ($Attempts -lt 2) { return $false }
    if (Test-DdcCodeUnsupported -TimingProfile $TimingProfile -Code $Code) { return $false }
    $TimingProfile.UnsupportedCodes = @(@($TimingProfile.UnsupportedCodes) + [PSCustomObject]@{
        Code = [int]$Code
        LastError = [int]$LastError
        ObservedAt = (Get-Date).ToString("o")
    })
    return $true
}

function Set-DdcTimingMode {
    param([string]$IdentityKey, [string]$Mode)
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    $requested = if ($Mode -eq "Manual") { "Manual" } else { "Adaptive" }
    if ([string]$timingProfile.Mode -eq $requested) { return $timingProfile }
    $timingProfile.Mode = $requested
    if ($requested -eq "Adaptive") {
        # Adaptive and manual are mutually exclusive, so re-entering adaptive discards the
        # stored calibration rather than mixing an operator value with a learned one.
        $timingProfile.SleepMultiplier = 1.0
        $timingProfile.CalibratedAt = ""
    }
    return $timingProfile
}

function Clear-DdcTimingCalibration {
    param([string]$IdentityKey)
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    $timingProfile.SleepMultiplier = 1.0
    $timingProfile.CalibratedAt = ""
    $timingProfile.UnsupportedCodes = @()
    return $timingProfile
}

function Update-DdcTimingCalibration {
    param([string]$IdentityKey, [int]$Attempts, [bool]$Success)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    if ([string]$timingProfile.Mode -ne "Adaptive") { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { return $false }
    if (-not $Success) { return $false }
    $timingProfile.SleepMultiplier = Get-DdcCalibratedSleepMultiplier -Attempts $Attempts -Success $Success -Current ([double]$timingProfile.SleepMultiplier)
    $timingProfile.CalibratedAt = (Get-Date).ToString("o")
    return $true
}

function Get-DdcTimingSettingsObject {
    $records = @()
    foreach ($key in @($script:DdcTimingProfiles.Keys)) {
        $entry = $script:DdcTimingProfiles[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            Mode = [string]$entry.Mode
            SleepMultiplier = [double]$entry.SleepMultiplier
            CalibratedAt = [string]$entry.CalibratedAt
            ReadRetries = [int]$entry.ReadRetries
            WriteRetries = [int]$entry.WriteRetries
            CapabilityRetries = [int]$entry.CapabilityRetries
            UnsupportedCodes = @(@($entry.UnsupportedCodes) | ForEach-Object {
                [PSCustomObject]@{ Code = [int]$_.Code; LastError = [int]$_.LastError; ObservedAt = [string]$_.ObservedAt }
            })
        }
    }
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:DdcTimingSchemaVersion
        Monitors = @($records)
    }
}

function Save-DdcTimingSettings {
    return (Write-JsonFileSafely -Path $script:DdcTimingSettingsPath -Data (Get-DdcTimingSettingsObject) -Depth 6)
}

function Import-DdcTimingSettings {
    $script:DdcTimingProfiles = @{}
    if (-not (Test-Path -LiteralPath $script:DdcTimingSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:DdcTimingSettingsPath -Label "DDC timing settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:DdcTimingSchemaVersion) {
        Update-Status "DDC timing settings use schema v$schema; defaults will be used instead"
        return
    }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey)) { continue }
        $timingProfile = New-DdcTimingProfile -IdentityKey $identityKey
        $mode = [string](Get-ProfilePropertyValue -Object $record -Property "Mode" -Default "Adaptive")
        $timingProfile.Mode = if ($mode -eq "Manual") { "Manual" } else { "Adaptive" }
        $timingProfile.SleepMultiplier = [double](Get-ProfilePropertyValue -Object $record -Property "SleepMultiplier" -Default 1.0)
        $timingProfile.CalibratedAt = [string](Get-ProfilePropertyValue -Object $record -Property "CalibratedAt" -Default "")
        $timingProfile.ReadRetries = [int](Get-ProfilePropertyValue -Object $record -Property "ReadRetries" -Default ([int][MonitorAPI]::VcpReadRetryCount))
        $timingProfile.WriteRetries = [int](Get-ProfilePropertyValue -Object $record -Property "WriteRetries" -Default ([int][MonitorAPI]::VcpWriteRetryCount))
        $timingProfile.CapabilityRetries = [int](Get-ProfilePropertyValue -Object $record -Property "CapabilityRetries" -Default ([int][MonitorAPI]::VcpReadRetryCount))
        $codes = @()
        foreach ($codeRecord in @((Get-ProfilePropertyValue -Object $record -Property "UnsupportedCodes" -Default @()))) {
            if ($null -eq $codeRecord) { continue }
            $codes += [PSCustomObject]@{
                Code = [int](Get-ProfilePropertyValue -Object $codeRecord -Property "Code" -Default 0)
                LastError = [int](Get-ProfilePropertyValue -Object $codeRecord -Property "LastError" -Default 0)
                ObservedAt = [string](Get-ProfilePropertyValue -Object $codeRecord -Property "ObservedAt" -Default "")
            }
        }
        $timingProfile.UnsupportedCodes = @($codes)
        $script:DdcTimingProfiles[$identityKey] = $timingProfile
    }
}

function Test-DdcMonitorResponded {
    param([string]$IdentityKey)
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    return [bool]$script:DdcRespondedIdentityKeys.ContainsKey([string]$IdentityKey)
}

function Get-IdentityKeyForHandle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return "" }
    foreach ($monitor in @($script:PhysicalMonitors)) {
        if ($null -ne $monitor -and $monitor.Handle -eq $Handle) { return [string]$monitor.IdentityKey }
    }
    return ""
}

function Get-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [string]$MonitorName = "", [string]$IdentityKey = "")
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { $IdentityKey = Get-IdentityKeyForHandle -Handle $Handle }
    $timingProfile = Get-DdcTimingProfile -IdentityKey $IdentityKey
    if (Test-DdcCodeUnsupported -TimingProfile $timingProfile -Code ([int]$VCPCode)) {
        return @{ Success = $false; Current = [uint32]0; Maximum = [uint32]0; Type = [uint32]0; LastError = 0; Attempts = 0; RetryCount = 0; Skipped = $true }
    }
    $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
    $vct = [uint32]0; $cur = [uint32]0; $max = [uint32]0
    $lastError = [int]0; $attempts = [int]0
    $result = [MonitorAPI]::ReadVCPWithRetry($Handle, $VCPCode, [int]$timing.ReadRetries, [int]$timing.DelayMilliseconds, [ref]$vct, [ref]$cur, [ref]$max, [ref]$lastError, [ref]$attempts)
    if (-not [string]::IsNullOrWhiteSpace($IdentityKey)) {
        $dirty = Update-DdcTimingCalibration -IdentityKey $IdentityKey -Attempts $attempts -Success $result
        if (Register-DdcCodeOutcome -TimingProfile $timingProfile -Code ([int]$VCPCode) -Success $result -LastError $lastError -Attempts $attempts -OtherCodesResponded (Test-DdcMonitorResponded -IdentityKey $IdentityKey)) { $dirty = $true }
        if ($dirty) { Save-DdcTimingSettings | Out-Null }
        if ($result) { $script:DdcRespondedIdentityKeys[$IdentityKey] = $true }
    }
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Read" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $null -LastError $lastError -Attempts $attempts -Message "" -SuppressStatus | Out-Null
    }
    return @{ Success = $result; Current = $cur; Maximum = $max; Type = $vct; LastError = $lastError; Attempts = $attempts; RetryCount = [Math]::Max(0, $attempts - 1); Skipped = $false }
}

function Set-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$MonitorName = "")
    $lastError = [int]0; $attempts = [int]0
    $timing = Get-DdcEffectiveTiming -TimingProfile (Get-DdcTimingProfile -IdentityKey (Get-IdentityKeyForHandle -Handle $Handle))
    $result = [MonitorAPI]::SetVCPWithRetry($Handle, $VCPCode, $Value, [int]$timing.WriteRetries, [int]$timing.DelayMilliseconds, [ref]$lastError, [ref]$attempts)
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Write" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $Value -LastError $lastError -Attempts $attempts -Message "" | Out-Null
    }
    return $result
}

function Queue-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$Key, [string]$MonitorName = "", [switch]$ForceWrite)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    [MonitorAPI]::QueueVCPWrite($Handle, $VCPCode, $Value, $Key, $MonitorName, [bool]$ForceWrite)
    return $true
}

function Get-SuppressedDdcWriteCount {
    try { return [int64][MonitorAPI]::GetSuppressedVcpWriteCount() } catch { return [int64]0 }
}

function Resolve-VcpWriteValueForMonitor {
    param($Monitor, [int]$Code, [uint32]$Value, [switch]$Percent)
    if (-not $Percent -or -not (Test-VcpCodeIsScaled -Code $Code)) { return [uint32]$Value }
    $maximum = Get-VcpMaximumForMonitor -Monitor $Monitor -Code $Code
    return [uint32](ConvertTo-VcpRawValue -Percent ([double]$Value) -Maximum $maximum)
}

function Set-VCPValueWithSync {
    param([byte]$VCPCode, [uint32]$Value, [switch]$Force, [switch]$Percent)
    if (Test-VcpWriteRequiresSafetyConsent -Code ([int]$VCPCode)) {
        if (Get-Command Update-Status -ErrorAction SilentlyContinue) {
            Update-Status "Risky VCP 0x$("{0:X2}" -f $VCPCode) requires the verified manual or consented automation path"
        }
        return $false
    }
    $code = [int]$VCPCode
    # WMI brightness is always expressed as a percentage, so an unscaled caller has to be
    # converted from the selected monitor's range before it reaches the integrated panel.
    $wmiPercent = if ($Percent) {
        [uint32][Math]::Max(0, [Math]::Min(100, [int]$Value))
    } else {
        [uint32](ConvertTo-VcpPercent -RawValue ([double]$Value) -Maximum (Get-SelectedMonitorVcpMaximum -Code $code))
    }
    $queued = 0
    if ($script:ApplyToAll -or $Force) {
        for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
            $mon = $script:PhysicalMonitors[$i]
            $target = Resolve-VcpWriteValueForMonitor -Monitor $mon -Code $code -Value $Value -Percent:$Percent
            if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $target -Key "$i`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name) { $queued++ }
        }
        if ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $wmiPercent | Out-Null }
    } else {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        $target = Resolve-VcpWriteValueForMonitor -Monitor $mon -Code $code -Value $Value -Percent:$Percent
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $target -Key "$script:CurrentMonitorIndex`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name) { $queued++ }
        elseif ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $wmiPercent | Out-Null }
    }
    if ($queued -gt 0) { return $true }
    return ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable)
}

function Get-VcpWriteOperation {
    param($Monitor, [int]$Code, [uint32]$Value, [string]$Backend = "DDC")
    return [PSCustomObject]@{
        Monitor = $Monitor
        MonitorName = if ($Monitor) { [string]$Monitor.Name } else { "Integrated display" }
        IdentityKey = if ($Monitor) { [string]$Monitor.IdentityKey } else { "wmi:integrated" }
        Handle = if ($Monitor) { [IntPtr]$Monitor.Handle } else { [IntPtr]::Zero }
        Code = [int]$Code
        Value = [uint32]$Value
        Backend = $Backend
    }
}

function Invoke-VerifiedVcpTransaction {
    param(
        [object[]]$Operations,
        [scriptblock]$ReadValue,
        [scriptblock]$WriteValue,
        [switch]$RollbackOnFailure,
        [int]$VerificationDelayMs = 75
    )
    $items = @($Operations | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Outcome = "NoTargets"; Results = @(); Rollback = "NotNeeded" }
    }
    if ($null -eq $ReadValue) {
        $ReadValue = {
            param($Operation)
            if ([string]$Operation.Backend -eq "WMI") {
                $current = Get-WmiBrightness
                return [PSCustomObject]@{ Success = $null -ne $current; Current = if ($null -ne $current) { [uint32]$current } else { [uint32]0 } }
            }
            return Get-VCPValue -Handle ([IntPtr]$Operation.Handle) -VCPCode ([byte]$Operation.Code) -MonitorName ([string]$Operation.MonitorName)
        }
    }
    if ($null -eq $WriteValue) {
        $WriteValue = {
            param($Operation, [uint32]$TargetValue)
            if ([string]$Operation.Backend -eq "WMI") {
                return (Set-WmiBrightness -Value $TargetValue)
            }
            return (Set-VCPValue -Handle ([IntPtr]$Operation.Handle) -VCPCode ([byte]$Operation.Code) -Value $TargetValue -MonitorName ([string]$Operation.MonitorName))
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $applied = New-Object System.Collections.Generic.List[object]
    $failureOutcome = ""
    foreach ($operation in $items) {
        $snapshot = $null
        try { $snapshot = & $ReadValue $operation } catch { $snapshot = $null }
        $snapshotReadable = $null -ne $snapshot -and [bool]$snapshot.Success
        $previousValue = if ($snapshotReadable) { [uint32]$snapshot.Current } else { [uint32]0 }
        $writeSucceeded = $false
        try { $writeSucceeded = [bool](& $WriteValue $operation ([uint32]$operation.Value)) } catch { $writeSucceeded = $false }
        $verification = "WriteFailed"
        $readbackValue = [uint32]0
        if ($writeSucceeded) {
            if ($VerificationDelayMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(1000, $VerificationDelayMs)) }
            $readback = $null
            try { $readback = & $ReadValue $operation } catch { $readback = $null }
            if ($null -eq $readback -or -not [bool]$readback.Success) {
                $verification = "Unverified"
            } else {
                $readbackValue = [uint32]$readback.Current
                $verification = if ($readbackValue -eq [uint32]$operation.Value) { "Verified" } else { "Mismatched" }
            }
        }
        $record = [PSCustomObject]@{
            Operation = $operation
            PreviousReadable = [bool]$snapshotReadable
            PreviousValue = $previousValue
            WriteSuccess = [bool]$writeSucceeded
            Verification = $verification
            ReadbackValue = $readbackValue
            Rollback = "NotNeeded"
        }
        $results.Add($record)
        if ($writeSucceeded -or $snapshotReadable) { $applied.Add($record) }
        if (-not $writeSucceeded) {
            $failureOutcome = "WriteFailed"
            break
        }
        if ($verification -eq "Mismatched") {
            $failureOutcome = "Mismatched"
            break
        }
    }

    $rollbackStatus = "NotNeeded"
    if ($failureOutcome -and $RollbackOnFailure) {
        $rollbackStatus = "Restored"
        for ($index = $applied.Count - 1; $index -ge 0; $index--) {
            $record = $applied[$index]
            if (-not [bool]$record.PreviousReadable) {
                $record.Rollback = "Unavailable"
                $rollbackStatus = "Partial"
                continue
            }
            $restored = $false
            try { $restored = [bool](& $WriteValue $record.Operation ([uint32]$record.PreviousValue)) } catch { $restored = $false }
            if (-not $restored) {
                $record.Rollback = "WriteFailed"
                $rollbackStatus = "Partial"
                continue
            }
            if ($VerificationDelayMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(1000, $VerificationDelayMs)) }
            $rollbackRead = $null
            try { $rollbackRead = & $ReadValue $record.Operation } catch { $rollbackRead = $null }
            if ($null -eq $rollbackRead -or -not [bool]$rollbackRead.Success) {
                $record.Rollback = "Unverified"
                $rollbackStatus = "Partial"
            } elseif ([uint32]$rollbackRead.Current -ne [uint32]$record.PreviousValue) {
                $record.Rollback = "Mismatched"
                $rollbackStatus = "Partial"
            } else {
                $record.Rollback = "Restored"
            }
        }
    }

    if ($failureOutcome) {
        return [PSCustomObject]@{
            Success = $false
            Outcome = $failureOutcome
            Results = $results.ToArray()
            Rollback = $rollbackStatus
        }
    }
    $unverifiedCount = @($results | Where-Object Verification -eq "Unverified").Count
    return [PSCustomObject]@{
        Success = $true
        Outcome = if ($unverifiedCount -gt 0) { "Unverified" } else { "Verified" }
        Results = $results.ToArray()
        Rollback = "NotNeeded"
    }
}

function Get-VcpWriteRiskNote {
    param([int]$Code)
    switch ($Code) {
        0x14 { return "Some monitors keep a color preset after this app closes and need a factory reset to undo it." }
        0xCA { return "This can disable the monitor's own buttons and on-screen menu, which is the only way to recover a display that stops responding to software." }
        0xCC { return "This changes the language of the monitor's own on-screen menu, which can make its settings hard to read." }
        0xD6 { return "Some monitors enter standby and will not wake from software; recovery may need the physical power button or a cable reseat." }
        0xD7 { return "This changes auxiliary power output, which can cut power to devices attached to the monitor." }
        0x60 { return "If the selected input has no signal the screen goes black, and software control may be unavailable until you switch back with the monitor's buttons." }
        0x04 { return "This resets every monitor setting to factory defaults and cannot be undone from this app." }
        0x08 { return "This resets the monitor's color settings to factory defaults." }
        default { return "" }
    }
}

function Format-VcpWriteConfirmation {
    param([object[]]$Operations, [string]$ActionLabel = "Direct VCP write")
    $items = @($Operations)
    $code = if ($items.Count -gt 0) { [int]$items[0].Code } else { 0 }
    $value = if ($items.Count -gt 0) { [uint32]$items[0].Value } else { 0 }
    $targets = @($items | ForEach-Object { [string]$_.MonitorName } | Sort-Object -Unique)
    $riskNote = Get-VcpWriteRiskNote -Code $code
    $riskLine = if ([string]::IsNullOrWhiteSpace($riskNote)) { "" } else { "$riskNote`n`n" }
    return @"
$ActionLabel

VCP code: 0x$("{0:X2}" -f $code) ($(Get-VcpDescription -Code $code))
Value: $value
Target: $($targets -join ", ")

$riskLine`This write may blank the display, change its input, remove access to the current desktop, or reset monitor settings. MonitorControl Pro will attempt an immediate readback, but some commands cannot be verified after the display changes state.

Apply this exact code and value?
"@
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
    if ($null -eq $Transaction) {
        $Transaction = {
            param([object[]]$Operations)
            # Manual writes get the same recovery guarantee as profile and automation writes:
            # a failed or mismatched command restores the readable prior value instead of
            # leaving the monitor in a state the user did not ask for.
            return (Invoke-VerifiedVcpTransaction -Operations $Operations -RollbackOnFailure)
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
    if (-not (Wait-DdcWriteQueueIdle -TimeoutMs 2000)) {
        Update-Status "VCP write queue is busy; try again"
        return [PSCustomObject]@{ Success = $false; Outcome = "Busy"; Results = @() }
    }
    $result = & $Transaction $operations
    $codeText = "0x{0:X2} = {1}" -f $Code, $Value
    $rollback = [string]$result.Rollback
    switch ($result.Outcome) {
        "Verified" { Update-Status "Verified VCP $codeText" }
        "Unverified" { Update-Status "VCP $codeText applied; readback unavailable" }
        "Mismatched" { Update-Status "VCP $codeText mismatched its readback; restore: $rollback" }
        default { Update-Status "VCP $codeText failed; restore: $rollback" }
    }
    return $result
}

function Get-VcpDescription {
    param([int]$Code)
    if ($script:VCPCodeDescriptions.ContainsKey($Code)) { return $script:VCPCodeDescriptions[$Code] }
    return "Unknown"
}

function Format-VcpResultLine {
    param($Result)
    $code = [int]$Result.Code
    $desc = Get-VcpDescription -Code $code
    if ([bool]$Result.Success) {
        return "0x{0:X2} {1,-24} = {2} (max:{3})" -f $code, $desc, [uint32]$Result.Current, [uint32]$Result.Maximum
    }
    return "0x{0:X2} {1,-24} read failed (Win32:{2}, retries:{3})" -f $code, $desc, [int]$Result.LastError, [int]$Result.RetryCount
}

function Stop-VcpWorker {
    param([switch]$Cancel)
    if ($script:VcpWorkerTimer) { $script:VcpWorkerTimer.Stop() }
    if ($script:VcpWorker) {
        if ($Cancel -and $script:VcpWorkerAsyncResult -and -not $script:VcpWorkerAsyncResult.IsCompleted) {
            try { $script:VcpWorker.Stop() } catch {}
        }
        try { $script:VcpWorker.Dispose() } catch {}
    }
    if ($script:VcpWorkerInput) { try { $script:VcpWorkerInput.Dispose() } catch {} }
    if ($script:VcpWorkerOutput) { try { $script:VcpWorkerOutput.Dispose() } catch {} }
    $script:VcpWorker = $null
    $script:VcpWorkerInput = $null
    $script:VcpWorkerOutput = $null
    $script:VcpWorkerAsyncResult = $null
    $script:VcpWorkerMode = ""
    $script:VcpWorkerMonitorName = ""
    $script:VcpWorkerLastOutputCount = 0
    $script:VcpWorkerGeneration = -1
    $script:VcpWorkerIdentityKey = ""
    $script:VcpWorkerMonitorIndex = -1
    $script:VcpWorkerHandleValue = [int64]0
    if ($vcpQueryBtn) { $vcpQueryBtn.IsEnabled = $true }
    if ($vcpScanBtn) { $vcpScanBtn.IsEnabled = $true }
}

function Update-VcpWorkerOutput {
    if (-not $script:VcpWorker -or -not $script:VcpWorkerOutput -or -not $script:VcpWorkerAsyncResult) { return }
    $context = [PSCustomObject]@{
        Generation = [int]$script:VcpWorkerGeneration
        MonitorIndex = [int]$script:VcpWorkerMonitorIndex
        IdentityKey = [string]$script:VcpWorkerIdentityKey
        HandleValue = [int64]$script:VcpWorkerHandleValue
    }
    if (-not (Test-DisplayWorkerResultCurrent -Result $context -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) {
        Stop-VcpWorker -Cancel
        return
    }
    $count = $script:VcpWorkerOutput.Count
    $completed = [bool]$script:VcpWorkerAsyncResult.IsCompleted
    if ($count -ne $script:VcpWorkerLastOutputCount -or $completed) {
        $script:VcpWorkerLastOutputCount = $count
        $items = @($script:VcpWorkerOutput | Where-Object {
            Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
        })
        if ($script:VcpWorkerMode -eq "Query") {
            if ($items.Count -gt 0) {
                $result = $items[-1]
                $code = [int]$result.Code
                $desc = Get-VcpDescription -Code $code
                if ([bool]$result.Success) {
                    $vcpResultBox.Text = "VCP 0x$("{0:X2}" -f $code) ($desc)`nCurrent: $($result.Current)`nMaximum: $($result.Maximum)"
                } else {
                    $vcpResultBox.Text = Format-DdcDiagnostic -Operation "Read" -Monitor ([string]$result.MonitorName) -Code $code -Value $null -LastError ([int]$result.LastError) -Attempts ([int]$result.Attempts) -Message ""
                }
            } else {
                $vcpResultBox.Text = "Reading VCP..."
            }
        } else {
            $last = if ($items.Count -gt 0) { $items[-1] } else { $null }
            $done = if ($last) { [int]$last.Index } else { 0 }
            $total = if ($last) { [int]$last.Count } else { 0 }
            $found = @($items | Where-Object { [bool]$_.Success } | ForEach-Object { Format-VcpResultLine -Result $_ })
            $failed = @($items | Where-Object { -not [bool]$_.Success } | ForEach-Object { Format-VcpResultLine -Result $_ })
            $scanMonitor = if ([string]::IsNullOrWhiteSpace($script:VcpWorkerMonitorName)) { "selected monitor" } else { $script:VcpWorkerMonitorName }
            $header = if ($completed) { "Supported VCP Codes for ${scanMonitor}:" } else { "Scanning VCP codes $done/$total..." }
            if ($completed) {
                $sections = @()
                if ($found.Count -gt 0) { $sections += "Readable:`n$($found -join "`n")" } else { $sections += "Readable:`nNone found" }
                if ($failed.Count -gt 0) { $sections += "Failed or unsupported:`n$($failed -join "`n")" }
                $body = $sections -join "`n`n"
            } else {
                $body = if ($found.Count -gt 0) { $found -join "`n" } else { "" }
            }
            $vcpResultBox.Text = "$header`n$body"
        }
    }
    if ($completed) {
        try { $script:VcpWorker.EndInvoke($script:VcpWorkerAsyncResult) } catch { Update-Status "VCP read failed: $($_.Exception.Message)" }
        $items = @($script:VcpWorkerOutput | Where-Object {
            Test-DisplayWorkerResultCurrent -Result $_ -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors
        })
        if ($script:VcpWorkerMode -eq "Query" -and $items.Count -gt 0 -and -not [bool]$items[-1].Success) {
            $failure = $items[-1]
            Register-DdcDiagnostic -Operation "Read" -Monitor ([string]$failure.MonitorName) -Code ([int]$failure.Code) -Value $null -LastError ([int]$failure.LastError) -Attempts ([int]$failure.Attempts) -Message "" | Out-Null
        }
        if (@($items | Where-Object { [bool]$_.Success }).Count -gt 0) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$context.IdentityKey) -Outcome "Success" -Generation $script:DisplayRecoveryGeneration | Out-Null
        } elseif ($items.Count -gt 0) {
            Set-DisplayRecoveryOutcome -IdentityKey ([string]$context.IdentityKey) -Outcome "Failure" -Generation $script:DisplayRecoveryGeneration -ErrorMessage "VCP read failed" | Out-Null
        }
        if ($script:VcpWorkerMode -eq "Scan") { Update-Status "VCP scan complete" }
        Stop-VcpWorker
    }
}

function Start-VcpReadWorker {
    param(
        [IntPtr]$Handle,
        [int[]]$Codes,
        [string]$Mode,
        [string]$MonitorName,
        [int]$ReadRetries = -1,
        [string]$IdentityKey = "",
        [int]$MonitorIndex = -1
    )
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
    if ($ReadRetries -lt 0) {
        $state = if ($script:DisplayRecoveryStates.ContainsKey($IdentityKey)) { $script:DisplayRecoveryStates[$IdentityKey] } else { $null }
        $ReadRetries = Get-DisplayRecoveryReadRetryCount -State $state -DefaultRetries $script:DdcReadRetryCount
    }
    $generation = [int]$script:DisplayRecoveryGeneration
    $handleValue = [int64]$Handle.ToInt64()
    $workerScript = {
        param([IntPtr]$Handle, [int[]]$Codes, [string]$MonitorName, [int]$ReadRetries, [string]$IdentityKey, [int]$MonitorIndex, [int]$Generation, [int64]$HandleValue)
        $index = 0
        foreach ($code in $Codes) {
            $index++
            $vct = [uint32]0
            $current = [uint32]0
            $maximum = [uint32]0
            $lastError = [int]0
            $attempts = [int]0
            $ok = [MonitorAPI]::ReadVCPWithRetry($Handle, [byte]$code, $ReadRetries, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
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
    $script:VcpWorker.AddScript($workerScript.ToString()).AddArgument($Handle).AddArgument($Codes).AddArgument($MonitorName).AddArgument($ReadRetries).AddArgument($IdentityKey).AddArgument($MonitorIndex).AddArgument($generation).AddArgument($handleValue) | Out-Null
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

function Get-DdcReportProbeCodes {
    return @(
        [int][MonitorAPI]::VCP_BRIGHTNESS,
        [int][MonitorAPI]::VCP_CONTRAST,
        [int][MonitorAPI]::VCP_COLOR_PRESET,
        [int][MonitorAPI]::VCP_RED_GAIN,
        [int][MonitorAPI]::VCP_GREEN_GAIN,
        [int][MonitorAPI]::VCP_BLUE_GAIN,
        [int][MonitorAPI]::VCP_VOLUME,
        [int][MonitorAPI]::VCP_MUTE,
        [int][MonitorAPI]::VCP_SHARPNESS,
        [int][MonitorAPI]::VCP_DISPLAY_USAGE_TIME,
        [int][MonitorAPI]::VCP_DISPLAY_MODE,
        [int][MonitorAPI]::VCP_VERSION
    )
}

function Format-DdcReportCodeList {
    param([object[]]$Codes)
    $items = @($Codes | ForEach-Object { [int]$_ } | Sort-Object -Unique | ForEach-Object { "0x{0:X2}" -f $_ })
    if ($items.Count -eq 0) { return "None parsed" }
    return ($items -join ", ")
}

function Get-DdcReportTargets {
    $allProbeCodes = @(Get-DdcReportProbeCodes)
    $targets = @()
    for ($monitorIndex = 0; $monitorIndex -lt $script:PhysicalMonitors.Count; $monitorIndex++) {
        $mon = $script:PhysicalMonitors[$monitorIndex]
        if ($null -eq $mon) { continue }
        $supportedCodes = @()
        if ([bool]$mon.CapabilitiesKnown -and $mon.SupportedVcpCodes) {
            $supportedCodes = @($mon.SupportedVcpCodes.Keys | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        }
        $probeCodes = @($allProbeCodes)
        $skippedCodes = @()
        if ($supportedCodes.Count -gt 0) {
            $probeCodes = @($allProbeCodes | Where-Object { $supportedCodes -contains $_ })
            $skippedCodes = @($allProbeCodes | Where-Object { $supportedCodes -notcontains $_ })
        }
        $capabilityStatus = if ([bool]$mon.CapabilitiesPending) {
            "Pending"
        } elseif ([bool]$mon.CapabilitiesKnown) {
            "Known"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$mon.Capabilities)) {
            "Raw available; parser found no VCP map"
        } else {
            "Unavailable"
        }
        $targets += [PSCustomObject]@{
            Index = [int]$mon.Index
            MonitorIndex = [int]$monitorIndex
            Label = [string](Get-MonitorDisplayLabel -Monitor $mon)
            Name = [string]$mon.Name
            DeviceName = [string]$mon.DeviceName
            DevicePath = [string]$mon.DevicePath
            HardwareId = [string]$mon.HardwareId
            IdentityKey = [string]$mon.IdentityKey
            IdentitySource = [string]$mon.IdentitySource
            Manufacturer = [string]$mon.Manufacturer
            EdidModel = [string]$mon.EdidModel
            EdidSerial = [string]$mon.EdidSerial
            EdidName = [string]$mon.EdidName
            Resolution = "{0}x{1}@{2}Hz" -f [int]$mon.Width, [int]$mon.Height, [int]$mon.RefreshRate
            Primary = [bool]$mon.IsPrimary
            CapabilityStatus = $capabilityStatus
            CapabilitiesLength = if ($mon.Capabilities) { [int]$mon.Capabilities.Length } else { 0 }
            SupportedCodes = [object[]]$supportedCodes
            ProbeCodes = [object[]]$probeCodes
            SkippedProbeCodes = [object[]]$skippedCodes
            RiskyWritesEnabled = Test-VcpWriteEnabledForMonitor -Monitor $mon
            RecoveryState = if ($mon.PSObject.Properties.Name -contains "RecoveryState") { [string]$mon.RecoveryState } else { "Stale" }
            RecoveryLastSuccessUtc = if ($mon.PSObject.Properties.Name -contains "RecoveryLastSuccessUtc") { $mon.RecoveryLastSuccessUtc } else { $null }
            Handle = $mon.Handle
            HandleValue = [int64]$mon.Handle.ToInt64()
            Generation = [int]$script:DisplayRecoveryGeneration
        }
    }
    return $targets
}

function Get-DdcReportSystemInfo {
    $osText = [Environment]::OSVersion.VersionString
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os) { $osText = "{0} {1} (build {2})" -f $os.Caption, $os.Version, $os.BuildNumber }
    } catch {}
    $gpuLines = @()
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        foreach ($gpu in $gpus) {
            $name = if ($gpu.Name) { [string]$gpu.Name } else { "Unknown GPU" }
            $driver = if ($gpu.DriverVersion) { [string]$gpu.DriverVersion } else { "unknown driver" }
            $gpuLines += "$name | driver $driver"
        }
    } catch {}
    if ($gpuLines.Count -eq 0) { $gpuLines = @("No GPU driver data available") }
    return [PSCustomObject]@{
        OS = $osText
        PowerShell = $PSVersionTable.PSVersion.ToString()
        GPUs = [object[]]$gpuLines
    }
}

function Get-DdcReportRecentErrors {
    return @($script:DdcRecentErrors | Sort-Object -Property Timestamp -Descending | Select-Object -First 8)
}

function Format-DdcReportProbeLine {
    param($Result)
    if ([bool]$Result.Skipped) { return "  - skipped: $($Result.Message)" }
    $code = [int]$Result.Code
    $desc = Get-VcpDescription -Code $code
    if ([bool]$Result.Success) {
        return "  - 0x{0:X2} {1}: OK current={2} max={3} type={4}" -f $code, $desc, [uint32]$Result.Current, [uint32]$Result.Maximum, [uint32]$Result.Type
    }
    return "  - 0x{0:X2} {1}: failed Win32={2} retries={3}" -f $code, $desc, [int]$Result.LastError, [int]$Result.RetryCount
}

function New-DdcCompatibilityReport {
    param([object[]]$Targets, [object[]]$ProbeResults, [object[]]$RecentErrors)
    $system = Get-DdcReportSystemInfo
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("MonitorControl Pro DDC Compatibility Report")
    [void]$sb.AppendLine("Generated: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))")
    [void]$sb.AppendLine("App version: 3.36.0")
    [void]$sb.AppendLine("OS: $($system.OS)")
    [void]$sb.AppendLine("PowerShell: $($system.PowerShell)")
    [void]$sb.AppendLine("Probe safety: read-only probes only; risky codes are never written automatically and power, input, reset, PiP/PbP, OSD, and arbitrary codes are not queried")
    [void]$sb.AppendLine("Capability cache entries: $($script:CapabilitiesCache.Count); shipped known-bad models: $(@($script:CapabilitiesKnownBadModels).Count)")
    [void]$sb.AppendLine("Redundant writes suppressed this session: $(Get-SuppressedDdcWriteCount)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("GPU drivers:")
    foreach ($gpu in @($system.GPUs)) { [void]$sb.AppendLine("- $gpu") }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("DDC availability:")
    $diagnosis = $script:DdcAvailabilityDiagnosis
    if ($null -eq $diagnosis) {
        [void]$sb.AppendLine("- not evaluated")
    } else {
        [void]$sb.AppendLine("- $($diagnosis.Summary) (severity $($diagnosis.Severity))")
        foreach ($cause in @($diagnosis.Causes)) {
            [void]$sb.AppendLine("- $($cause.Title)")
            [void]$sb.AppendLine("    why: $($cause.Detail)")
            [void]$sb.AppendLine("    try: $($cause.Fix)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Display paths:")
    if (@($script:DisplayPathInventory).Count -eq 0) {
        [void]$sb.AppendLine("- none enumerated")
    } else {
        foreach ($path in @($script:DisplayPathInventory)) {
            $channelText = if ([bool]$path.HasControlChannel) { "DDC/CI channel" } else { "no DDC/CI channel" }
            [void]$sb.AppendLine("- $($path.DeviceName) [$($path.Kind)] $channelText | $($path.Name) | adapter $($path.Adapter)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("DDC timing (effective values):")
    if (@($Targets).Count -eq 0) {
        [void]$sb.AppendLine("- no monitors")
    } else {
        foreach ($target in @($Targets | Sort-Object -Property Index)) {
            $timingProfile = Get-DdcTimingProfile -IdentityKey ([string]$target.IdentityKey)
            $timing = Get-DdcEffectiveTiming -TimingProfile $timingProfile
            $calibration = if ([string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { "uncalibrated" } else { "calibrated $($timingProfile.CalibratedAt)" }
            [void]$sb.AppendLine("- $($target.Label): mode=$($timing.Mode) multiplier=$($timing.SleepMultiplier) delay=$($timing.DelayMilliseconds)ms retries read=$($timing.ReadRetries) write=$($timing.WriteRetries) capability=$($timing.CapabilityRetries) ($calibration)")
            $unsupported = @($timingProfile.UnsupportedCodes)
            if ($unsupported.Count -gt 0) {
                $codeText = ($unsupported | ForEach-Object { "0x{0:X2} (Win32 {1})" -f [int]$_.Code, [int]$_.LastError }) -join ", "
                [void]$sb.AppendLine("    null-signalled unsupported: $codeText")
            }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Monitors:")
    foreach ($target in @($Targets | Sort-Object -Property Index)) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Monitor $($target.Index): $($target.Label)")
        [void]$sb.AppendLine("  Friendly name: $($target.Name)")
        [void]$sb.AppendLine("  Display device: $($target.DeviceName)")
        [void]$sb.AppendLine("  Resolution: $($target.Resolution)")
        [void]$sb.AppendLine("  Primary: $($target.Primary)")
        [void]$sb.AppendLine("  Identity: $($target.IdentityKey) ($($target.IdentitySource))")
        if (-not [string]::IsNullOrWhiteSpace([string]$target.HardwareId)) { [void]$sb.AppendLine("  Hardware ID: $($target.HardwareId)") }
        if (-not [string]::IsNullOrWhiteSpace([string]$target.DevicePath)) { [void]$sb.AppendLine("  Device path: $($target.DevicePath)") }
        $edidParts = @()
        if ($target.Manufacturer) { $edidParts += "manufacturer=$($target.Manufacturer)" }
        if ($target.EdidModel) { $edidParts += "model=$($target.EdidModel)" }
        if ($target.EdidSerial) { $edidParts += "serial=$($target.EdidSerial)" }
        if ($target.EdidName) { $edidParts += "name=$($target.EdidName)" }
        if ($edidParts.Count -gt 0) { [void]$sb.AppendLine("  EDID: $($edidParts -join "; ")") }
        [void]$sb.AppendLine("  Capabilities: $($target.CapabilityStatus), length=$($target.CapabilitiesLength), parsed codes=$(@($target.SupportedCodes).Count)")
        [void]$sb.AppendLine("  Parsed VCP list: $(Format-DdcReportCodeList -Codes $target.SupportedCodes)")
        $recoverySuccess = if ($null -ne $target.RecoveryLastSuccessUtc) { ([DateTime]$target.RecoveryLastSuccessUtc).ToString("o") } else { "never" }
        [void]$sb.AppendLine("  Recovery: $($target.RecoveryState), last successful read=$recoverySuccess")
        [void]$sb.AppendLine("  Risky VCP writes: $(if ([bool]$target.RiskyWritesEnabled) { 'identity unlocked; direct confirmation still required' } else { 'disabled' })")
        if (@($target.SkippedProbeCodes).Count -gt 0) {
            [void]$sb.AppendLine("  Common probes skipped by capabilities: $(Format-DdcReportCodeList -Codes $target.SkippedProbeCodes)")
        }
        [void]$sb.AppendLine("  Tested VCP results:")
        $monitorResults = @($ProbeResults | Where-Object { [int]$_.TargetIndex -eq [int]$target.Index } | Sort-Object -Property ProbeIndex)
        if ([int64]$target.HandleValue -eq 0) {
            [void]$sb.AppendLine("  - no DDC/CI handle; probes skipped")
        } elseif ($monitorResults.Count -eq 0) {
            [void]$sb.AppendLine("  - no common probe codes available")
        } else {
            foreach ($result in $monitorResults) { [void]$sb.AppendLine((Format-DdcReportProbeLine -Result $result)) }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Recent DDC errors:")
    if (@($RecentErrors).Count -eq 0) {
        [void]$sb.AppendLine("- None recorded in this session")
    } else {
        foreach ($entry in @($RecentErrors)) {
            [void]$sb.AppendLine("- $($entry.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")) | $($entry.Operation) | monitor=$($entry.Monitor) | VCP=0x$("{0:X2}" -f [int]$entry.Code) | Win32=$($entry.LastError) | attempts=$($entry.Attempts)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Privacy: local script, profile, and report file paths are omitted.")
    return $sb.ToString().TrimEnd()
}

function Save-DdcCompatibilityReport {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $dir = Join-Path $script:DefaultProfilesPath "diagnostics"
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $leaf = "ddc-compatibility-report-$((Get-Date).ToString("yyyyMMdd-HHmmss")).txt"
        $path = Join-Path $dir $leaf
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, ($Text + [Environment]::NewLine), $encoding)
        return $path
    } catch {
        return ""
    }
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

function Stop-DdcReportWorker {
    param([switch]$Cancel)
    if ($script:DdcReportWorkerTimer) { $script:DdcReportWorkerTimer.Stop() }
    if ($script:DdcReportWorker) {
        if ($Cancel -and $script:DdcReportWorkerAsyncResult -and -not $script:DdcReportWorkerAsyncResult.IsCompleted) {
            try { $script:DdcReportWorker.Stop() } catch {}
        }
        try { $script:DdcReportWorker.Dispose() } catch {}
    }
    if ($script:DdcReportWorkerInput) { try { $script:DdcReportWorkerInput.Dispose() } catch {} }
    if ($script:DdcReportWorkerOutput) { try { $script:DdcReportWorkerOutput.Dispose() } catch {} }
    $script:DdcReportWorker = $null
    $script:DdcReportWorkerInput = $null
    $script:DdcReportWorkerOutput = $null
    $script:DdcReportWorkerAsyncResult = $null
    $script:DdcReportWorkerLastOutputCount = 0
    $script:DdcReportTargets = @()
    $script:DdcReportWorkerGeneration = -1
    if ($ddcReportGenerateBtn) { $ddcReportGenerateBtn.IsEnabled = $true }
    if ($ddcReportCopyBtn) { $ddcReportCopyBtn.IsEnabled = $true }
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
    $report = New-DdcCompatibilityReport -Targets $script:DdcReportTargets -ProbeResults $probeResults -RecentErrors (Get-DdcReportRecentErrors)
    $script:DdcReportLastText = $report
    $ddcReportBox.Text = $report
    $copied = Copy-DdcCompatibilityReport -Text $report
    $path = Save-DdcCompatibilityReport -Text $report
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
    $total = 0
    foreach ($target in @($targets)) { $total += @($target.ProbeCodes).Count }
    $ddcReportBox.Text = "Generating DDC compatibility report... 0/$total probes"
    if ($ddcReportGenerateBtn) { $ddcReportGenerateBtn.IsEnabled = $false }
    if ($ddcReportCopyBtn) { $ddcReportCopyBtn.IsEnabled = $false }
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
                $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]$code, $ReadRetries, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
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

function New-AutomationBridgeApiKey {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Protect-AutomationBridgeApiKey {
    param([string]$ApiKey)
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { return "" }
    if ($null -eq ("System.Security.Cryptography.ProtectedData" -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($ApiKey)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("MonitorControlPro.AutomationBridge.v2")
    try {
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return "dpapi:v1:$([Convert]::ToBase64String($protectedBytes))"
    } finally {
        if ($plainBytes.Length -gt 0) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($entropy.Length -gt 0) { [Array]::Clear($entropy, 0, $entropy.Length) }
    }
}

function Unprotect-AutomationBridgeApiKey {
    param([string]$ProtectedApiKey)
    if ([string]::IsNullOrWhiteSpace($ProtectedApiKey) -or -not $ProtectedApiKey.StartsWith("dpapi:v1:", [StringComparison]::Ordinal)) { return "" }
    if ($null -eq ("System.Security.Cryptography.ProtectedData" -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $encoded = $ProtectedApiKey.Substring(9)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes("MonitorControlPro.AutomationBridge.v2")
    $plainBytes = $null
    try {
        $protectedBytes = [Convert]::FromBase64String($encoded)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($plainBytes)
    } catch {
        return ""
    } finally {
        if ($null -ne $plainBytes -and $plainBytes.Length -gt 0) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($entropy.Length -gt 0) { [Array]::Clear($entropy, 0, $entropy.Length) }
    }
}

function Get-AutomationBridgeSettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:AutomationBridgeSettingsSchemaVersion
        Enabled = [bool]$script:AutomationBridgeEnabled
        BindAddress = [string]$script:AutomationBridgeBindAddress
        Port = [int]$script:AutomationBridgePort
        ApiKeyProtected = Protect-AutomationBridgeApiKey -ApiKey $script:AutomationBridgeApiKey
        NetworkExposureApproved = [bool]$script:AutomationBridgeNetworkExposureApproved
        NetworkExposureApprovedFor = [string]$script:AutomationBridgeNetworkExposureApprovedFor
        MqttEnabled = [bool]$script:AutomationBridgeMqttEnabled
        AllowedCommands = @($script:AutomationBridgeAllowedCommands)
        UpdatedAt = (Get-Date).ToString("o")
    }
}

function Save-AutomationBridgeSettings {
    if ([string]::IsNullOrWhiteSpace($script:AutomationBridgeApiKey)) { $script:AutomationBridgeApiKey = New-AutomationBridgeApiKey }
    try {
        $saved = Write-JsonFileSafely -Path $script:AutomationBridgeSettingsPath -Data (Get-AutomationBridgeSettingsObject) -Depth 5
        if (-not $saved) {
            $script:AutomationBridgeLastError = "Settings could not be protected and saved"
            Update-Status "Automation bridge settings could not be protected and saved"
        } elseif ($script:AutomationBridgeLastError -eq "Settings could not be protected and saved") {
            $script:AutomationBridgeLastError = ""
        }
        return [bool]$saved
    } catch {
        $script:AutomationBridgeLastError = "Settings could not be protected and saved"
        Update-Status "Automation bridge settings could not be protected and saved"
        return $false
    }
}

function Load-AutomationBridgeSettings {
    $script:AutomationBridgeEnabled = $false
    $script:AutomationBridgeBindAddress = "127.0.0.1"
    $script:AutomationBridgePort = 34291
    $script:AutomationBridgeApiKey = New-AutomationBridgeApiKey
    $script:AutomationBridgeMqttEnabled = $false
    $script:AutomationBridgeNetworkExposureApproved = $false
    $script:AutomationBridgeNetworkExposureApprovedFor = ""
    $script:AutomationBridgeLastError = ""
    $settingsExists = Test-Path -LiteralPath $script:AutomationBridgeSettingsPath
    $rewriteSettings = $false
    if ($settingsExists) {
        try {
            $data = Read-JsonFileSafely -Path $script:AutomationBridgeSettingsPath -Label "Automation bridge"
            if ($null -ne $data) {
                $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
                if ($schema -gt $script:AutomationBridgeSettingsSchemaVersion) {
                    $script:AutomationBridgeLastError = "Settings schema is newer than this app"
                } else {
                    $script:AutomationBridgeEnabled = [bool]$data.Enabled
                    if ($schema -lt $script:AutomationBridgeSettingsSchemaVersion) { $rewriteSettings = $true }
                    if ($data.BindAddress) {
                        $script:AutomationBridgeBindAddress = [string]$data.BindAddress
                        if ($null -eq (Resolve-AutomationBridgeIPAddress -BindAddress $script:AutomationBridgeBindAddress)) {
                            $script:AutomationBridgeEnabled = $false
                            $script:AutomationBridgeLastError = "Invalid bind address"
                            $rewriteSettings = $true
                        }
                    }
                    if ($data.Port) { $script:AutomationBridgePort = [Math]::Max(1024, [Math]::Min(65535, [int]$data.Port)) }
                    if ($data.PSObject.Properties.Name -contains "ApiKeyProtected") {
                        $unprotected = Unprotect-AutomationBridgeApiKey -ProtectedApiKey ([string]$data.ApiKeyProtected)
                        if ([string]::IsNullOrWhiteSpace($unprotected)) {
                            $script:AutomationBridgeEnabled = $false
                            $script:AutomationBridgeLastError = "Stored API key could not be unlocked"
                        } else {
                            $script:AutomationBridgeApiKey = $unprotected
                        }
                    } elseif ($data.PSObject.Properties.Name -contains "ApiKey" -and -not [string]::IsNullOrWhiteSpace([string]$data.ApiKey)) {
                        $script:AutomationBridgeApiKey = [string]$data.ApiKey
                        $rewriteSettings = $true
                    }
                    if ($data.PSObject.Properties.Name -contains "NetworkExposureApproved") {
                        $script:AutomationBridgeNetworkExposureApproved = [bool]$data.NetworkExposureApproved
                    }
                    if ($data.PSObject.Properties.Name -contains "NetworkExposureApprovedFor") {
                        $script:AutomationBridgeNetworkExposureApprovedFor = [string]$data.NetworkExposureApprovedFor
                    }
                    $script:AutomationBridgeMqttEnabled = [bool]$data.MqttEnabled
                }
            }
        } catch {
            $script:AutomationBridgeEnabled = $false
            $script:AutomationBridgeLastError = "Settings could not be loaded"
        }
    }
    $resolved = Resolve-AutomationBridgeIPAddress -BindAddress $script:AutomationBridgeBindAddress
    if ($script:AutomationBridgeEnabled -and $null -ne $resolved -and -not [System.Net.IPAddress]::IsLoopback($resolved)) {
        if (-not $script:AutomationBridgeNetworkExposureApproved -or $script:AutomationBridgeNetworkExposureApprovedFor -ne $resolved.ToString()) {
            $script:AutomationBridgeEnabled = $false
            $script:AutomationBridgeLastError = "Network exposure requires approval"
            $rewriteSettings = $true
        }
    }
    if ($rewriteSettings) { Save-AutomationBridgeSettings | Out-Null }
    Initialize-AutomationBridgeAuditLog
}

function Resolve-AutomationBridgeIPAddress {
    param([string]$BindAddress)
    if ([string]::IsNullOrWhiteSpace($BindAddress) -or $BindAddress.Trim().ToLowerInvariant() -eq "localhost") {
        return [System.Net.IPAddress]::Loopback
    }
    $address = [System.Net.IPAddress]::Loopback
    if ([System.Net.IPAddress]::TryParse($BindAddress.Trim(), [ref]$address)) { return $address }
    return $null
}

function Test-AutomationBridgeLoopback {
    param([string]$BindAddress)
    $address = Resolve-AutomationBridgeIPAddress -BindAddress $BindAddress
    return ($null -ne $address -and [System.Net.IPAddress]::IsLoopback($address))
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
    $script:AutomationBridgeMqttEnabled = $false
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
        $mqtt = if ($script:AutomationBridgeMqttEnabled) { "MQTT on" } else { "MQTT off" }
        $automationBridgeStatusText.Text = "$state - http://$script:AutomationBridgeBindAddress`:$script:AutomationBridgePort ($mqtt)"
    } finally {
        $script:UpdatingAutomationBridgeUI = $false
    }
}

function New-AutomationBridgeResponse {
    param([int]$Status, $Body)
    return [PSCustomObject]@{ Status = [int]$Status; Body = $Body }
}

function Get-AutomationBridgeBodyJson {
    param($Request)
    if ($null -eq $Request -or [string]::IsNullOrWhiteSpace([string]$Request.Body)) { return $null }
    try { return ([string]$Request.Body | ConvertFrom-Json) } catch { return $null }
}

function Get-AutomationBridgeInputValue {
    param($Request, $Body, [string]$Name)
    if ($Request.Query -and $Request.Query.ContainsKey($Name)) { return [string]$Request.Query[$Name] }
    if ($null -ne $Body -and $Body.PSObject.Properties.Name -contains $Name) { return [string]$Body.$Name }
    return ""
}

function Test-AutomationBridgeToken {
    param([string]$Provided, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Provided) -or [string]::IsNullOrWhiteSpace($Expected) -or $Provided.Length -gt 256 -or $Expected.Length -gt 256) {
        return $false
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $providedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Provided))
        $expectedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Expected))
        $difference = 0
        for ($i = 0; $i -lt $expectedHash.Length; $i++) {
            $difference = $difference -bor ($providedHash[$i] -bxor $expectedHash[$i])
        }
        return $difference -eq 0
    } finally {
        $sha.Dispose()
    }
}

function Test-AutomationBridgeRequestAuthorized {
    param($Request)
    if ($null -ne $Request -and $Request.PSObject.Properties.Name -contains "Authenticated" -and [bool]$Request.Authenticated) { return $true }
    $provided = ""
    if ($Request.Headers -and $Request.Headers.ContainsKey("x-monitorcontrol-key")) { $provided = [string]$Request.Headers["x-monitorcontrol-key"] }
    if (-not $provided -and $Request.Headers -and $Request.Headers.ContainsKey("authorization")) {
        $auth = [string]$Request.Headers["authorization"]
        if ($auth -match '^Bearer\s+(.+)$') { $provided = $matches[1] }
    }
    return Test-AutomationBridgeToken -Provided $provided -Expected $script:AutomationBridgeApiKey
}

function Test-AutomationBridgePayloadCredential {
    param($Request, $Body)
    if ($Request.Query -and $Request.Query.ContainsKey("apiKey")) { return $true }
    if ($null -ne $Body -and @($Body.PSObject.Properties.Name | Where-Object { $_ -ieq "apiKey" }).Count -gt 0) { return $true }
    return $false
}

function ConvertTo-AutomationBridgeAuditEntry {
    param([string]$Action, [string]$Target, $Value, [bool]$Success, [string]$Remote, [string]$Message, [string]$Timestamp)
    $safeAction = if ($Action -in @("setBrightness", "loadProfile")) { $Action } else { "unknown" }
    $targetScope = if ([string]::IsNullOrWhiteSpace($Target)) { "default" } else { "specified" }
    $remoteScope = "network"
    if ([string]::IsNullOrWhiteSpace($Remote)) {
        $remoteScope = "unknown"
    } elseif ($Remote -eq "loopback" -or $Remote -match '^\[?(127\.|::1\]?:)') {
        $remoteScope = "loopback"
    }
    $resultCode = if ($Message -in @("queued", "loaded", "no_monitors", "monitor_not_found", "no_write_target", "completed", "operation_failed")) {
        $Message
    } else {
        switch ($Message) {
            "Queued" { "queued" }
            "Loaded" { "loaded" }
            "No monitors enumerated" { "no_monitors" }
            "Monitor not found" { "monitor_not_found" }
            "No write target" { "no_write_target" }
            default { if ($Success) { "completed" } else { "operation_failed" } }
        }
    }
    $safeValue = ""
    $parsedValue = 0
    if ($safeAction -eq "setBrightness" -and [int]::TryParse([string]$Value, [ref]$parsedValue)) {
        $safeValue = [Math]::Max(0, [Math]::Min(100, $parsedValue))
    }
    $parsedTimestamp = [DateTime]::MinValue
    $safeTimestamp = if (
        -not [string]::IsNullOrWhiteSpace($Timestamp) -and
        [DateTime]::TryParse($Timestamp, [ref]$parsedTimestamp)
    ) {
        $parsedTimestamp.ToUniversalTime().ToString("o")
    } else {
        [DateTime]::UtcNow.ToString("o")
    }
    return [PSCustomObject]@{
        Timestamp = $safeTimestamp
        Action = $safeAction
        TargetScope = $targetScope
        Value = $safeValue
        Success = [bool]$Success
        RemoteScope = $remoteScope
        ResultCode = $resultCode
    }
}

function Convert-AutomationBridgeAuditFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $retained = New-Object 'System.Collections.Generic.Queue[object]'
        $retainedBytes = 0
        foreach ($rawLine in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
            try {
                $legacy = $rawLine | ConvertFrom-Json
            } catch {
                continue
            }
            $sanitized = ConvertTo-AutomationBridgeAuditEntry `
                -Action ([string]$legacy.Action) `
                -Target $(if ($legacy.PSObject.Properties.Name -contains "TargetScope") { if ([string]$legacy.TargetScope -eq "default") { "" } else { "specified" } } else { [string]$legacy.Target }) `
                -Value $legacy.Value `
                -Success ([bool]$legacy.Success) `
                -Remote $(if ($legacy.PSObject.Properties.Name -contains "RemoteScope") { [string]$legacy.RemoteScope } else { [string]$legacy.Remote }) `
                -Message $(if ($legacy.PSObject.Properties.Name -contains "ResultCode") { [string]$legacy.ResultCode } else { [string]$legacy.Message }) `
                -Timestamp ([string]$legacy.Timestamp)
            $line = (($sanitized | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
            $byteCount = $encoding.GetByteCount($line)
            if ($byteCount -gt $script:AutomationBridgeAuditLogMaxBytes) { continue }
            while ($retained.Count -gt 0 -and ($retainedBytes + $byteCount) -gt $script:AutomationBridgeAuditLogMaxBytes) {
                $removed = $retained.Dequeue()
                $retainedBytes -= [int]$removed.Bytes
            }
            $retained.Enqueue([PSCustomObject]@{ Text = $line; Bytes = $byteCount })
            $retainedBytes += $byteCount
        }
        $builder = New-Object System.Text.StringBuilder
        foreach ($item in $retained) { [void]$builder.Append([string]$item.Text) }
        [System.IO.File]::WriteAllText($tempPath, $builder.ToString(), $encoding)
        [System.IO.File]::Copy($tempPath, $Path, $true)
        Remove-Item -LiteralPath $tempPath -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        Set-DeferredStatus "Automation bridge audit log privacy migration failed"
        return $false
    }
}

function Initialize-AutomationBridgeAuditLog {
    Convert-AutomationBridgeAuditFile -Path $script:AutomationBridgeWriteLogPath | Out-Null
    Convert-AutomationBridgeAuditFile -Path "$script:AutomationBridgeWriteLogPath.1" | Out-Null
}

function Write-AutomationBridgeWriteLog {
    param([string]$Action, [string]$Target, $Value, [bool]$Success, [string]$Remote, [string]$Message)
    $entry = ConvertTo-AutomationBridgeAuditEntry -Action $Action -Target $Target -Value $Value -Success $Success -Remote $Remote -Message $Message -Timestamp ([DateTime]::UtcNow.ToString("o"))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $line = (($entry | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
        $lineBytes = $encoding.GetByteCount($line)
        if (Test-Path -LiteralPath $script:AutomationBridgeWriteLogPath) {
            $currentLength = (Get-Item -LiteralPath $script:AutomationBridgeWriteLogPath).Length
            if (($currentLength + $lineBytes) -gt $script:AutomationBridgeAuditLogMaxBytes) {
                $archivePath = "$script:AutomationBridgeWriteLogPath.1"
                if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
                Move-Item -LiteralPath $script:AutomationBridgeWriteLogPath -Destination $archivePath
            }
        }
        [System.IO.File]::AppendAllText($script:AutomationBridgeWriteLogPath, $line, $encoding)
    } catch {
        Set-DeferredStatus "Automation bridge audit log is unavailable"
    }
}

function Get-AutomationBridgeMonitorList {
    $items = @()
    foreach ($mon in @($script:PhysicalMonitors)) {
        if ($null -eq $mon) { continue }
        $brightness = $null
        if (($mon.Index - 1) -eq $script:CurrentMonitorIndex) { $brightness = [int](Get-SelectedBrightnessPercent) }
        $items += [PSCustomObject]@{
            Index = [int]$mon.Index
            Label = [string](Get-MonitorDisplayLabel -Monitor $mon)
            Name = [string]$mon.Name
            IdentityKey = [string]$mon.IdentityKey
            DeviceName = [string]$mon.DeviceName
            HasDdc = ([int64]$mon.Handle.ToInt64() -ne 0)
            Brightness = $brightness
            BrightnessMaximum = [int](Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))
        }
    }
    return $items
}

function Resolve-AutomationBridgeMonitorIndex {
    param([string]$MonitorRef)
    if ([string]::IsNullOrWhiteSpace($MonitorRef) -or $MonitorRef.Trim().ToLowerInvariant() -eq "current") {
        return $script:CurrentMonitorIndex
    }
    $ref = $MonitorRef.Trim()
    $number = 0
    if ([int]::TryParse($ref, [ref]$number)) {
        for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
            if ([int]$script:PhysicalMonitors[$i].Index -eq $number) { return $i }
        }
    }
    for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
        $mon = $script:PhysicalMonitors[$i]
        if ($ref -eq [string]$mon.IdentityKey -or $ref -eq (Get-MonitorDisplayLabel -Monitor $mon)) { return $i }
    }
    return -1
}

function Read-AutomationBridgeBrightness {
    param([string]$MonitorRef)
    $index = Resolve-AutomationBridgeMonitorIndex -MonitorRef $MonitorRef
    if ($index -lt 0 -or $index -ge $script:PhysicalMonitors.Count) { return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Monitor not found" } }
    $mon = $script:PhysicalMonitors[$index]
    if ($mon.Handle -eq [IntPtr]::Zero) {
        if ($script:WmiBrightnessAvailable) {
            $wmi = Get-WmiBrightness
            if ($null -ne $wmi) { return New-AutomationBridgeResponse -Status 200 -Body @{ monitor = $mon.Index; brightness = [int]$wmi; source = "WMI" } }
        }
        return New-AutomationBridgeResponse -Status 409 -Body @{ error = "No DDC/CI handle" }
    }
    $result = Get-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -MonitorName $mon.Name
    if (-not [bool]$result.Success) { return New-AutomationBridgeResponse -Status 502 -Body @{ error = "ddc_read_failed" } }
    Set-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS) -Maximum ([int]$result.Maximum)
    $maximum = Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
    return New-AutomationBridgeResponse -Status 200 -Body @{
        monitor = $mon.Index
        brightness = [int](ConvertTo-VcpPercent -RawValue ([double]$result.Current) -Maximum $maximum)
        raw = [int]$result.Current
        maximum = [int]$result.Maximum
        source = "DDC"
    }
}

function Set-AutomationBridgeBrightness {
    param([string]$MonitorRef, [int]$Value, [string]$Remote)
    $value = [Math]::Max(0, [Math]::Min(100, $Value))
    $targets = @()
    if ($script:PhysicalMonitors.Count -eq 0) {
        Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $MonitorRef -Value $value -Success $false -Remote $Remote -Message "No monitors enumerated"
        return New-AutomationBridgeResponse -Status 404 -Body @{ error = "No monitors enumerated" }
    }
    if ($MonitorRef -and $MonitorRef.Trim().ToLowerInvariant() -eq "all") {
        $targets = @(0..($script:PhysicalMonitors.Count - 1))
    } else {
        $index = Resolve-AutomationBridgeMonitorIndex -MonitorRef $MonitorRef
        if ($index -lt 0 -or $index -ge $script:PhysicalMonitors.Count) {
            Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $MonitorRef -Value $value -Success $false -Remote $Remote -Message "Monitor not found"
            return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Monitor not found" }
        }
        $targets = @($index)
    }
    $queued = 0
    foreach ($index in $targets) {
        $mon = $script:PhysicalMonitors[$index]
        $rawTarget = [uint32](ConvertTo-VcpRawValue -Percent ([double]$value) -Maximum (Get-VcpMaximumForMonitor -Monitor $mon -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)))
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $rawTarget -Key "bridge:$index`:0x10" -MonitorName $mon.Name) { $queued++ }
        if ($index -eq $script:CurrentMonitorIndex) {
            $script:UpdatingUI = $true
            try {
                $rawValue = ConvertTo-SelectedRawValue -Percent $value -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
                $brightnessSlider.Value = $rawValue
                $brightnessValue.Text = ([int]$rawValue).ToString()
            } finally { $script:UpdatingUI = $false }
        }
    }
    if ($queued -eq 0 -and $script:WmiBrightnessAvailable) {
        if (Set-WmiBrightness -Value ([uint32]$value)) { $queued = 1 }
    }
    $success = $queued -gt 0
    Write-AutomationBridgeWriteLog -Action "setBrightness" -Target $(if ($MonitorRef) { $MonitorRef } else { "current" }) -Value $value -Success $success -Remote $Remote -Message $(if ($success) { "Queued" } else { "No write target" })
    if (-not $success) { return New-AutomationBridgeResponse -Status 409 -Body @{ error = "No DDC/CI or WMI write target" } }
    Update-Status "Bridge brightness $value queued"
    Update-TrayPopupState
    Update-TrayIconText
    return New-AutomationBridgeResponse -Status 202 -Body @{ queued = $queued; brightness = $value }
}

function Invoke-AutomationBridgeRequest {
    param($Request)
    $body = Get-AutomationBridgeBodyJson -Request $Request
    $path = ([string]$Request.Path).TrimEnd("/").ToLowerInvariant()
    if ($path -eq "") { $path = "/" }
    $queryCount = if ($Request.Query) { [int]$Request.Query.Count } else { 0 }
    $isEmptyHealthCheck = (
        $Request.Method -eq "GET" -and
        ($path -eq "/health" -or $path -eq "/api/health") -and
        $queryCount -eq 0 -and
        [string]::IsNullOrEmpty([string]$Request.Body)
    )
    if ($isEmptyHealthCheck) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ ok = $true }
    }
    if (Test-AutomationBridgePayloadCredential -Request $Request -Body $body) {
        return New-AutomationBridgeResponse -Status 400 -Body @{ error = "credential_must_use_header" }
    }
    if (-not (Test-AutomationBridgeRequestAuthorized -Request $Request)) {
        return New-AutomationBridgeResponse -Status 401 -Body @{ error = "unauthorized" }
    }
    if ($Request.Method -eq "GET" -and ($path -eq "/monitors" -or $path -eq "/api/monitors")) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ monitors = @(Get-AutomationBridgeMonitorList) }
    }
    if ($Request.Method -eq "GET" -and ($path -eq "/profiles" -or $path -eq "/api/profiles")) {
        return New-AutomationBridgeResponse -Status 200 -Body @{ profiles = @((Get-UserProfileFiles | ForEach-Object { $_.BaseName })) }
    }
    if ($path -eq "/brightness" -or $path -eq "/api/brightness") {
        if ($Request.Method -eq "GET") { return Read-AutomationBridgeBrightness -MonitorRef (Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "monitor") }
        if ($Request.Method -eq "POST") {
            $rawValue = Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "value"
            $value = 0
            if (-not [int]::TryParse($rawValue, [ref]$value)) { return New-AutomationBridgeResponse -Status 400 -Body @{ error = "Brightness value required" } }
            return Set-AutomationBridgeBrightness -MonitorRef (Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "monitor") -Value $value -Remote ([string]$Request.Remote)
        }
    }
    if (($path -eq "/profile" -or $path -eq "/api/profile") -and $Request.Method -eq "POST") {
        $name = Get-AutomationBridgeInputValue -Request $Request -Body $body -Name "name"
        if ([string]::IsNullOrWhiteSpace($name)) { return New-AutomationBridgeResponse -Status 400 -Body @{ error = "Profile name required" } }
        $ok = Apply-ProfileByName -Name $name -Reason "Bridge profile" -AutomationRuleId "bridge:profile:$name"
        Write-AutomationBridgeWriteLog -Action "loadProfile" -Target $name -Value "" -Success $ok -Remote ([string]$Request.Remote) -Message $(if ($ok) { "Loaded" } else { "Failed" })
        if (-not $ok) { return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Profile not found or failed" } }
        return New-AutomationBridgeResponse -Status 202 -Body @{ profile = $name; queued = $true }
    }
    return New-AutomationBridgeResponse -Status 404 -Body @{ error = "Endpoint not allowed"; allowed = @($script:AutomationBridgeAllowedCommands) }
}

function Process-AutomationBridgeRequests {
    $request = $null
    while ($script:AutomationBridgeRequests.TryDequeue([ref]$request)) {
        if (
            $request.PSObject.Properties.Name -contains "ExpiresAtUtc" -and
            [DateTime]::UtcNow -ge [DateTime]$request.ExpiresAtUtc
        ) {
            $request = $null
            continue
        }
        try {
            $response = Invoke-AutomationBridgeRequest -Request $request
        } catch {
            $response = New-AutomationBridgeResponse -Status 500 -Body @{ error = "internal_error"; code = "bridge_request_failed" }
        }
        if (
            -not ($request.PSObject.Properties.Name -contains "ExpiresAtUtc") -or
            [DateTime]::UtcNow -lt [DateTime]$request.ExpiresAtUtc
        ) {
            $script:AutomationBridgeResponses[$request.Id] = $response
        }
        $request = $null
    }
}

function Start-AutomationBridgeRequestTimer {
    if ($script:AutomationBridgeTimer) { $script:AutomationBridgeTimer.Start(); return }
    $script:AutomationBridgeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutomationBridgeTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:AutomationBridgeTimer.Add_Tick({ Process-AutomationBridgeRequests })
    $script:AutomationBridgeTimer.Start()
}

function Get-AutomationBridgeWorkerScript {
    return {
        param($Settings, $RequestQueue, $ResponseMap, $BridgeState)

        function Send-BridgeBusy {
            param($Client, $Settings, $BridgeState)
            try {
                $Client.SendTimeout = [int]$Settings.WriteTimeoutMs
                $stream = $Client.GetStream()
                $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout
                $payload = '{"error":"server_busy"}'
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $header = "HTTP/1.1 503 Service Unavailable`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            } catch {
                $BridgeState["WriteFailureCount"] = [int]$BridgeState["WriteFailureCount"] + 1
            } finally {
                try {
                    $stream = $Client.GetStream()
                    $buffer = New-Object byte[] 1024
                    $deadline = [DateTime]::UtcNow.AddMilliseconds(75)
                    while ([DateTime]::UtcNow -lt $deadline) {
                        $available = [int]$Client.Available
                        if ($available -le 0) { Start-Sleep -Milliseconds 5; continue }
                        $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $available))
                        if ($read -le 0) { break }
                    }
                } catch { $null = $_ }
                try { $Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { $null = $_ }
                try { $Client.Close() } catch { $null = $_ }
            }
        }

        $handlerScript = {
            param($Client, $Settings, $RequestQueue, $ResponseMap, $BridgeState)

            function Read-BridgeLine {
                param($Stream, [int]$Limit)
                $bytes = New-Object 'System.Collections.Generic.List[byte]'
                $sawCarriageReturn = $false
                while ($true) {
                    $value = $Stream.ReadByte()
                    if ($value -lt 0) {
                        return [PSCustomObject]@{ Ok = $false; Error = "unexpected_eof"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($sawCarriageReturn) {
                        if ($value -ne 10) {
                            return [PSCustomObject]@{ Ok = $false; Error = "invalid_line_ending"; Line = ""; Bytes = [int]$bytes.Count }
                        }
                        return [PSCustomObject]@{
                            Ok = $true
                            Error = ""
                            Line = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
                            Bytes = [int]$bytes.Count + 2
                        }
                    }
                    if ($value -eq 13) {
                        $sawCarriageReturn = $true
                        continue
                    }
                    if ($value -eq 10) {
                        return [PSCustomObject]@{ Ok = $false; Error = "invalid_line_ending"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($value -gt 127 -or ($value -lt 32 -and $value -ne 9)) {
                        return [PSCustomObject]@{ Ok = $false; Error = "invalid_header_character"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    if ($bytes.Count -ge $Limit) {
                        return [PSCustomObject]@{ Ok = $false; Error = "line_too_long"; Line = ""; Bytes = [int]$bytes.Count }
                    }
                    $bytes.Add([byte]$value)
                }
            }

            function ConvertFrom-BridgeQuery {
                param([string]$Query)
                $result = @{}
                if ([string]::IsNullOrEmpty($Query)) { return $result }
                foreach ($pair in $Query.TrimStart("?").Split("&")) {
                    if ([string]::IsNullOrEmpty($pair)) { continue }
                    $parts = $pair.Split("=", 2)
                    $name = [Uri]::UnescapeDataString($parts[0].Replace("+", " "))
                    $value = if ($parts.Count -gt 1) { [Uri]::UnescapeDataString($parts[1].Replace("+", " ")) } else { "" }
                    $result[$name] = $value
                }
                return $result
            }

            function Test-BridgeToken {
                param([string]$Provided, [string]$Expected)
                if ([string]::IsNullOrWhiteSpace($Provided) -or [string]::IsNullOrWhiteSpace($Expected) -or $Provided.Length -gt 256 -or $Expected.Length -gt 256) {
                    return $false
                }
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $providedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Provided))
                    $expectedHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Expected))
                    $difference = 0
                    for ($i = 0; $i -lt $expectedHash.Length; $i++) {
                        $difference = $difference -bor ($providedHash[$i] -bxor $expectedHash[$i])
                    }
                    return $difference -eq 0
                } finally {
                    $sha.Dispose()
                }
            }

            function Send-BridgeJson {
                param($Client, [int]$Status, $Body, $Settings, $BridgeState)
                try {
                    $reason = switch ($Status) {
                        200 { "OK" }
                        202 { "Accepted" }
                        400 { "Bad Request" }
                        401 { "Unauthorized" }
                        404 { "Not Found" }
                        405 { "Method Not Allowed" }
                        408 { "Request Timeout" }
                        409 { "Conflict" }
                        411 { "Length Required" }
                        413 { "Payload Too Large" }
                        414 { "URI Too Long" }
                        431 { "Request Header Fields Too Large" }
                        500 { "Internal Server Error" }
                        502 { "Bad Gateway" }
                        503 { "Service Unavailable" }
                        504 { "Gateway Timeout" }
                        505 { "HTTP Version Not Supported" }
                        default { "Bad Request" }
                    }
                    $payload = if ($null -eq $Body) { "{}" } else { $Body | ConvertTo-Json -Depth 8 -Compress }
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    if ($bodyBytes.Length -gt [int]$Settings.MaxResponseBytes) {
                        $Status = 500
                        $reason = "Internal Server Error"
                        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"response_too_large"}')
                    }
                    $authenticationHeader = if ($Status -eq 401) { "WWW-Authenticate: Bearer`r`n" } else { "" }
                    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`n$authenticationHeader" + "Connection: close`r`n`r`n"
                    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                    $stream = $Client.GetStream()
                    $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                    $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    return $true
                } catch {
                    $BridgeState["WriteFailureCount"] = [int]$BridgeState["WriteFailureCount"] + 1
                    return $false
                }
            }

            function Close-BridgeClient {
                param($Client, [bool]$DrainInput)
                if ($DrainInput) {
                    try {
                        $drainStream = $Client.GetStream()
                        $drainBuffer = New-Object byte[] 1024
                        $drainDeadline = [DateTime]::UtcNow.AddMilliseconds(75)
                        while ([DateTime]::UtcNow -lt $drainDeadline) {
                            $available = [int]$Client.Available
                            if ($available -le 0) { Start-Sleep -Milliseconds 5; continue }
                            $read = $drainStream.Read($drainBuffer, 0, [Math]::Min($drainBuffer.Length, $available))
                            if ($read -le 0) { break }
                        }
                    } catch { $null = $_ }
                }
                try { $Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { $null = $_ }
                try { $Client.Close() } catch { $null = $_ }
            }

            $stream = $null
            $requestFullyRead = $false
            try {
                $Client.NoDelay = $true
                $Client.ReceiveTimeout = [int]$Settings.ReadTimeoutMs
                $Client.SendTimeout = [int]$Settings.WriteTimeoutMs
                $stream = $Client.GetStream()
                $stream.ReadTimeout = [int]$Settings.ReadTimeoutMs
                $stream.WriteTimeout = [int]$Settings.WriteTimeoutMs
                $BridgeState["LastReadTimeoutMs"] = [int]$stream.ReadTimeout
                $BridgeState["LastWriteTimeoutMs"] = [int]$stream.WriteTimeout

                $requestLineResult = Read-BridgeLine -Stream $stream -Limit ([int]$Settings.MaxRequestLineBytes)
                if (-not $requestLineResult.Ok) {
                    $status = if ($requestLineResult.Error -eq "line_too_long") { 414 } else { 400 }
                    Send-BridgeJson -Client $Client -Status $status -Body @{ error = [string]$requestLineResult.Error } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $requestLine = [string]$requestLineResult.Line
                $match = [regex]::Match($requestLine, '^([A-Z]+) ([^ ]+) (HTTP/[0-9]+\.[0-9]+)$')
                if (-not $match.Success) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_line" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $method = $match.Groups[1].Value
                $target = $match.Groups[2].Value
                $httpVersion = $match.Groups[3].Value
                if ($method -notin @("GET", "POST")) {
                    Send-BridgeJson -Client $Client -Status 405 -Body @{ error = "method_not_allowed" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($httpVersion -notin @("HTTP/1.0", "HTTP/1.1")) {
                    Send-BridgeJson -Client $Client -Status 505 -Body @{ error = "http_version_not_supported" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if (-not $target.StartsWith("/") -or $target.Contains("#")) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_target" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $headers = @{}
                $headerBytesRead = 0
                $headerCount = 0
                while ($true) {
                    $headerResult = Read-BridgeLine -Stream $stream -Limit ([int]$Settings.MaxHeaderBytes)
                    if (-not $headerResult.Ok) {
                        $status = if ($headerResult.Error -eq "line_too_long") { 431 } else { 400 }
                        Send-BridgeJson -Client $Client -Status $status -Body @{ error = [string]$headerResult.Error } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $headerBytesRead += [int]$headerResult.Bytes
                    if ($headerBytesRead -gt [int]$Settings.MaxHeaderBytes) {
                        Send-BridgeJson -Client $Client -Status 431 -Body @{ error = "headers_too_large" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $line = [string]$headerResult.Line
                    if ($line.Length -eq 0) { break }
                    $headerCount++
                    if ($headerCount -gt [int]$Settings.MaxHeaderCount) {
                        Send-BridgeJson -Client $Client -Status 431 -Body @{ error = "too_many_headers" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    if ($line.StartsWith(" ") -or $line.StartsWith("`t")) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "folded_header_not_allowed" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $colon = $line.IndexOf(":")
                    if ($colon -le 0) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $name = $line.Substring(0, $colon)
                    if (-not [regex]::IsMatch($name, "^[A-Za-z0-9!#$%&'*+.^_|~-]+$")) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_header_name" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $name = $name.ToLowerInvariant()
                    if ($headers.ContainsKey($name)) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "duplicate_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $headers[$name] = $line.Substring($colon + 1).Trim()
                }

                if ($httpVersion -eq "HTTP/1.1" -and (-not $headers.ContainsKey("host") -or [string]::IsNullOrWhiteSpace([string]$headers["host"]))) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "host_required" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($headers.ContainsKey("transfer-encoding")) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "transfer_encoding_not_supported" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $contentLength = [long]0
                if ($headers.ContainsKey("content-length")) {
                    $lengthText = [string]$headers["content-length"]
                    if (-not [regex]::IsMatch($lengthText, '^(0|[1-9][0-9]*)$') -or -not [long]::TryParse($lengthText, [ref]$contentLength)) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_content_length" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                } elseif ($method -eq "POST") {
                    Send-BridgeJson -Client $Client -Status 411 -Body @{ error = "content_length_required" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                if ($contentLength -gt [int]$Settings.MaxBodyBytes) {
                    Send-BridgeJson -Client $Client -Status 413 -Body @{ error = "body_too_large" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $body = ""
                if ($contentLength -gt 0) {
                    $bodyBytes = New-Object byte[] ([int]$contentLength)
                    $offset = 0
                    while ($offset -lt $bodyBytes.Length) {
                        $read = $stream.Read($bodyBytes, $offset, $bodyBytes.Length - $offset)
                        if ($read -le 0) {
                            Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "incomplete_body" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                            return
                        }
                        $offset += $read
                    }
                    try {
                        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
                        $body = $strictUtf8.GetString($bodyBytes)
                    } catch {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_utf8_body" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                }
                $requestFullyRead = $true

                try {
                    $uri = [Uri]::new("http://localhost$target")
                    $rawQueryCount = if ([string]::IsNullOrEmpty($uri.Query)) {
                        0
                    } else {
                        @($uri.Query.TrimStart("?").Split("&") | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count
                    }
                    if ($rawQueryCount -gt [int]$Settings.MaxQueryParameterCount) {
                        Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "too_many_query_parameters" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                        return
                    }
                    $query = ConvertFrom-BridgeQuery -Query $uri.Query
                } catch {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "invalid_request_target" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $isEmptyHealthCheck = (
                    $method -eq "GET" -and
                    ($uri.AbsolutePath -ieq "/health" -or $uri.AbsolutePath -ieq "/api/health") -and
                    $query.Count -eq 0 -and
                    $contentLength -eq 0
                )
                if ($isEmptyHealthCheck) {
                    Send-BridgeJson -Client $Client -Status 200 -Body @{ ok = $true } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $bodyJson = $null
                if (-not [string]::IsNullOrEmpty($body)) {
                    try { $bodyJson = $body | ConvertFrom-Json } catch { $bodyJson = $null }
                }
                $payloadCredential = $query.ContainsKey("apiKey")
                if ($null -ne $bodyJson -and @($bodyJson.PSObject.Properties.Name | Where-Object { $_ -ieq "apiKey" }).Count -gt 0) {
                    $payloadCredential = $true
                }
                if ($payloadCredential) {
                    Send-BridgeJson -Client $Client -Status 400 -Body @{ error = "credential_must_use_header" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }

                $provided = ""
                if ($headers.ContainsKey("x-monitorcontrol-key")) {
                    $provided = [string]$headers["x-monitorcontrol-key"]
                } elseif ($headers.ContainsKey("authorization")) {
                    $authorization = [string]$headers["authorization"]
                    if ($authorization -match '^Bearer\s+(.+)$') { $provided = $matches[1] }
                }
                if (-not (Test-BridgeToken -Provided $provided -Expected ([string]$Settings.ApiKey))) {
                    Send-BridgeJson -Client $Client -Status 401 -Body @{ error = "unauthorized" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                    return
                }
                $headers.Remove("x-monitorcontrol-key")
                $headers.Remove("authorization")

                $remoteScope = "unknown"
                try {
                    if ([System.Net.IPAddress]::IsLoopback($Client.Client.RemoteEndPoint.Address)) { $remoteScope = "loopback" } else { $remoteScope = "network" }
                } catch {
                    $remoteScope = "unknown"
                }
                $id = [guid]::NewGuid().ToString("N")
                $request = [PSCustomObject]@{
                    Id = $id
                    Method = $method
                    Path = [string]$uri.AbsolutePath
                    Query = $query
                    Headers = $headers
                    Body = $body
                    Remote = $remoteScope
                    Authenticated = $true
                    ExpiresAtUtc = [DateTime]::UtcNow.AddMilliseconds([int]$Settings.RouteTimeoutMs)
                }
                $RequestQueue.Enqueue($request)
                $deadline = [DateTime]$request.ExpiresAtUtc
                $response = $null
                while ([DateTime]::UtcNow -lt $deadline -and -not [bool]$BridgeState["Stop"]) {
                    if ($ResponseMap.ContainsKey($id)) {
                        $response = $ResponseMap[$id]
                        $ResponseMap.Remove($id)
                        break
                    }
                    Start-Sleep -Milliseconds 20
                }
                if ($null -eq $response) {
                    $ResponseMap.Remove($id)
                    Send-BridgeJson -Client $Client -Status 504 -Body @{ error = "route_timeout" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                } else {
                    Send-BridgeJson -Client $Client -Status ([int]$response.Status) -Body $response.Body -Settings $Settings -BridgeState $BridgeState | Out-Null
                }
            } catch [System.IO.IOException] {
                if ($null -ne $stream) {
                    Send-BridgeJson -Client $Client -Status 408 -Body @{ error = "request_timeout" } -Settings $Settings -BridgeState $BridgeState | Out-Null
                }
            } catch {
                Send-BridgeJson -Client $Client -Status 500 -Body @{ error = "internal_error" } -Settings $Settings -BridgeState $BridgeState | Out-Null
            } finally {
                Close-BridgeClient -Client $Client -DrainInput (-not $requestFullyRead)
            }
        }

        $listener = $Settings.Listener
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [int]$Settings.MaxConcurrentClients)
        $pool.Open()
        $active = New-Object System.Collections.ArrayList
        try {
            while (-not [bool]$BridgeState["Stop"]) {
                foreach ($job in @($active.ToArray())) {
                    if ($job.Async.IsCompleted) {
                        try { $job.PowerShell.EndInvoke($job.Async) | Out-Null } catch {
                            $BridgeState["HandlerFailureCount"] = [int]$BridgeState["HandlerFailureCount"] + 1
                        }
                        $job.PowerShell.Dispose()
                        [void]$active.Remove($job)
                    }
                }
                $BridgeState["ActiveClients"] = [int]$active.Count
                if ([int]$active.Count -gt [int]$BridgeState["PeakActiveClients"]) {
                    $BridgeState["PeakActiveClients"] = [int]$active.Count
                }

                if ($listener.Pending()) {
                    $client = $listener.AcceptTcpClient()
                    if ($active.Count -ge [int]$Settings.MaxConcurrentClients) {
                        $BridgeState["RejectedClients"] = [int]$BridgeState["RejectedClients"] + 1
                        Send-BridgeBusy -Client $client -Settings $Settings -BridgeState $BridgeState
                        continue
                    }
                    $powershell = [PowerShell]::Create()
                    $powershell.RunspacePool = $pool
                    $powershell.AddScript($handlerScript.ToString()).AddArgument($client).AddArgument($Settings).AddArgument($RequestQueue).AddArgument($ResponseMap).AddArgument($BridgeState) | Out-Null
                    $async = $powershell.BeginInvoke()
                    [void]$active.Add([PSCustomObject]@{ PowerShell = $powershell; Async = $async; Client = $client })
                    continue
                }
                Start-Sleep -Milliseconds 20
            }
        } finally {
            try { $listener.Stop() } catch { $null = $_ }
            foreach ($job in @($active.ToArray())) {
                try { $job.Client.Close() } catch { $null = $_ }
                try {
                    if (-not $job.Async.AsyncWaitHandle.WaitOne(500)) { $job.PowerShell.Stop() }
                    $job.PowerShell.EndInvoke($job.Async) | Out-Null
                } catch {
                    $BridgeState["HandlerFailureCount"] = [int]$BridgeState["HandlerFailureCount"] + 1
                }
                $job.PowerShell.Dispose()
            }
            $active.Clear()
            $BridgeState["ActiveClients"] = 0
            try { $pool.Close() } catch { $null = $_ }
            $pool.Dispose()
        }
    }
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

function Stop-MonitorSettingsWorker {
    param([switch]$Cancel)
    if ($script:MonitorSettingsWorkerTimer) { $script:MonitorSettingsWorkerTimer.Stop() }
    if ($script:MonitorSettingsWorker) {
        if ($Cancel -and $script:MonitorSettingsWorkerAsyncResult -and -not $script:MonitorSettingsWorkerAsyncResult.IsCompleted) {
            try { $script:MonitorSettingsWorker.Stop() } catch {}
        }
        try { $script:MonitorSettingsWorker.Dispose() } catch {}
    }
    if ($script:MonitorSettingsWorkerInput) { try { $script:MonitorSettingsWorkerInput.Dispose() } catch {} }
    if ($script:MonitorSettingsWorkerOutput) { try { $script:MonitorSettingsWorkerOutput.Dispose() } catch {} }
    $script:MonitorSettingsWorker = $null
    $script:MonitorSettingsWorkerInput = $null
    $script:MonitorSettingsWorkerOutput = $null
    $script:MonitorSettingsWorkerAsyncResult = $null
    $script:MonitorSettingsWorkerIndex = -1
    $script:MonitorSettingsWorkerName = ""
    $script:MonitorSettingsWorkerLastOutputCount = 0
    $script:MonitorSettingsWorkerGeneration = -1
    $script:MonitorSettingsWorkerTotalReads = 0
    $script:MonitorSettingsWorkerTargets = @()
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
    $raw = ConvertTo-VcpRawValue -Percent ([double]$Percent) -Maximum (Get-SelectedMonitorVcpMaximum -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))
    $script:UpdatingUI = $true
    try {
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
    return Set-VCPValueWithSync -VCPCode $VCPCode -Value ([uint32]$percent) -Percent
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
    Update-VcpMaximumCache -Results $results
    $selectedPublished = $false
    foreach ($target in $workerTargets) {
        if (-not (Test-DisplayWorkerResultCurrent -Result $target -CurrentGeneration $script:DisplayRecoveryGeneration -Monitors $script:PhysicalMonitors)) { continue }
        $targetResults = @($results | Where-Object { [string]$_.IdentityKey -eq [string]$target.IdentityKey })
        $successes = @($targetResults | Where-Object { [bool]$_.Success })
        $failures = @($targetResults | Where-Object { -not [bool]$_.Success })
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
    Invoke-DisplayStateRestore -Generation $script:DisplayRecoveryGeneration -Reason "display refresh" | Out-Null
    if (-not $selectedPublished -and $workerName -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        Update-SelectedMonitorRecoveryUi
    }
    Stop-MonitorSettingsWorker
}

function Start-MonitorSettingsWorker {
    param([IntPtr]$Handle, [int]$MonitorIndex, [string]$MonitorName)
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
        $targets += [PSCustomObject]@{
            MonitorIndex = [int]$index
            MonitorName = [string]$monitor.Name
            IdentityKey = [string]$monitor.IdentityKey
            Handle = $monitor.Handle
            HandleValue = [int64]$monitor.Handle.ToInt64()
            Generation = $generation
            Codes = [object[]]$codes
            ReadRetries = Get-DisplayRecoveryReadRetryCount -State $state -DefaultRetries ([int](Get-DdcEffectiveTiming -TimingProfile (Get-DdcTimingProfile -IdentityKey ([string]$monitor.IdentityKey))).ReadRetries)
            DelayMilliseconds = [int](Get-DdcEffectiveTiming -TimingProfile (Get-DdcTimingProfile -IdentityKey ([string]$monitor.IdentityKey))).DelayMilliseconds
            SkipCodes = [object[]]@(@((Get-DdcTimingProfile -IdentityKey ([string]$monitor.IdentityKey)).UnsupportedCodes) | ForEach-Object { [int]$_.Code })
        }
        Set-DisplayRecoveryOutcome -IdentityKey ([string]$monitor.IdentityKey) -Outcome "Retry" -Generation $generation | Out-Null
    }
    if ($targets.Count -eq 0) { return }
    $workerScript = {
        param([object[]]$Targets)
        foreach ($target in $Targets) {
            $index = 0
            foreach ($code in @($target.Codes)) {
                $index++
                $vct = [uint32]0
                $current = [uint32]0
                $maximum = [uint32]0
                $lastError = [int]0
                $attempts = [int]0
                if (@($target.SkipCodes) -contains [int]$code) { continue }
                $ok = [MonitorAPI]::ReadVCPWithRetry($target.Handle, [byte]$code, [int]$target.ReadRetries, [int]$target.DelayMilliseconds, [ref]$vct, [ref]$current, [ref]$maximum, [ref]$lastError, [ref]$attempts)
                [PSCustomObject]@{
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
        }
    }
    $script:MonitorSettingsWorkerIndex = $MonitorIndex
    $script:MonitorSettingsWorkerName = $MonitorName
    $script:MonitorSettingsWorkerGeneration = $generation
    $script:MonitorSettingsWorkerTargets = $targets
    $script:MonitorSettingsWorkerTotalReads = [int](($targets | ForEach-Object { @($_.Codes).Count } | Measure-Object -Sum).Sum)
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

function Set-GammaRamp {
    param([double]$Gamma = 1.0, [double]$RedMult = 1.0, [double]$GreenMult = 1.0, [double]$BlueMult = 1.0)
    $hdc = [MonitorAPI]::GetDC([IntPtr]::Zero)
    if ($hdc -eq [IntPtr]::Zero) { return }
    try {
        $ramp = New-Object MonitorAPI+RAMP
        $ramp.Red = [UInt16[]]::new(256); $ramp.Green = [UInt16[]]::new(256); $ramp.Blue = [UInt16[]]::new(256)
        for ($i = 0; $i -lt 256; $i++) {
            $normalized = $i / 255.0
            $ramp.Red[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $RedMult)))
            $ramp.Green[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $GreenMult)))
            $ramp.Blue[$i] = [Math]::Min(65535, [Math]::Max(0, [int]([Math]::Pow($normalized, 1.0/$Gamma) * 65535 * $BlueMult)))
        }
        [MonitorAPI]::SetDeviceGammaRamp($hdc, [ref]$ramp) | Out-Null
    } finally { [MonitorAPI]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null }
}

function Get-TimeBasedSettings {
    $hour = (Get-Date).Hour
    if ($hour -ge 7 -and $hour -lt 18) { return @{ Mode = "Day"; Brightness = 80; GammaRed = 1.0; GammaGreen = 1.0; GammaBlue = 1.0 } }
    elseif ($hour -ge 18 -and $hour -lt 21) { return @{ Mode = "Evening"; Brightness = 60; GammaRed = 1.0; GammaGreen = 0.95; GammaBlue = 0.85 } }
    else { return @{ Mode = "Night"; Brightness = 40; GammaRed = 1.0; GammaGreen = 0.9; GammaBlue = 0.75 } }
}

function Apply-TimeBasedSettings {
    $settings = Get-TimeBasedSettings
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $settings.Brightness -Force -Percent | Out-Null
    Set-GammaRamp -Gamma 1.0 -RedMult $settings.GammaRed -GreenMult $settings.GammaGreen -BlueMult $settings.GammaBlue
    return $settings
}

function Initialize-WmiBrightness {
    try {
        $script:WmiBrightnessAvailable = @(
            Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop
        ).Count -gt 0
    } catch {
        $script:WmiBrightnessAvailable = $false
    }
}

function Get-WmiBrightness {
    try {
        $level = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
        if ($level -and $null -ne $level.CurrentBrightness) { return [int]$level.CurrentBrightness }
    } catch {}
    return $null
}

function Set-WmiBrightness {
    param([int]$Value)
    if (-not $script:WmiBrightnessAvailable) { return $false }
    $brightness = [Math]::Max(0, [Math]::Min(100, $Value))
    try {
        $methods = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
        foreach ($method in $methods) {
            Invoke-CimMethod -InputObject $method -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = $brightness } -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        Update-Status "WMI brightness failed: $_"
        return $false
    }
}

function Initialize-AmbientLightSensor {
    if ($script:AmbientLightSensor) { return $true }
    try {
        [void][Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
        $sensor = [Windows.Devices.Sensors.LightSensor]::GetDefault()
        if ($sensor) {
            $script:AmbientLightSensor = $sensor
            return $true
        }
    } catch {}
    return $false
}

function Get-AmbientLux {
    if (-not (Initialize-AmbientLightSensor)) { return $null }
    try {
        $reading = $script:AmbientLightSensor.GetCurrentReading()
        if ($reading -and $null -ne $reading.IlluminanceInLux) { return [double]$reading.IlluminanceInLux }
    } catch {}
    return $null
}

function Get-BrightnessForAmbientLux {
    param([double]$Lux)
    if ($Lux -lt 20) { return 25 }
    if ($Lux -lt 100) { return 40 }
    if ($Lux -lt 300) { return 55 }
    if ($Lux -lt 800) { return 70 }
    return 85
}

function Apply-AmbientLightSettings {
    $lux = Get-AmbientLux
    if ($null -eq $lux) {
        $autoModeText.Text = "Ambient unavailable"
        Update-Status "Ambient light sensor unavailable"
        return
    }
    $brightness = Get-BrightnessForAmbientLux -Lux $lux
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $brightness -Force -Percent
    Set-BrightnessSliderFromPercent -Percent $brightness | Out-Null
    $autoModeText.Text = "Ambient: $([math]::Round($lux, 0)) lx"
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
    Apply-AmbientLightSettings
}

function Initialize-GPU {
    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        if ($gpu.Name -match "NVIDIA") {
            $script:HasNvidia = $true
            @("${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "${env:SystemRoot}\System32\nvidia-smi.exe") | ForEach-Object { if (Test-Path $_) { $script:NvidiaSmiPath = $_; return } }
        }
        if ($gpu.Name -match "AMD|Radeon") {
            $script:HasAmd = $true
        }
    }
}

function Get-NvidiaStats {
    if (-not $script:NvidiaSmiPath) { return $null }
    try {
        $output = & $script:NvidiaSmiPath --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed,power.draw,power.limit,clocks.gr --format=csv,noheader,nounits 2>$null
        if ($output) {
            $p = $output.Split(',').Trim()
            if ($p.Count -ge 9) {
                return @{ Name = $p[0]; Temp = [int]$p[1]; Util = [int]$p[2]; MemUsed = [math]::Round([double]$p[3]/1024, 1)
                    MemTotal = [math]::Round([double]$p[4]/1024, 1); Fan = if ($p[5] -match '\d+') { [int]$p[5] } else { 0 }
                    Power = [math]::Round([double]$p[6], 0); PowerLimit = [math]::Round([double]$p[7], 0); Clock = [int]$p[8] }
            }
        }
    } catch {}
    return $null
}

function Get-AmdStats {
    $name = ""; $temp = 0; $util = 0; $engineClock = 0; $memoryClock = 0; $fan = 0; $message = ""
    if ([AmdAdlInterop]::TryGetStats([ref]$name, [ref]$temp, [ref]$util, [ref]$engineClock, [ref]$memoryClock, [ref]$fan, [ref]$message)) {
        return @{
            Name = $name; Temp = $temp; Util = $util; MemUsed = 0; MemTotal = 0; Fan = $fan
            Power = 0; PowerLimit = 0; Clock = $engineClock; MemoryClock = $memoryClock; Message = ""
        }
    }
    return @{ Name = "AMD Radeon"; Temp = 0; Util = 0; MemUsed = 0; MemTotal = 0; Fan = 0; Power = 0; PowerLimit = 0; Clock = 0; MemoryClock = 0; Message = $message }
}

function ConvertTo-HelperVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $parts = @()
    for ($group = 1; $group -le 4; $group++) {
        if (-not $match.Groups[$group].Success) { break }
        $parts += [int]$match.Groups[$group].Value
    }
    while ($parts.Count -lt 2) { $parts += 0 }
    try { return [version]($parts -join ".") } catch { return $null }
}

function Get-OptionalHelperSourceCategory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "Unknown" }
    $full = try { [System.IO.Path]::GetFullPath($Path) } catch { return "Unknown" }
    $roots = @(
        @{ Category = "ScriptDirectory"; Root = $PSScriptRoot },
        @{ Category = "ProgramFiles"; Root = $env:ProgramFiles },
        @{ Category = "ProgramFiles"; Root = ${env:ProgramFiles(x86)} }
    )
    foreach ($candidate in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Root)) { continue }
        $root = try { [System.IO.Path]::GetFullPath([string]$candidate.Root).TrimEnd("\") + "\" } catch { continue }
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$candidate.Category }
    }
    foreach ($entry in @(([string]$env:PATH) -split ";")) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $root = try { [System.IO.Path]::GetFullPath($entry.Trim()).TrimEnd("\") + "\" } catch { continue }
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return "SystemPath" }
    }
    return "Other"
}

function Test-OptionalHelperVersionSupported {
    param([string]$Kind, $Version)
    if (-not $script:OptionalHelperMinimumVersions.ContainsKey($Kind)) { return $false }
    if ($null -eq $Version) { return $false }
    return ([version]$Version -ge [version]$script:OptionalHelperMinimumVersions[$Kind])
}

function Get-OptionalHelperProvenance {
    param([string]$Path, [string]$Kind)
    $record = [PSCustomObject]@{
        Kind = [string]$Kind
        Path = [string]$Path
        Exists = $false
        SourceCategory = "Unknown"
        ProductVersion = ""
        FileVersion = ""
        Version = $null
        Sha256 = ""
        Supported = $false
        Reason = ""
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $record.Reason = "No path supplied"
        return $record
    }
    try { $record.Path = [System.IO.Path]::GetFullPath($Path) } catch {
        $record.Reason = "Path could not be resolved"
        return $record
    }
    if (-not (Test-Path -LiteralPath $record.Path -PathType Leaf)) {
        $record.Reason = "File not found"
        return $record
    }
    $record.Exists = $true
    $record.SourceCategory = Get-OptionalHelperSourceCategory -Path $record.Path
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($record.Path)
        $record.ProductVersion = [string]$info.ProductVersion
        $record.FileVersion = [string]$info.FileVersion
    } catch {}
    $record.Version = ConvertTo-HelperVersion -Text $record.FileVersion
    if ($null -eq $record.Version) { $record.Version = ConvertTo-HelperVersion -Text $record.ProductVersion }
    try { $record.Sha256 = Get-FileSha256Hex -Path $record.Path } catch { $record.Sha256 = "" }
    if ($null -eq $record.Version) {
        $record.Reason = "No readable version resource; refusing to load"
        return $record
    }
    if (-not (Test-OptionalHelperVersionSupported -Kind $Kind -Version $record.Version)) {
        $record.Reason = "Version $($record.Version) is below the supported minimum $($script:OptionalHelperMinimumVersions[$Kind])"
        return $record
    }
    $record.Supported = $true
    $record.Reason = "Supported"
    return $record
}

function Format-OptionalHelperProvenance {
    param([string]$Label, $Provenance, [bool]$Enabled)
    if (-not $Enabled) { return "${Label}: disabled" }
    if ($null -eq $Provenance) { return "${Label}: enabled, no helper resolved" }
    if (-not $Provenance.Exists) { return "${Label}: enabled, not found ($($Provenance.Reason))" }
    $fileVersion = if ($Provenance.FileVersion) { $Provenance.FileVersion } else { "unknown" }
    $productVersion = if ($Provenance.ProductVersion) { $Provenance.ProductVersion } else { "unknown" }
    $hash = if ($Provenance.Sha256) { $Provenance.Sha256 } else { "unavailable" }
    $lines = @(
        "${Label}: $($Provenance.Reason)",
        "  Path: $($Provenance.Path)",
        "  Source: $($Provenance.SourceCategory)",
        "  Version: $fileVersion (product $productVersion)",
        "  SHA-256: $hash"
    )
    return ($lines -join "`n")
}

function Get-OptionalHelperStatusText {
    return (@(
        (Format-OptionalHelperProvenance -Label "CPU temperature library" -Provenance $script:CpuMonitorProvenance -Enabled $script:CpuMonitorEnabled),
        (Format-OptionalHelperProvenance -Label "PresentMon" -Provenance $script:PresentMonProvenance -Enabled $script:PresentMonEnabled)
    ) -join "`n`n")
}

function Get-DisplayStateRestoreSettingsObject {
    $records = @()
    foreach ($key in @($script:DisplayStateRestoreValues.Keys)) {
        $entry = $script:DisplayStateRestoreValues[$key]
        if ($null -eq $entry) { continue }
        $records += [PSCustomObject]@{
            IdentityKey = [string]$key
            Brightness = [int]$entry.Brightness
            UpdatedAt = [string]$entry.UpdatedAt
        }
    }
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:DisplayStateRestoreSchemaVersion
        Enabled = [bool]$script:DisplayStateRestoreEnabled
        Monitors = @($records)
    }
}

function Save-DisplayStateRestoreSettings {
    return (Write-JsonFileSafely -Path $script:DisplayStateRestoreSettingsPath -Data (Get-DisplayStateRestoreSettingsObject) -Depth 5)
}

function Import-DisplayStateRestoreSettings {
    $script:DisplayStateRestoreEnabled = $false
    $script:DisplayStateRestoreValues = @{}
    if (-not (Test-Path -LiteralPath $script:DisplayStateRestoreSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:DisplayStateRestoreSettingsPath -Label "Display restore settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:DisplayStateRestoreSchemaVersion) {
        Update-Status "Display restore settings use schema v$schema; restore stays disabled"
        return
    }
    if ($data.PSObject.Properties.Name -contains "Enabled") { $script:DisplayStateRestoreEnabled = [bool]$data.Enabled }
    foreach ($record in @((Get-ProfilePropertyValue -Object $data -Property "Monitors" -Default @()))) {
        if ($null -eq $record) { continue }
        $identityKey = [string](Get-ProfilePropertyValue -Object $record -Property "IdentityKey" -Default "")
        if ([string]::IsNullOrWhiteSpace($identityKey)) { continue }
        $brightness = Get-ProfilePercentValue -Object $record -Property "Brightness" -Default -1
        if ($brightness -lt 0) { continue }
        $script:DisplayStateRestoreValues[$identityKey] = [PSCustomObject]@{
            Brightness = [int]$brightness
            UpdatedAt = [string](Get-ProfilePropertyValue -Object $record -Property "UpdatedAt" -Default "")
        }
    }
}

function Set-DisplayStateRestoreValue {
    param([string]$IdentityKey, [int]$BrightnessPercent, [string]$UpdatedAt = "")
    if ([string]::IsNullOrWhiteSpace($IdentityKey)) { return $false }
    if ($BrightnessPercent -lt 0 -or $BrightnessPercent -gt 100) { return $false }
    if ([string]::IsNullOrWhiteSpace($UpdatedAt)) { $UpdatedAt = (Get-Date).ToString("o") }
    $script:DisplayStateRestoreValues[$IdentityKey] = [PSCustomObject]@{
        Brightness = [int]$BrightnessPercent
        UpdatedAt = [string]$UpdatedAt
    }
    return $true
}

function Get-DisplayStateRestorePlan {
    param([object[]]$Monitors, [hashtable]$Remembered, [bool]$Enabled)
    $plan = [PSCustomObject]@{ Operations = @(); Skipped = @() }
    if (-not $Enabled) { return $plan }
    $operations = @()
    $skipped = @()
    foreach ($monitor in @($Monitors)) {
        if ($null -eq $monitor) { continue }
        $identityKey = [string]$monitor.IdentityKey
        $label = if ($monitor.PSObject.Properties["DisplayLabel"] -and $monitor.DisplayLabel) { [string]$monitor.DisplayLabel } else { [string]$monitor.Name }
        if ([string]::IsNullOrWhiteSpace($identityKey)) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "no stable identity" }
            continue
        }
        if (-not $Remembered.ContainsKey($identityKey)) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "nothing remembered" }
            continue
        }
        if ([int64]$monitor.Handle.ToInt64() -eq 0) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "no DDC/CI handle" }
            continue
        }
        $percent = [int]$Remembered[$identityKey].Brightness
        if (-not (Test-MonitorSupportsVcp -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS))) {
            $skipped += [PSCustomObject]@{ Monitor = $label; Reason = "brightness not reported" }
            continue
        }
        $raw = [uint32](ConvertTo-VcpRawValue -Percent ([double]$percent) -Maximum (Get-VcpMaximumForMonitor -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)))
        $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([int][MonitorAPI]::VCP_BRIGHTNESS) -Value $raw
    }
    $plan.Operations = @($operations)
    $plan.Skipped = @($skipped)
    return $plan
}

function Invoke-DisplayStateRestore {
    param([int]$Generation = $script:DisplayRecoveryGeneration, [string]$Reason = "startup")
    if (-not $script:DisplayStateRestoreEnabled) { return $false }
    # One restore per recovery generation, so a burst of display events cannot replay writes.
    if ($script:DisplayStateRestoreGeneration -eq $Generation) { return $false }
    $script:DisplayStateRestoreGeneration = $Generation
    $plan = Get-DisplayStateRestorePlan -Monitors @($script:PhysicalMonitors) -Remembered $script:DisplayStateRestoreValues -Enabled $true
    if (@($plan.Operations).Count -eq 0) { return $false }
    $result = Invoke-VerifiedVcpTransaction -Operations @($plan.Operations) -RollbackOnFailure
    $applied = @($plan.Operations).Count
    if ([bool]$result.Success) {
        Update-Status "Restored brightness on $applied display(s) after $Reason"
    } else {
        Update-Status "Brightness restore after $Reason ended $($result.Outcome); restore: $($result.Rollback)"
    }
    return [bool]$result.Success
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

function Get-OptionalHelperSettingsObject {
    return [PSCustomObject]@{
        SchemaVersion = [int]$script:OptionalHelperSchemaVersion
        CpuMonitorEnabled = [bool]$script:CpuMonitorEnabled
        PresentMonEnabled = [bool]$script:PresentMonEnabled
    }
}

function Save-OptionalHelperSettings {
    return (Write-JsonFileSafely -Path $script:OptionalHelperSettingsPath -Data (Get-OptionalHelperSettingsObject) -Depth 4)
}

function Import-OptionalHelperSettings {
    $script:CpuMonitorEnabled = $false
    $script:PresentMonEnabled = $false
    if (-not (Test-Path -LiteralPath $script:OptionalHelperSettingsPath)) { return }
    $data = Read-JsonFileSafely -Path $script:OptionalHelperSettingsPath -Label "Optional helper settings"
    if ($null -eq $data) { return }
    $schema = if ($data.PSObject.Properties.Name -contains "SchemaVersion") { [int]$data.SchemaVersion } else { 1 }
    if ($schema -gt $script:OptionalHelperSchemaVersion) {
        Update-Status "Optional helper settings use schema v$schema; helpers stay disabled"
        return
    }
    if ($data.PSObject.Properties.Name -contains "CpuMonitorEnabled") { $script:CpuMonitorEnabled = [bool]$data.CpuMonitorEnabled }
    if ($data.PSObject.Properties.Name -contains "PresentMonEnabled") { $script:PresentMonEnabled = [bool]$data.PresentMonEnabled }
}

function Get-CpuMonitorCandidatePaths {
    return @(
        (Join-Path $PSScriptRoot "LibreHardwareMonitorLib.dll"),
        (Join-Path $PSScriptRoot "OpenHardwareMonitorLib.dll"),
        "${env:ProgramFiles}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll"
    )
}

function Get-PresentMonCandidatePaths {
    # Well-known install locations are probed before PATH: a PATH-resolved executable is the
    # easiest thing for another process to place ahead of the real one.
    $paths = @(
        (Join-Path $PSScriptRoot "PresentMon.exe"),
        (Join-Path $PSScriptRoot "PresentMon64.exe"),
        "${env:ProgramFiles}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles}\Intel\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\Intel\PresentMon\PresentMon.exe"
    )
    foreach ($command in @(Get-Command PresentMon.exe, PresentMon64.exe -ErrorAction SilentlyContinue)) {
        if ($command -and $command.Source) { $paths += [string]$command.Source }
    }
    return $paths
}

function Stop-CpuMonitor {
    if ($script:HardwareMonitorComputer) {
        try { $script:HardwareMonitorComputer.Close() } catch {}
    }
    $script:HardwareMonitorComputer = $null
    $script:HasCpuTempMonitor = $false
    $script:HardwareMonitorKind = ""
    $script:CpuMonitorProvenance = $null
}

function Initialize-CpuMonitor {
    if (-not $script:CpuMonitorEnabled) { return }
    if ($script:HardwareMonitorComputer) { return }
    $rejected = $null
    foreach ($candidate in (Get-CpuMonitorCandidatePaths)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $provenance = Get-OptionalHelperProvenance -Path $candidate -Kind "CpuMonitor"
        if (-not $provenance.Supported) {
            if ($null -eq $rejected) { $rejected = $provenance }
            continue
        }
        $path = $provenance.Path
        try {
            [System.Reflection.Assembly]::LoadFrom($path) | Out-Null
            $computerType = if ($path -like "*LibreHardwareMonitor*") {
                [Type]::GetType("LibreHardwareMonitor.Hardware.Computer, LibreHardwareMonitorLib", $false)
            } else {
                [Type]::GetType("OpenHardwareMonitor.Hardware.Computer, OpenHardwareMonitorLib", $false)
            }
            if (-not $computerType) { continue }
            $computer = [Activator]::CreateInstance($computerType)
            $computer.IsCpuEnabled = $true
            $computer.Open()
            $script:HardwareMonitorComputer = $computer
            $script:HardwareMonitorKind = if ($path -like "*LibreHardwareMonitor*") { "LibreHardwareMonitor" } else { "OpenHardwareMonitor" }
            $script:HasCpuTempMonitor = $true
            $script:CpuMonitorProvenance = $provenance
            return
        } catch {}
    }
    $script:CpuMonitorProvenance = $rejected
}

function Get-CpuTemperature {
    if (-not $script:HardwareMonitorComputer) { return $null }
    try {
        $temperatures = @()
        foreach ($hardware in $script:HardwareMonitorComputer.Hardware) {
            if ($hardware.HardwareType.ToString() -ne "Cpu") { continue }
            $hardware.Update()
            foreach ($subHardware in $hardware.SubHardware) { $subHardware.Update() }
            foreach ($sensor in @($hardware.Sensors) + @($hardware.SubHardware | ForEach-Object { $_.Sensors })) {
                if ($sensor -and $sensor.SensorType.ToString() -eq "Temperature" -and $null -ne $sensor.Value) {
                    $temperatures += [double]$sensor.Value
                }
            }
        }
        if ($temperatures.Count -gt 0) { return [math]::Round(($temperatures | Measure-Object -Maximum).Maximum, 0) }
    } catch {}
    return $null
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
        Title="MonitorControl Pro v3.36.0" Width="1120" Height="760" MinWidth="920" MinHeight="640"
        Background="{DynamicResource CanvasBrush}" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
<Window.Resources>
    <GridLength x:Key="SidebarWidth">260</GridLength>
    <SolidColorBrush x:Key="CanvasBrush" Color="#08111d"/>
    <SolidColorBrush x:Key="SidebarBrush" Color="#0a1422"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#0b1625"/>
    <SolidColorBrush x:Key="FooterBrush" Color="#091320"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#101b2b"/>
    <SolidColorBrush x:Key="CardBrush" Color="#142235"/>
    <SolidColorBrush x:Key="CardHoverBrush" Color="#192b42"/>
    <SolidColorBrush x:Key="ControlBrush" Color="#0d1928"/>
    <SolidColorBrush x:Key="TrackBrush" Color="#526985"/>
    <SolidColorBrush x:Key="BorderBrush" Color="#5f7794"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#2f6fcf"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#2864c7"/>
    <SolidColorBrush x:Key="AccentPressedBrush" Color="#1f5bb8"/>
    <SolidColorBrush x:Key="FocusBrush" Color="#75a9ff"/>
    <SolidColorBrush x:Key="TextBrush" Color="#e8eef7"/>
    <SolidColorBrush x:Key="MutedTextBrush" Color="#9aabc0"/>
    <SolidColorBrush x:Key="OnAccentBrush" Color="#ffffff"/>
    <SolidColorBrush x:Key="SuccessBrush" Color="#62d891"/>
    <SolidColorBrush x:Key="WarningBrush" Color="#ffd18a"/>
    <SolidColorBrush x:Key="WarningSurfaceBrush" Color="#3a2f1e"/>
    <SolidColorBrush x:Key="DangerBrush" Color="#f46969"/>
    <SolidColorBrush x:Key="DangerSurfaceBrush" Color="#40212a"/>
    <Style TargetType="TextBlock">
        <Setter Property="FontFamily" Value="Segoe UI"/>
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
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,8"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="12"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
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
                <Border Grid.Column="0" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,1,0" Padding="14,18">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
                        <StackPanel IsItemsHost="True" KeyboardNavigation.TabIndex="1"/>
                    </ScrollViewer>
                </Border>
                <Border Grid.Column="1" Background="{DynamicResource CanvasBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,0,0" Padding="24,20,24,16">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <TextBlock Text="{Binding SelectedItem.Header, RelativeSource={RelativeSource TemplatedParent}}" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}"/>
                        <ScrollViewer Grid.Row="2" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"
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
        <Setter Property="Foreground" Value="{DynamicResource MutedTextBrush}"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/>
        <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="18,13"/><Setter Property="Margin" Value="0,0,0,6"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="9">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="Indicator" Width="3" Height="22" CornerRadius="2" Background="{DynamicResource AccentBrush}" HorizontalAlignment="Left" Margin="-18,0,0,0" Visibility="Collapsed"/>
                    <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
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
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,6"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/><Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
    </Style>
    <Style TargetType="PasswordBox">
        <Setter Property="Background" Value="{DynamicResource ControlBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,6"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/><Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
        <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusVisual}"/>
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
</Window.Resources>
<ScrollViewer x:Name="ShellScrollViewer" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Disabled"
              HorizontalContentAlignment="Stretch" VerticalContentAlignment="Stretch" Focusable="False">
<Grid x:Name="ShellRoot" Background="{DynamicResource CanvasBrush}" MinWidth="880" MinHeight="600">
    <Grid.LayoutTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.LayoutTransform>
    <Grid.RowDefinitions><RowDefinition Height="Auto" MinHeight="74"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="32"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="{StaticResource SidebarWidth}"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Row="0" Grid.Column="0" Background="{DynamicResource SidebarBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,0,1,0" Padding="18,0">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="30" Height="30" CornerRadius="8" Background="{DynamicResource AccentBrush}" VerticalAlignment="Center">
                <TextBlock Text="MC" Foreground="{DynamicResource OnAccentBrush}" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0,0,0">
                <TextBlock x:Name="AppTitleText" Text="MonitorControl Pro" FontSize="12.5" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}" TextWrapping="Wrap"/>
                <TextBlock x:Name="AppSubtitleText" Text="Version 3.36.0" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
        </Grid>
    </Border>
    <Border Grid.Row="0" Grid.Column="1" Background="{DynamicResource HeaderBrush}" Padding="24,8">
        <WrapPanel VerticalAlignment="Center">
            <StackPanel Width="380" VerticalAlignment="Center" Margin="0,0,16,0">
                <TextBlock x:Name="SelectedMonitorName" Text="No monitor selected" FontSize="14" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
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
    <TabControl Grid.Row="2" Grid.ColumnSpan="2" TabStripPlacement="Left">
        <TabItem x:Name="DisplayTab" Header="Display" Tag="&#xE7F4;">
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
        <TabItem x:Name="MonitorTab" Header="Monitor" Tag="&#xE7F8;">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Label" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <TextBox x:Name="MonitorLabelBox" Grid.Column="2" VerticalAlignment="Center"/>
                        <Button x:Name="MonitorLabelSaveBtn" Grid.Column="4" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                        <Button x:Name="MonitorLabelResetBtn" Grid.Column="6" Content="Reset" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                    <TextBlock x:Name="MonitorIdentityText" Grid.Row="2" Text="Identity: unknown" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" TextTrimming="CharacterEllipsis"/>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Input source" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" Margin="0,0,0,8"/>
                        <ComboBox x:Name="InputSourceCombo"/></StackPanel></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Power control" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" Margin="0,0,0,8"/>
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="PowerOffBtn" Content="Off" Style="{StaticResource WarnBtn}" Padding="4,4" FontSize="12"/>
                            <Button x:Name="PowerStandbyBtn" Grid.Column="2" Content="Standby" Style="{StaticResource Btn}" Padding="4,4" FontSize="12"/>
                            <Button x:Name="PowerOnBtn" Grid.Column="4" Content="On" Style="{StaticResource GreenBtn}" Padding="4,4" FontSize="12"/>
                        </Grid></StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><StackPanel Orientation="Horizontal"><TextBlock Text="Volume" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><CheckBox x:Name="MuteCheckbox" Content="Mute" Margin="8,0,0,0" VerticalAlignment="Center" FontSize="12"/></StackPanel>
                            <TextBlock x:Name="VolumeValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VolumeSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Sharpness" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="SharpnessValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="SharpnessSlider" Grid.Row="2" Value="50" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="ResetColorBtn" Content="Reset Colors" Style="{StaticResource Btn}"/>
                    <Button x:Name="FactoryResetBtn" Grid.Column="2" Content="Factory Reset" Style="{StaticResource WarnBtn}"/>
                </Grid></Border>
                <Button x:Name="AllMonitorsStandbyBtn" Grid.Row="8" Content="All Monitors to Standby" Style="{StaticResource Btn}"/>
                <Border Grid.Row="10" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="PiP / PbP Mode" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <Button x:Name="PipPbpOffBtn" Grid.Column="2" Content="Off" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                        <Button x:Name="PipModeBtn" Grid.Column="4" Content="PiP" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                        <Button x:Name="PbpModeBtn" Grid.Column="6" Content="PbP" Style="{StaticResource AccBtn}" Padding="8,4" FontSize="12"/>
                    </Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Secondary Input" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <Button x:Name="PipSecondaryDpBtn" Grid.Column="2" Content="DP" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                        <Button x:Name="PipSecondaryHdmi1Btn" Grid.Column="4" Content="HDMI 1" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                        <Button x:Name="PipSecondaryHdmi2Btn" Grid.Column="6" Content="HDMI 2" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                    </Grid>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="GpuTab" Header="Hardware" Tag="&#xEA86;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="16"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock x:Name="GpuNameText" Text="GPU" FontSize="14" Foreground="{DynamicResource SuccessBrush}" FontWeight="SemiBold"/>
                        <TextBlock x:Name="GpuStatsText" Text="-- C | -- MHz | -- W" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/>
                        <TextBlock x:Name="CpuTempText" Text="CPU: -- C" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock x:Name="GpuTempText" Text="--" FontSize="20" Foreground="{DynamicResource OnAccentBrush}" FontWeight="Light"/>
                        <TextBlock Text=" C" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Top" Margin="0,3,0,0"/></StackPanel>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="GPU Utilization" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="GpuUtilText" Text="0%" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="GpuUtilBar" Value="0" Foreground="{DynamicResource SuccessBrush}"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Memory Usage" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="MemUsageText" Text="0 / 0 GB" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="MemUtilBar" Value="0" Foreground="{DynamicResource WarningBrush}"/>
                    </StackPanel></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="Fan Speed" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="FanSpeedText" Text="0%" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="FanSpeedBar" Value="0" Foreground="{DynamicResource FocusBrush}"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Power Draw" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="PowerDrawText" Text="0 / 0 W" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="PowerDrawBar" Value="0" Foreground="{DynamicResource DangerBrush}"/>
                    </StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Digital Vibrance" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="VibranceValue" Text="50" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VibranceSlider" Grid.Row="2" Value="50" Tag="{DynamicResource SuccessBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Software Gamma" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/><TextBlock x:Name="GammaValue" Text="1.00" FontSize="12" Foreground="{DynamicResource OnAccentBrush}" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GammaSlider" Grid.Row="2" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="FPS Overlay" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <TextBlock x:Name="FpsOverlayStatusText" Text="PresentMon idle" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0"/></StackPanel>
                    <Button x:Name="FpsOverlayStartBtn" Grid.Column="2" Content="Start" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                    <Button x:Name="FpsOverlayStopBtn" Grid.Column="4" Content="Stop" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="VcpTab" Header="VCP Explorer" Tag="&#xE943;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="60"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="VCP Code:" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                    <TextBox x:Name="VCPCodeBox" Grid.Column="2" Text="0x10" VerticalAlignment="Center"/>
                    <ComboBox x:Name="VCPPresetCombo" Grid.Column="4"/>
                    <Button x:Name="VCPQueryBtn" Grid.Column="6" Content="Query" Style="{StaticResource AccBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="VCP response" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                    <TextBox x:Name="VCPResultBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Set Value:" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                    <TextBox x:Name="VCPSetValueBox" Grid.Column="2" Text="50" VerticalAlignment="Center"/>
                    <Button x:Name="VCPSetBtn" Grid.Column="4" Content="Set" Style="{StaticResource GreenBtn}" Padding="10,4"/>
                    <Button x:Name="VCPScanBtn" Grid.Column="6" Content="Scan All" Style="{StaticResource Btn}" Padding="10,4"/>
                    <CheckBox x:Name="VCPScanCapabilitiesOnlyCheckbox" Grid.Column="8" Content="Caps only" IsChecked="True" VerticalAlignment="Center"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="ProfilesTab" Header="Profiles" Tag="&#xE8B7;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ProfileNameBox" Text="My Profile"/>
                    <Button x:Name="SaveProfileBtn" Grid.Column="2" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Saved profiles" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                    <ListBox x:Name="ProfilesList" Grid.Row="2" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource TextBrush}"/>
                </Grid></Border>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="LoadProfileBtn" Content="Load" Style="{StaticResource AccBtn}"/>
                    <Button x:Name="DeleteProfileBtn" Grid.Column="2" Content="Delete" Style="{StaticResource WarnBtn}"/>
                </Grid>
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="ExportProfilesBtn" Content="Export Bundle" Style="{StaticResource Btn}"/>
                    <Button x:Name="ImportProfilesBtn" Grid.Column="2" Content="Import Bundle" Style="{StaticResource Btn}"/>
                </Grid>
                <Border Grid.Row="8" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Profile Storage" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <TextBlock x:Name="ProfileStorageStatusText" Text="Local" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                    <Button x:Name="ProfileSyncFolderBtn" Grid.Column="2" Content="Sync Folder" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                    <Button x:Name="ProfileLocalFolderBtn" Grid.Column="4" Content="Use Local" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AppProfileEnabledCheckbox" Content="Per-application profiles" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AppProfileStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AppProfileExeBox" Text="app.exe"/>
                        <Button x:Name="AppProfileCaptureBtn" Grid.Column="2" Content="Capture" Style="{StaticResource Btn}" Padding="8,4" FontSize="12"/>
                    </Grid>
                    <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <ComboBox x:Name="AppProfileProfileCombo"/>
                        <CheckBox x:Name="AppProfileRiskyConsentCheckbox" Grid.Column="2" Content="Risky writes" VerticalAlignment="Center" FontSize="12" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                        <Button x:Name="AppProfileAddBtn" Grid.Column="4" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                        <Button x:Name="AppProfileRemoveBtn" Grid.Column="6" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                    <ListBox x:Name="AppProfileRulesList" Grid.Row="6" Height="76" Background="{DynamicResource ControlBrush}" BorderThickness="0" Foreground="{DynamicResource TextBrush}" FontSize="12"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="ScheduleTab" Header="Automation" Tag="&#xE823;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <CheckBox x:Name="ScheduleEnabledCheckbox" Content="Scheduled profiles" VerticalAlignment="Center"/>
                    <TextBlock x:Name="ScheduleStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="76"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ScheduleTimeBox" Text="21:00" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ScheduleProfileCombo" Grid.Column="2"/>
                    <CheckBox x:Name="ScheduleRiskyConsentCheckbox" Grid.Column="4" Content="Risky writes" VerticalAlignment="Center" FontSize="12" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                    <Button x:Name="ScheduleAddBtn" Grid.Column="6" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                    <Button x:Name="ScheduleRemoveBtn" Grid.Column="8" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Profile schedule" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                    <Border Grid.Row="2" Background="{DynamicResource ControlBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Height="56">
                        <Canvas x:Name="ScheduleTimelineCanvas" ClipToBounds="True"/>
                    </Border>
                    <ListBox x:Name="ScheduleRulesList" Grid.Row="4" Background="{DynamicResource ControlBrush}" BorderThickness="0" Foreground="{DynamicResource TextBrush}" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="6" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="IdleDimEnabledCheckbox" Content="Idle dim" VerticalAlignment="Center"/>
                        <TextBlock x:Name="IdleDimStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="IdleDimMinutesBox" Text="10" VerticalAlignment="Center"/>
                        <TextBox x:Name="IdleDimBrightnessBox" Grid.Column="2" Text="20" VerticalAlignment="Center"/>
                        <CheckBox x:Name="IdleDimRestoreCheckbox" Grid.Column="4" Content="Restore" VerticalAlignment="Center"/>
                        <Button x:Name="IdleDimSaveBtn" Grid.Column="6" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="8" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="BatteryProfileEnabledCheckbox" Content="Battery profile" VerticalAlignment="Center"/>
                        <TextBlock x:Name="BatteryProfileStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="BatteryBrightnessBox" Text="35" VerticalAlignment="Center"/>
                        <TextBox x:Name="AcBrightnessBox" Grid.Column="2" Text="75" VerticalAlignment="Center"/>
                        <Button x:Name="BatteryProfileSaveBtn" Grid.Column="4" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="SystemTab" Header="System" Tag="&#xE713;">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Quick links" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Button x:Name="DisplaySettingsBtn" Content="Display" Style="{StaticResource Btn}" Padding="5,4" FontSize="12"/>
                        <Button x:Name="ColorMgmtBtn" Grid.Column="2" Content="Color Mgmt" Style="{StaticResource Btn}" Padding="5,4" FontSize="12"/>
                        <Button x:Name="GpuControlPanelBtn" Grid.Column="4" Content="GPU Panel" Style="{StaticResource Btn}" Padding="5,4" FontSize="12"/>
                    </Grid></StackPanel></Border>
                <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><TextBlock Text="Software Gamma R/G/B" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"/>
                        <Button x:Name="ResetGammaBtn" Content="Reset" Style="{StaticResource Btn}" Padding="8,2" FontSize="12" HorizontalAlignment="Right"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <StackPanel><TextBlock x:Name="GammaRedValue" Text="1.00" FontSize="12" Foreground="{DynamicResource DangerBrush}" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaRedSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource DangerBrush}" Style="{StaticResource Sld}"/></StackPanel>
                        <StackPanel Grid.Column="2"><TextBlock x:Name="GammaGreenValue" Text="1.00" FontSize="12" Foreground="{DynamicResource SuccessBrush}" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaGreenSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource SuccessBrush}" Style="{StaticResource Sld}"/></StackPanel>
                        <StackPanel Grid.Column="4"><TextBlock x:Name="GammaBlueValue" Text="1.00" FontSize="12" Foreground="{DynamicResource FocusBrush}" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaBlueSlider" Value="100" Minimum="50" Maximum="150" Tag="{DynamicResource FocusBrush}" Style="{StaticResource Sld}"/></StackPanel>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="4" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Monitor capabilities" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <TextBox x:Name="CapabilitiesBox" IsReadOnly="True" TextWrapping="Wrap" Height="70" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12"/>
                </StackPanel></Border>
                <Border Grid.Row="6" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="CapabilitiesDiscoveryEnabledCheckbox" Content="Allow capability discovery" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CapabilitiesSafetyStatusText" Text="Discovery off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <CheckBox x:Name="CapabilitiesMaximumCompatibilityCheckbox" Grid.Row="2" Content="Maximum compatibility (never request capability strings)" Foreground="{DynamicResource MutedTextBrush}"/>
                    <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="A pending probe is recorded before every firmware call." Foreground="{DynamicResource MutedTextBrush}" FontSize="12" VerticalAlignment="Center"/>
                        <Button x:Name="CapabilitiesExcludeCurrentBtn" Grid.Column="2" Content="Exclude selected" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                        <Button x:Name="CapabilitiesClearExclusionsBtn" Grid.Column="4" Content="Clear exclusions" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                        <Button x:Name="CapabilitiesClearCacheBtn" Grid.Column="6" Content="Clear cache" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="8" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource WarningBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="RiskyVcpEnabledCheckbox" Content="Enable risky VCP writes for selected display" VerticalAlignment="Center"/>
                        <TextBlock x:Name="RiskyVcpStatusText" Text="Disabled" FontSize="12" Foreground="{DynamicResource WarningBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <TextBlock Grid.Row="2" Text="Power, input, reset, PiP/PbP, and arbitrary writes require this per-identity unlock plus confirmation for every direct command." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AutomationBridgeEnabledCheckbox" Content="Local Automation Bridge" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AutomationBridgeStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="64"/><ColumnDefinition Width="6"/><ColumnDefinition Width="74"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AutomationBridgeBindBox" Text="127.0.0.1" VerticalAlignment="Center" FontSize="12"/>
                        <TextBox x:Name="AutomationBridgePortBox" Grid.Column="2" Text="34291" VerticalAlignment="Center" FontSize="12"/>
                        <PasswordBox x:Name="AutomationBridgeKeyBox" Grid.Column="4" Password="" VerticalAlignment="Center" FontSize="12"/>
                        <Button x:Name="AutomationBridgeSaveBtn" Grid.Column="6" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="12" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="DDC Compatibility Report" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <Button x:Name="DdcReportGenerateBtn" Grid.Column="2" Content="Build" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="12"/>
                        <Button x:Name="DdcReportCopyBtn" Grid.Column="4" Content="Copy" Style="{StaticResource Btn}" Padding="10,4" FontSize="12"/>
                    </Grid>
                    <TextBox x:Name="DdcReportBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" Height="180" VerticalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"/>
                </Grid></Border>
                <Border Grid.Row="18" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Text="DDC timing for the selected monitor" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                    <StackPanel Grid.Row="2" Orientation="Horizontal">
                        <RadioButton x:Name="DdcTimingAdaptiveRadio" GroupName="DdcTimingMode" Content="Adaptive" IsChecked="True" VerticalAlignment="Center"/>
                        <RadioButton x:Name="DdcTimingManualRadio" GroupName="DdcTimingMode" Content="Manual" Margin="16,0,0,0" VerticalAlignment="Center"/>
                        <Button x:Name="DdcTimingResetBtn" Content="Reset calibration" Style="{StaticResource Btn}" Padding="10,4" FontSize="12" Margin="20,0,0,0"/>
                    </StackPanel>
                    <Grid Grid.Row="4">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="60"/><ColumnDefinition Width="16"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="60"/><ColumnDefinition Width="16"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Read retries" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <TextBox x:Name="DdcTimingReadRetriesBox" Grid.Column="2" FontSize="12" Background="{DynamicResource ControlBrush}"/>
                        <TextBlock Grid.Column="4" Text="Write retries" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <TextBox x:Name="DdcTimingWriteRetriesBox" Grid.Column="6" FontSize="12" Background="{DynamicResource ControlBrush}"/>
                        <TextBlock Grid.Column="8" Text="Capability retries" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
                        <TextBox x:Name="DdcTimingCapabilityRetriesBox" Grid.Column="10" FontSize="12" Background="{DynamicResource ControlBrush}"/>
                    </Grid>
                    <TextBlock x:Name="DdcTimingEffectiveText" Grid.Row="6" Text="" TextWrapping="Wrap" Foreground="{DynamicResource TextBrush}" FontSize="12"/>
                    <TextBlock x:Name="DdcTimingWarningText" Grid.Row="8" Text="" TextWrapping="Wrap" Foreground="{DynamicResource WarningBrush}" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="16" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="DisplayRestoreEnabledCheckbox" Content="Restore brightness at launch and after resume" VerticalAlignment="Center"/>
                        <TextBlock x:Name="DisplayRestoreStatusText" Text="Off" FontSize="12" Foreground="{DynamicResource MutedTextBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <TextBlock Grid.Row="2" Text="Monitors often reset themselves to full brightness after a power or sleep cycle. When this is on, the last brightness you set for each display is written back once per detected display change, through the verified write path." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}" FontSize="12"/>
                </Grid></Border>
                <Border Grid.Row="14" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource WarningBrush}" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <TextBlock Text="Optional hardware helpers" FontSize="12" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold"/>
                    <CheckBox x:Name="CpuMonitorEnabledCheckbox" Grid.Row="2" Content="Load CPU temperature library (LibreHardwareMonitorLib / OpenHardwareMonitorLib)"/>
                    <CheckBox x:Name="PresentMonEnabledCheckbox" Grid.Row="4" Content="Run PresentMon for the FPS overlay"/>
                    <StackPanel Grid.Row="6">
                        <TextBlock Text="These load a DLL or run an executable found beside this script, in Program Files, or on PATH. They stay off until enabled here, and every resolved binary is reported below with its version and SHA-256." TextWrapping="Wrap" Foreground="{DynamicResource MutedTextBrush}" FontSize="12" Margin="0,0,0,6"/>
                        <TextBox x:Name="OptionalHelperStatusBox" IsReadOnly="True" TextWrapping="NoWrap" Height="112" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="{DynamicResource ControlBrush}" FontFamily="Consolas" FontSize="12" AcceptsReturn="True"/>
                    </StackPanel>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
    </TabControl>
    <Border Grid.Row="3" Grid.ColumnSpan="2" Background="{DynamicResource FooterBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="0,1,0,0" Padding="18,0"><Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="7" Height="7" Fill="{DynamicResource SuccessBrush}" Margin="0,0,8,0"/>
            <TextBlock x:Name="StatusText" Text="Ready" FontSize="12" Foreground="{DynamicResource MutedTextBrush}"
                       AutomationProperties.Name="Status: Ready" AutomationProperties.LiveSetting="Polite"/>
        </StackPanel>
        <TextBlock x:Name="AutoModeText" Text="" FontSize="12" Foreground="{DynamicResource WarningBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid></Border>
</Grid>
</ScrollViewer>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

try {
    $brandingIconPath = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $brandingIconPath) {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($brandingIconPath)))
    }
} catch {}
# Get all UI elements
$shellScrollViewer = $window.FindName("ShellScrollViewer"); $shellRoot = $window.FindName("ShellRoot")
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
$vcpResultBox = $window.FindName("VCPResultBox"); $vcpSetValueBox = $window.FindName("VCPSetValueBox"); $vcpSetBtn = $window.FindName("VCPSetBtn"); $vcpScanBtn = $window.FindName("VCPScanBtn")
$vcpScanCapabilitiesOnlyCheckbox = $window.FindName("VCPScanCapabilitiesOnlyCheckbox")
$profileNameBox = $window.FindName("ProfileNameBox"); $profilesList = $window.FindName("ProfilesList")
$saveProfileBtn = $window.FindName("SaveProfileBtn"); $loadProfileBtn = $window.FindName("LoadProfileBtn"); $deleteProfileBtn = $window.FindName("DeleteProfileBtn")
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
$ddcTimingResetBtn = $window.FindName("DdcTimingResetBtn"); $ddcTimingEffectiveText = $window.FindName("DdcTimingEffectiveText")
$ddcTimingWarningText = $window.FindName("DdcTimingWarningText")
$ddcTimingReadRetriesBox = $window.FindName("DdcTimingReadRetriesBox"); $ddcTimingWriteRetriesBox = $window.FindName("DdcTimingWriteRetriesBox")
$ddcTimingCapabilityRetriesBox = $window.FindName("DdcTimingCapabilityRetriesBox")
$displayRestoreEnabledCheckbox = $window.FindName("DisplayRestoreEnabledCheckbox"); $displayRestoreStatusText = $window.FindName("DisplayRestoreStatusText")
$cpuMonitorEnabledCheckbox = $window.FindName("CpuMonitorEnabledCheckbox"); $presentMonEnabledCheckbox = $window.FindName("PresentMonEnabledCheckbox"); $optionalHelperStatusBox = $window.FindName("OptionalHelperStatusBox")
$capabilitiesClearCacheBtn = $window.FindName("CapabilitiesClearCacheBtn")
$capabilitiesDiscoveryEnabledCheckbox = $window.FindName("CapabilitiesDiscoveryEnabledCheckbox"); $capabilitiesMaximumCompatibilityCheckbox = $window.FindName("CapabilitiesMaximumCompatibilityCheckbox")
$capabilitiesSafetyStatusText = $window.FindName("CapabilitiesSafetyStatusText"); $capabilitiesExcludeCurrentBtn = $window.FindName("CapabilitiesExcludeCurrentBtn"); $capabilitiesClearExclusionsBtn = $window.FindName("CapabilitiesClearExclusionsBtn")
$riskyVcpEnabledCheckbox = $window.FindName("RiskyVcpEnabledCheckbox"); $riskyVcpStatusText = $window.FindName("RiskyVcpStatusText")
$automationBridgeEnabledCheckbox = $window.FindName("AutomationBridgeEnabledCheckbox"); $automationBridgeStatusText = $window.FindName("AutomationBridgeStatusText")
$automationBridgeBindBox = $window.FindName("AutomationBridgeBindBox"); $automationBridgePortBox = $window.FindName("AutomationBridgePortBox")
$automationBridgeKeyBox = $window.FindName("AutomationBridgeKeyBox"); $automationBridgeSaveBtn = $window.FindName("AutomationBridgeSaveBtn")
$ddcReportGenerateBtn = $window.FindName("DdcReportGenerateBtn"); $ddcReportCopyBtn = $window.FindName("DdcReportCopyBtn")
$statusText = $window.FindName("StatusText"); $autoModeText = $window.FindName("AutoModeText")

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
        $ddcTimingReadRetriesBox.IsEnabled = $true
        $ddcTimingWriteRetriesBox.IsEnabled = $true
        $ddcTimingCapabilityRetriesBox.IsEnabled = $true
        $calibration = if ([string]::IsNullOrWhiteSpace([string]$timingProfile.CalibratedAt)) { "not calibrated yet" } else { "calibrated $($timingProfile.CalibratedAt)" }
        $skipped = @($timingProfile.UnsupportedCodes)
        $skippedText = if ($skipped.Count -eq 0) { "no codes skipped" } else {
            "skipping " + (($skipped | ForEach-Object { "0x{0:X2}" -f [int]$_.Code }) -join ", ")
        }
        $ddcTimingEffectiveText.Text = "Effective: $($timing.DelayMilliseconds) ms between retries (multiplier $($timing.SleepMultiplier)), read $($timing.ReadRetries), write $($timing.WriteRetries), capability $($timing.CapabilityRetries). $calibration; $skippedText."
        $ddcTimingWarningText.Text = if ($isManual) {
            "Manual mode ignores the learned sleep multiplier. Switching back to Adaptive discards the stored calibration and relearns it from the next successful handshake."
        } else {
            "Adaptive mode learns the sleep multiplier from the first successful handshake with this monitor. Switching to Manual leaves that calibration unused."
        }
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
    Stop-MonitorSettingsWorker -Cancel
    Stop-VcpWorker -Cancel
    Stop-DdcReportWorker -Cancel
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

function Invoke-DisplayRecoveryEventPump {
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
    if ($dueIdentities.Count -eq 0) { return }
    foreach ($identityKey in $dueIdentities) {
        Set-DisplayRecoveryOutcome -IdentityKey $identityKey -Outcome "Retry" -Generation $script:DisplayRecoveryGeneration | Out-Null
    }
    Load-MonitorSettings
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
    })
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

function ConvertTo-CurrentProfileSchema {
    param($Profile, [string]$FallbackName)
    $schema = if ($Profile.PSObject.Properties.Name -contains "SchemaVersion") { [int]$Profile.SchemaVersion } else { 1 }
    if ($schema -lt 1) { throw "Profile schema version must be at least 1" }
    if ($schema -gt $script:ProfileSchemaVersion) { throw "Profile schema v$schema is newer than this app" }
    $name = if (Get-ProfilePropertyValue -Object $Profile -Property "Name" -Default "") { [string]$Profile.Name } else { $FallbackName }
    $topSetting = [PSCustomObject]@{
        IdentityKey = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorIdentityKey" -Default "")
        MonitorLabel = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorLabel" -Default "")
        MonitorName = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorName" -Default "")
        DevicePath = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorDevicePath" -Default "")
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
        $settings += [PSCustomObject]@{
            IdentityKey = [string](Get-ProfilePropertyValue -Object $setting -Property "IdentityKey" -Default "")
            MonitorLabel = [string](Get-ProfilePropertyValue -Object $setting -Property "MonitorLabel" -Default "")
            MonitorName = [string](Get-ProfilePropertyValue -Object $setting -Property "MonitorName" -Default "")
            DevicePath = [string](Get-ProfilePropertyValue -Object $setting -Property "DevicePath" -Default "")
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
        $converted = ConvertTo-CurrentProfileSchema -Profile $profileObject -FallbackName $safeName
        if ($schema -lt $script:ProfileSchemaVersion) {
            if ($script:ProfileStorageOffline) {
                Update-Status "Profile '$safeName' uses schema v$schema; converted in memory while storage is offline"
            } else {
                Save-ProfileObject -Profile $converted | Out-Null
                Update-Status "Migrated profile '$safeName' to schema v$script:ProfileSchemaVersion"
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
            AppVersion = "3.36.0"
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
    if (-not (Wait-DdcWriteQueueIdle -TimeoutMs 2000)) {
        Update-Status "Profile '$Name' is waiting for the DDC write queue"
        return $false
    }
    $transaction = Invoke-VerifiedVcpTransaction -Operations $plan.Operations -RollbackOnFailure
    if (-not $transaction.Success) {
        Update-Status "Profile '$Name' failed ($($transaction.Outcome)); rollback: $($transaction.Rollback)"
        return $false
    }
    try {
        $script:UpdatingUI = $true
        $brightnessRaw = ConvertTo-SelectedRawValue -Percent $plan.Values.Brightness -Code ([int][MonitorAPI]::VCP_BRIGHTNESS)
        $contrastRaw = ConvertTo-SelectedRawValue -Percent $plan.Values.Contrast -Code ([int][MonitorAPI]::VCP_CONTRAST)
        $redRaw = ConvertTo-SelectedRawValue -Percent $plan.Values.Red -Code ([int][MonitorAPI]::VCP_RED_GAIN)
        $greenRaw = ConvertTo-SelectedRawValue -Percent $plan.Values.Green -Code ([int][MonitorAPI]::VCP_GREEN_GAIN)
        $blueRaw = ConvertTo-SelectedRawValue -Percent $plan.Values.Blue -Code ([int][MonitorAPI]::VCP_BLUE_GAIN)
        $brightnessSlider.Value = $brightnessRaw; $brightnessValue.Text = $brightnessRaw
        $contrastSlider.Value = $contrastRaw; $contrastValue.Text = $contrastRaw
        $redSlider.Value = $redRaw; $redValue.Text = $redRaw
        $greenSlider.Value = $greenRaw; $greenValue.Text = $greenRaw
        $blueSlider.Value = $blueRaw; $blueValue.Text = $blueRaw
        if ($plan.Values.Gamma) { $gammaSlider.Value = $plan.Values.Gamma; $gammaValue.Text = ($plan.Values.Gamma / 100).ToString("F2") }
        if ($plan.Values.GammaRed) {
            $gammaRedSlider.Value = $plan.Values.GammaRed
            $gammaGreenSlider.Value = $plan.Values.GammaGreen
            $gammaBlueSlider.Value = $plan.Values.GammaBlue
            Set-GammaRamp -Gamma ($plan.Values.Gamma/100) -RedMult ($plan.Values.GammaRed/100) -GreenMult ($plan.Values.GammaGreen/100) -BlueMult ($plan.Values.GammaBlue/100)
        }
    } catch {
        Update-Status "Profile '$Name' failed"
        return $false
    } finally {
        $script:UpdatingUI = $false
    }
    $profilesList.SelectedItem = $Name
    $verificationSuffix = if ($transaction.Outcome -eq "Unverified") { " (write applied; some readbacks unavailable)" } else { " (verified)" }
    $capabilitySuffix = if ($plan.SkippedUnsupported -gt 0) { "; $($plan.SkippedUnsupported) unsupported values skipped" } else { "" }
    if ($targetIndex -ge 0) {
        Update-Status "$Reason '$Name' -> $(Get-MonitorDisplayLabel -Monitor $script:PhysicalMonitors[$targetIndex])$verificationSuffix$capabilitySuffix"
    } elseif ($targetMissing) {
        Update-Status "$Reason '$Name' (saved monitor missing; current monitor used)$verificationSuffix$capabilitySuffix"
    } else {
        Update-Status "$Reason '$Name'$verificationSuffix$capabilitySuffix"
    }
    Update-TrayPopupState
    Update-TrayIconText
    return $true
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
        $script:BatteryProfileEnabled = [bool]$data.Enabled
        $script:BatteryBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.BatteryBrightness))
        $script:AcBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.AcBrightness))
    } catch {
        Update-Status "Battery profile settings could not be loaded"
    }
}

function Save-BatteryProfileSettings {
    if (-not (Test-ProfileStorageWriteAllowed -Operation "battery profile changes")) { return $false }
    $payload = @{
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
    $trayIconPath = Join-Path $PSScriptRoot 'icon.ico'
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
        $timer.Add_Tick({ $currentTimer.Stop(); $currentOverlay.Close() }); $timer.Start()
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
$muteCheckbox.Add_Checked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 1 }); $muteCheckbox.Add_Unchecked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 2 })

$colorTempWarm.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_5000K) -ActionLabel "Set color temperature to 5000K (Warm)" | Out-Null })
$colorTemp6500.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_6500K) -ActionLabel "Set color temperature to 6500K" | Out-Null })
$colorTempCool.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_9300K) -ActionLabel "Set color temperature to 9300K (Cool)" | Out-Null })
$colorTempSRGB.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_SRGB) -ActionLabel "Set color temperature to sRGB" | Out-Null })

$dynamicContrastOff.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_STANDARD); Update-Status "Dynamic contrast off" })
$dynamicContrastOn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_DYNAMIC_CONTRAST); Update-Status "Dynamic contrast on" })
$pictureModeWeb.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_PRODUCTIVITY); Update-Status "Picture mode: Web" })
$pictureModeCinema.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_MOVIE); Update-Status "Picture mode: Cinema" })
$pictureModeGame.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_GAMES); Update-Status "Picture mode: Game" })

$presetDay.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 80 -Force -Percent; Set-GammaRamp -Gamma 1.0; Set-BrightnessSliderFromPercent -Percent 80 | Out-Null; Update-Status "Day Mode" })
$presetNight.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 40 -Force -Percent; Set-GammaRamp -Gamma 1.0 -RedMult 1.0 -GreenMult 0.9 -BlueMult 0.75; Set-BrightnessSliderFromPercent -Percent 40 | Out-Null; Update-Status "Night Mode" })
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
$presetReset.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 50 -Force -Percent; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value 50 -Force -Percent; Set-GammaRamp -Gamma 1.0; Load-MonitorSettings; Update-Status "Reset" })

$inputSourceCombo.Add_SelectionChanged({
    if ($script:UpdatingUI -or $inputSourceCombo.SelectedItem -eq $null) { return }
    $result = Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_INPUT_SOURCE) -Value ([uint32]$inputSourceCombo.SelectedItem.Tag) -ActionLabel "Change monitor input to $($inputSourceCombo.SelectedItem.Content)"
    if (-not $result.Success) { Load-MonitorSettings }
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
    $result = Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_COLOR) -Value 1 -ActionLabel "Reset the selected monitor's color settings"
    if ($result.Success) {
        Invoke-DelayedMonitorSettingsRefresh -DelayMs 700
    }
})
$factoryResetBtn.Add_Click({
    $result = Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_RESTORE_FACTORY_DEFAULTS) -Value 1 -ActionLabel "Restore the selected monitor to factory defaults"
    if ($result.Success) {
        Invoke-DelayedMonitorSettingsRefresh -DelayMs 1500
    }
})
$allMonitorsStandbyBtn.Add_Click({ Invoke-ManualVcpWrite -Code ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) -ActionLabel "Put every DDC/CI monitor in standby" -AllMonitors | Out-Null })

$vcpPresetCombo.Add_SelectionChanged({ if ($vcpPresetCombo.SelectedItem -ne $null) { $vcpCodeBox.Text = "0x{0:X2}" -f $vcpPresetCombo.SelectedItem.Tag } })
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
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { return }
    try {
        $code = ConvertTo-VcpCode -Text $vcpCodeBox.Text
        $value = ConvertTo-VcpValue -Text $vcpSetValueBox.Text
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
    Start-VcpReadWorker -Handle $mon.Handle -Codes $codes -Mode "Scan" -MonitorName $mon.Name -ReadRetries $script:DdcScanRetryCount -IdentityKey $mon.IdentityKey -MonitorIndex $script:CurrentMonitorIndex
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
    if ($profilesList.SelectedItem -ne $null -and [System.Windows.MessageBox]::Show("Delete '$($profilesList.SelectedItem)'?", "Delete", "YesNo", "Question") -eq "Yes") {
        $deletedProfile = [string]$profilesList.SelectedItem
        $safeDeletedProfile = Get-SafeProfileName -Name $deletedProfile
        if ($safeDeletedProfile) {
            Remove-Item -LiteralPath (Join-Path $script:ProfilesPath "$safeDeletedProfile.json") -ErrorAction SilentlyContinue
        }
        $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Profile -ne $deletedProfile })
        $script:ProfileSchedules = @($script:ProfileSchedules | Where-Object { $_.Profile -ne $deletedProfile })
        Save-AppProfileRules
        Save-ProfileSchedules
        Update-ProfilesList
        Update-AppProfileControls
        Update-ScheduleControls
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
$ddcTimingReadRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Read" -Text $ddcTimingReadRetriesBox.Text } })
$ddcTimingWriteRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Write" -Text $ddcTimingWriteRetriesBox.Text } })
$ddcTimingCapabilityRetriesBox.Add_LostFocus({ if (-not $script:UpdatingDdcTimingUI) { Set-DdcTimingRetryFromUi -Field "Capability" -Text $ddcTimingCapabilityRetriesBox.Text } })
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

# Initialize
Initialize-WmiBrightness; Load-MonitorIdentitySettings; Import-CapabilitySafetyState; Import-VcpWriteSafetyState; Import-OptionalHelperSettings; Import-DisplayStateRestoreSettings; Import-CapabilitiesCache; Import-DdcTimingSettings; Get-Monitors; Initialize-GPU; Initialize-CpuMonitor; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList
Load-AppProfileRules; Update-AppProfileControls; Start-AppProfileWatcher
Load-ProfileSchedules; Update-ScheduleControls; Start-ProfileScheduleWatcher
Load-IdleDimSettings; Update-IdleDimControls; Start-IdleDimWatcher
Load-BatteryProfileSettings; Update-BatteryProfileControls; Start-BatteryProfileWatcher
Load-AutomationBridgeSettings; Update-AutomationBridgeControls; Start-AutomationBridge
Update-ProfileStorageControls
Sync-CapabilitySafetyUi
Sync-VcpWriteSafetyUi
Update-OptionalHelperControls
Update-DisplayStateRestoreControls
Update-DdcTimingControls
Update-HardwareTabVisibility

Initialize-TrayIcon

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

$window.Add_StateChanged({
    if ($script:TraySuppressWindowStateEvent -or $script:IsQuitting) { return }
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { Hide-MainWindowToTray }
})

$window.Add_Closed({ Stop-SystemAccessibility; if ($script:GpuTimer) { $script:GpuTimer.Stop() }; if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; if ($script:AmbientLightTimer) { $script:AmbientLightTimer.Stop() }; if ($script:AppProfileTimer) { $script:AppProfileTimer.Stop() }; if ($script:AppProfileCaptureTimer) { $script:AppProfileCaptureTimer.Stop() }; if ($script:ProfileScheduleTimer) { $script:ProfileScheduleTimer.Stop() }; if ($script:IdleDimTimer) { $script:IdleDimTimer.Stop() }; if ($script:BatteryProfileTimer) { $script:BatteryProfileTimer.Stop() }; if ($script:FpsOverlayTimer) { $script:FpsOverlayTimer.Stop() }; if ($script:DdcWriteResultTimer) { $script:DdcWriteResultTimer.Stop() }; foreach ($timer in @($script:DeferredRefreshTimers)) { try { $timer.Stop() } catch {} }; $script:DeferredRefreshTimers = @(); Stop-DisplayRecoveryEventPipeline; Stop-AutomationBridge; Stop-VcpWorker -Cancel; Stop-MonitorSettingsWorker -Cancel; Stop-CapabilitiesWorker -Cancel; Stop-DdcReportWorker -Cancel
    if ($script:FpsOverlayWindow) { try { $script:FpsOverlayWindow.Close() } catch {} }
    if ($script:HardwareMonitorComputer) { try { $script:HardwareMonitorComputer.Close() } catch {} }
    Dispose-TrayMode
    Wait-DdcWriteQueueIdle -TimeoutMs 1000 | Out-Null
    Clear-PhysicalMonitorHandles -ClearList
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
