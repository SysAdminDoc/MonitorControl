<#
.SYNOPSIS
    MonitorControl Pro v3.18.0 - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version: 3.18.0 - Enhanced with cloud-sync profile storage
#>

param([switch]$StartMinimized, [string]$LoadProfile)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.IO.Compression.FileSystem

$nativeCode = @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;

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

$script:PhysicalMonitors = @()
$script:CurrentMonitorIndex = 0
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
$script:DefaultProfilesPath = "$env:APPDATA\MonitorControlPro"
$script:ProfileStorageSettingsPath = Join-Path $script:DefaultProfilesPath "profile-storage.json"
$script:ProfilesPath = $script:DefaultProfilesPath
$script:ProfileStorageMode = "Local"
if (-not (Test-Path $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
if (Test-Path $script:ProfileStorageSettingsPath) {
    try {
        $profileStorage = Get-Content -Path $script:ProfileStorageSettingsPath -Raw | ConvertFrom-Json
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
$script:ProfileSchemaVersion = 2
$script:ProfileBundleSchemaVersion = 1
$script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
$script:ProfileMetadataFiles = @("app-profile-rules.json", "profile-schedules.json", "idle-dim.json", "battery-profile.json", "profile-storage.json")
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

$script:VCPCodeDescriptions = @{
    0x04 = "Factory Reset"; 0x08 = "Reset Color"; 0x10 = "Brightness"; 0x12 = "Contrast"
    0x14 = "Color Preset"; 0x16 = "Red Gain"; 0x18 = "Green Gain"; 0x1A = "Blue Gain"
    0x60 = "Input Source"; 0x62 = "Volume"; 0x72 = "Gamma"; 0x87 = "Sharpness"; 0x8D = "Mute"
    0xC0 = "Display Usage Time"; 0xC6 = "Application Enable Key"; 0xCA = "OSD/Button Control"; 0xCC = "OSD Language"
    0xCD = "Status Indicators / LED"; 0xD6 = "Power Mode"; 0xD7 = "Aux Power Output"; 0xDC = "Display Mode"; 0xDF = "VCP Version"
    0xE8 = "Secondary Input Source"; 0xE9 = "PiP/PbP Mode"
}

function Get-Monitors {
    $script:PhysicalMonitors = @()
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
                        $capabilities = ""
                        try {
                            $capLen = [uint32]0
                            if ([MonitorAPI]::GetCapabilitiesStringLength($pm.hPhysicalMonitor, [ref]$capLen) -and $capLen -gt 0) {
                                $capStr = New-Object System.Text.StringBuilder -ArgumentList ([int]$capLen)
                                if ([MonitorAPI]::CapabilitiesRequestAndCapabilitiesReply($pm.hPhysicalMonitor, $capStr, $capLen)) { $capabilities = $capStr.ToString() }
                            }
                        } catch {}
                        $script:PhysicalMonitors += [PSCustomObject]@{
                            Handle = $pm.hPhysicalMonitor; HMonitor = $hMonitor; Name = $name; Index = $monitorIndex
                            DeviceName = $monInfo.DeviceName; Width = $devMode.dmPelsWidth; Height = $devMode.dmPelsHeight
                            RefreshRate = $devMode.dmDisplayFrequency; IsPrimary = ($monInfo.Flags -band [MonitorAPI]::MONITORINFOF_PRIMARY) -ne 0
                            Left = $monInfo.Monitor.Left; Top = $monInfo.Monitor.Top; Right = $monInfo.Monitor.Right
                            Bottom = $monInfo.Monitor.Bottom; Capabilities = $capabilities
                        }
                        $monitorIndex++
                    }
                }
            }
        }
    }
    if ($script:PhysicalMonitors.Count -eq 0) {
        $fallbackName = if ($script:WmiBrightnessAvailable) { "Integrated Laptop Display" } else { "No DDC/CI Monitor" }
        $fallbackDevice = if ($script:WmiBrightnessAvailable) { "WMI" } else { "" }
        $script:PhysicalMonitors += [PSCustomObject]@{
            Handle = [IntPtr]::Zero; HMonitor = [IntPtr]::Zero; Name = $fallbackName; Index = 1
            DeviceName = $fallbackDevice; Width = 1920; Height = 1080; RefreshRate = 60; IsPrimary = $true
            Left = 0; Top = 0; Right = 1920; Bottom = 1080; Capabilities = ""
        }
    }
}

function Get-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode)
    $vct = [uint32]0; $cur = [uint32]0; $max = [uint32]0
    $result = [MonitorAPI]::GetVCPFeatureAndVCPFeatureReply($Handle, $VCPCode, [ref]$vct, [ref]$cur, [ref]$max)
    return @{ Success = $result; Current = $cur; Maximum = $max; Type = $vct }
}

function Set-VCPValue {
    param([IntPtr]$Handle, [byte]$VCPCode, [uint32]$Value)
    return [MonitorAPI]::SetVCPFeature($Handle, $VCPCode, $Value)
}

function Set-VCPValueWithSync {
    param([byte]$VCPCode, [uint32]$Value, [switch]$Force)
    if ($script:ApplyToAll -or $Force) {
        foreach ($mon in $script:PhysicalMonitors) {
            if ($mon.Handle -ne [IntPtr]::Zero) { Set-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $Value | Out-Null; Start-Sleep -Milliseconds 50 }
        }
        if ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $Value | Out-Null }
    } else {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if ($mon.Handle -ne [IntPtr]::Zero) { Set-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $Value | Out-Null }
        elseif ($VCPCode -eq [MonitorAPI]::VCP_BRIGHTNESS -and $script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $Value | Out-Null }
    }
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
    foreach ($mon in $script:PhysicalMonitors) {
        if ($mon.Handle -ne [IntPtr]::Zero) { Set-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $settings.Brightness | Out-Null; Start-Sleep -Milliseconds 50 }
    }
    if ($script:WmiBrightnessAvailable) { Set-WmiBrightness -Value $settings.Brightness | Out-Null }
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
    if (-not (Test-Path $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
} catch {
    $script:ProfilesPath = $script:DefaultProfilesPath
    $script:ProfileStorageMode = "Local"
    $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
    $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
    $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
    $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
    $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
    if (-not (Test-Path $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MonitorControl Pro v3.18.0" Width="640" Height="680" MinWidth="560" MinHeight="560"
        Background="#0a0a0a" WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
<Window.Resources>
    <ControlTemplate x:Key="ComboBoxToggleButton" TargetType="ToggleButton">
        <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="20"/></Grid.ColumnDefinitions>
            <Border x:Name="Border" Grid.ColumnSpan="2" CornerRadius="5" Background="#1a1a1a" BorderBrush="#333" BorderThickness="1"/>
            <Path Grid.Column="1" Fill="#808080" HorizontalAlignment="Center" VerticalAlignment="Center" Data="M 0 0 L 4 4 L 8 0 Z"/>
        </Grid>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Border" Property="Background" Value="#262626"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
        <Setter Property="Foreground" Value="#e0e0e0"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="Height" Value="28"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
            <ToggleButton Template="{StaticResource ComboBoxToggleButton}" Focusable="False" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press"/>
            <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
            <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#1a1a1a" BorderThickness="1" BorderBrush="#333" CornerRadius="5" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="200" Margin="0,2,0,0">
                    <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer></Border>
            </Popup></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="#e0e0e0"/><Setter Property="Padding" Value="8,5"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="3"><ContentPresenter/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#0078d4"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
        <Setter Property="Background" Value="#1a1a1a"/><Setter Property="Foreground" Value="#d0d0d0"/><Setter Property="BorderBrush" Value="#333"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="10,6"/><Setter Property="Cursor" Value="Hand"/>
        <Setter Property="FontSize" Value="11"/><Setter Property="FontFamily" Value="Segoe UI"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#262626"/></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#333"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="AccBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#0078d4"/><Setter Property="BorderBrush" Value="#0078d4"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1a88e0"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="WarnBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#c44"/><Setter Property="BorderBrush" Value="#c44"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#d55"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="GreenBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#2a9d4a"/><Setter Property="BorderBrush" Value="#2a9d4a"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#33b85a"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="OrangeBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
        <Setter Property="Background" Value="#e67e22"/><Setter Property="BorderBrush" Value="#e67e22"/><Setter Property="Foreground" Value="#fff"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#f39c12"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Sld" TargetType="Slider">
        <Setter Property="Height" Value="18"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
                <Border Height="4" Background="#1f1f1f" CornerRadius="2"/>
                <Track x:Name="PART_Track">
                    <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge"><RepeatButton.Template>
                        <ControlTemplate><Border Background="{Binding Tag, RelativeSource={RelativeSource AncestorType=Slider}}" CornerRadius="2" Height="4"/></ControlTemplate>
                    </RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb><Thumb.Template><ControlTemplate><Grid><Ellipse Width="14" Height="14" Fill="#fff"/><Ellipse Width="5" Height="5" Fill="#0a0a0a"/></Grid></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge"><RepeatButton.Template><ControlTemplate><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TabControl"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="TabItem">
        <Setter Property="Foreground" Value="#707070"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="11"/><Setter Property="Padding" Value="10,6"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="5,5,0,0">
                <ContentPresenter ContentSource="Header" HorizontalAlignment="Center"/></Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#151515"/><Setter Property="Foreground" Value="#fff"/></Trigger>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1a1a1a"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
        <Setter Property="Foreground" Value="#d0d0d0"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="11"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
                <Border x:Name="cb" Width="16" Height="16" Background="#1a1a1a" BorderBrush="#444" BorderThickness="1" CornerRadius="3" Margin="0,0,6,0">
                    <Path x:Name="cm" Data="M 2 5 L 5 8 L 12 1" Stroke="#fff" StrokeThickness="2" Visibility="Collapsed" Margin="1"/></Border>
                <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True">
                <Setter TargetName="cb" Property="Background" Value="#0078d4"/><Setter TargetName="cb" Property="BorderBrush" Value="#0078d4"/>
                <Setter TargetName="cm" Property="Visibility" Value="Visible"/>
            </Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ProgressBar">
        <Setter Property="Height" Value="5"/><Setter Property="Background" Value="#1f1f1f"/><Setter Property="Foreground" Value="#0078d4"/><Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar"><Grid>
            <Border Background="{TemplateBinding Background}" CornerRadius="3"/><Border x:Name="PART_Track"/>
            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="3" HorizontalAlignment="Left"/>
        </Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
        <Setter Property="Background" Value="#1a1a1a"/><Setter Property="Foreground" Value="#e0e0e0"/><Setter Property="BorderBrush" Value="#333"/>
        <Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="6,4"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="CaretBrush" Value="#fff"/>
    </Style>
</Window.Resources>
<Grid Margin="12,10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
            <TextBlock Text="MonitorControl Pro" FontSize="16" FontWeight="SemiBold" Foreground="#fff" FontFamily="Segoe UI"/>
            <TextBlock Text="v3.18.0 - Click monitor to select" FontSize="9" Foreground="#505050" Margin="0,1,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
            <CheckBox x:Name="ApplyAllCheckbox" Content="All Monitors" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <Button x:Name="IdentifyBtn" Content="Identify" Style="{StaticResource Btn}" Padding="8,5" Margin="0,0,4,0"/>
            <Button x:Name="RefreshBtn" Content="Refresh" Style="{StaticResource Btn}" Padding="8,5"/>
        </StackPanel>
    </Grid>
    <Border Grid.Row="2" Background="#111" CornerRadius="6" Padding="10,8">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Canvas x:Name="MonitorCanvas" Height="65" ClipToBounds="True"/>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0,0,0" MinWidth="130">
                <TextBlock x:Name="SelectedMonitorName" Text="No Monitor" FontSize="11" Foreground="#fff" FontWeight="SemiBold"/>
                <TextBlock x:Name="SelectedMonitorRes" FontSize="9" Foreground="#707070" Margin="0,1,0,0"/>
                <TextBlock x:Name="SelectedMonitorInfo" FontSize="8" Foreground="#505050" Margin="0,1,0,0"/>
            </StackPanel>
        </Grid>
    </Border>
    <TabControl Grid.Row="4">
        <TabItem Header="Display">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><ScrollViewer VerticalScrollBarVisibility="Auto"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Brightness" FontSize="10" Foreground="#909090"/><TextBlock x:Name="BrightnessValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="BrightnessSlider" Grid.Row="2" Value="50" Tag="#f5b800" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Contrast" FontSize="10" Foreground="#909090"/><TextBlock x:Name="ContrastValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="ContrastSlider" Grid.Row="2" Value="50" Tag="#888" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="8,6"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="4"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Red" FontSize="9" Foreground="#e85050"/><TextBlock x:Name="RedValue" Text="50" FontSize="9" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="RedSlider" Grid.Row="2" Value="50" Tag="#e85050" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="8,6"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="4"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Green" FontSize="9" Foreground="#45c770"/><TextBlock x:Name="GreenValue" Text="50" FontSize="9" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GreenSlider" Grid.Row="2" Value="50" Tag="#45c770" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="4" Background="#1a1a1a" CornerRadius="5" Padding="8,6"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="4"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Blue" FontSize="9" Foreground="#4a90e8"/><TextBlock x:Name="BlueValue" Text="50" FontSize="9" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="BlueSlider" Grid.Row="2" Value="50" Tag="#4a90e8" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="4" Background="#1a1a1a" CornerRadius="5" Padding="10,7"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Color Temp:" FontSize="10" Foreground="#909090" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="ColorTempWarm" Content="Warm" Style="{StaticResource Btn}" Padding="7,3" Margin="0,0,3,0" FontSize="9"/>
                        <Button x:Name="ColorTemp6500" Content="6500K" Style="{StaticResource Btn}" Padding="7,3" Margin="0,0,3,0" FontSize="9"/>
                        <Button x:Name="ColorTempCool" Content="Cool" Style="{StaticResource Btn}" Padding="7,3" Margin="0,0,3,0" FontSize="9"/>
                        <Button x:Name="ColorTempSRGB" Content="sRGB" Style="{StaticResource AccBtn}" Padding="7,3" FontSize="9"/>
                    </StackPanel>
                </Grid></Border>
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="PresetDay" Content="Day" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetNight" Grid.Column="2" Content="Night" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetAutoMode" Grid.Column="4" Content="Auto" Style="{StaticResource OrangeBtn}" Padding="5,5"/>
                    <Button x:Name="PresetAmbientMode" Grid.Column="6" Content="Ambient" Style="{StaticResource GreenBtn}" Padding="5,5"/>
                    <Button x:Name="PresetReset" Grid.Column="8" Content="Reset" Style="{StaticResource AccBtn}" Padding="5,5"/>
                </Grid>
                <Border Grid.Row="8" Background="#1a1a1a" CornerRadius="5" Padding="10,7"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Dynamic Contrast" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                    <Button x:Name="DynamicContrastOff" Grid.Column="2" Content="Off" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="DynamicContrastOn" Grid.Column="4" Content="On" Style="{StaticResource OrangeBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="#1a1a1a" CornerRadius="5" Padding="10,7"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Picture Mode" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                    <Button x:Name="PictureModeWeb" Grid.Column="2" Content="Web" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="PictureModeCinema" Grid.Column="4" Content="Cinema" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="PictureModeGame" Grid.Column="6" Content="Game" Style="{StaticResource AccBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem Header="Monitor">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><ScrollViewer VerticalScrollBarVisibility="Auto"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel><TextBlock Text="Input Source" FontSize="10" Foreground="#909090" Margin="0,0,0,5"/>
                        <ComboBox x:Name="InputSourceCombo"/></StackPanel></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel><TextBlock Text="Power Control" FontSize="10" Foreground="#909090" Margin="0,0,0,5"/>
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/><ColumnDefinition Width="3"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="PowerOffBtn" Content="Off" Style="{StaticResource WarnBtn}" Padding="4,4" FontSize="9"/>
                            <Button x:Name="PowerStandbyBtn" Grid.Column="2" Content="Standby" Style="{StaticResource Btn}" Padding="4,4" FontSize="9"/>
                            <Button x:Name="PowerOnBtn" Grid.Column="4" Content="On" Style="{StaticResource GreenBtn}" Padding="4,4" FontSize="9"/>
                        </Grid></StackPanel></Border>
                </Grid>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><StackPanel Orientation="Horizontal"><TextBlock Text="Volume" FontSize="10" Foreground="#909090"/><CheckBox x:Name="MuteCheckbox" Content="Mute" Margin="8,0,0,0" VerticalAlignment="Center" FontSize="9"/></StackPanel>
                            <TextBlock x:Name="VolumeValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VolumeSlider" Grid.Row="2" Value="50" Tag="#9b59b6" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Sharpness" FontSize="10" Foreground="#909090"/><TextBlock x:Name="SharpnessValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="SharpnessSlider" Grid.Row="2" Value="50" Tag="#3498db" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="4" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="ResetColorBtn" Content="Reset Colors" Style="{StaticResource Btn}"/>
                    <Button x:Name="FactoryResetBtn" Grid.Column="2" Content="Factory Reset" Style="{StaticResource WarnBtn}"/>
                </Grid></Border>
                <Button x:Name="AllMonitorsStandbyBtn" Grid.Row="6" Content="All Monitors to Standby" Style="{StaticResource Btn}"/>
                <Border Grid.Row="8" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
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
        <TabItem x:Name="GpuTab" Header="GPU">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock x:Name="GpuNameText" Text="GPU" FontSize="12" Foreground="#76b900" FontWeight="SemiBold"/>
                        <TextBlock x:Name="GpuStatsText" Text="-- C | -- MHz | -- W" FontSize="8" Foreground="#707070" Margin="0,2,0,0"/>
                        <TextBlock x:Name="CpuTempText" Text="CPU: -- C" FontSize="8" Foreground="#707070" Margin="0,1,0,0"/></StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock x:Name="GpuTempText" Text="--" FontSize="20" Foreground="#fff" FontWeight="Light"/>
                        <TextBlock Text=" C" FontSize="10" Foreground="#606060" VerticalAlignment="Top" Margin="0,3,0,0"/></StackPanel>
                </Grid></Border>
                <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="GPU Utilization" FontSize="9" Foreground="#909090"/><TextBlock x:Name="GpuUtilText" Text="0%" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="GpuUtilBar" Value="0" Foreground="#76b900"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Memory Usage" FontSize="9" Foreground="#909090"/><TextBlock x:Name="MemUsageText" Text="0 / 0 GB" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="MemUtilBar" Value="0" Foreground="#e67e22"/>
                    </StackPanel></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel>
                        <Grid Margin="0,0,0,3"><TextBlock Text="Fan Speed" FontSize="9" Foreground="#909090"/><TextBlock x:Name="FanSpeedText" Text="0%" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="FanSpeedBar" Value="0" Foreground="#3498db"/>
                        <Grid Margin="0,6,0,3"><TextBlock Text="Power Draw" FontSize="9" Foreground="#909090"/><TextBlock x:Name="PowerDrawText" Text="0 / 0 W" FontSize="9" Foreground="#fff" HorizontalAlignment="Right"/></Grid>
                        <ProgressBar x:Name="PowerDrawBar" Value="0" Foreground="#e74c3c"/>
                    </StackPanel></Border>
                </Grid>
                <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Digital Vibrance" FontSize="10" Foreground="#909090"/><TextBlock x:Name="VibranceValue" Text="50" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="VibranceSlider" Grid.Row="2" Value="50" Tag="#76b900" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                    <Border Grid.Column="2" Background="#1a1a1a" CornerRadius="5" Padding="10,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid><TextBlock Text="Software Gamma" FontSize="10" Foreground="#909090"/><TextBlock x:Name="GammaValue" Text="1.00" FontSize="10" Foreground="#fff" FontWeight="SemiBold" HorizontalAlignment="Right"/></Grid>
                        <Slider x:Name="GammaSlider" Grid.Row="2" Value="100" Minimum="50" Maximum="150" Tag="#9b59b6" Style="{StaticResource Sld}"/>
                    </Grid></Border>
                </Grid>
                <Border Grid.Row="6" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="FPS Overlay" FontSize="10" Foreground="#909090"/>
                        <TextBlock x:Name="FpsOverlayStatusText" Text="PresentMon idle" FontSize="8" Foreground="#707070" Margin="0,2,0,0"/></StackPanel>
                    <Button x:Name="FpsOverlayStartBtn" Grid.Column="2" Content="Start" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="FpsOverlayStopBtn" Grid.Column="4" Content="Stop" Style="{StaticResource Btn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem Header="VCP">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="60"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="VCP Code:" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                    <TextBox x:Name="VCPCodeBox" Grid.Column="2" Text="10" VerticalAlignment="Center"/>
                    <ComboBox x:Name="VCPPresetCombo" Grid.Column="4"/>
                    <Button x:Name="VCPQueryBtn" Grid.Column="6" Content="Query" Style="{StaticResource AccBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="VCP Response" FontSize="10" Foreground="#909090"/>
                    <TextBox x:Name="VCPResultBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#111" FontFamily="Consolas" FontSize="10" AcceptsReturn="True"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Set Value:" FontSize="10" Foreground="#909090" VerticalAlignment="Center"/>
                    <TextBox x:Name="VCPSetValueBox" Grid.Column="2" Text="50" VerticalAlignment="Center"/>
                    <Button x:Name="VCPSetBtn" Grid.Column="4" Content="Set" Style="{StaticResource GreenBtn}" Padding="10,4"/>
                    <Button x:Name="VCPScanBtn" Grid.Column="6" Content="Scan All" Style="{StaticResource Btn}" Padding="10,4"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem Header="Profiles">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ProfileNameBox" Text="My Profile"/>
                    <Button x:Name="SaveProfileBtn" Grid.Column="2" Content="Save" Style="{StaticResource GreenBtn}" Padding="10,4"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Saved Profiles" FontSize="10" Foreground="#909090"/>
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
                <Border Grid.Row="8" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="Profile Storage" FontSize="10" Foreground="#909090"/>
                        <TextBlock x:Name="ProfileStorageStatusText" Text="Local" FontSize="8" Foreground="#707070" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                    <Button x:Name="ProfileSyncFolderBtn" Grid.Column="2" Content="Sync Folder" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                    <Button x:Name="ProfileLocalFolderBtn" Grid.Column="4" Content="Use Local" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="10" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <Grid><CheckBox x:Name="AppProfileEnabledCheckbox" Content="Per-application profiles" VerticalAlignment="Center"/>
                        <TextBlock x:Name="AppProfileStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="AppProfileExeBox" Text="app.exe"/>
                        <Button x:Name="AppProfileCaptureBtn" Grid.Column="2" Content="Capture" Style="{StaticResource Btn}" Padding="8,4" FontSize="9"/>
                    </Grid>
                    <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <ComboBox x:Name="AppProfileProfileCombo"/>
                        <Button x:Name="AppProfileAddBtn" Grid.Column="2" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                        <Button x:Name="AppProfileRemoveBtn" Grid.Column="4" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="9"/>
                    </Grid>
                    <ListBox x:Name="AppProfileRulesList" Grid.Row="6" Height="66" Background="#111" BorderThickness="0" Foreground="#e0e0e0" FontSize="10"/>
                </Grid></Border>
            </Grid></Border>
        </TabItem>
        <TabItem Header="Schedule">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <CheckBox x:Name="ScheduleEnabledCheckbox" Content="Scheduled profiles" VerticalAlignment="Center"/>
                    <TextBlock x:Name="ScheduleStatusText" Text="Off" FontSize="9" Foreground="#707070" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid></Border>
                <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="76"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="6"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="ScheduleTimeBox" Text="21:00" VerticalAlignment="Center"/>
                    <ComboBox x:Name="ScheduleProfileCombo" Grid.Column="2"/>
                    <Button x:Name="ScheduleAddBtn" Grid.Column="4" Content="Add" Style="{StaticResource GreenBtn}" Padding="10,4" FontSize="9"/>
                    <Button x:Name="ScheduleRemoveBtn" Grid.Column="6" Content="Remove" Style="{StaticResource WarnBtn}" Padding="10,4" FontSize="9"/>
                </Grid></Border>
                <Border Grid.Row="4" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="6"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Profile schedule" FontSize="10" Foreground="#909090"/>
                    <ListBox x:Name="ScheduleRulesList" Grid.Row="2" Background="#111" BorderThickness="0" Foreground="#e0e0e0" FontSize="11"/>
                </Grid></Border>
                <Border Grid.Row="6" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
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
                <Border Grid.Row="8" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid>
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
        <TabItem Header="System">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel><TextBlock Text="Quick Links" FontSize="10" Foreground="#909090" Margin="0,0,0,5"/>
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Button x:Name="DisplaySettingsBtn" Content="Display" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                        <Button x:Name="ColorMgmtBtn" Grid.Column="2" Content="Color Mgmt" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                        <Button x:Name="GpuControlPanelBtn" Grid.Column="4" Content="GPU Panel" Style="{StaticResource Btn}" Padding="5,4" FontSize="9"/>
                    </Grid></StackPanel></Border>
                <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
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
                <Border Grid.Row="4" Background="#1a1a1a" CornerRadius="5" Padding="10"><StackPanel><TextBlock Text="Monitor Capabilities" FontSize="10" Foreground="#909090" Margin="0,0,0,4"/>
                    <TextBox x:Name="CapabilitiesBox" IsReadOnly="True" TextWrapping="Wrap" Height="60" VerticalScrollBarVisibility="Auto" Background="#111" FontFamily="Consolas" FontSize="8"/>
                </StackPanel></Border>
            </Grid></Border>
        </TabItem>
    </TabControl>
    <Border Grid.Row="5" Margin="0,6,0,0"><Grid>
        <TextBlock x:Name="StatusText" Text="Ready" FontSize="9" Foreground="#505050"/>
        <TextBlock x:Name="AutoModeText" Text="" FontSize="9" Foreground="#e67e22" HorizontalAlignment="Right"/>
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
$monitorCanvas = $window.FindName("MonitorCanvas"); $selectedMonitorName = $window.FindName("SelectedMonitorName")
$selectedMonitorRes = $window.FindName("SelectedMonitorRes"); $selectedMonitorInfo = $window.FindName("SelectedMonitorInfo")
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
$profileNameBox = $window.FindName("ProfileNameBox"); $profilesList = $window.FindName("ProfilesList")
$saveProfileBtn = $window.FindName("SaveProfileBtn"); $loadProfileBtn = $window.FindName("LoadProfileBtn"); $deleteProfileBtn = $window.FindName("DeleteProfileBtn")
$exportProfilesBtn = $window.FindName("ExportProfilesBtn"); $importProfilesBtn = $window.FindName("ImportProfilesBtn")
$profileStorageStatusText = $window.FindName("ProfileStorageStatusText"); $profileSyncFolderBtn = $window.FindName("ProfileSyncFolderBtn"); $profileLocalFolderBtn = $window.FindName("ProfileLocalFolderBtn")
$appProfileEnabledCheckbox = $window.FindName("AppProfileEnabledCheckbox"); $appProfileStatusText = $window.FindName("AppProfileStatusText")
$appProfileExeBox = $window.FindName("AppProfileExeBox"); $appProfileCaptureBtn = $window.FindName("AppProfileCaptureBtn")
$appProfileProfileCombo = $window.FindName("AppProfileProfileCombo"); $appProfileAddBtn = $window.FindName("AppProfileAddBtn")
$appProfileRemoveBtn = $window.FindName("AppProfileRemoveBtn"); $appProfileRulesList = $window.FindName("AppProfileRulesList")
$scheduleEnabledCheckbox = $window.FindName("ScheduleEnabledCheckbox"); $scheduleStatusText = $window.FindName("ScheduleStatusText")
$scheduleTimeBox = $window.FindName("ScheduleTimeBox"); $scheduleProfileCombo = $window.FindName("ScheduleProfileCombo")
$scheduleAddBtn = $window.FindName("ScheduleAddBtn"); $scheduleRemoveBtn = $window.FindName("ScheduleRemoveBtn"); $scheduleRulesList = $window.FindName("ScheduleRulesList")
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
$capabilitiesBox = $window.FindName("CapabilitiesBox"); $statusText = $window.FindName("StatusText"); $autoModeText = $window.FindName("AutoModeText")

function Update-Status { param([string]$Message); $statusText.Text = $Message }

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
    $canvasHeight = if ($monitorCanvas.ActualHeight -gt 0) { $monitorCanvas.ActualHeight } else { 65 }
    $scale = [Math]::Min(($canvasWidth - 12) / $totalWidth, ($canvasHeight - 12) / $totalHeight)
    $offsetX = ($canvasWidth - ($totalWidth * $scale)) / 2; $offsetY = ($canvasHeight - ($totalHeight * $scale)) / 2
    foreach ($mon in $script:PhysicalMonitors) {
        $x = (($mon.Left - $minX) * $scale) + $offsetX; $y = (($mon.Top - $minY) * $scale) + $offsetY
        $w = [Math]::Max(38, ($mon.Right - $mon.Left) * $scale - 4); $h = [Math]::Max(24, ($mon.Bottom - $mon.Top) * $scale - 4)
        $isSelected = ($mon.Index - 1) -eq $script:CurrentMonitorIndex
        $border = New-Object System.Windows.Controls.Border
        $border.Width = $w; $border.Height = $h; $border.CornerRadius = New-Object System.Windows.CornerRadius(3)
        $border.BorderThickness = New-Object System.Windows.Thickness(2); $border.Cursor = [System.Windows.Input.Cursors]::Hand
        $border.Tag = [int]($mon.Index - 1)
        if ($isSelected) {
            $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,120,212))
            $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,150,255))
        } else {
            $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(40,40,40))
            $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(60,60,60))
        }
        $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = $mon.Index.ToString(); $tb.Foreground = [System.Windows.Media.Brushes]::White
        $tb.FontSize = 10; $tb.FontWeight = [System.Windows.FontWeights]::Bold; $tb.HorizontalAlignment = "Center"; $tb.VerticalAlignment = "Center"
        $border.Child = $tb
        [System.Windows.Controls.Canvas]::SetLeft($border, $x); [System.Windows.Controls.Canvas]::SetTop($border, $y)
        $border.Add_MouseLeftButtonDown([System.Windows.Input.MouseButtonEventHandler]{ param($sender,$args); $script:CurrentMonitorIndex = [int]$sender.Tag; Draw-MonitorLayout; Load-MonitorSettings })
        $border.Add_MouseEnter([System.Windows.Input.MouseEventHandler]{ param($sender,$args); if ([int]$sender.Tag -ne $script:CurrentMonitorIndex) { $sender.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(50,50,50)) } })
        $border.Add_MouseLeave([System.Windows.Input.MouseEventHandler]{ param($sender,$args); if ([int]$sender.Tag -ne $script:CurrentMonitorIndex) { $sender.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(40,40,40)) } })
        $monitorCanvas.Children.Add($border) | Out-Null
    }
    if ($script:CurrentMonitorIndex -lt $script:PhysicalMonitors.Count) {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        $selectedMonitorName.Text = "$($mon.Index): $($mon.Name)"
        $selectedMonitorRes.Text = "$($mon.Width) x $($mon.Height) @ $($mon.RefreshRate)Hz"
        $selectedMonitorInfo.Text = "$($mon.DeviceName)$(if ($mon.IsPrimary) { ' (Primary)' } else { '' })"
    }
}

function Load-MonitorSettings {
    if ($script:PhysicalMonitors.Count -eq 0 -or $script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { return }
    $script:UpdatingUI = $true
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; $h = $mon.Handle
    Update-Status "Reading from $($mon.Name)..."
    if ($h -eq [IntPtr]::Zero -and $script:WmiBrightnessAvailable) {
        $wmiBrightness = Get-WmiBrightness
        if ($null -ne $wmiBrightness) {
            $brightnessSlider.Maximum = 100; $brightnessSlider.Value = $wmiBrightness; $brightnessValue.Text = $wmiBrightness
            $capabilitiesBox.Text = "Integrated display brightness via WMI"
            $script:UpdatingUI = $false; Update-Status "$($mon.Name) via WMI"; Update-TrayPopupState; Update-TrayIconText
            return
        }
    }
    $b = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS); if ($b.Success) { $brightnessSlider.Maximum = $b.Maximum; $brightnessSlider.Value = $b.Current; $brightnessValue.Text = $b.Current }
    $c = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_CONTRAST); if ($c.Success) { $contrastSlider.Maximum = $c.Maximum; $contrastSlider.Value = $c.Current; $contrastValue.Text = $c.Current }
    $r = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_RED_GAIN); if ($r.Success) { $redSlider.Maximum = $r.Maximum; $redSlider.Value = $r.Current; $redValue.Text = $r.Current }
    $g = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_GREEN_GAIN); if ($g.Success) { $greenSlider.Maximum = $g.Maximum; $greenSlider.Value = $g.Current; $greenValue.Text = $g.Current }
    $bl = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_BLUE_GAIN); if ($bl.Success) { $blueSlider.Maximum = $bl.Maximum; $blueSlider.Value = $bl.Current; $blueValue.Text = $bl.Current }
    $v = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_VOLUME); if ($v.Success) { $volumeSlider.Maximum = $v.Maximum; $volumeSlider.Value = $v.Current; $volumeValue.Text = $v.Current }
    $sh = Get-VCPValue -Handle $h -VCPCode ([MonitorAPI]::VCP_SHARPNESS); if ($sh.Success) { $sharpnessSlider.Maximum = $sh.Maximum; $sharpnessSlider.Value = $sh.Current; $sharpnessValue.Text = $sh.Current }
    $inputSourceCombo.Items.Clear()
    @(@{N="HDMI 1";V=0x11},@{N="HDMI 2";V=0x12},@{N="DisplayPort 1";V=0x0F},@{N="DisplayPort 2";V=0x10},@{N="USB-C";V=0x13},@{N="DVI";V=0x03},@{N="VGA";V=0x01}) | ForEach-Object {
        $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = $_.N; $item.Tag = $_.V; $inputSourceCombo.Items.Add($item) | Out-Null
    }
    $capabilitiesBox.Text = if ($mon.Capabilities) { $mon.Capabilities } else { "DDC/CI capabilities not available" }
    $script:UpdatingUI = $false; Update-Status "$($mon.Name)"; Update-TrayPopupState; Update-TrayIconText
}

function Refresh-Monitors { Get-Monitors; if ($script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { $script:CurrentMonitorIndex = 0 }; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList }
function Get-UserProfileFiles {
    if (-not (Test-Path $script:ProfilesPath)) { return @() }
    return @(Get-ChildItem -Path $script:ProfilesPath -Filter "*.json" -File |
        Where-Object { $script:ProfileMetadataFiles -notcontains $_.Name } |
        Sort-Object -Property BaseName)
}

function Update-ProfilesList {
    $profilesList.Items.Clear()
    Get-UserProfileFiles | ForEach-Object { $profilesList.Items.Add($_.BaseName) | Out-Null }
    Update-AppProfileProfileCombo
}

function New-ProfileObject {
    param([string]$Name)
    return [PSCustomObject]@{
        SchemaVersion = $script:ProfileSchemaVersion
        Name = $Name
        Brightness = [int]$brightnessSlider.Value
        Contrast = [int]$contrastSlider.Value
        Red = [int]$redSlider.Value
        Green = [int]$greenSlider.Value
        Blue = [int]$blueSlider.Value
        Gamma = [int]$gammaSlider.Value
        GammaRed = [int]$gammaRedSlider.Value
        GammaGreen = [int]$gammaGreenSlider.Value
        GammaBlue = [int]$gammaBlueSlider.Value
        UpdatedAt = (Get-Date).ToString("o")
    }
}

function ConvertTo-CurrentProfileSchema {
    param($Profile, [string]$FallbackName)
    $schema = if ($Profile.PSObject.Properties.Name -contains "SchemaVersion") { [int]$Profile.SchemaVersion } else { 1 }
    $name = if ($Profile.Name) { [string]$Profile.Name } else { $FallbackName }
    $converted = [PSCustomObject]@{
        SchemaVersion = $script:ProfileSchemaVersion
        Name = $name
        Brightness = [int]$Profile.Brightness
        Contrast = [int]$Profile.Contrast
        Red = [int]$Profile.Red
        Green = [int]$Profile.Green
        Blue = [int]$Profile.Blue
        Gamma = if ($null -ne $Profile.Gamma) { [int]$Profile.Gamma } else { 100 }
        GammaRed = if ($null -ne $Profile.GammaRed) { [int]$Profile.GammaRed } else { 100 }
        GammaGreen = if ($null -ne $Profile.GammaGreen) { [int]$Profile.GammaGreen } else { 100 }
        GammaBlue = if ($null -ne $Profile.GammaBlue) { [int]$Profile.GammaBlue } else { 100 }
        UpdatedAt = if ($Profile.UpdatedAt) { [string]$Profile.UpdatedAt } else { (Get-Date).ToString("o") }
    }
    return $converted
}

function Save-ProfileObject {
    param($Profile)
    $safeName = [System.IO.Path]::GetFileNameWithoutExtension([string]$Profile.Name)
    if ([string]::IsNullOrWhiteSpace($safeName)) { return $false }
    $path = Join-Path $script:ProfilesPath "$safeName.json"
    $Profile | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
    return $true
}

function Read-ProfileObject {
    param([string]$Name)
    $path = Join-Path $script:ProfilesPath "$Name.json"
    if (-not (Test-Path $path)) { return $null }
    $profile = Get-Content $path -Raw | ConvertFrom-Json
    $schema = if ($profile.PSObject.Properties.Name -contains "SchemaVersion") { [int]$profile.SchemaVersion } else { 1 }
    $converted = ConvertTo-CurrentProfileSchema -Profile $profile -FallbackName $Name
    if ($schema -lt $script:ProfileSchemaVersion) {
        Save-ProfileObject -Profile $converted | Out-Null
        Update-Status "Migrated profile '$Name' to schema v$script:ProfileSchemaVersion"
    }
    return $converted
}

function Export-ProfileBundle {
    param([string]$OutputPath)
    $profileFiles = @(Get-UserProfileFiles)
    if ($profileFiles.Count -eq 0) {
        Update-Status "No profiles to export"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if (-not (Test-Path $script:ProfileExportsPath)) { New-Item -ItemType Directory -Path $script:ProfileExportsPath -Force | Out-Null }
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $OutputPath = Join-Path $script:ProfileExportsPath "monitorcontrol-profiles-$timestamp.zip"
    } else {
        $parent = Split-Path -Path $OutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
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
            $profile | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $tempProfiles "$safeName.json") -Encoding UTF8
            $exportedProfiles += $safeName
        }

        if ($exportedProfiles.Count -eq 0) {
            Update-Status "No profiles to export"
            return $null
        }

        $manifest = [PSCustomObject]@{
            BundleSchemaVersion = $script:ProfileBundleSchemaVersion
            AppVersion = "3.17.0"
            ProfileSchemaVersion = $script:ProfileSchemaVersion
            ExportedAt = (Get-Date).ToString("o")
            ProfileCount = $exportedProfiles.Count
            Profiles = $exportedProfiles
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $tempRoot "manifest.json") -Encoding UTF8
        if (Test-Path $OutputPath) { Remove-Item -Path $OutputPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempRoot, $OutputPath)
        Update-Status "Exported $($exportedProfiles.Count) profiles to $(Split-Path -Path $OutputPath -Leaf)"
        return $OutputPath
    } catch {
        Update-Status "Profile export failed: $($_.Exception.Message)"
        return $null
    } finally {
        if (Test-Path $tempRoot) { Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Import-ProfileBundle {
    param([string]$BundlePath)
    if ([string]::IsNullOrWhiteSpace($BundlePath) -or -not (Test-Path $BundlePath)) {
        Update-Status "Profile bundle not found"
        return 0
    }

    $archive = $null
    $imported = 0
    $skipped = 0
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
        $entries = @($archive.Entries | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name) -and
            $_.Name.ToLowerInvariant().EndsWith(".json") -and
            $_.Name -ne "manifest.json" -and
            $script:ProfileMetadataFiles -notcontains $_.Name
        })

        foreach ($entry in $entries) {
            $fallbackName = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
            if ([string]::IsNullOrWhiteSpace($fallbackName)) { $skipped++; continue }
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                $rawProfile = $reader.ReadToEnd() | ConvertFrom-Json
                $profile = ConvertTo-CurrentProfileSchema -Profile $rawProfile -FallbackName $fallbackName
                if (Save-ProfileObject -Profile $profile) { $imported++ } else { $skipped++ }
            } catch {
                $skipped++
            } finally {
                if ($reader) { $reader.Dispose() }
            }
        }

        Update-ProfilesList
        $status = if ($imported -gt 0) { "Imported $imported profiles from $(Split-Path -Path $BundlePath -Leaf)" } else { "No profiles imported" }
        if ($skipped -gt 0) { $status = "$status ($skipped skipped)" }
        Update-Status $status
        return $imported
    } catch {
        Update-Status "Profile import failed: $($_.Exception.Message)"
        return 0
    } finally {
        if ($archive) { $archive.Dispose() }
    }
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
        if (-not (Test-Path $fullPath)) { New-Item -ItemType Directory -Path $fullPath -Force | Out-Null }
        $script:ProfilesPath = $fullPath
        $script:ProfileStorageMode = $Mode
        $script:AppProfileRulesPath = Join-Path $script:ProfilesPath "app-profile-rules.json"
        $script:ProfileScheduleRulesPath = Join-Path $script:ProfilesPath "profile-schedules.json"
        $script:IdleDimSettingsPath = Join-Path $script:ProfilesPath "idle-dim.json"
        $script:BatteryProfileSettingsPath = Join-Path $script:ProfilesPath "battery-profile.json"
        $script:ProfileExportsPath = Join-Path $script:ProfilesPath "exports"
        return $true
    } catch {
        Update-Status "Profile storage failed: $($_.Exception.Message)"
        return $false
    }
}

function Save-ProfileStorageSettings {
    if (-not (Test-Path $script:DefaultProfilesPath)) { New-Item -ItemType Directory -Path $script:DefaultProfilesPath -Force | Out-Null }
    $payload = [PSCustomObject]@{
        Mode = $script:ProfileStorageMode
        ProfilePath = $script:ProfilesPath
        UpdatedAt = (Get-Date).ToString("o")
    }
    $payload | ConvertTo-Json | Set-Content -Path $script:ProfileStorageSettingsPath -Encoding UTF8
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
    Update-ProfilesList
    Update-AppProfileControls
    Update-ScheduleControls
    Update-IdleDimControls
    Update-BatteryProfileControls
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
    if (-not (Test-Path $script:AppProfileRulesPath)) { return }
    try {
        $data = Get-Content -Path $script:AppProfileRulesPath -Raw | ConvertFrom-Json
        $script:AppProfileEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $exe = Normalize-AppExeName -ExeName ([string]$rule.Exe)
            $profile = ([string]$rule.Profile).Trim()
            if ($exe -and $profile) { $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profile } }
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
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $script:AppProfileRulesPath -Encoding UTF8
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
            $item.Content = "$($rule.Exe) -> $($rule.Profile)"
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

function Apply-ProfileByName {
    param([string]$Name, [string]$Reason = "Loaded")
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $p = Read-ProfileObject -Name $Name
    if (-not $p) {
        Update-Status "Profile '$Name' not found"
        return $false
    }
    try {
        $script:UpdatingUI = $true
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $p.Brightness
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value $p.Contrast
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_RED_GAIN) -Value $p.Red
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_GREEN_GAIN) -Value $p.Green
        Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BLUE_GAIN) -Value $p.Blue
        $brightnessSlider.Value = $p.Brightness; $brightnessValue.Text = $p.Brightness
        $contrastSlider.Value = $p.Contrast; $contrastValue.Text = $p.Contrast
        $redSlider.Value = $p.Red; $redValue.Text = $p.Red
        $greenSlider.Value = $p.Green; $greenValue.Text = $p.Green
        $blueSlider.Value = $p.Blue; $blueValue.Text = $p.Blue
        if ($p.Gamma) { $gammaSlider.Value = $p.Gamma; $gammaValue.Text = ($p.Gamma / 100).ToString("F2") }
        if ($p.GammaRed) {
            $gammaRedSlider.Value = $p.GammaRed
            $gammaGreenSlider.Value = $p.GammaGreen
            $gammaBlueSlider.Value = $p.GammaBlue
            Set-GammaRamp -Gamma ($p.Gamma/100) -RedMult ($p.GammaRed/100) -GreenMult ($p.GammaGreen/100) -BlueMult ($p.GammaBlue/100)
        }
    } catch {
        Update-Status "Profile '$Name' failed"
        return $false
    } finally {
        $script:UpdatingUI = $false
    }
    $profilesList.SelectedItem = $Name
    Update-Status "$Reason '$Name'"
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
    if (Apply-ProfileByName -Name $rule.Profile -Reason "App profile $exe ->") {
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

function Load-ProfileSchedules {
    $script:ProfileScheduleEnabled = $false
    $script:ProfileSchedules = @()
    if (-not (Test-Path $script:ProfileScheduleRulesPath)) { return }
    try {
        $data = Get-Content -Path $script:ProfileScheduleRulesPath -Raw | ConvertFrom-Json
        $script:ProfileScheduleEnabled = [bool]$data.Enabled
        foreach ($rule in @($data.Rules)) {
            $time = Normalize-ScheduleTime -TimeText ([string]$rule.Time)
            $profile = ([string]$rule.Profile).Trim()
            if ($time -and $profile) { $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profile } }
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
    $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ProfileScheduleRulesPath -Encoding UTF8
}

function Update-ScheduleControls {
    if ($null -eq $scheduleEnabledCheckbox) { return }
    $script:UpdatingScheduleUI = $true
    try {
        $scheduleRulesList.Items.Clear()
        foreach ($rule in ($script:ProfileSchedules | Sort-Object -Property Time)) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = "$($rule.Time) -> $($rule.Profile)"
            $item.Tag = $rule.Time
            $scheduleRulesList.Items.Add($item) | Out-Null
        }
        $scheduleEnabledCheckbox.IsChecked = [bool]$script:ProfileScheduleEnabled
        $scheduleStatusText.Text = if ($script:ProfileScheduleEnabled) { "Watching" } else { "Off" }
        Update-ProfileCombo -Combo $scheduleProfileCombo
    } finally {
        $script:UpdatingScheduleUI = $false
    }
}

function Get-ActiveScheduleRule {
    if ($script:ProfileSchedules.Count -eq 0) { return $null }
    $now = Get-Date
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
    if (Apply-ProfileByName -Name $active.Rule.Profile -Reason "Schedule $($active.Rule.Time) ->") {
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
    if (-not (Test-Path $script:IdleDimSettingsPath)) { return }
    try {
        $data = Get-Content -Path $script:IdleDimSettingsPath -Raw | ConvertFrom-Json
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
    $payload | ConvertTo-Json | Set-Content -Path $script:IdleDimSettingsPath -Encoding UTF8
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

function Get-IdleSeconds {
    $info = New-Object MonitorAPI+LASTINPUTINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
    if (-not [MonitorAPI]::GetLastInputInfo([ref]$info)) { return 0 }
    $current = [MonitorAPI]::GetTickCount()
    $elapsedMs = if ($current -ge $info.dwTime) { $current - $info.dwTime } else { ([uint64][uint32]::MaxValue - $info.dwTime) + $current }
    return [int]($elapsedMs / 1000)
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
    if (-not (Test-Path $script:BatteryProfileSettingsPath)) { return }
    try {
        $data = Get-Content -Path $script:BatteryProfileSettingsPath -Raw | ConvertFrom-Json
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
    $payload | ConvertTo-Json | Set-Content -Path $script:BatteryProfileSettingsPath -Encoding UTF8
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
    return "$($mon.Index): $($mon.Name)"
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

# Populate VCP preset combo
foreach ($code in ($script:VCPCodeDescriptions.Keys | Sort-Object)) { $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = "0x{0:X2} - {1}" -f $code, $script:VCPCodeDescriptions[$code]; $item.Tag = $code; $vcpPresetCombo.Items.Add($item) | Out-Null }
$vcpPresetCombo.SelectedIndex = 0

# Event handlers
$applyAllCheckbox.Add_Checked({ Set-ApplyToAllMode -Enabled $true }); $applyAllCheckbox.Add_Unchecked({ Set-ApplyToAllMode -Enabled $false })
$refreshBtn.Add_Click({ Refresh-Monitors }); $identifyBtn.Add_Click({ Show-IdentifyOverlays })

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

$inputSourceCombo.Add_SelectionChanged({ if ($script:UpdatingUI -or $inputSourceCombo.SelectedItem -eq $null) { return }; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_INPUT_SOURCE) -Value ([uint32]$inputSourceCombo.SelectedItem.Tag); Update-Status "Input: $($inputSourceCombo.SelectedItem.Content)" })
$powerOffBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_OFF); Update-Status "Monitor Off" })
$powerStandbyBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY); Update-Status "Monitor Standby" })
$powerOnBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_ON); Update-Status "Monitor On" })
$pipPbpOffBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_OFF); Update-Status "PiP/PbP off" })
$pipModeBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_UPPER_RIGHT); Update-Status "PiP mode" })
$pbpModeBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_MODE) -Value ([MonitorAPI]::PIP_MODE_PBP_SPLIT); Update-Status "PbP split mode" })
$pipSecondaryDpBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_DISPLAYPORT); Update-Status "PiP/PbP secondary: DisplayPort" })
$pipSecondaryHdmi1Btn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI1); Update-Status "PiP/PbP secondary: HDMI 1" })
$pipSecondaryHdmi2Btn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_PIP_SECONDARY_SOURCE) -Value ([MonitorAPI]::PIP_SECONDARY_HDMI2); Update-Status "PiP/PbP secondary: HDMI 2" })
$resetColorBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_RESTORE_FACTORY_COLOR) -Value 1; Start-Sleep -Milliseconds 500; Load-MonitorSettings; Update-Status "Colors Reset" })
$factoryResetBtn.Add_Click({ if ([System.Windows.MessageBox]::Show("Reset ALL settings?", "Factory Reset", "YesNo", "Warning") -eq "Yes") { Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_RESTORE_FACTORY_DEFAULTS) -Value 1; Start-Sleep -Milliseconds 1000; Load-MonitorSettings; Update-Status "Factory Reset Done" } })
$allMonitorsStandbyBtn.Add_Click({ foreach ($mon in $script:PhysicalMonitors) { if ($mon.Handle -ne [IntPtr]::Zero) { Set-VCPValue -Handle $mon.Handle -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY) | Out-Null; Start-Sleep -Milliseconds 100 } }; Update-Status "All Standby" })

$vcpPresetCombo.Add_SelectionChanged({ if ($vcpPresetCombo.SelectedItem -ne $null) { $vcpCodeBox.Text = "0x{0:X2}" -f $vcpPresetCombo.SelectedItem.Tag } })
$vcpQueryBtn.Add_Click({
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { $vcpResultBox.Text = "No DDC/CI"; return }
    try {
        $codeText = $vcpCodeBox.Text.Trim(); $code = if ($codeText -match '^0x') { [Convert]::ToInt32($codeText, 16) } else { [int]$codeText }
        $result = Get-VCPValue -Handle $mon.Handle -VCPCode ([byte]$code)
        if ($result.Success) { $desc = if ($script:VCPCodeDescriptions.ContainsKey($code)) { $script:VCPCodeDescriptions[$code] } else { "Unknown" }; $vcpResultBox.Text = "VCP 0x$("{0:X2}" -f $code) ($desc)`nCurrent: $($result.Current)`nMaximum: $($result.Maximum)" }
        else { $vcpResultBox.Text = "Failed to read VCP 0x$("{0:X2}" -f $code)" }
    } catch { $vcpResultBox.Text = "Error: $_" }
})
$vcpSetBtn.Add_Click({
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { return }
    try { $codeText = $vcpCodeBox.Text.Trim(); $code = if ($codeText -match '^0x') { [Convert]::ToInt32($codeText, 16) } else { [int]$codeText }; $value = [uint32]$vcpSetValueBox.Text
        if (Set-VCPValue -Handle $mon.Handle -VCPCode ([byte]$code) -Value $value) { Update-Status "Set VCP 0x$("{0:X2}" -f $code) = $value"; $vcpQueryBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }
    } catch { Update-Status "Error: $_" }
})
$vcpScanBtn.Add_Click({
    $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]; if ($mon.Handle -eq [IntPtr]::Zero) { $vcpResultBox.Text = "No DDC/CI"; return }
    $vcpResultBox.Text = "Scanning...`n"; [System.Windows.Forms.Application]::DoEvents()
    $found = @(); foreach ($code in ($script:VCPCodeDescriptions.Keys | Sort-Object)) {
        $r = Get-VCPValue -Handle $mon.Handle -VCPCode ([byte]$code)
        if ($r.Success) { $desc = if ($script:VCPCodeDescriptions.ContainsKey($code)) { $script:VCPCodeDescriptions[$code] } else { "Unknown" }; $found += "0x{0:X2} {1,-20} = {2} (max:{3})" -f $code, $desc, $r.Current, $r.Maximum }
    }
    $vcpResultBox.Text = "Supported VCP Codes:`n" + ($found -join "`n")
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
        Remove-Item "$script:ProfilesPath\$deletedProfile.json" -ErrorAction SilentlyContinue
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
    $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Exe -ne $exe })
    $script:AppProfileRules += [PSCustomObject]@{ Exe = $exe; Profile = $profile }
    Save-AppProfileRules
    Update-AppProfileControls
    Update-Status "Mapped $exe to '$profile'"
})
$appProfileRemoveBtn.Add_Click({
    if ($appProfileRulesList.SelectedItem -eq $null) { return }
    $exe = [string]$appProfileRulesList.SelectedItem.Tag
    $script:AppProfileRules = @($script:AppProfileRules | Where-Object { $_.Exe -ne $exe })
    Save-AppProfileRules
    Update-AppProfileControls
    Update-Status "Removed app profile for $exe"
})

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
    $script:ProfileSchedules = @($script:ProfileSchedules | Where-Object { $_.Time -ne $time })
    $script:ProfileSchedules += [PSCustomObject]@{ Time = $time; Profile = $profile }
    Save-ProfileSchedules
    Update-ScheduleControls
    Update-Status "Scheduled $profile at $time"
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
Initialize-WmiBrightness; Get-Monitors; Initialize-GPU; Initialize-CpuMonitor; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList
Load-AppProfileRules; Update-AppProfileControls; Start-AppProfileWatcher
Load-ProfileSchedules; Update-ScheduleControls; Start-ProfileScheduleWatcher
Load-IdleDimSettings; Update-IdleDimControls; Start-IdleDimWatcher
Load-BatteryProfileSettings; Update-BatteryProfileControls; Start-BatteryProfileWatcher
Update-ProfileStorageControls
if (-not ($script:HasNvidia -or $script:HasAmd -or $script:HasCpuTempMonitor)) { $gpuTab.Visibility = "Collapsed" } else {
    $script:GpuTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:GpuTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:GpuTimer.Add_Tick({ Update-GpuStats }); $script:GpuTimer.Start(); Update-GpuStats
}

Initialize-TrayIcon

$window.Add_StateChanged({
    if ($script:TraySuppressWindowStateEvent -or $script:IsQuitting) { return }
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { Hide-MainWindowToTray }
})

$window.Add_Closed({ if ($script:GpuTimer) { $script:GpuTimer.Stop() }; if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; if ($script:AmbientLightTimer) { $script:AmbientLightTimer.Stop() }; if ($script:AppProfileTimer) { $script:AppProfileTimer.Stop() }; if ($script:AppProfileCaptureTimer) { $script:AppProfileCaptureTimer.Stop() }; if ($script:ProfileScheduleTimer) { $script:ProfileScheduleTimer.Stop() }; if ($script:IdleDimTimer) { $script:IdleDimTimer.Stop() }; if ($script:BatteryProfileTimer) { $script:BatteryProfileTimer.Stop() }; if ($script:FpsOverlayTimer) { $script:FpsOverlayTimer.Stop() }
    if ($script:FpsOverlayWindow) { try { $script:FpsOverlayWindow.Close() } catch {} }
    if ($script:HardwareMonitorComputer) { try { $script:HardwareMonitorComputer.Close() } catch {} }
    Dispose-TrayMode
    foreach ($mon in $script:PhysicalMonitors) { if ($mon.Handle -ne [IntPtr]::Zero) { [MonitorAPI]::DestroyPhysicalMonitor($mon.Handle) | Out-Null } }
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
if ($LoadProfile -and (Test-Path "$script:ProfilesPath\$LoadProfile.json")) { $profilesList.SelectedItem = $LoadProfile; $loadProfileBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }

$window.ShowDialog() | Out-Null
