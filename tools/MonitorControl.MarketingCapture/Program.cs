using System.ComponentModel;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace MonitorControl.MarketingCapture;

internal static class Program
{
    private const uint DesktopAccess = 0x000F01FF;
    private const uint WaitTimeout = 0x00000102;
    private const uint WmClose = 0x0010;
    private const int UoiName = 2;
    private static readonly string[] ScreenshotNames =
    [
        "display.png",
        "monitor.png",
        "hardware.png",
        "vcp-explorer.png",
        "profiles.png",
        "automation.png",
        "system.png",
    ];

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            SetBestDpiAwareness();
            if (args.Length > 0 && args[0].Equals("--axe-scan", StringComparison.OrdinalIgnoreCase))
                return RunAxeScan(AxeScanOptions.Parse(args), GetCurrentDesktopName());
            var options = CaptureOptions.Parse(args);
            return options.Worker ? RunWorker(options) : RunOnPrivateDesktop(options);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static int RunOnPrivateDesktop(CaptureOptions options)
    {
        Directory.CreateDirectory(options.OutputDirectory);
        var desktopName = $"MonitorControlCapture_{Environment.ProcessId}_{DateTime.UtcNow.Ticks}";
        var desktop = CreateDesktop(desktopName, null, IntPtr.Zero, 0, DesktopAccess, IntPtr.Zero);
        if (desktop == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the private capture desktop.");

        try
        {
            var workerPath = Environment.ProcessPath
                ?? throw new InvalidOperationException("The capture worker path is unavailable.");
            var commandLine = new StringBuilder(
                $"\"{workerPath}\" --worker --operation {options.Operation} --script \"{options.ScriptPath}\" --output-dir \"{options.OutputDirectory}\"");
            var startup = new StartupInfo
            {
                Size = Marshal.SizeOf<StartupInfo>(),
                Desktop = $"winsta0\\{desktopName}",
            };

            if (!CreateProcess(
                    workerPath,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    0,
                    IntPtr.Zero,
                    AppContext.BaseDirectory,
                    ref startup,
                    out var processInfo))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not start the private capture worker.");
            }

            try
            {
                var timeout = options.Operation.Equals("verify", StringComparison.OrdinalIgnoreCase) ? 960_000u : 180_000u;
                var wait = WaitForSingleObject(processInfo.Process, timeout);
                if (wait == WaitTimeout)
                {
                    TerminateProcess(processInfo.Process, 124);
                    throw new TimeoutException($"The private {options.Operation} operation timed out.");
                }
                if (!GetExitCodeProcess(processInfo.Process, out var exitCode))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the capture worker status.");
                return unchecked((int)exitCode);
            }
            finally
            {
                CloseHandle(processInfo.Thread);
                CloseHandle(processInfo.Process);
            }
        }
        finally
        {
            CloseDesktop(desktop);
        }
    }

    private static int RunWorker(CaptureOptions options)
    {
        var desktopName = GetCurrentDesktopName();
        if (string.Equals(desktopName, "Default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The capture worker refuses to run on the interactive desktop.");

        return options.Operation.Equals("verify", StringComparison.OrdinalIgnoreCase)
            ? RunVerificationWorker(options, desktopName)
            : RunCaptureWorker(options, desktopName);
    }

    private static int RunVerificationWorker(CaptureOptions options, string desktopName)
    {
        var windowsPowerShell = GetWindowsPowerShellPath();
        var startInfo = new ProcessStartInfo
        {
            FileName = windowsPowerShell,
            WorkingDirectory = Path.GetDirectoryName(options.ScriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(options.ScriptPath);
        startInfo.Environment["MONITORCONTROL_PRIVATE_RUNNER"] = Environment.ProcessPath
            ?? throw new InvalidOperationException("The private verification host path is unavailable.");
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("The private verification process did not start.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(900_000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("Private verification timed out after 15 minutes.");
        }
        Task.WaitAll(stdout, stderr);
        if (!string.IsNullOrWhiteSpace(stdout.Result))
            Console.Write(stdout.Result);
        if (!string.IsNullOrWhiteSpace(stderr.Result))
            Console.Error.Write(stderr.Result);
        Console.WriteLine($"Verification ran on private desktop '{desktopName}'.");
        return process.ExitCode;
    }

    private static int RunAxeScan(AxeScanOptions options, string desktopName)
    {
        if (string.Equals(desktopName, "Default", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The accessibility scan refuses to run on the interactive desktop.");

        Directory.CreateDirectory(Path.GetDirectoryName(options.OutputPath)!);
        var loadContext = AssemblyLoadContext.Default;
        Assembly? ResolveAxeAssembly(AssemblyLoadContext context, AssemblyName name)
        {
            if (string.IsNullOrWhiteSpace(name.Name))
                return null;
            var candidate = Path.Combine(options.AxeDirectory, name.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
        }

        loadContext.Resolving += ResolveAxeAssembly;
        try
        {
            var automationPath = Path.Combine(options.AxeDirectory, "Axe.Windows.Automation.dll");
            if (!File.Exists(automationPath))
                throw new FileNotFoundException("Axe.Windows.Automation.dll was not found.", automationPath);
            var automation = loadContext.LoadFromAssemblyPath(automationPath);
            var configType = GetRequiredType(automation, "Axe.Windows.Automation.Config");
            var builderType = configType.GetNestedType("Builder", BindingFlags.Public)
                ?? throw new MissingMemberException(configType.FullName, "Builder");
            var builder = GetRequiredMethod(builderType, "ForProcessId", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, [options.ProcessId])
                ?? throw new InvalidOperationException("Axe.Windows did not create a configuration builder.");
            var formatType = GetRequiredType(automation, "Axe.Windows.Automation.OutputFileFormat");
            var noOutput = Enum.Parse(formatType, "None");
            builder = GetRequiredMethod(builderType, "WithOutputFileFormat", BindingFlags.Public | BindingFlags.Instance)
                .Invoke(builder, [noOutput])
                ?? throw new InvalidOperationException("Axe.Windows did not accept the output format.");
            var config = GetRequiredMethod(builderType, "Build", BindingFlags.Public | BindingFlags.Instance)
                .Invoke(builder, null)
                ?? throw new InvalidOperationException("Axe.Windows did not build a scan configuration.");
            var factoryType = GetRequiredType(automation, "Axe.Windows.Automation.ScannerFactory");
            var scanner = GetRequiredMethod(factoryType, "CreateScanner", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, [config])
                ?? throw new InvalidOperationException("Axe.Windows did not create a scanner.");
            var scannerType = GetRequiredType(automation, "Axe.Windows.Automation.IScanner");
            var output = GetRequiredMethod(scannerType, "Scan", BindingFlags.Public | BindingFlags.Instance)
                .Invoke(scanner, [null])
                ?? throw new InvalidOperationException("Axe.Windows returned no scan output.");

            var windowOutputs = GetRequiredProperty(output, "WindowScanOutputs") as IEnumerable
                ?? throw new InvalidOperationException("Axe.Windows returned no window collection.");
            var findings = new List<object>();
            var windowCount = 0;
            var errorCount = 0;
            foreach (var window in windowOutputs)
            {
                if (window is null)
                    continue;
                windowCount++;
                errorCount += Convert.ToInt32(GetRequiredProperty(window, "ErrorCount"));
                if (GetRequiredProperty(window, "Errors") is not IEnumerable errors)
                    continue;
                foreach (var error in errors)
                {
                    if (error is null)
                        continue;
                    var rule = GetRequiredProperty(error, "Rule")
                        ?? throw new InvalidOperationException("An Axe.Windows finding has no rule metadata.");
                    var element = GetRequiredProperty(error, "Element")
                        ?? throw new InvalidOperationException("An Axe.Windows finding has no element metadata.");
                    findings.Add(new
                    {
                        ruleId = GetRequiredProperty(rule, "ID")?.ToString(),
                        description = GetRequiredProperty(rule, "Description")?.ToString(),
                        howToFix = GetRequiredProperty(rule, "HowToFix")?.ToString(),
                        standard = GetRequiredProperty(rule, "Standard")?.ToString(),
                        propertyId = Convert.ToInt32(GetRequiredProperty(rule, "PropertyID")),
                        condition = GetRequiredProperty(rule, "Condition")?.ToString(),
                        element = ReadStringDictionary(GetRequiredProperty(element, "Properties")),
                    });
                }
            }

            var report = new
            {
                schemaVersion = 1,
                scanner = "Axe.Windows",
                scannerVersion = automation.GetName().Version?.ToString(),
                scanId = options.ScanId,
                processId = options.ProcessId,
                desktop = "private",
                outputFileFormat = "None",
                windowCount,
                errorCount,
                findings,
            };
            File.WriteAllText(
                options.OutputPath,
                JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true })
                    .Replace("\r\n", "\n", StringComparison.Ordinal) + "\n");
            if (windowCount == 0)
                throw new InvalidOperationException("Axe.Windows found no top-level application window.");
            Console.WriteLine($"Axe.Windows scanned {windowCount} window(s) with {errorCount} finding(s) on private desktop '{desktopName}'.");
            return errorCount == 0 ? 0 : 2;
        }
        finally
        {
            loadContext.Resolving -= ResolveAxeAssembly;
        }
    }

    private static Type GetRequiredType(Assembly assembly, string name) =>
        assembly.GetType(name, throwOnError: true)
        ?? throw new TypeLoadException($"Required Axe.Windows type was not found: {name}");

    private static MethodInfo GetRequiredMethod(Type type, string name, BindingFlags flags) =>
        type.GetMethods(flags).SingleOrDefault(method => method.Name == name)
        ?? throw new MissingMethodException(type.FullName, name);

    private static object? GetRequiredProperty(object instance, string name)
    {
        var property = instance.GetType().GetProperty(name, BindingFlags.Public | BindingFlags.Instance)
            ?? throw new MissingMemberException(instance.GetType().FullName, name);
        return property.GetValue(instance);
    }

    private static SortedDictionary<string, string?> ReadStringDictionary(object? value)
    {
        var result = new SortedDictionary<string, string?>(StringComparer.Ordinal);
        if (value is not IEnumerable entries)
            return result;
        foreach (var entry in entries)
        {
            if (entry is null)
                continue;
            var key = entry.GetType().GetProperty("Key")?.GetValue(entry)?.ToString();
            if (!string.IsNullOrWhiteSpace(key))
                result[key] = entry.GetType().GetProperty("Value")?.GetValue(entry)?.ToString();
        }
        return result;
    }

    private static int RunCaptureWorker(CaptureOptions options, string desktopName)
    {

        Directory.CreateDirectory(options.OutputDirectory);
        foreach (var name in ScreenshotNames.Append("render.complete").Append("render.error.txt"))
        {
            var path = Path.Combine(options.OutputDirectory, name);
            if (File.Exists(path))
                File.Delete(path);
        }

        var sandboxRoot = Path.Combine(Path.GetTempPath(), $"MonitorControl-MarketingCapture-{Guid.NewGuid():N}");
        var roaming = Path.Combine(sandboxRoot, "AppData", "Roaming");
        var local = Path.Combine(sandboxRoot, "AppData", "Local");
        Directory.CreateDirectory(roaming);
        Directory.CreateDirectory(local);

        Process? process = null;
        try
        {
            process = StartPowerShell(options, roaming, local);
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            var deadline = DateTime.UtcNow.AddSeconds(75);
            var completePath = Path.Combine(options.OutputDirectory, "render.complete");
            var errorPath = Path.Combine(options.OutputDirectory, "render.error.txt");
            while (DateTime.UtcNow < deadline && !File.Exists(completePath) && !File.Exists(errorPath))
            {
                if (process.HasExited)
                    break;
                Thread.Sleep(150);
            }

            if (File.Exists(errorPath))
                throw new InvalidOperationException(File.ReadAllText(errorPath));
            if (!File.Exists(completePath))
            {
                var processOutput = stdout.IsCompletedSuccessfully ? stdout.Result : string.Empty;
                var processError = stderr.IsCompletedSuccessfully ? stderr.Result : string.Empty;
                throw new TimeoutException($"Product renders did not complete. Output: {processOutput} {processError}");
            }

            var screenshots = ScreenshotNames.Select(name => InspectScreenshot(options.OutputDirectory, name)).ToArray();
            var report = new
            {
                capturedAtUtc = DateTimeOffset.UtcNow,
                privateDesktop = desktopName,
                source = Path.GetFileName(options.ScriptPath),
                theme = "Dark",
                marketingCapture = true,
                screenshots,
            };
            File.WriteAllText(
                Path.Combine(options.OutputDirectory, "capture-report.json"),
                JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true })
                    .Replace("\r\n", "\n", StringComparison.Ordinal) + "\n");
            File.Delete(completePath);
            Console.WriteLine($"Captured {screenshots.Length} product views on private desktop '{desktopName}'.");
            return 0;
        }
        finally
        {
            if (process is not null)
            {
                if (!process.HasExited)
                {
                    var window = FindWindowForProcess(process.Id);
                    if (window != IntPtr.Zero)
                        PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero);
                    if (!process.WaitForExit(5_000))
                        process.Kill(entireProcessTree: true);
                }
                process.Dispose();
            }
            try
            {
                if (Directory.Exists(sandboxRoot))
                    Directory.Delete(sandboxRoot, recursive: true);
            }
            catch
            {
                // A terminated PowerShell child may release its final profile handle just after exit.
            }
        }
    }

    private static Process StartPowerShell(CaptureOptions options, string roaming, string local)
    {
        var windowsPowerShell = GetWindowsPowerShellPath();

        var startInfo = new ProcessStartInfo
        {
            FileName = windowsPowerShell,
            WorkingDirectory = Path.GetDirectoryName(options.ScriptPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-STA");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(options.ScriptPath);
        startInfo.ArgumentList.Add("-Theme");
        startInfo.ArgumentList.Add("Dark");
        startInfo.ArgumentList.Add("-MarketingCapture");
        startInfo.ArgumentList.Add("-RenderDirectory");
        startInfo.ArgumentList.Add(options.OutputDirectory);
        startInfo.Environment["APPDATA"] = roaming;
        startInfo.Environment["LOCALAPPDATA"] = local;
        return Process.Start(startInfo)
            ?? throw new InvalidOperationException("Windows PowerShell 5.1 did not start.");
    }

    private static string GetWindowsPowerShellPath()
    {
        var windowsPowerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");
        if (!File.Exists(windowsPowerShell))
            throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", windowsPowerShell);
        return windowsPowerShell;
    }

    private static object InspectScreenshot(string outputDirectory, string name)
    {
        var path = Path.Combine(outputDirectory, name);
        if (!File.Exists(path) || new FileInfo(path).Length < 10_000)
            throw new InvalidDataException($"The {name} product render is missing or unexpectedly small.");

        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var bitmap = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
        if (bitmap.PixelWidth < 1_000 || bitmap.PixelHeight < 600)
            throw new InvalidDataException($"The {name} product render has an unexpected size: {bitmap.PixelWidth}x{bitmap.PixelHeight}.");
        var stride = bitmap.PixelWidth * 4;
        var pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);
        var colors = new HashSet<uint>();
        for (var y = 0; y < bitmap.PixelHeight; y += Math.Max(1, bitmap.PixelHeight / 32))
        {
            for (var x = 0; x < bitmap.PixelWidth; x += Math.Max(1, bitmap.PixelWidth / 48))
                colors.Add(BitConverter.ToUInt32(pixels, (y * stride) + (x * 4)));
        }
        if (colors.Count < 12)
            throw new InvalidDataException($"The {name} product render appears blank or unrendered.");
        return new { file = name, width = bitmap.PixelWidth, height = bitmap.PixelHeight, sampledColors = colors.Count };
    }

    private static IntPtr FindWindowForProcess(int processId)
    {
        var desktop = GetThreadDesktop(GetCurrentThreadId());
        var found = IntPtr.Zero;
        EnumDesktopWindows(desktop, (window, _) =>
        {
            GetWindowThreadProcessId(window, out var owner);
            if (owner == processId && IsWindowVisible(window) && GetWindowTextLength(window) > 0)
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    private static string GetCurrentDesktopName()
    {
        var desktop = GetThreadDesktop(GetCurrentThreadId());
        var required = 0;
        GetUserObjectInformation(desktop, UoiName, IntPtr.Zero, 0, ref required);
        if (required <= 2)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not size the desktop name buffer.");
        var buffer = Marshal.AllocHGlobal(required);
        try
        {
            if (!GetUserObjectInformation(desktop, UoiName, buffer, required, ref required))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the desktop name.");
            return Marshal.PtrToStringUni(buffer) ?? string.Empty;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void SetBestDpiAwareness()
    {
        if (!SetProcessDpiAwarenessContext(new IntPtr(-4)))
            SetProcessDpiAware();
    }

    private sealed record CaptureOptions(bool Worker, string Operation, string ScriptPath, string OutputDirectory)
    {
        public static CaptureOptions Parse(string[] args)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var worker = false;
            for (var index = 0; index < args.Length; index++)
            {
                if (args[index].Equals("--worker", StringComparison.OrdinalIgnoreCase))
                {
                    worker = true;
                    continue;
                }
                if (!args[index].StartsWith("--", StringComparison.Ordinal) || index + 1 >= args.Length)
                    throw new ArgumentException("Expected --script and --output-dir arguments.");
                values[args[index][2..]] = args[++index];
            }
            if (!values.TryGetValue("script", out var script))
                throw new ArgumentException("The --script argument is required.");
            var operation = values.GetValueOrDefault("operation", "capture").ToLowerInvariant();
            if (operation is not ("capture" or "verify"))
                throw new ArgumentException("The operation must be capture or verify.");
            var scriptPath = Path.GetFullPath(script);
            if (!File.Exists(scriptPath))
                throw new FileNotFoundException("The MonitorControl entry point was not found.", scriptPath);
            var output = Path.GetFullPath(values.GetValueOrDefault("output-dir", "assets/screenshots"));
            return new CaptureOptions(worker, operation, scriptPath, output);
        }
    }

    private sealed record AxeScanOptions(int ProcessId, string AxeDirectory, string OutputPath, string ScanId)
    {
        public static AxeScanOptions Parse(string[] args)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var index = 1; index < args.Length; index++)
            {
                if (!args[index].StartsWith("--", StringComparison.Ordinal) || index + 1 >= args.Length)
                    throw new ArgumentException("Expected process, Axe.Windows directory, output, and scan id arguments.");
                values[args[index][2..]] = args[++index];
            }
            if (!values.TryGetValue("process-id", out var processText) || !int.TryParse(processText, out var processId) || processId <= 0)
                throw new ArgumentException("The --process-id argument must be a positive integer.");
            if (!values.TryGetValue("axe-directory", out var axeDirectory))
                throw new ArgumentException("The --axe-directory argument is required.");
            if (!values.TryGetValue("output", out var output))
                throw new ArgumentException("The --output argument is required.");
            var fullAxeDirectory = Path.GetFullPath(axeDirectory);
            if (!Directory.Exists(fullAxeDirectory))
                throw new DirectoryNotFoundException($"The Axe.Windows directory was not found: {fullAxeDirectory}");
            var fullOutput = Path.GetFullPath(output);
            var scanId = values.GetValueOrDefault("scan-id", Path.GetFileNameWithoutExtension(fullOutput));
            if (string.IsNullOrWhiteSpace(scanId))
                throw new ArgumentException("The --scan-id argument cannot be empty.");
            return new AxeScanOptions(processId, fullAxeDirectory, fullOutput, scanId);
        }
    }

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string? Reserved;
        public string? Desktop;
        public string? Title;
        public int X;
        public int Y;
        public int XSize;
        public int YSize;
        public int XCountChars;
        public int YCountChars;
        public int FillAttribute;
        public short ShowWindow;
        public short Reserved2;
        public IntPtr Reserved2Pointer;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [DllImport("user32.dll", EntryPoint = "CreateDesktopW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDesktop(string name, string? device, IntPtr deviceMode, uint flags, uint desiredAccess, IntPtr attributes);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumDesktopWindows(IntPtr desktop, EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDesktop(uint threadId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformation(IntPtr handle, int index, IntPtr information, int length, ref int needed);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDpiAware();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
}
