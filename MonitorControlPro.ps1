<#
.SYNOPSIS
    MonitorControl Pro v3.34.0 - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version: 3.34.0 - Added no-hardware parser and storage tests
#>

param([switch]$StartMinimized, [string]$LoadProfile)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem

$nativeCode = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;
using System.Threading;

public class MonitorAPI
{
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

    private static readonly object VcpWriteQueueLock = new object();
    private static readonly Dictionary<string, QueuedVcpWrite> QueuedVcpWrites = new Dictionary<string, QueuedVcpWrite>();
    private static readonly object VcpWriteResultsLock = new object();
    private static readonly List<VcpWriteResult> VcpWriteResults = new List<VcpWriteResult>();
    private static bool VcpWriteWorkerActive = false;
    public const int VcpReadRetryCount = 2;
    public const int VcpWriteRetryCount = 2;
    public const int VcpRetryDelayMilliseconds = 60;

    public static void QueueVCPWrite(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, string coalesceKey, string monitorName)
    {
        if (hMonitor == IntPtr.Zero) { return; }
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

    public static bool ReadVCPWithRetry(IntPtr hMonitor, byte bVCPCode, int maxRetries, out uint pvct, out uint pdwCurrentValue, out uint pdwMaximumValue, out int lastError, out int attempts)
    {
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
                return true;
            }
            lastError = Marshal.GetLastWin32Error();
            if (retry < maxRetries) { Thread.Sleep(VcpRetryDelayMilliseconds); }
        }
        return false;
    }

    public static bool SetVCPWithRetry(IntPtr hMonitor, byte bVCPCode, uint dwNewValue, int maxRetries, out int lastError, out int attempts)
    {
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
                return true;
            }
            lastError = Marshal.GetLastWin32Error();
            if (retry < maxRetries) { Thread.Sleep(VcpRetryDelayMilliseconds); }
        }
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
    param([string]$Path, [string]$Label = "JSON")
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        $quarantinePath = Move-CorruptJsonFile -Path $Path
        $backupPath = "$Path.bak"
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
$script:MonitorSettingsWorker = $null
$script:MonitorSettingsWorkerInput = $null
$script:MonitorSettingsWorkerOutput = $null
$script:MonitorSettingsWorkerAsyncResult = $null
$script:MonitorSettingsWorkerTimer = $null
$script:MonitorSettingsWorkerIndex = -1
$script:MonitorSettingsWorkerName = ""
$script:MonitorSettingsWorkerLastOutputCount = 0
$script:CapabilitiesWorker = $null
$script:CapabilitiesWorkerInput = $null
$script:CapabilitiesWorkerOutput = $null
$script:CapabilitiesWorkerAsyncResult = $null
$script:CapabilitiesWorkerTimer = $null
$script:CapabilitiesWorkerLastOutputCount = 0
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
$script:RiskyVcpCodes = @(0x04, 0x08, 0x60, 0xD6, 0xE8, 0xE9)
$script:UpdatingVcpWriteSafetyUI = $false
$script:DdcReportWorker = $null
$script:DdcReportWorkerInput = $null
$script:DdcReportWorkerOutput = $null
$script:DdcReportWorkerAsyncResult = $null
$script:DdcReportWorkerTimer = $null
$script:DdcReportWorkerLastOutputCount = 0
$script:DdcReportTargets = @()
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
$script:CapabilitiesSafetySettingsPath = Join-Path $script:DefaultProfilesPath "capabilities-safety.json"
$script:CapabilitiesProbeSentinelPath = Join-Path $script:DefaultProfilesPath "capabilities-probe-pending.json"
$script:VcpWriteSafetySettingsPath = Join-Path $script:DefaultProfilesPath "vcp-write-safety.json"
$script:ProfilesPath = $script:DefaultProfilesPath
$script:ProfileStorageMode = "Local"
if (-not (Test-Path -LiteralPath $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
if (Test-Path -LiteralPath $script:ProfileStorageSettingsPath) {
    try {
        $profileStorage = Read-JsonFileSafely -Path $script:ProfileStorageSettingsPath -Label "Profile storage"
        $configuredPath = [string]$profileStorage.ProfilePath
        if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
            $script:ProfilesPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configuredPath))
            $script:ProfileStorageMode = if ($profileStorage.Mode) { [string]$profileStorage.Mode } else { "Sync" }
        }
    } catch {
        $script:ProfilesPath = $script:DefaultProfilesPath
        $script:ProfileStorageMode = "Local"
    }
}
$script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
$script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
$script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
$script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
$script:MonitorIdentitySettingsPath = Join-Path $script:ProfilesPath "monitor-identities.json"
$script:ProfileSchemaVersion = 3
$script:ProfileBundleSchemaVersion = 2
$script:ProfileBundleMaxProfiles = 100
$script:ProfileBundleMaxArchiveBytes = 16777216
$script:ProfileBundleMaxManifestBytes = 65536
$script:ProfileBundleMaxEntryBytes = 262144
$script:ProfileBundleMaxTotalBytes = 10485760
$script:ProfileBundleMaxCompressionRatio = 100
$script:ProfileBundleMaxMonitorSettings = 32
$script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
$script:ProfileMetadataFiles = @("app-profile-rules.json", "profile-schedules.json", "idle-dim.json", "battery-profile.json", "profile-storage.json", "monitor-identities.json", "automation-bridge.json", "capabilities-safety.json", "capabilities-probe-pending.json", "vcp-write-safety.json")
$script:MonitorIdentityRecords = @{}
$script:UpdatingMonitorLabelUI = $false
$script:UiCulture = "en-US"
$script:UiStrings = @{
    "App.Title" = "MonitorControl Pro"
    "App.Subtitle" = "Version 3.34.0"
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
}
$script:UpdatingUI = $false
$script:ApplyToAll = $false
$script:AutoModeEnabled = $false
$script:WmiBrightnessAvailable = $false
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
    Set-ControlVcpSupport -Control $colorTempWarm -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_5000K)
    Set-ControlVcpSupport -Control $colorTemp6500 -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_6500K)
    Set-ControlVcpSupport -Control $colorTempCool -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_9300K)
    Set-ControlVcpSupport -Control $colorTempSRGB -Monitor $Monitor -Code ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_SRGB)
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
        $data = Read-JsonFileSafely -Path $script:MonitorIdentitySettingsPath -Label "Monitor identities"
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
        $window.Title = "$(Get-UiString -Key 'App.Title') v3.34.0"
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
        $capabilitiesDiscoveryEnabledCheckbox,$capabilitiesMaximumCompatibilityCheckbox,$capabilitiesExcludeCurrentBtn,$capabilitiesClearExclusionsBtn,$riskyVcpEnabledCheckbox,
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
    param([switch]$ClearList)
    $seen = @{}
    foreach ($mon in @($script:PhysicalMonitors)) {
        if ($null -eq $mon -or $mon.Handle -eq [IntPtr]::Zero) { continue }
        $key = $mon.Handle.ToInt64()
        if (-not $seen.ContainsKey($key)) {
            try { [MonitorAPI]::DestroyPhysicalMonitor($mon.Handle) | Out-Null } catch {}
            $seen[$key] = $true
        }
        try { $mon.Handle = [IntPtr]::Zero } catch {}
    }
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
    if ($count -ne $script:CapabilitiesWorkerLastOutputCount -and -not $completed) {
        $script:CapabilitiesWorkerLastOutputCount = $count
        Update-Status "Reading capabilities... $count"
    }
    if (-not $completed) { return }
    try { $script:CapabilitiesWorker.EndInvoke($script:CapabilitiesWorkerAsyncResult) } catch { Update-Status "Capabilities read failed: $($_.Exception.Message)" }
    foreach ($result in @($script:CapabilitiesWorkerOutput)) {
        $index = [int]$result.Index
        if ($index -lt 0 -or $index -ge $script:PhysicalMonitors.Count) { continue }
        $mon = $script:PhysicalMonitors[$index]
        if ($mon.Handle.ToInt64() -ne [int64]$result.HandleValue) { continue }
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
    }
    if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $selected = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        Update-CapabilitiesBox -Monitor $selected
        Update-CapabilityControls -Monitor $selected
    }
    $sentinelFailures = @($script:CapabilitiesWorkerOutput | Where-Object { -not [bool]$_.SentinelReady }).Count
    if ($sentinelFailures -gt 0) {
        Update-Status "Capability reads skipped where the crash sentinel could not be persisted"
    } else {
        Update-Status "Capabilities read complete"
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
        if (Test-CapabilityProbeAllowed -Monitor $mon) {
            $mon.CapabilitiesPending = $true
            $targets += [PSCustomObject]@{
                Index = [int]$i
                Handle = $mon.Handle
                HandleValue = $mon.Handle.ToInt64()
                Name = [string]$mon.Name
                IdentityKey = [string]$mon.IdentityKey
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
                HandleValue = [int64]$target.HandleValue
                MonitorName = [string]$target.Name
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
    if (-not $script:CapabilitiesWorkerTimer) {
        $script:CapabilitiesWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CapabilitiesWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:CapabilitiesWorkerTimer.Add_Tick({ Update-CapabilitiesWorkerOutput })
    }
    Update-Status "Reading capabilities... 0/$($targets.Count)"
    $script:CapabilitiesWorkerTimer.Start()
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
    while ([MonitorAPI]::EnumDisplayDevices($null, $devNum, [ref]$device, 0)) {
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
                            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false
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
    if ($script:PhysicalMonitors.Count -eq 0) {
        $fallbackName = if ($script:WmiBrightnessAvailable) { "Integrated Laptop Display" } else { "No DDC/CI Monitor" }
        $fallbackDevice = if ($script:WmiBrightnessAvailable) { "WMI" } else { "" }
        $identity = New-MonitorIdentity -DisplayDeviceName $fallbackDevice -FriendlyName $fallbackName -Width 1920 -Height 1080 -MonitorIndex 1
        $fallbackObject = [PSCustomObject]@{
            Handle = [IntPtr]::Zero; HMonitor = [IntPtr]::Zero; Name = $fallbackName; Index = 1
            DeviceName = $fallbackDevice; Width = 1920; Height = 1080; RefreshRate = 60; IsPrimary = $true
            Left = 0; Top = 0; Right = 1920; Bottom = 1080; Capabilities = ""
            CapabilitiesKnown = $false; SupportedVcpCodes = @{}; CapabilitiesPending = $false
            CapabilitiesExcluded = $false; CapabilitiesSafetyError = ""
            IdentityKey = $identity.Key; IdentitySource = $identity.Source; IdentityDefaultLabel = $identity.DefaultLabel
            DevicePath = $identity.DevicePath; MonitorDeviceString = $identity.DeviceString; HardwareId = $identity.HardwareId
            Manufacturer = $identity.Manufacturer; EdidModel = $identity.Model; EdidSerial = $identity.Serial; EdidName = $identity.EdidName
            UserLabel = ""; DisplayLabel = $identity.DefaultLabel
        }
        Apply-MonitorIdentity -Monitor $fallbackObject
        $script:PhysicalMonitors += $fallbackObject
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

function Get-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [string]$MonitorName = "")
    $vct = [uint32]0; $cur = [uint32]0; $max = [uint32]0
    $lastError = [int]0; $attempts = [int]0
    $result = [MonitorAPI]::ReadVCPWithRetry($Handle, $VCPCode, $script:DdcReadRetryCount, [ref]$vct, [ref]$cur, [ref]$max, [ref]$lastError, [ref]$attempts)
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Read" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $null -LastError $lastError -Attempts $attempts -Message "" -SuppressStatus | Out-Null
    }
    return @{ Success = $result; Current = $cur; Maximum = $max; Type = $vct; LastError = $lastError; Attempts = $attempts; RetryCount = [Math]::Max(0, $attempts - 1) }
}

function Set-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$MonitorName = "")
    $lastError = [int]0; $attempts = [int]0
    $result = [MonitorAPI]::SetVCPWithRetry($Handle, $VCPCode, $Value, $script:DdcWriteRetryCount, [ref]$lastError, [ref]$attempts)
    if (-not $result) {
        Register-DdcDiagnostic -Operation "Write" -Monitor $MonitorName -Code ([int]$VCPCode) -Value $Value -LastError $lastError -Attempts $attempts -Message "" | Out-Null
    }
    return $result
}

function Queue-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value, [string]$Key, [string]$MonitorName = "")
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    [MonitorAPI]::QueueVCPWrite($Handle, $VCPCode, $Value, $Key, $MonitorName)
    return $true
}

function Set-VCPValueWithSync {
    param([byte]$VCPCode, [uint32]$Value, [switch]$Force)
    if (Test-VcpWriteRequiresSafetyConsent -Code ([int]$VCPCode)) {
        if (Get-Command Update-Status -ErrorAction SilentlyContinue) {
            Update-Status "Risky VCP 0x$("{0:X2}" -f $VCPCode) requires the verified manual or consented automation path"
        }
        return $false
    }
    $queued = 0
    if ($script:ApplyToAll -or $Force) {
        for ($i = 0; $i -lt $script:PhysicalMonitors.Count; $i++) {
            $mon = $script:PhysicalMonitors[$i]
            if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $Value -Key "$i`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name) { $queued++ }
        }
        if ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $Value | Out-Null }
    } else {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $Value -Key "$script:CurrentMonitorIndex`:0x$("{0:X2}" -f $VCPCode)" -MonitorName $mon.Name) { $queued++ }
        elseif ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $Value | Out-Null }
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

function Format-VcpWriteConfirmation {
    param([object[]]$Operations, [string]$ActionLabel = "Direct VCP write")
    $items = @($Operations)
    $code = if ($items.Count -gt 0) { [int]$items[0].Code } else { 0 }
    $value = if ($items.Count -gt 0) { [uint32]$items[0].Value } else { 0 }
    $targets = @($items | ForEach-Object { [string]$_.MonitorName } | Sort-Object -Unique)
    return @"
$ActionLabel

VCP code: 0x$("{0:X2}" -f $code) ($(Get-VcpDescription -Code $code))
Value: $value
Target: $($targets -join ", ")

This write may blank the display, change its input, remove access to the current desktop, or reset monitor settings. MonitorControl Pro will attempt an immediate readback, but some commands cannot be verified after the display changes state.

Apply this exact code and value?
"@
}

function Invoke-ManualVcpWrite {
    param(
        [int]$Code,
        [uint32]$Value,
        [string]$ActionLabel = "Direct VCP write",
        [switch]$AllMonitors,
        [switch]$Arbitrary
    )
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
    $choice = [System.Windows.MessageBox]::Show(
        $confirmation,
        "Confirm exact VCP write",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
        Update-Status "VCP write canceled"
        return [PSCustomObject]@{ Success = $false; Outcome = "Canceled"; Results = @() }
    }
    if (-not (Wait-DdcWriteQueueIdle -TimeoutMs 2000)) {
        Update-Status "VCP write queue is busy; try again"
        return [PSCustomObject]@{ Success = $false; Outcome = "Busy"; Results = @() }
    }
    $result = Invoke-VerifiedVcpTransaction -Operations $operations
    $codeText = "0x{0:X2} = {1}" -f $Code, $Value
    switch ($result.Outcome) {
        "Verified" { Update-Status "Verified VCP $codeText" }
        "Unverified" { Update-Status "VCP $codeText applied; readback unavailable" }
        "Mismatched" { Update-Status "VCP $codeText mismatched its readback" }
        default { Update-Status "VCP $codeText failed" }
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
    if ($vcpQueryBtn) { $vcpQueryBtn.IsEnabled = $true }
    if ($vcpScanBtn) { $vcpScanBtn.IsEnabled = $true }
}

function Update-VcpWorkerOutput {
    if (-not $script:VcpWorker -or -not $script:VcpWorkerOutput -or -not $script:VcpWorkerAsyncResult) { return }
    $count = $script:VcpWorkerOutput.Count
    $completed = [bool]$script:VcpWorkerAsyncResult.IsCompleted
    if ($count -ne $script:VcpWorkerLastOutputCount -or $completed) {
        $script:VcpWorkerLastOutputCount = $count
        $items = @($script:VcpWorkerOutput)
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
        $items = @($script:VcpWorkerOutput)
        if ($script:VcpWorkerMode -eq "Query" -and $items.Count -gt 0 -and -not [bool]$items[-1].Success) {
            $failure = $items[-1]
            Register-DdcDiagnostic -Operation "Read" -Monitor ([string]$failure.MonitorName) -Code ([int]$failure.Code) -Value $null -LastError ([int]$failure.LastError) -Attempts ([int]$failure.Attempts) -Message "" | Out-Null
        }
        if ($script:VcpWorkerMode -eq "Scan") { Update-Status "VCP scan complete" }
        Stop-VcpWorker
    }
}

function Start-VcpReadWorker {
    param([IntPtr]$Handle, [int[]]$Codes, [string]$Mode, [string]$MonitorName, [int]$ReadRetries = 0)
    Stop-VcpWorker -Cancel
    if ($Handle -eq [IntPtr]::Zero -or $Codes.Count -eq 0) { return }
    $workerScript = {
        param([IntPtr]$Handle, [int[]]$Codes, [string]$MonitorName, [int]$ReadRetries)
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
                Index = [int]$index
                Count = [int]$Codes.Count
            }
        }
    }
    $script:VcpWorkerMode = $Mode
    $script:VcpWorkerMonitorName = $MonitorName
    $script:VcpWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VcpWorkerInput.Complete()
    $script:VcpWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:VcpWorker = [PowerShell]::Create()
    $script:VcpWorker.AddScript($workerScript.ToString()).AddArgument($Handle).AddArgument($Codes).AddArgument($MonitorName).AddArgument($ReadRetries) | Out-Null
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
    foreach ($mon in @($script:PhysicalMonitors)) {
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
            Handle = $mon.Handle
            HandleValue = [int64]$mon.Handle.ToInt64()
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
    [void]$sb.AppendLine("App version: 3.34.0")
    [void]$sb.AppendLine("OS: $($system.OS)")
    [void]$sb.AppendLine("PowerShell: $($system.PowerShell)")
    [void]$sb.AppendLine("Probe safety: power, input, reset, PiP/PbP, and arbitrary VCP codes are not automatically queried")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("GPU drivers:")
    foreach ($gpu in @($system.GPUs)) { [void]$sb.AppendLine("- $gpu") }
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
    if ($ddcReportGenerateBtn) { $ddcReportGenerateBtn.IsEnabled = $true }
    if ($ddcReportCopyBtn) { $ddcReportCopyBtn.IsEnabled = $true }
}

function Update-DdcReportWorkerOutput {
    if (-not $script:DdcReportWorker -or -not $script:DdcReportWorkerOutput -or -not $script:DdcReportWorkerAsyncResult) { return }
    $probeResults = @($script:DdcReportWorkerOutput | Where-Object { $_.Kind -eq "Probe" })
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
        if (($mon.Index - 1) -eq $script:CurrentMonitorIndex) { $brightness = [int]$brightnessSlider.Value }
        $items += [PSCustomObject]@{
            Index = [int]$mon.Index
            Label = [string](Get-MonitorDisplayLabel -Monitor $mon)
            Name = [string]$mon.Name
            IdentityKey = [string]$mon.IdentityKey
            DeviceName = [string]$mon.DeviceName
            HasDdc = ([int64]$mon.Handle.ToInt64() -ne 0)
            Brightness = $brightness
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
    return New-AutomationBridgeResponse -Status 200 -Body @{ monitor = $mon.Index; brightness = [int]$result.Current; maximum = [int]$result.Maximum; source = "DDC" }
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
        if (Queue-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$value) -Key "bridge:$index`:0x10" -MonitorName $mon.Name) { $queued++ }
        if ($index -eq $script:CurrentMonitorIndex) {
            $script:UpdatingUI = $true
            try { $brightnessSlider.Value = $value; $brightnessValue.Text = $value.ToString() } finally { $script:UpdatingUI = $false }
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
    $count = $script:MonitorSettingsWorkerOutput.Count
    $completed = [bool]$script:MonitorSettingsWorkerAsyncResult.IsCompleted
    if ($count -ne $script:MonitorSettingsWorkerLastOutputCount -and -not $completed) {
        $script:MonitorSettingsWorkerLastOutputCount = $count
        Update-Status "Reading from $script:MonitorSettingsWorkerName... $count/7"
    }
    if (-not $completed) { return }
    $workerName = $script:MonitorSettingsWorkerName
    $workerIndex = $script:MonitorSettingsWorkerIndex
    try { $script:MonitorSettingsWorker.EndInvoke($script:MonitorSettingsWorkerAsyncResult) } catch { Update-Status "Monitor settings read failed: $($_.Exception.Message)" }
    if ($workerIndex -eq $script:CurrentMonitorIndex) {
        $results = @($script:MonitorSettingsWorkerOutput)
        $failures = @($results | Where-Object { -not [bool]$_.Success })
        $script:UpdatingUI = $true
        try {
            foreach ($result in $results) { Apply-MonitorSettingResult -Result $result }
        } finally {
            $script:UpdatingUI = $false
        }
        foreach ($failure in $failures) {
            Register-DdcDiagnostic -Operation "Read" -Monitor $workerName -Code ([int]$failure.Code) -Value $null -LastError ([int]$failure.LastError) -Attempts ([int]$failure.Attempts) -Message "Monitor setting refresh" -SuppressStatus | Out-Null
        }
        if ($failures.Count -gt 0) {
            Update-Status ("{0} ({1}/7 readable; DDC diagnostics captured)" -f $workerName, ($results.Count - $failures.Count))
        } else {
            Update-Status "$workerName"
        }
        Update-TrayPopupState
        Update-TrayIconText
    }
    Stop-MonitorSettingsWorker
}

function Start-MonitorSettingsWorker {
    param([IntPtr]$Handle, [int]$MonitorIndex, [string]$MonitorName)
    Stop-MonitorSettingsWorker -Cancel
    if ($Handle -eq [IntPtr]::Zero) { return }
    $codes = @(
        [int][MonitorAPI]::VCP_BRIGHTNESS,
        [int][MonitorAPI]::VCP_CONTRAST,
        [int][MonitorAPI]::VCP_RED_GAIN,
        [int][MonitorAPI]::VCP_GREEN_GAIN,
        [int][MonitorAPI]::VCP_BLUE_GAIN,
        [int][MonitorAPI]::VCP_VOLUME,
        [int][MonitorAPI]::VCP_SHARPNESS
    )
    $workerScript = {
        param([IntPtr]$Handle, [int[]]$Codes, [string]$MonitorName, [int]$ReadRetries)
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
                Index = [int]$index
                Count = [int]$Codes.Count
            }
        }
    }
    $script:MonitorSettingsWorkerIndex = $MonitorIndex
    $script:MonitorSettingsWorkerName = $MonitorName
    $script:MonitorSettingsWorkerInput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:MonitorSettingsWorkerInput.Complete()
    $script:MonitorSettingsWorkerOutput = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $script:MonitorSettingsWorker = [PowerShell]::Create()
    $script:MonitorSettingsWorker.AddScript($workerScript.ToString()).AddArgument($Handle).AddArgument($codes).AddArgument($MonitorName).AddArgument($script:DdcReadRetryCount) | Out-Null
    $script:MonitorSettingsWorkerAsyncResult = $script:MonitorSettingsWorker.BeginInvoke($script:MonitorSettingsWorkerInput, $script:MonitorSettingsWorkerOutput)
    $script:MonitorSettingsWorkerLastOutputCount = 0
    if (-not $script:MonitorSettingsWorkerTimer) {
        $script:MonitorSettingsWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:MonitorSettingsWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:MonitorSettingsWorkerTimer.Add_Tick({ Update-MonitorSettingsWorkerOutput })
    }
    Update-Status "Reading from $MonitorName... 0/$($codes.Count)"
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
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $settings.Brightness -Force | Out-Null
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
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $brightness -Force
    $script:UpdatingUI = $true
    $brightnessSlider.Value = $brightness; $brightnessValue.Text = $brightness
    $script:UpdatingUI = $false
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

function Initialize-CpuMonitor {
    $candidatePaths = @(
        (Join-Path $PSScriptRoot "LibreHardwareMonitorLib.dll"),
        (Join-Path $PSScriptRoot "OpenHardwareMonitorLib.dll"),
        "${env:ProgramFiles}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\LibreHardwareMonitor\LibreHardwareMonitorLib.dll",
        "${env:ProgramFiles(x86)}\OpenHardwareMonitor\OpenHardwareMonitorLib.dll"
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($path in $candidatePaths) {
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
            return
        } catch {}
    }
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
    $script:ProfileStorageMode = "Local"
    $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
    $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
    $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
    $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
    $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
    if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MonitorControl Pro v3.34.0" Width="1120" Height="760" MinWidth="920" MinHeight="640"
        Background="#08111d" Foreground="#e8eef7" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
<Window.Resources>
    <SolidColorBrush x:Key="CanvasBrush" Color="#08111d"/>
    <SolidColorBrush x:Key="SidebarBrush" Color="#0a1422"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#101b2b"/>
    <SolidColorBrush x:Key="CardBrush" Color="#142235"/>
    <SolidColorBrush x:Key="CardHoverBrush" Color="#192b42"/>
    <SolidColorBrush x:Key="BorderBrush" Color="#26384f"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#4c8dff"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#67a0ff"/>
    <SolidColorBrush x:Key="TextBrush" Color="#e8eef7"/>
    <SolidColorBrush x:Key="MutedTextBrush" Color="#8e9db1"/>
    <Style TargetType="TextBlock">
        <Setter Property="FontFamily" Value="Segoe UI"/>
        <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
    <ControlTemplate x:Key="ComboBoxToggleButton" TargetType="ToggleButton">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="20"/></Grid.ColumnDefinitions>
            <Border x:Name="Border" Grid.ColumnSpan="2" CornerRadius="8" Background="#0d1928" BorderBrush="#2a3a50" BorderThickness="1"/>
            <Path Grid.Column="1" Fill="#91a2b8" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 4 4 L 8 0 Z"/>
        </Grid>
        <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Border" Property="Background" Value="#17263a"/><Setter TargetName="Border" Property="BorderBrush" Value="#3c5270"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Border" Property="BorderBrush" Value="#4c8dff"/></Trigger>
        </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
        <Setter Property="Foreground" Value="#e8eef7"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="Height" Value="34"/>
        <Setter Property="FontSize" Value="12"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
            <ToggleButton Template="{StaticResource ComboBoxToggleButton}" Focusable="False" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press"/>
            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
            <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#142235" BorderThickness="1" BorderBrush="#2a3a50" CornerRadius="8" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="240" Margin="0,3,0,0">
                    <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer></Border>
            </Popup></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="#e8eef7"/><Setter Property="Padding" Value="10,7"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6"><ContentPresenter/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#254d82"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
        <Setter Property="Background" Value="#142235"/><Setter Property="Foreground" Value="#dce6f3"/><Setter Property="BorderBrush" Value="#2a3a50"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,8"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="12"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1d3049"/><Setter TargetName="bd" Property="BorderBrush" Value="#405773"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#243a56"/></Trigger>
                <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#75a9ff"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="AccBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#367ff4"/><Setter Property="BorderBrush" Value="#4c8dff"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#4c91ff"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#286edb"/></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="WarnBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#40212a"/><Setter Property="BorderBrush" Value="#78404c"/><Setter Property="Foreground" Value="#ffb8c1"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#552a35"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="GreenBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#367ff4"/><Setter Property="BorderBrush" Value="#4c8dff"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#4c91ff"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="OrangeBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#3a2f1e"/><Setter Property="BorderBrush" Value="#765b2b"/><Setter Property="Foreground" Value="#ffd18a"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#4a3c25"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Sld" TargetType="Slider">
        <Setter Property="Height" Value="24"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
                <Border Height="5" Background="#26364a" CornerRadius="3"/>
                <Track x:Name="PART_Track">
                    <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge"><RepeatButton.Template>
                        <ControlTemplate><Border Background="{Binding Tag, RelativeSource={RelativeSource AncestorType=Slider}}" CornerRadius="3" Height="5"/></ControlTemplate>
                    </RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb><Thumb.Template><ControlTemplate><Grid><Ellipse Width="18" Height="18" Fill="#f5f8fc" Stroke="#4c8dff" StrokeThickness="2"/><Ellipse Width="5" Height="5" Fill="#4c8dff"/></Grid></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
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
                <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="#0a1422" BorderBrush="#1d2b3d" BorderThickness="0,1,1,0" Padding="14,18">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.TabIndex="1"/>
                </Border>
                <Border Grid.Column="1" Background="#08111d" BorderBrush="#1d2b3d" BorderThickness="0,1,0,0" Padding="24,20,24,16">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="16"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <TextBlock Text="{Binding SelectedItem.Header, RelativeSource={RelativeSource TemplatedParent}}" FontSize="24" FontWeight="SemiBold" Foreground="#f5f8fc"/>
                        <ContentPresenter Grid.Row="2" ContentSource="SelectedContent" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" KeyboardNavigation.TabIndex="2"/>
                    </Grid>
                </Border>
            </Grid>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TabItem">
        <Setter Property="Foreground" Value="#8e9db1"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/>
        <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="18,13"/><Setter Property="Margin" Value="0,0,0,6"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Stretch"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="9">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="Indicator" Width="3" Height="22" CornerRadius="2" Background="#4c8dff" HorizontalAlignment="Left" Margin="-18,0,0,0" Visibility="Collapsed"/>
                    <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                    <ContentPresenter Grid.Column="1" ContentSource="Header" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                </Grid>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#172842"/><Setter TargetName="Indicator" Property="Visibility" Value="Visible"/><Setter Property="Foreground" Value="#f5f8fc"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#132238"/><Setter Property="Foreground" Value="#dce6f3"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="#dce6f3"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
                <Border x:Name="cb" Width="18" Height="18" Background="#0d1928" BorderBrush="#40516a" BorderThickness="1" CornerRadius="4" Margin="0,0,8,0">
                    <Path x:Name="cm" Data="M 2 5 L 5 8 L 12 1" Stroke="#fff" StrokeThickness="2" Visibility="Collapsed" Margin="1"/></Border>
                <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True">
                <Setter TargetName="cb" Property="Background" Value="#367ff4"/><Setter TargetName="cb" Property="BorderBrush" Value="#4c8dff"/>
                <Setter TargetName="cm" Property="Visibility" Value="Visible"/>
            </Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ProgressBar">
        <Setter Property="Height" Value="6"/><Setter Property="Background" Value="#26364a"/><Setter Property="Foreground" Value="#4c8dff"/><Setter Property="BorderThickness" Value="0"/>
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
                        <Border x:Name="ThumbBorder" Background="#34475f" CornerRadius="5" Margin="3,2"/>
                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#4b6381"/></Trigger></ControlTemplate.Triggers>
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
        <Setter Property="Background" Value="#0d1928"/><Setter Property="Foreground" Value="#e8eef7"/><Setter Property="BorderBrush" Value="#2a3a50"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,6"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/><Setter Property="CaretBrush" Value="#fff"/>
    </Style>
    <Style TargetType="PasswordBox">
        <Setter Property="Background" Value="#0d1928"/><Setter Property="Foreground" Value="#e8eef7"/><Setter Property="BorderBrush" Value="#2a3a50"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,6"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="12"/><Setter Property="CaretBrush" Value="#fff"/>
    </Style>
</Window.Resources>
<Grid Background="#08111d">
    <Grid.RowDefinitions><RowDefinition Height="74"/><RowDefinition Height="*"/><RowDefinition Height="32"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Row="0" Grid.Column="0" Background="#0a1422" BorderBrush="#1d2b3d" BorderThickness="0,0,1,0" Padding="18,0">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="30" Height="30" CornerRadius="8" Background="#367ff4" VerticalAlignment="Center">
                <TextBlock Text="MC" Foreground="#fff" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0,0,0">
                <TextBlock x:Name="AppTitleText" Text="MonitorControl Pro" FontSize="15" FontWeight="SemiBold" Foreground="#f5f8fc"/>
                <TextBlock x:Name="AppSubtitleText" Text="Version 3.34.0" FontSize="10" Foreground="#75869d" Margin="0,2,0,0"/>
            </StackPanel>
        </Grid>
    </Border>
    <Border Grid.Row="0" Grid.Column="1" Background="#0b1625" Padding="24,0">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="SelectedMonitorName" Text="No monitor selected" FontSize="14" Foreground="#f5f8fc" FontWeight="SemiBold"/>
                    <Ellipse Width="7" Height="7" Fill="#42c77a" Margin="12,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Ready" FontSize="11" Foreground="#91a2b8" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                    <TextBlock x:Name="SelectedMonitorRes" FontSize="10" Foreground="#75869d"/>
                    <TextBlock x:Name="SelectedMonitorInfo" FontSize="10" Foreground="#5f7188" Margin="10,0,0,0"/>
                </StackPanel>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <CheckBox x:Name="ApplyAllCheckbox" Content="All displays" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <Button x:Name="IdentifyBtn" Content="Identify" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                <Button x:Name="RefreshBtn" Content="Refresh" Style="{StaticResource Btn}"/>
            </StackPanel>
        </Grid>
    </Border>
    <TabControl Grid.Row="1" Grid.ColumnSpan="2" TabStripPlacement="Left">
        <TabItem x:Name="DisplayTab" Header="Display" Tag="&#xE7F4;">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="12" Padding="18">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid>
                            <TextBlock Text="Displays" FontSize="14" FontWeight="SemiBold"/>
                            <TextBlock Text="Select a display to adjust its settings" FontSize="11" Foreground="#75869d" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                        <Border Grid.Row="2" Height="118" Background="#0c1725" BorderBrush="#223249" BorderThickness="1" CornerRadius="9" Padding="12">
                            <Canvas x:Name="MonitorCanvas" ClipToBounds="True"/>
                        </Border>
                    </Grid>
                </Border>
                <Grid Grid.Row="2">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#142235" BorderBrush="#2a3d56" BorderThickness="1" CornerRadius="12" Padding="18,14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid>
                            <StackPanel><TextBlock Text="Brightness" FontSize="13" Foreground="#dce6f3" FontWeight="SemiBold"/>
                                <TextBlock Text="Hardware luminance" FontSize="10" Foreground="#75869d" Margin="0,2,0,0"/></StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                <TextBlock x:Name="BrightnessValue" Text="50" FontSize="28" Foreground="#f5f8fc" FontWeight="SemiBold"/>
                                <TextBlock Text="%" FontSize="13" Foreground="#8e9db1" Margin="2,8,0,0"/>
                            </StackPanel>
                        </Grid>
                        <Slider x:Name="BrightnessSlider" Grid.Row="2" Value="50" Tag="#4c8dff" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="12" Padding="16,14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Contrast" FontSize="13" Foreground="#dce6f3" FontWeight="SemiBold"/><TextBlock x:Name="ContrastValue" Text="50" FontSize="18" Foreground="#f5f8fc" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="ContrastSlider" Grid.Row="2" Value="50" Tag="#7396c6" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Red gain" FontSize="11" Foreground="#ff7b84"/><TextBlock x:Name="RedValue" Text="50" FontSize="11" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="RedSlider" Grid.Row="2" Value="50" Tag="#e85050" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Green gain" FontSize="11" Foreground="#62d891"/><TextBlock x:Name="GreenValue" Text="50" FontSize="11" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GreenSlider" Grid.Row="2" Value="50" Tag="#45c770" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="4" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="12,9"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Blue gain" FontSize="11" Foreground="#6ca9ff"/><TextBlock x:Name="BlueValue" Text="50" FontSize="11" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="BlueSlider" Grid.Row="2" Value="50" Tag="#4a90e8" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="4" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel VerticalAlignment="Center"><TextBlock Text="Color temperature" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold"/>
                        <TextBlock Text="Choose a white-point preset" FontSize="10" Foreground="#75869d" Margin="0,2,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="ColorTempWarm" Content="Warm" Style="{StaticResource Btn}" Padding="12,6" Margin="0,0,6,0" FontSize="11"/>
                        <Button x:Name="ColorTemp6500" Content="6500K" Style="{StaticResource AccBtn}" Padding="12,6" Margin="0,0,6,0" FontSize="11"/>
                        <Button x:Name="ColorTempCool" Content="Cool" Style="{StaticResource Btn}" Padding="12,6" Margin="0,0,6,0" FontSize="11"/>
                        <Button x:Name="ColorTempSRGB" Content="sRGB" Style="{StaticResource Btn}" Padding="12,6" FontSize="11"/>
                    </StackPanel>
                </Grid></Border>
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="PresetDay" Content="Day" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetNight" Grid.Column="2" Content="Night" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetAutoMode" Grid.Column="4" Content="Auto" Style="{StaticResource OrangeBtn}" Padding="5,5"/>
                    <Button x:Name="PresetAmbientMode" Grid.Column="6" Content="Ambient" Style="{StaticResource GreenBtn}" Padding="5,5"/>
                    <Button x:Name="PresetReset" Grid.Column="8" Content="Reset" Style="{StaticResource AccBtn}" Padding="5,5"/>
                </Grid>
                <Border Grid.Row="8" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Dynamic contrast" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Button x:Name="DynamicContrastOff" Grid.Column="2" Content="Off" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="DynamicContrastOn" Grid.Column="4" Content="On" Style="{StaticResource OrangeBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Picture mode" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <Button x:Name="PictureModeWeb" Grid.Column="2" Content="Web" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="PictureModeCinema" Grid.Column="4" Content="Cinema" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="PictureModeGame" Grid.Column="6" Content="Game" Style="{StaticResource AccBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
            </Grid></Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="MonitorTab" Header="Monitor" Tag="&#xE7F8;">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Label" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                        <TextBox x:Name="MonitorLabelBox" Grid.Column="2" VerticalAlignment="Center"/>
                        <Button x:Name="MonitorLabelSaveBtn" Grid.Column="4" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                        <Button x:Name="MonitorLabelResetBtn" Grid.Column="6" Content="Reset" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                    <TextBlock x:Name="MonitorIdentityText" Grid.Row="2" Text="Identity: unknown" FontSize="8" Foreground="#606060" TextTrimming="CharacterEllipsis"/>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Input source" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" Margin="0,0,0,8"/>
                        <ComboBox x:Name="InputSourceCombo"/></StackPanel></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Power control" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" Margin="0,0,0,8"/>
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="PowerOffBtn" Content="Off" Style="{StaticResource WarnBtn}" Padding="4,4" FontSize="9"/>
                            <Button x:Name="PowerStandbyBtn" Grid.Column="2" Content="Standby" Style="{StaticResource Btn}" Padding="4,4" FontSize="9"/>
                            <Button x:Name="PowerOnBtn" Grid.Column="4" Content="On" Style="{StaticResource GreenBtn}" Padding="4,4" FontSize="9"/>
                        </Grid></StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><StackPanel Orientation="Horizontal"><TextBlock Text="Volume" FontSize="10" Foreground="#909090"/><CheckBox x:Name="MuteCheckbox" Content="Mute" Margin="8,0,0,0" VerticalAlignment="Center" FontSize="9"/></StackPanel>
                            <TextBlock x:Name="VolumeValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VolumeSlider" Grid.Row="2" Value="50" Tag="#9b59b6" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Sharpness" FontSize="10" Foreground="#909090"/><TextBlock x:Name="SharpnessValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="SharpnessSlider" Grid.Row="2" Value="50" Tag="#3498db" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="ResetColorBtn" Content="Reset Colors" Style="{StaticResource Btn}"/>
                    <Button x:Name="FactoryResetBtn" Grid.Column="2" Content="Factory Reset" Style="{StaticResource WarnBtn}"/>
                </Grid></Border>
                <Button x:Name="AllMonitorsStandbyBtn" Grid.Row="8" Content="All Monitors to Standby" Style="{StaticResource Btn}"/>
                <Border Grid.Row="10" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="PiP / PbP Mode" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                        <Button x:Name="PipPbpOffBtn" Grid.Column="2" Content="Off" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                        <Button x:Name="PipModeBtn" Grid.Column="4" Content="PiP" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                        <Button x:Name="PbpModeBtn" Grid.Column="6" Content="PbP" Style="{StaticResource AccBtn}" Padding="8,4" FontSize="9"/>
                    </Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="Secondary Input" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                        <Button x:Name="PipSecondaryDpBtn" Grid.Column="2" Content="DP" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                        <Button x:Name="PipSecondaryHdmi1Btn" Grid.Column="4" Content="HDMI 1" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                        <Button x:Name="PipSecondaryHdmi2Btn" Grid.Column="6" Content="HDMI 2" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                    </Grid>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="GpuTab" Header="Hardware" Tag="&#xEA86;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="16"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock x:Name="GpuNameText" Text="GPU" FontSize="14" Foreground="#62d891" FontWeight="SemiBold"/>
                        <TextBlock x:Name="GpuStatsText" Text="-- C | -- MHz | -- W" FontSize="10" Foreground="#75869d" Margin="0,3,0,0"/>
                        <TextBlock x:Name="CpuTempText" Text="CPU: -- C" FontSize="10" Foreground="#75869d" Margin="0,2,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock x:Name="GpuTempText" Text="--" FontSize="20" Foreground="#fff" FontWeight="Light"/>
                        <TextBlock Text=" C" FontSize="10" Foreground="#606060" VerticalAlignment="Top" Margin="0,3,0,0"/></StackPanel>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="GPU Utilization" FontSize="9" Foreground="#909090"/><TextBlock x:Name="GpuUtilText" Text="0%" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="GpuUtilBar" Value="0" Foreground="#76b900"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Memory Usage" FontSize="9" Foreground="#909090"/><TextBlock x:Name="MemUsageText" Text="0 / 0 GB" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="MemUtilBar" Value="0" Foreground="#e67e22"/>
                    </StackPanel></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="Fan Speed" FontSize="9" Foreground="#909090"/><TextBlock x:Name="FanSpeedText" Text="0%" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="FanSpeedBar" Value="0" Foreground="#3498db"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Power Draw" FontSize="9" Foreground="#909090"/><TextBlock x:Name="PowerDrawText" Text="0 / 0 W" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="PowerDrawBar" Value="0" Foreground="#e74c3c"/>
                    </StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Digital Vibrance" FontSize="10" Foreground="#909090"/><TextBlock x:Name="VibranceValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VibranceSlider" Grid.Row="2" Value="50" Tag="#76b900" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="7"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Software Gamma" FontSize="10" Foreground="#909090"/><TextBlock x:Name="GammaValue" Text="1.00" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GammaSlider" Grid.Row="2" Value="100" Minimum="50" Maximum="150" Tag="#9b59b6" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="FPS Overlay" FontSize="10" Foreground="#909090"/>
                        <TextBlock x:Name="FpsOverlayStatusText" Text="PresentMon idle" FontSize="8" Foreground="#707070" Margin="0,2,0,0"/></StackPanel>
                    <Button x:Name="FpsOverlayStartBtn" Grid.Column="2" Content="Start" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="FpsOverlayStopBtn" Grid.Column="4" Content="Stop" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="VcpTab" Header="VCP Explorer" Tag="&#xE943;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="60"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="VCP Code:" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                    <TextBox x:Name="VCPCodeBox" Grid.Column="2" Text="0x10" VerticalAlignment="Center"/>
                    <ComboBox x:Name="VCPPresetCombo" Grid.Column="4"/>
                    <Button x:Name="VCPQueryBtn" Grid.Column="6" Content="Query" Style="{StaticResource AccBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="VCP response" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold"/>
                    <TextBox x:Name="VCPResultBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#0c1725" FontFamily="Consolas" FontSize="11" AcceptsReturn="True"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Set Value:" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
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
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ProfileNameBox" Text="My Profile"/>
                    <Button x:Name="SaveProfileBtn" Grid.Column="2" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Saved profiles" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold"/>
                    <ListBox x:Name="ProfilesList" Grid.Row="2" Background="Transparent" BorderThickness="0" Foreground="#e0e0e0"/>
                </Grid></Border>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="LoadProfileBtn" Content="Load" Style="{StaticResource AccBtn}"/>
                    <Button x:Name="DeleteProfileBtn" Grid.Column="2" Content="Delete" Style="{StaticResource WarnBtn}"/>
                </Grid>
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="ExportProfilesBtn" Content="Export Bundle" Style="{StaticResource Btn}"/>
                    <Button x:Name="ImportProfilesBtn" Grid.Column="2" Content="Import Bundle" Style="{StaticResource Btn}"/>
                </Grid>
                <Border Grid.Row="8" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Profile Storage" FontSize="10" Foreground="#909090"/>
                        <TextBlock x:Name="ProfileStorageStatusText" Text="Local" FontSize="8" Foreground="#707070" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                    <Button x:Name="ProfileSyncFolderBtn" Grid.Column="2" Content="Sync Folder" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                    <Button x:Name="ProfileLocalFolderBtn" Grid.Column="4" Content="Use Local" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AppProfileEnabledCheckbox" Content="Per-application profiles" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AppProfileStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AppProfileExeBox" Text="app.exe"/>
                        <Button x:Name="AppProfileCaptureBtn" Grid.Column="2" Content="Capture" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                    </Grid>
                    <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <ComboBox x:Name="AppProfileProfileCombo"/>
                        <CheckBox x:Name="AppProfileRiskyConsentCheckbox" Grid.Column="2" Content="Risky writes" VerticalAlignment="Center" FontSize="9" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                        <Button x:Name="AppProfileAddBtn" Grid.Column="4" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                        <Button x:Name="AppProfileRemoveBtn" Grid.Column="6" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                    <ListBox x:Name="AppProfileRulesList" Grid.Row="6" Height="76" Background="#0c1725" BorderThickness="0" Foreground="#e8eef7" FontSize="11"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="ScheduleTab" Header="Automation" Tag="&#xE823;">
            <Border Background="Transparent" Padding="0"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <CheckBox x:Name="ScheduleEnabledCheckbox" Content="Scheduled profiles" VerticalAlignment="Center"/>
                    <TextBlock x:Name="ScheduleStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="76"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ScheduleTimeBox" Text="21:00" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ScheduleProfileCombo" Grid.Column="2"/>
                    <CheckBox x:Name="ScheduleRiskyConsentCheckbox" Grid.Column="4" Content="Risky writes" VerticalAlignment="Center" FontSize="9" ToolTip="Separate rule-level consent; the target monitor identity must also be unlocked."/>
                    <Button x:Name="ScheduleAddBtn" Grid.Column="6" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="ScheduleRemoveBtn" Grid.Column="8" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Profile schedule" FontSize="10" Foreground="#909090"/>
                    <Border Grid.Row="2" Background="#0c1725" BorderBrush="#26384f" BorderThickness="1" CornerRadius="8" Height="56">
                        <Canvas x:Name="ScheduleTimelineCanvas" ClipToBounds="True"/>
                    </Border>
                    <ListBox x:Name="ScheduleRulesList" Grid.Row="4" Background="#0c1725" BorderThickness="0" Foreground="#e0e0e0" FontSize="11"/>
                </Grid></Border>
                <Border Grid.Row="6" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="IdleDimEnabledCheckbox" Content="Idle dim" VerticalAlignment="Center"/>
                        <TextBlock x:Name="IdleDimStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="IdleDimMinutesBox" Text="10" VerticalAlignment="Center"/>
                        <TextBox x:Name="IdleDimBrightnessBox" Grid.Column="2" Text="20" VerticalAlignment="Center"/>
                        <CheckBox x:Name="IdleDimRestoreCheckbox" Grid.Column="4" Content="Restore" VerticalAlignment="Center"/>
                        <Button x:Name="IdleDimSaveBtn" Grid.Column="6" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="8" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="BatteryProfileEnabledCheckbox" Content="Battery profile" VerticalAlignment="Center"/>
                        <TextBlock x:Name="BatteryProfileStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="BatteryBrightnessBox" Text="35" VerticalAlignment="Center"/>
                        <TextBox x:Name="AcBrightnessBox" Grid.Column="2" Text="75" VerticalAlignment="Center"/>
                        <Button x:Name="BatteryProfileSaveBtn" Grid.Column="4" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem x:Name="SystemTab" Header="System" Tag="&#xE713;">
            <Border Background="Transparent" Padding="0"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Quick links" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Button x:Name="DisplaySettingsBtn" Content="Display" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                        <Button x:Name="ColorMgmtBtn" Grid.Column="2" Content="Color Mgmt" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                        <Button x:Name="GpuControlPanelBtn" Grid.Column="4" Content="GPU Panel" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                    </Grid></StackPanel></Border>
                <Border Grid.Row="2" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><TextBlock Text="Software Gamma R/G/B" FontSize="10" Foreground="#909090"/>
                        <Button x:Name="ResetGammaBtn" Content="Reset" Style="{StaticResource Btn}" Padding="8,2" FontSize="9" HorizontalAlignment="Right"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <StackPanel><TextBlock x:Name="GammaRedValue" Text="1.00" FontSize="9" Foreground="#e85050" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaRedSlider" Value="100" Minimum="50" Maximum="150" Tag="#e85050" Style="{StaticResource Sld}"/></StackPanel>
                        <StackPanel Grid.Column="2"><TextBlock x:Name="GammaGreenValue" Text="1.00" FontSize="9" Foreground="#45c770" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaGreenSlider" Value="100" Minimum="50" Maximum="150" Tag="#45c770" Style="{StaticResource Sld}"/></StackPanel>
                        <StackPanel Grid.Column="4"><TextBlock x:Name="GammaBlueValue" Text="1.00" FontSize="9" Foreground="#4a90e8" HorizontalAlignment="Right" Margin="0,0,0,2"/>
                            <Slider x:Name="GammaBlueSlider" Value="100" Minimum="50" Maximum="150" Tag="#4a90e8" Style="{StaticResource Sld}"/></StackPanel>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="4" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><StackPanel><TextBlock Text="Monitor capabilities" FontSize="12" Foreground="#dce6f3" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <TextBox x:Name="CapabilitiesBox" IsReadOnly="True" TextWrapping="Wrap" Height="70" VerticalScrollBarVisibility="Auto" Background="#0c1725" FontFamily="Consolas" FontSize="10"/>
                </StackPanel></Border>
                <Border Grid.Row="6" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="CapabilitiesDiscoveryEnabledCheckbox" Content="Allow capability discovery" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CapabilitiesSafetyStatusText" Text="Discovery off" FontSize="9" Foreground="#8e9db1" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <CheckBox x:Name="CapabilitiesMaximumCompatibilityCheckbox" Grid.Row="2" Content="Maximum compatibility (never request capability strings)" Foreground="#b8c5d6"/>
                    <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="A pending probe is recorded before every firmware call." Foreground="#75869d" FontSize="9" VerticalAlignment="Center"/>
                        <Button x:Name="CapabilitiesExcludeCurrentBtn" Grid.Column="2" Content="Exclude selected" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                        <Button x:Name="CapabilitiesClearExclusionsBtn" Grid.Column="4" Content="Clear exclusions" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="8" Background="#101b2b" BorderBrush="#6b4b2b" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="RiskyVcpEnabledCheckbox" Content="Enable risky VCP writes for selected display" VerticalAlignment="Center"/>
                        <TextBlock x:Name="RiskyVcpStatusText" Text="Disabled" FontSize="9" Foreground="#ffd18a" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <TextBlock Grid.Row="2" Text="Power, input, reset, PiP/PbP, and arbitrary writes require this per-identity unlock plus confirmation for every direct command." TextWrapping="Wrap" Foreground="#aebbd0" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AutomationBridgeEnabledCheckbox" Content="Local Automation Bridge" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AutomationBridgeStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="64"/><ColumnDefinition Width="6"/><ColumnDefinition Width="74"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AutomationBridgeBindBox" Text="127.0.0.1" VerticalAlignment="Center" FontSize="9"/>
                        <TextBox x:Name="AutomationBridgePortBox" Grid.Column="2" Text="34291" VerticalAlignment="Center" FontSize="9"/>
                        <PasswordBox x:Name="AutomationBridgeKeyBox" Grid.Column="4" Password="" VerticalAlignment="Center" FontSize="9"/>
                        <Button x:Name="AutomationBridgeSaveBtn" Grid.Column="6" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                </Grid></Border>
                <Border Grid.Row="12" Background="#101b2b" BorderBrush="#26384f" BorderThickness="1" CornerRadius="10" Padding="14"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock Text="DDC Compatibility Report" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                        <Button x:Name="DdcReportGenerateBtn" Grid.Column="2" Content="Build" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                        <Button x:Name="DdcReportCopyBtn" Grid.Column="4" Content="Copy" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                    <TextBox x:Name="DdcReportBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" Height="180" VerticalScrollBarVisibility="Auto" Background="#0c1725" FontFamily="Consolas" FontSize="10" AcceptsReturn="True"/>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
    </TabControl>
    <Border Grid.Row="2" Grid.ColumnSpan="2" Background="#091320" BorderBrush="#1d2b3d" BorderThickness="0,1,0,0" Padding="18,0"><Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="7" Height="7" Fill="#42c77a" Margin="0,0,8,0"/>
            <TextBlock x:Name="StatusText" Text="Ready" FontSize="10" Foreground="#8393a8"/>
        </StackPanel>
        <TextBlock x:Name="AutoModeText" Text="" FontSize="10" Foreground="#ffd18a" HorizontalAlignment="Right" VerticalAlignment="Center"/>
    </Grid></Border>
</Grid>
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
$appTitleText = $window.FindName("AppTitleText"); $appSubtitleText = $window.FindName("AppSubtitleText")
$displayTab = $window.FindName("DisplayTab"); $monitorTab = $window.FindName("MonitorTab"); $vcpTab = $window.FindName("VcpTab")
$profilesTab = $window.FindName("ProfilesTab"); $scheduleTab = $window.FindName("ScheduleTab"); $systemTab = $window.FindName("SystemTab")
$monitorCanvas = $window.FindName("MonitorCanvas"); $selectedMonitorName = $window.FindName("SelectedMonitorName")
$selectedMonitorRes = $window.FindName("SelectedMonitorRes"); $selectedMonitorInfo = $window.FindName("SelectedMonitorInfo")
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
$capabilitiesDiscoveryEnabledCheckbox = $window.FindName("CapabilitiesDiscoveryEnabledCheckbox"); $capabilitiesMaximumCompatibilityCheckbox = $window.FindName("CapabilitiesMaximumCompatibilityCheckbox")
$capabilitiesSafetyStatusText = $window.FindName("CapabilitiesSafetyStatusText"); $capabilitiesExcludeCurrentBtn = $window.FindName("CapabilitiesExcludeCurrentBtn"); $capabilitiesClearExclusionsBtn = $window.FindName("CapabilitiesClearExclusionsBtn")
$riskyVcpEnabledCheckbox = $window.FindName("RiskyVcpEnabledCheckbox"); $riskyVcpStatusText = $window.FindName("RiskyVcpStatusText")
$automationBridgeEnabledCheckbox = $window.FindName("AutomationBridgeEnabledCheckbox"); $automationBridgeStatusText = $window.FindName("AutomationBridgeStatusText")
$automationBridgeBindBox = $window.FindName("AutomationBridgeBindBox"); $automationBridgePortBox = $window.FindName("AutomationBridgePortBox")
$automationBridgeKeyBox = $window.FindName("AutomationBridgeKeyBox"); $automationBridgeSaveBtn = $window.FindName("AutomationBridgeSaveBtn")
$ddcReportGenerateBtn = $window.FindName("DdcReportGenerateBtn"); $ddcReportCopyBtn = $window.FindName("DdcReportCopyBtn")
$statusText = $window.FindName("StatusText"); $autoModeText = $window.FindName("AutoModeText")

function Update-Status { param([string]$Message); $statusText.Text = $Message }
if ($script:PendingStatusMessage) { Update-Status $script:PendingStatusMessage; $script:PendingStatusMessage = "" }
Initialize-LocalizationAndAccessibility
Start-DdcWriteResultTimer

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
        $border = New-Object System.Windows.Controls.Border
        $border.Width = $w; $border.Height = $h; $border.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $border.BorderThickness = New-Object System.Windows.Thickness(2); $border.Cursor = [System.Windows.Input.Cursors]::Hand
        $border.Tag = [int]($mon.Index - 1)
        if ($isSelected) {
            $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(23,40,66))
            $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(76,141,255))
        } else {
            $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(16,27,43))
            $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(42,58,80))
        }
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = if ($w -ge 110) { "$($mon.Index)`n$(Get-MonitorDisplayLabel -Monitor $mon)" } else { $mon.Index.ToString() }
        $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(232,238,247))
        $tb.FontSize = if ($w -ge 110) { 11 } else { 12 }
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.TextAlignment = [System.Windows.TextAlignment]::Center
        $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
        $border.Child = $tb
        [System.Windows.Controls.Canvas]::SetLeft($border, $x); [System.Windows.Controls.Canvas]::SetTop($border, $y)
        $border.Add_MouseLeftButtonDown([System.Windows.Input.MouseButtonEventHandler]{ param($sender,$args); $script:CurrentMonitorIndex = [int]$sender.Tag; Draw-MonitorLayout; Load-MonitorSettings })
        $border.Add_MouseEnter([System.Windows.Input.MouseEventHandler]{ param($sender,$args); if ([int]$sender.Tag -ne $script:CurrentMonitorIndex) { $sender.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(24,42,64)) } })
        $border.Add_MouseLeave([System.Windows.Input.MouseEventHandler]{ param($sender,$args); if ([int]$sender.Tag -ne $script:CurrentMonitorIndex) { $sender.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(16,27,43)) } })
        $monitorCanvas.Children.Add($border) | Out-Null
    }
    if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        $selectedMonitorName.Text = "$($mon.Index): $(Get-MonitorDisplayLabel -Monitor $mon)"
        $selectedMonitorRes.Text = "$($mon.Width) x $($mon.Height) @ $($mon.RefreshRate)Hz"
        $selectedMonitorInfo.Text = "$($mon.DeviceName)$(if ($mon.IsPrimary) { ' (Primary)' } else { '' })"
        Update-MonitorIdentityControls
    }
}

function Load-MonitorSettings {
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; $h = $mon.Handle
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
                Update-Status "$(Get-MonitorDisplayLabel -Monitor $mon) via WMI"; Update-TrayPopupState; Update-TrayIconText
                return
            }
        }
        if ($h -eq [IntPtr]::Zero) {
            Update-Status "$(Get-MonitorDisplayLabel -Monitor $mon)"
            Update-TrayPopupState
            Update-TrayIconText
            return
        }
    } finally {
        $script:UpdatingUI = $false
    }
    Start-MonitorSettingsWorker -Handle $h -MonitorIndex $script:CurrentMonitorIndex -MonitorName $mon.Name
}

function Refresh-Monitors {
    $previousIdentity = ""
    if ($script:PhysicalMonitors.Count -gt 0 -and $script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $previousIdentity = [string]$script:PhysicalMonitors[$script:CurrentMonitorIndex].IdentityKey
    }
    Get-Monitors
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
}

function Invoke-DelayedMonitorSettingsRefresh {
    param([int]$DelayMs = 750, [int]$MonitorIndex = $script:CurrentMonitorIndex)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(100, $DelayMs))
    $targetIndex = $MonitorIndex
    $timer.Add_Tick({
        param($sender, $args)
        $sender.Stop()
        $script:DeferredRefreshTimers = @($script:DeferredRefreshTimers | Where-Object { $_ -ne $sender })
        if ($targetIndex -eq $script:CurrentMonitorIndex -and $script:PhysicalMonitors.Count -gt $targetIndex) {
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

function New-ProfileSettingsObject {
    param($Monitor)
    return [PSCustomObject]@{
        IdentityKey = if ($Monitor) { [string]$Monitor.IdentityKey } else { "" }
        MonitorLabel = if ($Monitor) { Get-MonitorDisplayLabel -Monitor $Monitor } else { "" }
        MonitorName = if ($Monitor) { [string]$Monitor.Name } else { "" }
        DevicePath = if ($Monitor) { [string]$Monitor.DevicePath } else { "" }
        Brightness = [int]$brightnessSlider.Value
        Contrast = [int]$contrastSlider.Value
        Red = [int]$redSlider.Value
        Green = [int]$greenSlider.Value
        Blue = [int]$blueSlider.Value
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
    $name = if (Get-ProfilePropertyValue -Object $Profile -Property "Name" -Default "") { [string]$Profile.Name } else { $FallbackName }
    $topSetting = [PSCustomObject]@{
        IdentityKey = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorIdentityKey" -Default "")
        MonitorLabel = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorLabel" -Default "")
        MonitorName = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorName" -Default "")
        DevicePath = [string](Get-ProfilePropertyValue -Object $Profile -Property "MonitorDevicePath" -Default "")
        Brightness = Get-ProfileIntValue -Object $Profile -Property "Brightness" -Default 50
        Contrast = Get-ProfileIntValue -Object $Profile -Property "Contrast" -Default 50
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
            Brightness = Get-ProfileIntValue -Object $setting -Property "Brightness" -Default $topSetting.Brightness
            Contrast = Get-ProfileIntValue -Object $setting -Property "Contrast" -Default $topSetting.Contrast
            Red = Get-ProfileIntValue -Object $setting -Property "Red" -Default $topSetting.Red
            Green = Get-ProfileIntValue -Object $setting -Property "Green" -Default $topSetting.Green
            Blue = Get-ProfileIntValue -Object $setting -Property "Blue" -Default $topSetting.Blue
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
    $profile = Read-JsonFileSafely -Path $path -Label "Profile '$safeName'"
    if ($null -eq $profile) { return $null }
    try {
        $schema = if ($profile.PSObject.Properties.Name -contains "SchemaVersion") { [int]$profile.SchemaVersion } else { 1 }
        $converted = ConvertTo-CurrentProfileSchema -Profile $profile -FallbackName $safeName
        if ($schema -lt $script:ProfileSchemaVersion) {
            Save-ProfileObject -Profile $converted | Out-Null
            Update-Status "Migrated profile '$safeName' to schema v$script:ProfileSchemaVersion"
        }
        return $converted
    } catch {
        $quarantinePath = Move-CorruptJsonFile -Path $path
        $leaf = if ($quarantinePath) { Split-Path -Path $quarantinePath -Leaf } else { "quarantine failed" }
        Update-Status "Profile '$safeName' invalid; quarantined to $leaf"
        $backupPath = "$path.bak"
        if (Test-Path -LiteralPath $backupPath) {
            $backupProfile = Read-JsonFileSafely -Path $backupPath -Label "Profile '$safeName' backup"
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
            $profile = Read-ProfileObject -Name $profileFile.BaseName
            if ($null -eq $profile) { continue }
            $safeName = $profileFile.BaseName
            $validation = Test-ImportedProfileObject -RawProfile $profile -ExpectedName $safeName
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
            AppVersion = "3.34.0"
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

function Set-ProfileStorageRoot {
    param([string]$Path, [string]$Mode = "Sync")
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Update-Status "Profile storage path is empty"
        return $false
    }
    try {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
        $fullPath = [System.IO.Path]::GetFullPath($expandedPath)
        if (-not (Test-Path -LiteralPath $fullPath)) { New-Item -ItemType Directory -Path $fullPath -Force | Out-Null }
        $script:ProfilesPath = $fullPath
        $script:ProfileStorageMode = $Mode
        $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
        $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
        $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
        $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
        $script:MonitorIdentitySettingsPath = Join-Path $script:ProfilesPath "monitor-identities.json"
        $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
        return $true
    } catch {
        Update-Status "Profile storage failed: $($_.Exception.Message)"
        return $false
    }
}

function Save-ProfileStorageSettings {
    if (-not (Test-Path -LiteralPath $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
    $payload = [PSCustomObject]@{
        Mode = $script:ProfileStorageMode
        ProfilePath = $script:ProfilesPath
        UpdatedAt = (Get-Date).ToString("o")
    }
    Write-JsonFileSafely -Path $script:ProfileStorageSettingsPath -Data $payload -Depth 4 | Out-Null
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
    $profileStorageStatusText.Text = "$mode - $script:ProfilesPath"
    $profileStorageStatusText.ToolTip = $script:ProfilesPath
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
    $pid = [uint32]0
    [MonitorAPI]::GetWindowThreadProcessId($hwnd, [ref]$pid) | Out-Null
    if ($pid -eq 0) { return $null }
    try {
        $process = Get-Process -Id $pid -ErrorAction Stop
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
        $data = Read-JsonFileSafely -Path $script:AppProfileRulesPath -Label "App profile rules"
        if ($null -eq $data) { return }
        $script:AppProfileEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $exe = Normalize-AppExeName -ExeName ([string]$rule.Exe)
            $profile = ([string]$rule.Profile).Trim()
            $allowRiskyVcp = $rule.PSObject.Properties.Name -contains "AllowRiskyVcp" -and [bool]$rule.AllowRiskyVcp
            if ($exe -and $profile) { $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profile; AllowRiskyVcp = $allowRiskyVcp } }
        }
    } catch {
        Update-Status "App profile rules could not be loaded"
    }
}

function Save-AppProfileRules {
    $payload = [PSCustomObject]@{
        Enabled = [bool]$script:AppProfileEnabled
        Rules = @($script:AppProfileRules)
    }
    Write-JsonFileSafely -Path $script:AppProfileRulesPath -Data $payload -Depth 4 | Out-Null
}

function Update-ProfileCombo {
    param($Combo)
    if ($null -eq $Combo) { return }
    $selected = if ($Combo.SelectedItem) { [string]$Combo.SelectedItem } else { $null }
    $Combo.Items.Clear()
    foreach ($profile in @($profilesList.Items)) { $Combo.Items.Add([string]$profile) | Out-Null }
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
                $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$values.Brightness) -Backend "WMI"
                $wmiIncluded = $true
            }
            continue
        }
        foreach ($codeValue in $codeValues) {
            if (Test-MonitorSupportsVcpValue -Monitor $monitor -Code ([int]$codeValue.Code) -Value ([int]$codeValue.Value)) {
                $operations += Get-VcpWriteOperation -Monitor $monitor -Code ([int]$codeValue.Code) -Value ([uint32]$codeValue.Value)
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
        $brightnessSlider.Value = $plan.Values.Brightness; $brightnessValue.Text = $plan.Values.Brightness
        $contrastSlider.Value = $plan.Values.Contrast; $contrastValue.Text = $plan.Values.Contrast
        $redSlider.Value = $plan.Values.Red; $redValue.Text = $plan.Values.Red
        $greenSlider.Value = $plan.Values.Green; $greenValue.Text = $plan.Values.Green
        $blueSlider.Value = $plan.Values.Blue; $blueValue.Text = $plan.Values.Blue
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
    $axisBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    $tickBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#505050"))
    $textBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#909090"))
    $markerBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#3498db"))

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
        $marker.Stroke = [System.Windows.Media.Brushes]::White; $marker.StrokeThickness = 1
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
        $data = Read-JsonFileSafely -Path $script:ProfileScheduleRulesPath -Label "Profile schedule"
        if ($null -eq $data) { return }
        $script:ProfileScheduleEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $time = Normalize-ScheduleTime -TimeText ([string]$rule.Time)
            $profile = ([string]$rule.Profile).Trim()
            $allowRiskyVcp = $rule.PSObject.Properties.Name -contains "AllowRiskyVcp" -and [bool]$rule.AllowRiskyVcp
            if ($time -and $profile) { $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profile; AllowRiskyVcp = $allowRiskyVcp } }
        }
    } catch {
        Update-Status "Profile schedule could not be loaded"
    }
}

function Save-ProfileSchedules {
    $payload = [PSCustomObject]@{
        Enabled = [bool]$script:ProfileScheduleEnabled
        Rules = @($script:ProfileSchedules | Sort-Object -Property Time)
    }
    Write-JsonFileSafely -Path $script:ProfileScheduleRulesPath -Data $payload -Depth 4 | Out-Null
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
    $ordered = @($script:ProfileSchedules | Sort-Object @{ Expression = { Get-ScheduleMinutes -TimeText $_.Time } })
    $due = @($ordered | Where-Object { (Get-ScheduleMinutes -TimeText $_.Time) -le $nowMinutes })
    $rule = if ($due.Count -gt 0) { $due[-1] } else { $ordered[-1] }
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
        $data = Read-JsonFileSafely -Path $script:IdleDimSettingsPath -Label "Idle dim settings"
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
    $payload = [PSCustomObject]@{
        Enabled = [bool]$script:IdleDimEnabled
        Minutes = [int]$script:IdleDimMinutes
        Brightness = [int]$script:IdleDimBrightness
        RestoreOnActivity = [bool]$script:IdleDimRestoreOnActivity
    }
    Write-JsonFileSafely -Path $script:IdleDimSettingsPath -Data $payload -Depth 4 | Out-Null
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
        $script:IdleDimPreviousBrightness = [int]$brightnessSlider.Value
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$script:IdleDimBrightness) -Force
        $script:UpdatingUI = $true
        try {
            $brightnessSlider.Value = $script:IdleDimBrightness
            $brightnessValue.Text = ([int]$script:IdleDimBrightness).ToString()
        } finally {
            $script:UpdatingUI = $false
        }
        $script:IdleDimActive = $true
        Update-IdleDimControls
        Update-TrayPopupState
        Update-TrayIconText
        Update-Status "Idle dim active"
    } elseif ($script:IdleDimActive -and $idleSeconds -lt 5) {
        if ($script:IdleDimRestoreOnActivity -and $null -ne $script:IdleDimPreviousBrightness) {
            Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value ([uint32]$script:IdleDimPreviousBrightness) -Force
            $script:UpdatingUI = $true
            try {
                $brightnessSlider.Value = $script:IdleDimPreviousBrightness
                $brightnessValue.Text = ([int]$script:IdleDimPreviousBrightness).ToString()
            } finally {
                $script:UpdatingUI = $false
            }
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
        $data = Read-JsonFileSafely -Path $script:BatteryProfileSettingsPath -Label "Battery profile settings"
        if ($null -eq $data) { return }
        $script:BatteryProfileEnabled = [bool]$data.Enabled
        $script:BatteryBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.BatteryBrightness))
        $script:AcBrightness = [Math]::Max(0, [Math]::Min(100, [int]$data.AcBrightness))
    } catch {
        Update-Status "Battery profile settings could not be loaded"
    }
}

function Save-BatteryProfileSettings {
    $payload = @{
        Enabled = [bool]$script:BatteryProfileEnabled
        BatteryBrightness = [int]$script:BatteryBrightness
        AcBrightness = [int]$script:AcBrightness
    }
    Write-JsonFileSafely -Path $script:BatteryProfileSettingsPath -Data $payload -Depth 4 | Out-Null
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
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $script:BatteryBrightness -Force
        Update-Status "Battery profile: $($script:BatteryBrightness)%"
        $batteryProfileStatusText.Text = "Battery"
    } elseif ($status -eq "Online") {
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $script:AcBrightness -Force
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
    $brightness = [int]$brightnessSlider.Value
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
    <Border Background="#111111" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="12">
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
                <TextBlock x:Name="TrayMonitorText" Text="Monitor" FontSize="12" Foreground="#ffffff" FontFamily="Segoe UI" FontWeight="SemiBold"/>
                <TextBlock x:Name="TrayBrightnessValue" Text="50" FontSize="12" Foreground="#f5b800" FontFamily="Segoe UI" FontWeight="SemiBold" HorizontalAlignment="Right"/>
            </Grid>
            <Slider x:Name="TrayBrightnessSlider" Grid.Row="2" Minimum="0" Maximum="100" Value="50" Height="24"/>
            <CheckBox x:Name="TrayLinkCheckbox" Grid.Row="4" Content="Link monitors" Foreground="#d0d0d0" FontFamily="Segoe UI" FontSize="11"/>
            <Grid Grid.Row="6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="TrayOpenButton" Content="Open" Padding="8,5" Background="#1a1a1a" Foreground="#e0e0e0" BorderBrush="#333333"/>
                <Button x:Name="TrayProfileButton" Grid.Column="2" Content="Profile" Padding="8,5" Background="#0078d4" Foreground="#ffffff" BorderBrush="#0078d4"/>
                <Button x:Name="TrayHideButton" Grid.Column="4" Content="Hide" Padding="8,5" Background="#1a1a1a" Foreground="#e0e0e0" BorderBrush="#333333"/>
            </Grid>
        </Grid>
    </Border>
</Window>
"@
    $trayReader = New-Object System.Xml.XmlNodeReader $trayPopupXaml
    $script:TrayPopup = [System.Windows.Markup.XamlReader]::Load($trayReader)
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
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $value
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
    $refreshItem.Add_Click({ Refresh-Monitors })
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
        $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(230,0,120,212))
        $border.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $mon.Index.ToString(); $tb.FontSize = 44; $tb.FontWeight = "Bold"
        $tb.Foreground = [System.Windows.Media.Brushes]::White; $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
        $border.Child = $tb; $overlay.Content = $border; $overlay.Show()
        $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromSeconds(2)
        $currentOverlay = $overlay; $currentTimer = $timer
        $timer.Add_Tick({ $currentTimer.Stop(); $currentOverlay.Close() }); $timer.Start()
    }
}

function Initialize-PresentMon {
    if ($script:PresentMonPath -and (Test-Path $script:PresentMonPath)) { return $true }
    $command = Get-Command PresentMon.exe, PresentMon64.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $script:PresentMonPath = $command.Source; return $true }
    $candidatePaths = @(
        (Join-Path $PSScriptRoot "PresentMon.exe"),
        (Join-Path $PSScriptRoot "PresentMon64.exe"),
        "${env:ProgramFiles}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles}\Intel\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\PresentMon\PresentMon.exe",
        "${env:ProgramFiles(x86)}\Intel\PresentMon\PresentMon.exe"
    )
    foreach ($path in $candidatePaths) {
        if ($path -and (Test-Path $path)) { $script:PresentMonPath = $path; return $true }
    }
    return $false
}

function Get-PresentMonFpsSnapshot {
    if (-not (Initialize-PresentMon)) { return @{ Success = $false; Text = "FPS --"; Status = "PresentMon.exe not found" } }
    try {
        $output = & $script:PresentMonPath --output_stdout --no_console_stats --timed 1 --terminate_after_timed --stop_existing_session 2>$null
        $csvLines = @($output) | Where-Object { $_ -and $_.Contains(",") }
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
    if (-not (Initialize-PresentMon)) {
        $fpsOverlayStatusText.Text = "PresentMon.exe not found"
        Update-Status "PresentMon.exe not found"
        return
    }
    if (-not $script:FpsOverlayWindow) {
        $overlay = New-Object System.Windows.Window
        $overlay.WindowStyle = "None"; $overlay.AllowsTransparency = $true; $overlay.Background = [System.Windows.Media.Brushes]::Transparent
        $overlay.Topmost = $true; $overlay.ShowInTaskbar = $false; $overlay.ResizeMode = "NoResize"; $overlay.Width = 190; $overlay.Height = 74
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $overlay.Left = $workArea.Right - 210; $overlay.Top = $workArea.Top + 20
        $border = New-Object System.Windows.Controls.Border
        $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(230, 10, 10, 10))
        $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(118, 185, 0))
        $border.BorderThickness = New-Object System.Windows.Thickness(1); $border.CornerRadius = New-Object System.Windows.CornerRadius(6); $border.Padding = New-Object System.Windows.Thickness(12, 8, 12, 8)
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = "FPS --"; $text.Foreground = [System.Windows.Media.Brushes]::White; $text.FontFamily = "Segoe UI"; $text.FontSize = 14; $text.FontWeight = "SemiBold"
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
$refreshBtn.Add_Click({ Refresh-Monitors }); $identifyBtn.Add_Click({ Show-IdentifyOverlays })
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

$brightnessSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$brightnessSlider.Value; $brightnessValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $v; Update-TrayPopupState; Update-TrayIconText })
$contrastSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$contrastSlider.Value; $contrastValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value $v })
$redSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$redSlider.Value; $redValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_RED_GAIN) -Value $v })
$greenSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$greenSlider.Value; $greenValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_GREEN_GAIN) -Value $v })
$blueSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$blueSlider.Value; $blueValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BLUE_GAIN) -Value $v })
$volumeSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$volumeSlider.Value; $volumeValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_VOLUME) -Value $v })
$sharpnessSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$sharpnessSlider.Value; $sharpnessValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_SHARPNESS) -Value $v })
$muteCheckbox.Add_Checked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 1 }); $muteCheckbox.Add_Unchecked({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_MUTE) -Value 2 })

$colorTempWarm.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_5000K); Update-Status "Color: 5000K (Warm)" })
$colorTemp6500.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_6500K); Update-Status "Color: 6500K" })
$colorTempCool.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_9300K); Update-Status "Color: 9300K (Cool)" })
$colorTempSRGB.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_COLOR_PRESET) -Value ([MonitorAPI]::COLOR_PRESET_SRGB); Update-Status "Color: sRGB" })

$dynamicContrastOff.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_STANDARD); Update-Status "Dynamic contrast off" })
$dynamicContrastOn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_DYNAMIC_CONTRAST); Update-Status "Dynamic contrast on" })
$pictureModeWeb.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_PRODUCTIVITY); Update-Status "Picture mode: Web" })
$pictureModeCinema.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_MOVIE); Update-Status "Picture mode: Cinema" })
$pictureModeGame.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_DISPLAY_MODE) -Value ([MonitorAPI]::DISPLAY_MODE_GAMES); Update-Status "Picture mode: Game" })

$presetDay.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 80 -Force; Set-GammaRamp -Gamma 1.0; $script:UpdatingUI = $true; $brightnessSlider.Value = 80; $brightnessValue.Text = "80"; $script:UpdatingUI = $false; Update-Status "Day Mode" })
$presetNight.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 40 -Force; Set-GammaRamp -Gamma 1.0 -RedMult 1.0 -GreenMult 0.9 -BlueMult 0.75; $script:UpdatingUI = $true; $brightnessSlider.Value = 40; $brightnessValue.Text = "40"; $script:UpdatingUI = $false; Update-Status "Night Mode" })
$presetAutoMode.Add_Click({
    $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher
    $script:AutoModeEnabled = -not $script:AutoModeEnabled
    if ($script:AutoModeEnabled) {
        $s = Apply-TimeBasedSettings; $autoModeText.Text = "Auto: $($s.Mode)"; $script:UpdatingUI = $true; $brightnessSlider.Value = $s.Brightness; $brightnessValue.Text = $s.Brightness; $script:UpdatingUI = $false
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
$presetReset.Add_Click({ $script:AutoModeEnabled = $false; $script:AmbientLightEnabled = $false; Start-AmbientLightWatcher; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 50 -Force; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value 50 -Force; Set-GammaRamp -Gamma 1.0; Load-MonitorSettings; Update-Status "Reset" })

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
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { $vcpResultBox.Text = "No DDC/CI"; return }
    try {
        $code = ConvertTo-VcpCode -Text $vcpCodeBox.Text
        if ($null -eq $code) { $vcpResultBox.Text = "Invalid VCP code"; return }
        Start-VcpReadWorker -Handle $mon.Handle -Codes @($code) -Mode "Query" -MonitorName $mon.Name -ReadRetries $script:DdcReadRetryCount
    } catch { $vcpResultBox.Text = "Error: $_" }
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
    Start-VcpReadWorker -Handle $mon.Handle -Codes $codes -Mode "Scan" -MonitorName $mon.Name -ReadRetries $script:DdcScanRetryCount
})

$saveProfileBtn.Add_Click({
    $name = $profileNameBox.Text.Trim(); if ([string]::IsNullOrEmpty($name)) { return }
    $profile = New-ProfileObject -Name $name
    if (Save-ProfileObject -Profile $profile) { Update-ProfilesList; Update-Status "Saved '$name'" }
})
$loadProfileBtn.Add_Click({
    if ($profilesList.SelectedItem -eq $null) { return }
    Apply-ProfileByName -Name ([string]$profilesList.SelectedItem) | Out-Null
})
$deleteProfileBtn.Add_Click({
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
    $dialog.SelectedPath = if (Test-Path $script:ProfilesPath) { $script:ProfilesPath } else { $script:DefaultProfilesPath }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if (Set-ProfileStorageRoot -Path $dialog.SelectedPath -Mode "Sync") {
            Save-ProfileStorageSettings
            Reload-ProfileStorageState
            Update-Status "Profile sync folder: $(Split-Path -Path $script:ProfilesPath -Leaf)"
        }
    }
})
$profileLocalFolderBtn.Add_Click({
    if (Set-ProfileStorageRoot -Path $script:DefaultProfilesPath -Mode "Local") {
        Save-ProfileStorageSettings
        Reload-ProfileStorageState
        Update-Status "Profile storage: local"
    }
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
    $profile = if ($appProfileProfileCombo.SelectedItem) { [string]$appProfileProfileCombo.SelectedItem } else { "" }
    if (-not $exe -or -not $profile) { Update-Status "Choose an app and profile"; return }
    $allowRiskyVcp = [bool]$appProfileRiskyConsentCheckbox.IsChecked
    if ($allowRiskyVcp -and -not (Confirm-AutomationRuleRiskyWriteConsent -RuleLabel "$exe -> $profile")) {
        Update-Status "Application rule not added"
        return
    }
    $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Exe -ne $exe })
    $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profile; AllowRiskyVcp = $allowRiskyVcp }
    Save-AppProfileRules
    Update-AppProfileControls
    Update-Status "Mapped $exe to '$profile'$(if ($allowRiskyVcp) { ' with risky-write consent' } else { '' })"
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
    $profile = if ($scheduleProfileCombo.SelectedItem) { [string]$scheduleProfileCombo.SelectedItem } else { "" }
    if (-not $time -or -not $profile) { Update-Status "Use HH:mm and choose a profile"; return }
    $allowRiskyVcp = [bool]$scheduleRiskyConsentCheckbox.IsChecked
    if ($allowRiskyVcp -and -not (Confirm-AutomationRuleRiskyWriteConsent -RuleLabel "$time -> $profile")) {
        Update-Status "Schedule rule not added"
        return
    }
    $script:ProfileSchedules = @($script:ProfileSchedules | Where-Object { $_.Time -ne $time })
    $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profile; AllowRiskyVcp = $allowRiskyVcp }
    Save-ProfileSchedules
    Update-ScheduleControls
    Update-Status "Scheduled $profile at $time$(if ($allowRiskyVcp) { ' with risky-write consent' } else { '' })"
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
Initialize-WmiBrightness; Load-MonitorIdentitySettings; Import-CapabilitySafetyState; Import-VcpWriteSafetyState; Get-Monitors; Initialize-GPU; Initialize-CpuMonitor; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList
Load-AppProfileRules; Update-AppProfileControls; Start-AppProfileWatcher
Load-ProfileSchedules; Update-ScheduleControls; Start-ProfileScheduleWatcher
Load-IdleDimSettings; Update-IdleDimControls; Start-IdleDimWatcher
Load-BatteryProfileSettings; Update-BatteryProfileControls; Start-BatteryProfileWatcher
Load-AutomationBridgeSettings; Update-AutomationBridgeControls; Start-AutomationBridge
Update-ProfileStorageControls
Sync-CapabilitySafetyUi
Sync-VcpWriteSafetyUi
if (-not ($script:HasNvidia -or $script:HasAmd -or $script:HasCpuTempMonitor)) { $gpuTab.Visibility = "Collapsed" } else {
    $script:GpuTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:GpuTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:GpuTimer.Add_Tick({ Update-GpuStats }); $script:GpuTimer.Start(); Update-GpuStats
}

Initialize-TrayIcon

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

$window.Add_Closed({ if ($script:GpuTimer) { $script:GpuTimer.Stop() }; if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; if ($script:AmbientLightTimer) { $script:AmbientLightTimer.Stop() }; if ($script:AppProfileTimer) { $script:AppProfileTimer.Stop() }; if ($script:AppProfileCaptureTimer) { $script:AppProfileCaptureTimer.Stop() }; if ($script:ProfileScheduleTimer) { $script:ProfileScheduleTimer.Stop() }; if ($script:IdleDimTimer) { $script:IdleDimTimer.Stop() }; if ($script:BatteryProfileTimer) { $script:BatteryProfileTimer.Stop() }; if ($script:FpsOverlayTimer) { $script:FpsOverlayTimer.Stop() }; if ($script:DdcWriteResultTimer) { $script:DdcWriteResultTimer.Stop() }; foreach ($timer in @($script:DeferredRefreshTimers)) { try { $timer.Stop() } catch {} }; $script:DeferredRefreshTimers = @(); Stop-AutomationBridge; Stop-VcpWorker -Cancel; Stop-MonitorSettingsWorker -Cancel; Stop-CapabilitiesWorker -Cancel; Stop-DdcReportWorker -Cancel
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
