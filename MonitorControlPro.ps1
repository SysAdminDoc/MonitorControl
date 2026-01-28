<#
.SYNOPSIS
    MonitorControl Pro v3.0 - Advanced Display & GPU Settings Utility
.DESCRIPTION
    Comprehensive GUI for monitor DDC/CI control with VCP explorer, input switching,
    color temperature presets, sync across monitors, and time-based automation.
.NOTES
    Version: 3.0 - Enhanced with features from Twinkle Tray, Monitorian, ControlMyMonitor research
#>

param([switch]$StartMinimized, [string]$LoadProfile)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

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
    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

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
    public const byte VCP_INPUT_SOURCE = 0x60, VCP_POWER_MODE = 0xD6;
    public const byte VCP_RESTORE_FACTORY_DEFAULTS = 0x04, VCP_RESTORE_FACTORY_COLOR = 0x08;
    public const byte VCP_VERSION = 0xDF, VCP_DISPLAY_USAGE_TIME = 0xC6;
    public const uint POWER_ON = 0x01, POWER_STANDBY = 0x02, POWER_OFF = 0x04;
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
"@

try { Add-Type -TypeDefinition $nativeCode -ErrorAction SilentlyContinue } catch {}

$script:PhysicalMonitors = @()
$script:CurrentMonitorIndex = 0
$script:HasNvidia = $false
$script:NvidiaSmiPath = $null
$script:GpuTimer = $null
$script:AutoModeTimer = $null
$script:ProfilesPath = "$env:APPDATA\MonitorControlPro"
$script:UpdatingUI = $false
$script:ApplyToAll = $false
$script:AutoModeEnabled = $false

$script:VCPCodeDescriptions = @{
    0x04 = "Factory Reset"; 0x08 = "Reset Color"; 0x10 = "Brightness"; 0x12 = "Contrast"
    0x14 = "Color Preset"; 0x16 = "Red Gain"; 0x18 = "Green Gain"; 0x1A = "Blue Gain"
    0x60 = "Input Source"; 0x62 = "Volume"; 0x87 = "Sharpness"; 0x8D = "Mute"
    0xC6 = "Usage Time"; 0xD6 = "Power Mode"; 0xDF = "VCP Version"
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
        $script:PhysicalMonitors += [PSCustomObject]@{
            Handle = [IntPtr]::Zero; HMonitor = [IntPtr]::Zero; Name = "No DDC/CI Monitor"; Index = 1
            DeviceName = ""; Width = 1920; Height = 1080; RefreshRate = 60; IsPrimary = $true
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
    } else {
        $mon = $script:PhysicalMonitors[$script:CurrentMonitorIndex]
        if ($mon.Handle -ne [IntPtr]::Zero) { Set-VCPValue -Handle $mon.Handle -VCPCode $VCPCode -Value $Value | Out-Null }
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
    Set-GammaRamp -Gamma 1.0 -RedMult $settings.GammaRed -GreenMult $settings.GammaGreen -BlueMult $settings.GammaBlue
    return $settings
}

function Initialize-GPU {
    $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        if ($gpu.Name -match "NVIDIA") {
            $script:HasNvidia = $true
            @("${env:ProgramFiles}\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "${env:SystemRoot}\System32\nvidia-smi.exe") | ForEach-Object { if (Test-Path $_) { $script:NvidiaSmiPath = $_; return } }
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

if (-not (Test-Path $script:ProfilesPath)) { New-Item -ItemType Directory -Path $script:ProfilesPath -Force | Out-Null }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MonitorControl Pro v3.0" Width="640" Height="680" MinWidth="560" MinHeight="560"
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
            <TextBlock Text="v3.0 - Click monitor to select" FontSize="9" Foreground="#505050" Margin="0,1,0,0"/>
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
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
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
                <Grid Grid.Row="6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Button x:Name="PresetDay" Content="Day" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetNight" Grid.Column="2" Content="Night" Style="{StaticResource Btn}" Padding="5,5"/>
                    <Button x:Name="PresetAutoMode" Grid.Column="4" Content="Auto" Style="{StaticResource OrangeBtn}" Padding="5,5"/>
                    <Button x:Name="PresetReset" Grid.Column="6" Content="Reset" Style="{StaticResource AccBtn}" Padding="5,5"/>
                </Grid>
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem Header="Monitor">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><ScrollViewer VerticalScrollBarVisibility="Auto"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
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
            </Grid></ScrollViewer></Border>
        </TabItem>
        <TabItem x:Name="GpuTab" Header="GPU">
            <Border Background="#151515" CornerRadius="0,5,5,5" Padding="10"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Border Background="#1a1a1a" CornerRadius="5" Padding="10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock x:Name="GpuNameText" Text="GPU" FontSize="12" Foreground="#76b900" FontWeight="SemiBold"/>
                        <TextBlock x:Name="GpuStatsText" Text="-- C | -- MHz | -- W" FontSize="8" Foreground="#707070" Margin="0,2,0,0"/></StackPanel>
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
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
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
$presetAutoMode = $window.FindName("PresetAutoMode"); $presetReset = $window.FindName("PresetReset")
$inputSourceCombo = $window.FindName("InputSourceCombo")
$powerOffBtn = $window.FindName("PowerOffBtn"); $powerStandbyBtn = $window.FindName("PowerStandbyBtn"); $powerOnBtn = $window.FindName("PowerOnBtn")
$volumeSlider = $window.FindName("VolumeSlider"); $volumeValue = $window.FindName("VolumeValue"); $muteCheckbox = $window.FindName("MuteCheckbox")
$sharpnessSlider = $window.FindName("SharpnessSlider"); $sharpnessValue = $window.FindName("SharpnessValue")
$resetColorBtn = $window.FindName("ResetColorBtn"); $factoryResetBtn = $window.FindName("FactoryResetBtn")
$allMonitorsStandbyBtn = $window.FindName("AllMonitorsStandbyBtn")
$gpuTab = $window.FindName("GpuTab"); $gpuNameText = $window.FindName("GpuNameText"); $gpuStatsText = $window.FindName("GpuStatsText")
$gpuTempText = $window.FindName("GpuTempText"); $gpuUtilText = $window.FindName("GpuUtilText"); $gpuUtilBar = $window.FindName("GpuUtilBar")
$memUsageText = $window.FindName("MemUsageText"); $memUtilBar = $window.FindName("MemUtilBar")
$fanSpeedText = $window.FindName("FanSpeedText"); $fanSpeedBar = $window.FindName("FanSpeedBar")
$powerDrawText = $window.FindName("PowerDrawText"); $powerDrawBar = $window.FindName("PowerDrawBar")
$vibranceSlider = $window.FindName("VibranceSlider"); $vibranceValue = $window.FindName("VibranceValue")
$gammaSlider = $window.FindName("GammaSlider"); $gammaValue = $window.FindName("GammaValue")
$vcpCodeBox = $window.FindName("VCPCodeBox"); $vcpPresetCombo = $window.FindName("VCPPresetCombo"); $vcpQueryBtn = $window.FindName("VCPQueryBtn")
$vcpResultBox = $window.FindName("VCPResultBox"); $vcpSetValueBox = $window.FindName("VCPSetValueBox"); $vcpSetBtn = $window.FindName("VCPSetBtn"); $vcpScanBtn = $window.FindName("VCPScanBtn")
$profileNameBox = $window.FindName("ProfileNameBox"); $profilesList = $window.FindName("ProfilesList")
$saveProfileBtn = $window.FindName("SaveProfileBtn"); $loadProfileBtn = $window.FindName("LoadProfileBtn"); $deleteProfileBtn = $window.FindName("DeleteProfileBtn")
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
    $script:UpdatingUI = $false; Update-Status "$($mon.Name)"
}

function Refresh-Monitors { Get-Monitors; if ($script:CurrentMonitorIndex -ge $script:PhysicalMonitors.Count) { $script:CurrentMonitorIndex = 0 }; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList }
function Update-ProfilesList { $profilesList.Items.Clear(); if (Test-Path $script:ProfilesPath) { Get-ChildItem -Path $script:ProfilesPath -Filter "*.json" | ForEach-Object { $profilesList.Items.Add($_.BaseName) | Out-Null } } }

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

# Populate VCP preset combo
foreach ($code in ($script:VCPCodeDescriptions.Keys | Sort-Object)) { $item = New-Object System.Windows.Controls.ComboBoxItem; $item.Content = "0x{0:X2} - {1}" -f $code, $script:VCPCodeDescriptions[$code]; $item.Tag = $code; $vcpPresetCombo.Items.Add($item) | Out-Null }
$vcpPresetCombo.SelectedIndex = 0

# Event handlers
$applyAllCheckbox.Add_Checked({ $script:ApplyToAll = $true }); $applyAllCheckbox.Add_Unchecked({ $script:ApplyToAll = $false })
$refreshBtn.Add_Click({ Refresh-Monitors }); $identifyBtn.Add_Click({ Show-IdentifyOverlays })

$brightnessSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $v = [int]$brightnessSlider.Value; $brightnessValue.Text = $v; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $v })
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

$presetDay.Add_Click({ $script:AutoModeEnabled = $false; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 80 -Force; Set-GammaRamp -Gamma 1.0; $script:UpdatingUI = $true; $brightnessSlider.Value = 80; $brightnessValue.Text = "80"; $script:UpdatingUI = $false; Update-Status "Day Mode" })
$presetNight.Add_Click({ $script:AutoModeEnabled = $false; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 40 -Force; Set-GammaRamp -Gamma 1.0 -RedMult 1.0 -GreenMult 0.9 -BlueMult 0.75; $script:UpdatingUI = $true; $brightnessSlider.Value = 40; $brightnessValue.Text = "40"; $script:UpdatingUI = $false; Update-Status "Night Mode" })
$presetAutoMode.Add_Click({
    $script:AutoModeEnabled = -not $script:AutoModeEnabled
    if ($script:AutoModeEnabled) {
        $s = Apply-TimeBasedSettings; $autoModeText.Text = "Auto: $($s.Mode)"; $script:UpdatingUI = $true; $brightnessSlider.Value = $s.Brightness; $brightnessValue.Text = $s.Brightness; $script:UpdatingUI = $false
        if ($null -eq $script:AutoModeTimer) { $script:AutoModeTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:AutoModeTimer.Interval = [TimeSpan]::FromMinutes(15); $script:AutoModeTimer.Add_Tick({ if ($script:AutoModeEnabled) { $s = Apply-TimeBasedSettings; $autoModeText.Text = "Auto: $($s.Mode)" } }) }
        $script:AutoModeTimer.Start()
    } else { if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }; $autoModeText.Text = ""; Update-Status "Auto Mode Off" }
})
$presetReset.Add_Click({ $script:AutoModeEnabled = $false; $autoModeText.Text = ""; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value 50 -Force; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value 50 -Force; Set-GammaRamp -Gamma 1.0; Load-MonitorSettings; Update-Status "Reset" })

$inputSourceCombo.Add_SelectionChanged({ if ($script:UpdatingUI -or $inputSourceCombo.SelectedItem -eq $null) { return }; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_INPUT_SOURCE) -Value ([uint32]$inputSourceCombo.SelectedItem.Tag); Update-Status "Input: $($inputSourceCombo.SelectedItem.Content)" })
$powerOffBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_OFF); Update-Status "Monitor Off" })
$powerStandbyBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_STANDBY); Update-Status "Monitor Standby" })
$powerOnBtn.Add_Click({ Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_POWER_MODE) -Value ([MonitorAPI]::POWER_ON); Update-Status "Monitor On" })
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
    $found = @(); foreach ($code in @(0x04,0x08,0x10,0x12,0x14,0x16,0x18,0x1A,0x60,0x62,0x87,0x8D,0xC6,0xD6,0xDF)) {
        $r = Get-VCPValue -Handle $mon.Handle -VCPCode ([byte]$code)
        if ($r.Success) { $desc = if ($script:VCPCodeDescriptions.ContainsKey($code)) { $script:VCPCodeDescriptions[$code] } else { "Unknown" }; $found += "0x{0:X2} {1,-20} = {2} (max:{3})" -f $code, $desc, $r.Current, $r.Maximum }
    }
    $vcpResultBox.Text = "Supported VCP Codes:`n" + ($found -join "`n")
})

$saveProfileBtn.Add_Click({
    $name = $profileNameBox.Text.Trim(); if ([string]::IsNullOrEmpty($name)) { return }
    $profile = @{ Name = $name; Brightness = $brightnessSlider.Value; Contrast = $contrastSlider.Value; Red = $redSlider.Value; Green = $greenSlider.Value; Blue = $blueSlider.Value; Gamma = $gammaSlider.Value; GammaRed = $gammaRedSlider.Value; GammaGreen = $gammaGreenSlider.Value; GammaBlue = $gammaBlueSlider.Value }
    $profile | ConvertTo-Json | Set-Content -Path "$script:ProfilesPath\$name.json" -Encoding UTF8; Update-ProfilesList; Update-Status "Saved '$name'"
})
$loadProfileBtn.Add_Click({
    if ($profilesList.SelectedItem -eq $null) { return }; $name = $profilesList.SelectedItem; $path = "$script:ProfilesPath\$name.json"; if (-not (Test-Path $path)) { return }
    $p = Get-Content $path -Raw | ConvertFrom-Json; $script:UpdatingUI = $true
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BRIGHTNESS) -Value $p.Brightness; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_CONTRAST) -Value $p.Contrast
    Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_RED_GAIN) -Value $p.Red; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_GREEN_GAIN) -Value $p.Green; Set-VCPValueWithSync -VCPCode ([MonitorAPI]::VCP_BLUE_GAIN) -Value $p.Blue
    $brightnessSlider.Value = $p.Brightness; $brightnessValue.Text = $p.Brightness; $contrastSlider.Value = $p.Contrast; $contrastValue.Text = $p.Contrast
    $redSlider.Value = $p.Red; $redValue.Text = $p.Red; $greenSlider.Value = $p.Green; $greenValue.Text = $p.Green; $blueSlider.Value = $p.Blue; $blueValue.Text = $p.Blue
    if ($p.Gamma) { $gammaSlider.Value = $p.Gamma; $gammaValue.Text = ($p.Gamma / 100).ToString("F2") }
    if ($p.GammaRed) { $gammaRedSlider.Value = $p.GammaRed; $gammaGreenSlider.Value = $p.GammaGreen; $gammaBlueSlider.Value = $p.GammaBlue; Set-GammaRamp -Gamma ($p.Gamma/100) -RedMult ($p.GammaRed/100) -GreenMult ($p.GammaGreen/100) -BlueMult ($p.GammaBlue/100) }
    $script:UpdatingUI = $false; Update-Status "Loaded '$name'"
})
$deleteProfileBtn.Add_Click({ if ($profilesList.SelectedItem -ne $null -and [System.Windows.MessageBox]::Show("Delete '$($profilesList.SelectedItem)'?", "Delete", "YesNo", "Question") -eq "Yes") { Remove-Item "$script:ProfilesPath\$($profilesList.SelectedItem).json" -ErrorAction SilentlyContinue; Update-ProfilesList } })

$displaySettingsBtn.Add_Click({ Start-Process "ms-settings:display" }); $colorMgmtBtn.Add_Click({ Start-Process "colorcpl.exe" })
$gpuControlPanelBtn.Add_Click({ if ($script:HasNvidia) { Start-Process "nvidia-settings" -ErrorAction SilentlyContinue } else { Start-Process "ms-settings:display" } })
$resetGammaBtn.Add_Click({ Set-GammaRamp -Gamma 1.0; $script:UpdatingUI = $true; $gammaSlider.Value = 100; $gammaValue.Text = "1.00"; $gammaRedSlider.Value = 100; $gammaRedValue.Text = "1.00"; $gammaGreenSlider.Value = 100; $gammaGreenValue.Text = "1.00"; $gammaBlueSlider.Value = 100; $gammaBlueValue.Text = "1.00"; $script:UpdatingUI = $false; Update-Status "Gamma Reset" })
$gammaSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $g = $gammaSlider.Value / 100; $gammaValue.Text = $g.ToString("F2"); Set-GammaRamp -Gamma $g -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaRedSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaRedValue.Text = ($gammaRedSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaGreenSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaGreenValue.Text = ($gammaGreenSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })
$gammaBlueSlider.Add_ValueChanged({ if ($script:UpdatingUI) { return }; $gammaBlueValue.Text = ($gammaBlueSlider.Value / 100).ToString("F2"); Set-GammaRamp -Gamma ($gammaSlider.Value/100) -RedMult ($gammaRedSlider.Value/100) -GreenMult ($gammaGreenSlider.Value/100) -BlueMult ($gammaBlueSlider.Value/100) })

function Update-GpuStats {
    if (-not $script:HasNvidia) { return }; $stats = Get-NvidiaStats
    if ($stats) {
        $gpuNameText.Text = $stats.Name; $gpuTempText.Text = $stats.Temp.ToString(); $gpuStatsText.Text = "$($stats.Temp) C | $($stats.Clock) MHz | $($stats.Power) W"
        $gpuUtilText.Text = "$($stats.Util)%"; $gpuUtilBar.Value = $stats.Util; $memUsageText.Text = "$($stats.MemUsed) / $($stats.MemTotal) GB"
        $memUtilBar.Value = if ($stats.MemTotal -gt 0) { ($stats.MemUsed / $stats.MemTotal) * 100 } else { 0 }
        $fanSpeedText.Text = "$($stats.Fan)%"; $fanSpeedBar.Value = $stats.Fan; $powerDrawText.Text = "$($stats.Power) / $($stats.PowerLimit) W"
        $powerDrawBar.Value = if ($stats.PowerLimit -gt 0) { ($stats.Power / $stats.PowerLimit) * 100 } else { 0 }
    }
}

# Initialize
Get-Monitors; Initialize-GPU; Draw-MonitorLayout; Load-MonitorSettings; Update-ProfilesList
if (-not $script:HasNvidia) { $gpuTab.Visibility = "Collapsed" } else {
    $script:GpuTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:GpuTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:GpuTimer.Add_Tick({ Update-GpuStats }); $script:GpuTimer.Start(); Update-GpuStats
}

$window.Add_Closed({ if ($script:GpuTimer) { $script:GpuTimer.Stop() }; if ($script:AutoModeTimer) { $script:AutoModeTimer.Stop() }
    foreach ($mon in $script:PhysicalMonitors) { if ($mon.Handle -ne [IntPtr]::Zero) { [MonitorAPI]::DestroyPhysicalMonitor($mon.Handle) | Out-Null } }
})

if ($StartMinimized) { $window.WindowState = "Minimized" }
if ($LoadProfile -and (Test-Path "$script:ProfilesPath\$LoadProfile.json")) { $profilesList.SelectedItem = $LoadProfile; $loadProfileBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }

$window.ShowDialog() | Out-Null
