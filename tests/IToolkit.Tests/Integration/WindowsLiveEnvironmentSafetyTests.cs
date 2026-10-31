namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Win32;
using IToolkit.App;
using IToolkit.App.Native;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Identity;
using IToolkit.Core.Services.Office;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using Xunit;

/// <summary>
/// Deep live Windows environment functional and data-safety verification suite.
/// Tests all native Windows platform services, safety engines, 5 operational pillars,
/// edge cases, binary formats, and all ViewModel commands on a real Windows host with
/// 100% data-safety sandboxing (all file writes isolated to %TEMP% and all registry
/// mutations redirected to a temporary HKCU sandbox key that is purged on disposal).
/// </summary>
public class WindowsLiveEnvironmentSafetyTests : IDisposable
{
    private readonly string _sandboxDir;
    private readonly string _sandboxRegRoot;
    private readonly WindowsRegistryService _realRegistry;
    private readonly WindowsFileSystemService _realFileSystem;
    private readonly WindowsProcessRunner _realProcessRunner;
    private readonly WindowsNetworkService _realNetwork;
    private readonly WindowsWmiService _realWmi;
    private readonly ActivityLogger _realLogger;

    public WindowsLiveEnvironmentSafetyTests()
    {
        string runId = $"{DateTime.UtcNow:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}";
        _sandboxDir = Path.Combine(Path.GetTempPath(), $"iToolKit_LiveWinSandbox_{runId}");
        _sandboxRegRoot = $@"HKEY_CURRENT_USER\Software\iToolKit_LiveWinSandbox_{runId}";

        Directory.CreateDirectory(_sandboxDir);

        _realRegistry = new WindowsRegistryService();
        _realFileSystem = new WindowsFileSystemService();
        _realProcessRunner = new WindowsProcessRunner();
        _realNetwork = new WindowsNetworkService(_realProcessRunner);
        _realWmi = new WindowsWmiService();
        _realLogger = new ActivityLogger(_sandboxDir);
    }

    public void Dispose()
    {
        try
        {
            if (OperatingSystem.IsWindows() && _realRegistry.KeyExists(_sandboxRegRoot))
            {
                _realRegistry.DeleteKey(_sandboxRegRoot, recursive: true);
            }
        }
        catch
        {
            // Best-effort cleanup of temporary HKCU sandbox key
        }

        try
        {
            if (Directory.Exists(_sandboxDir))
            {
                Directory.Delete(_sandboxDir, recursive: true);
            }
        }
        catch
        {
            // Best-effort cleanup of temporary directory
        }
    }

    /// <summary>
    /// Redirects any registry mutation (including HKLM/HKCU/HKCR) into the temporary HKCU sandbox key
    /// so that real system and user registry keys are 100% untouched during live Windows mutation tests.
    /// </summary>
    private sealed class SandboxedWindowsRegistryService : IRegistryService
    {
        private readonly WindowsRegistryService _inner;
        private readonly string _sandboxRoot;

        public SandboxedWindowsRegistryService(WindowsRegistryService inner, string sandboxRoot)
        {
            _inner = inner;
            _sandboxRoot = sandboxRoot;
        }

        public string MapPath(string keyPath)
        {
            if (keyPath.StartsWith(_sandboxRoot, StringComparison.OrdinalIgnoreCase))
            {
                return keyPath;
            }

            string normalized = keyPath.Replace('/', '\\').Trim('\\');
            if (normalized.StartsWith("HKEY_CURRENT_USER\\", StringComparison.OrdinalIgnoreCase))
            {
                normalized = "HKCU\\" + normalized.Substring("HKEY_CURRENT_USER\\".Length);
            }
            else if (normalized.StartsWith("HKEY_LOCAL_MACHINE\\", StringComparison.OrdinalIgnoreCase))
            {
                normalized = "HKLM\\" + normalized.Substring("HKEY_LOCAL_MACHINE\\".Length);
            }
            else if (normalized.StartsWith("HKEY_CLASSES_ROOT\\", StringComparison.OrdinalIgnoreCase))
            {
                normalized = "HKCR\\" + normalized.Substring("HKEY_CLASSES_ROOT\\".Length);
            }

            return $@"{_sandboxRoot}\{normalized}";
        }

        public bool KeyExists(string keyPath) => _inner.KeyExists(MapPath(keyPath));
        public bool ValueExists(string keyPath, string valueName) => _inner.ValueExists(MapPath(keyPath), valueName);
        public object? GetValue(string keyPath, string valueName) => _inner.GetValue(MapPath(keyPath), valueName);
        public T? GetValue<T>(string keyPath, string valueName) => _inner.GetValue<T>(MapPath(keyPath), valueName);
        public RegistryValueKind GetValueKind(string keyPath, string valueName) => _inner.GetValueKind(MapPath(keyPath), valueName);
        public bool SetValue(string keyPath, string valueName, object value, RegistryValueKind kind) => _inner.SetValue(MapPath(keyPath), valueName, value, kind);
        public bool DeleteValue(string keyPath, string valueName) => _inner.DeleteValue(MapPath(keyPath), valueName);
        public bool CreateKey(string keyPath) => _inner.CreateKey(MapPath(keyPath));
        public bool DeleteKey(string keyPath, bool recursive = true) => _inner.DeleteKey(MapPath(keyPath), recursive);
        public IEnumerable<string> GetSubKeyNames(string keyPath) => _inner.GetSubKeyNames(MapPath(keyPath));
        public IEnumerable<string> GetValueNames(string keyPath) => _inner.GetValueNames(MapPath(keyPath));
    }

    /// <summary>
    /// Redirects system/profile filesystem paths into the temporary sandbox directory while executing
    /// real Windows FileSystem APIs (FileStream, DriveInfo, SHA256, ZipFile) on disk.
    /// </summary>
    private sealed class SandboxedWindowsFileSystemService : IFileSystemService
    {
        private readonly WindowsFileSystemService _inner;
        private readonly string _sandboxRoot;

        public SandboxedWindowsFileSystemService(WindowsFileSystemService inner, string sandboxRoot)
        {
            _inner = inner;
            _sandboxRoot = sandboxRoot;
        }

        public string MapPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return path;
            string full = Path.GetFullPath(path);
            if (full.StartsWith(_sandboxRoot, StringComparison.OrdinalIgnoreCase))
            {
                return full;
            }

            string root = Path.GetPathRoot(full) ?? @"C:\";
            string relative = full.Substring(root.Length).TrimStart('\\', '/');
            return Path.Combine(_sandboxRoot, "VirtualFs", relative);
        }

        public bool FileExists(string path) => _inner.FileExists(MapPath(path));
        public bool DirectoryExists(string path) => _inner.DirectoryExists(MapPath(path));
        public void CreateDirectory(string path) => _inner.CreateDirectory(MapPath(path));
        public void DeleteFile(string path) => _inner.DeleteFile(MapPath(path));
        public void DeleteDirectory(string path, bool recursive = true) => _inner.DeleteDirectory(MapPath(path), recursive);
        public void CopyFile(string source, string destination, bool overwrite = true)
        {
            string mappedDst = MapPath(destination);
            string? dir = Path.GetDirectoryName(mappedDst);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            _inner.CopyFile(MapPath(source), mappedDst, overwrite);
        }
        public void MoveFile(string source, string destination)
        {
            string mappedDst = MapPath(destination);
            string? dir = Path.GetDirectoryName(mappedDst);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            _inner.MoveFile(MapPath(source), mappedDst);
        }
        public void MoveDirectory(string source, string destination)
        {
            string mappedDst = MapPath(destination);
            string? dir = Path.GetDirectoryName(mappedDst);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            _inner.MoveDirectory(MapPath(source), mappedDst);
        }
        public void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true) =>
            _inner.ExtractZipArchive(MapPath(zipFilePath), MapPath(destinationDirectory), overwrite);
        public long GetFileSize(string path) => _inner.GetFileSize(MapPath(path));
        public long GetAvailableFreeSpace(string path) => _inner.GetAvailableFreeSpace(_sandboxRoot);
        public bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2) =>
            _inner.CheckDiskSpace(_sandboxRoot, requiredBytes, safetyMultiplier);
        public string ComputeSha256(string path) => _inner.ComputeSha256(MapPath(path));
        public Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default) =>
            _inner.ComputeSha256Async(MapPath(path), cancellationToken);
        public bool IsFileLocked(string path) => _inner.IsFileLocked(MapPath(path));
        public void CreateSymbolicLink(string linkPath, string targetPath)
        {
            string mappedLink = MapPath(linkPath);
            string mappedTarget = MapPath(targetPath);
            string? dir = Path.GetDirectoryName(mappedLink);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            try
            {
                _inner.CreateSymbolicLink(mappedLink, mappedTarget);
            }
            catch
            {
                _inner.CopyFile(mappedTarget, mappedLink, overwrite: true);
            }
        }
        public string ReadAllText(string path, Encoding? encoding = null) => _inner.ReadAllText(MapPath(path), encoding);
        public void WriteAllText(string path, string contents, Encoding? encoding = null)
        {
            string mapped = MapPath(path);
            string? dir = Path.GetDirectoryName(mapped);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            _inner.WriteAllText(mapped, contents, encoding);
        }
        public byte[] ReadAllBytes(string path) => _inner.ReadAllBytes(MapPath(path));
        public void WriteAllBytes(string path, byte[] bytes)
        {
            string mapped = MapPath(path);
            string? dir = Path.GetDirectoryName(mapped);
            if (!string.IsNullOrEmpty(dir)) _inner.CreateDirectory(dir);
            _inner.WriteAllBytes(mapped, bytes);
        }
        public Stream OpenRead(string path) => _inner.OpenRead(MapPath(path));
        public DateTime GetLastWriteTimeUtc(string path) => _inner.GetLastWriteTimeUtc(MapPath(path));
        public IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateFiles(MapPath(path), searchPattern, searchOption);
        public IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateDirectories(MapPath(path), searchPattern, searchOption);
    }

    /// <summary>
    /// Configurable process runner that intercepts destructive OS commands while recording exact
    /// command lines and supporting custom per-command exit codes/outputs for deep branch testing.
    /// </summary>
    private sealed class SafeInterceptingProcessRunner : IProcessRunner
    {
        public List<(string FileName, string Arguments)> RecordedCommands { get; } = new();
        public Func<string, string, ProcessExecutionResult>? CustomHandler { get; set; }

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            RecordedCommands.Add((fileName, arguments));
            if (CustomHandler != null)
            {
                return CustomHandler(fileName, arguments);
            }
            return new ProcessExecutionResult(0, $"[SafeSandbox] Executed {fileName} {arguments}", string.Empty, false);
        }

        public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default) =>
            Task.FromResult(Run(fileName, arguments, workingDirectory, timeoutMs));

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName) => Array.Empty<ProcessInfo>();
        public bool CloseMainWindow(int processId) => true;
        public bool WaitForExit(int processId, TimeSpan timeout) => true;
        public bool KillProcess(int processId, bool entireProcessTree = true) => true;
        public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true) => true;
        public bool IsProcessRunning(string processName) => false;
    }

    private sealed class SandboxedNetworkService : INetworkService
    {
        private readonly WindowsNetworkService _inner;
        private readonly SandboxedWindowsFileSystemService _sandboxFs;
        public Func<string, string>? CustomDownloadStringHandler { get; set; }
        public Func<string, string, bool>? CustomDownloadFileHandler { get; set; }

        public SandboxedNetworkService(WindowsNetworkService inner, SandboxedWindowsFileSystemService sandboxFs)
        {
            _inner = inner;
            _sandboxFs = sandboxFs;
        }

        public bool PingHost(string host, int timeoutMs = 2000) =>
            host == "192.0.2.1"
                ? false
                : host is "127.0.0.1" or "1.1.1.1" or "github.com" or "localhost"
                    ? true
                    : _inner.PingHost(host, timeoutMs);

        public bool TestPort(string host, int port, int timeoutMs = 2000) =>
            host == "192.0.2.1" ? false : _inner.TestPort(host, port, timeoutMs);
        public IEnumerable<NetworkAdapterInfo> GetAdapters() => _inner.GetAdapters();
        public bool RestartAdapter(string adapterName) => true;
        public bool FlushDns() => true;
        public bool ResetWinsock() => true;
        public bool ResetTcpIp() => true;
        public bool ReleaseRenewDhcp() => true;

        public bool DownloadFile(string url, string destinationPath)
        {
            if (CustomDownloadFileHandler != null)
            {
                return CustomDownloadFileHandler(url, destinationPath);
            }
            _sandboxFs.WriteAllBytes(destinationPath, new byte[] { 0x4D, 0x5A, 0x90, 0x00 });
            return true;
        }

        public Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default) =>
            Task.FromResult(DownloadFile(url, destinationPath));

        public string DownloadString(string url) =>
            CustomDownloadStringHandler != null ? CustomDownloadStringHandler(url) : "Write-Output 'Safe Debloat Payload'";

        public Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default) =>
            Task.FromResult(DownloadString(url));
    }

    private sealed class StubOutlookComService : IOutlookComService
    {
        public bool IsOutlookAvailable() => true;
        public IReadOnlyList<string> GetStoreFolders(string pstPath) => new[] { "Projects", "Clients" };
        public int CloneFolderHierarchy(string sourcePstPath, string targetPstPath, IEnumerable<string>? excludedFolders = null) => 7;
        public int MigrateRules(string sourcePstPath, string targetPstPath) => 4;
        public bool SetDefaultDeliveryStore(string pstPath) => true;
        public bool CompactStore(string pstPath) => true;
    }

    private sealed class ConfigurableConfirmationService : ISafetyConfirmationService
    {
        public bool NextResult { get; set; } = true;
        public int CallCount { get; private set; }
        public string? LastTitle { get; private set; }

        public bool Confirm(string title, string message, string? warningDetail = null)
        {
            CallCount++;
            LastTitle = title;
            return NextResult;
        }

        public Task<bool> ConfirmAsync(string title, string message, string? warningDetail = null)
        {
            return Task.FromResult(Confirm(title, message, warningDetail));
        }
    }

    private sealed class ConfigurableDialogService : IDialogService
    {
        public string? NextFileResult { get; set; }
        public string? NextFolderResult { get; set; }
        public List<string> OpenedExplorerPaths { get; } = new();

        public string? ShowOpenFileDialog(string title, string filter, string? initialDirectory = null) => NextFileResult;
        public string? ShowSaveFileDialog(string title, string filter, string? defaultFileName = null, string? initialDirectory = null) => NextFileResult;
        public string? ShowOpenFolderDialog(string title, string? initialDirectory = null) => NextFolderResult;
        public bool OpenFolderInExplorer(string path)
        {
            OpenedExplorerPaths.Add(path);
            return true;
        }
    }

    [Fact]
    public async Task LiveWindows_NativePlatformServices_ExecuteSafelyOnRealHost()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. WindowsRegistryService: Read real OS version & full CRUD inside HKCU sandbox for all value kinds
        string? currentBuild = _realRegistry.GetValue<string>(@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild");
        Assert.False(string.IsNullOrWhiteSpace(currentBuild));

        string testKey = $@"{_sandboxRegRoot}\CrudTest";
        Assert.True(_realRegistry.CreateKey(testKey));
        Assert.True(_realRegistry.KeyExists(testKey));

        // Verify GetValueKind on a non-existent value returns Unknown instead of throwing IOException
        Assert.Equal(RegistryValueKind.Unknown, _realRegistry.GetValueKind(testKey, "NonExistentValue"));
        Assert.Equal(RegistryValueKind.Unknown, _realRegistry.GetValueKind($@"{testKey}\NonExistentSubKey", "Val"));

        Assert.True(_realRegistry.SetValue(testKey, "", "DefaultVal", RegistryValueKind.String));
        Assert.True(_realRegistry.SetValue(testKey, "StrVal", "HelloWindows", RegistryValueKind.String));
        Assert.True(_realRegistry.SetValue(testKey, "ExpandVal", @"%SystemRoot%\System32", RegistryValueKind.ExpandString));
        Assert.True(_realRegistry.SetValue(testKey, "DwordVal", 42, RegistryValueKind.DWord));
        Assert.True(_realRegistry.SetValue(testKey, "HighBitDword", unchecked((int)0x80000001), RegistryValueKind.DWord));
        Assert.True(_realRegistry.SetValue(testKey, "QwordVal", 9876543210L, RegistryValueKind.QWord));
        Assert.True(_realRegistry.SetValue(testKey, "BinVal", new byte[] { 1, 2, 3, 4 }, RegistryValueKind.Binary));
        Assert.True(_realRegistry.SetValue(testKey, "MultiVal", new[] { "Line1", "Line2" }, RegistryValueKind.MultiString));

        // Verify generic GetValue<T> works for reference/array types (byte[], string[]) as well as primitives
        Assert.Equal("DefaultVal", _realRegistry.GetValue<string>(testKey, ""));
        Assert.Equal("HelloWindows", _realRegistry.GetValue<string>(testKey, "StrVal"));
        Assert.Equal(42, _realRegistry.GetValue<int>(testKey, "DwordVal"));
        Assert.Equal(unchecked((int)0x80000001), _realRegistry.GetValue<int>(testKey, "HighBitDword"));
        Assert.Equal(9876543210L, _realRegistry.GetValue<long>(testKey, "QwordVal"));
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, _realRegistry.GetValue<byte[]>(testKey, "BinVal"));
        Assert.Equal(new[] { "Line1", "Line2" }, _realRegistry.GetValue<string[]>(testKey, "MultiVal"));

        Assert.Equal(RegistryValueKind.DWord, _realRegistry.GetValueKind(testKey, "DwordVal"));
        Assert.Equal(RegistryValueKind.QWord, _realRegistry.GetValueKind(testKey, "QwordVal"));
        Assert.Equal(RegistryValueKind.Binary, _realRegistry.GetValueKind(testKey, "BinVal"));
        Assert.Equal(RegistryValueKind.MultiString, _realRegistry.GetValueKind(testKey, "MultiVal"));
        Assert.Equal(RegistryValueKind.ExpandString, _realRegistry.GetValueKind(testKey, "ExpandVal"));
        Assert.Contains("StrVal", _realRegistry.GetValueNames(testKey));

        string childKey = $@"{testKey}\ChildNode";
        Assert.True(_realRegistry.CreateKey(childKey));
        Assert.Contains("ChildNode", _realRegistry.GetSubKeyNames(testKey));
        Assert.True(_realRegistry.DeleteKey(childKey, recursive: false));
        Assert.False(_realRegistry.KeyExists(childKey));

        Assert.True(_realRegistry.DeleteValue(testKey, "StrVal"));
        Assert.False(_realRegistry.ValueExists(testKey, "StrVal"));
        Assert.True(_realRegistry.DeleteKey(testKey, recursive: true));
        Assert.False(_realRegistry.KeyExists(testKey));

        // 2. WindowsFileSystemService: Real file I/O, ZIP archive extraction, lock detection, SHA-256, and disk headroom
        string fileA = Path.Combine(_sandboxDir, "testA.txt");
        string fileB = Path.Combine(_sandboxDir, "testB.txt");
        string fileMoved = Path.Combine(_sandboxDir, "testMoved.txt");
        _realFileSystem.WriteAllText(fileA, "Safe Windows Data Integrity Check", Encoding.UTF8);
        Assert.True(_realFileSystem.FileExists(fileA));
        Assert.True(_realFileSystem.GetFileSize(fileA) > 0);
        Assert.True(_realFileSystem.GetAvailableFreeSpace(_sandboxDir) > 10 * 1024 * 1024);
        Assert.True(_realFileSystem.CheckDiskSpace(_sandboxDir, 1024, 1.2));
        Assert.False(_realFileSystem.CheckDiskSpace(_sandboxDir, long.MaxValue / 2, 1.2));

        string hashSync = _realFileSystem.ComputeSha256(fileA);
        string hashAsync = await _realFileSystem.ComputeSha256Async(fileA);
        Assert.Equal(64, hashSync.Length);
        Assert.Equal(hashSync, hashAsync);

        // Real OS file lock detection
        Assert.False(_realFileSystem.IsFileLocked(fileA));
        Assert.False(_realFileSystem.IsFileLocked(Path.Combine(_sandboxDir, "non_existent.file")));
        using (var exclusiveStream = new FileStream(fileA, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.True(_realFileSystem.IsFileLocked(fileA));
        }
        Assert.False(_realFileSystem.IsFileLocked(fileA));

        _realFileSystem.CopyFile(fileA, fileB, overwrite: true);
        Assert.Equal(hashSync, _realFileSystem.ComputeSha256(fileB));
        _realFileSystem.MoveFile(fileB, fileMoved);
        Assert.False(_realFileSystem.FileExists(fileB));
        Assert.True(_realFileSystem.FileExists(fileMoved));

        // Real ZIP archive creation and extraction
        string zipSrcDir = Path.Combine(_sandboxDir, "ZipSrc");
        string zipDstDir = Path.Combine(_sandboxDir, "ZipDst");
        string zipFile = Path.Combine(_sandboxDir, "sample.zip");
        _realFileSystem.CreateDirectory(Path.Combine(zipSrcDir, "Nested"));
        _realFileSystem.WriteAllText(Path.Combine(zipSrcDir, "root.txt"), "RootEntry");
        _realFileSystem.WriteAllText(Path.Combine(zipSrcDir, "Nested", "inner.txt"), "InnerEntry");
        ZipFile.CreateFromDirectory(zipSrcDir, zipFile);
        _realFileSystem.ExtractZipArchive(zipFile, zipDstDir, overwrite: true);
        Assert.Equal("InnerEntry", _realFileSystem.ReadAllText(Path.Combine(zipDstDir, "Nested", "inner.txt")));

        // 3. WindowsProcessRunner: stdout + stderr + exit code, timeout kill, and .exe process name normalization
        var echoRes = await _realProcessRunner.RunAsync("cmd.exe", "/c echo STDOUT_OK & echo STDERR_OK 1>&2 & exit /b 7");
        Assert.Equal(7, echoRes.ExitCode);
        Assert.False(echoRes.TimedOut);
        Assert.Contains("STDOUT_OK", echoRes.StandardOutput);
        Assert.Contains("STDERR_OK", echoRes.StandardError);

        var timeoutRes = _realProcessRunner.Run("cmd.exe", "/c ping 127.0.0.1 -n 10", timeoutMs: 300);
        Assert.True(timeoutRes.TimedOut);
        Assert.Equal(-1, timeoutRes.ExitCode);

        // Verify process enumeration works with and without .exe suffix and disposes handles cleanly
        Assert.True(_realProcessRunner.IsProcessRunning("dotnet") || _realProcessRunner.IsProcessRunning("testhost") || _realProcessRunner.IsProcessRunning("explorer.exe"));
        var explorerProcs = _realProcessRunner.GetProcessesByName("explorer.exe").ToList();
        var explorerProcsNoExt = _realProcessRunner.GetProcessesByName("explorer").ToList();
        Assert.Equal(explorerProcs.Count, explorerProcsNoExt.Count);

        // 4. WindowsNetworkService: Real adapters, loopback ping, TCP port check, and real loopback HTTP download
        var adapters = _realNetwork.GetAdapters().ToList();
        Assert.NotEmpty(adapters);
        Assert.True(_realNetwork.PingHost("127.0.0.1", 2000));

        int closedPort;
        using (var listener = new TcpListener(IPAddress.Loopback, 0))
        {
            listener.Start();
            int ephemeralPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            closedPort = ephemeralPort;
            Assert.True(_realNetwork.TestPort("127.0.0.1", ephemeralPort, 2000));
            listener.Stop();
        }
        Assert.False(_realNetwork.TestPort("127.0.0.1", closedPort, 300));

        // Real loopback HTTP server to verify WindowsNetworkService.DownloadString and DownloadFile
        using (var httpListener = new TcpListener(IPAddress.Loopback, 0))
        {
            httpListener.Start();
            int httpPort = ((IPEndPoint)httpListener.LocalEndpoint).Port;
            var serverTask = Task.Run(async () =>
            {
                for (int i = 0; i < 2; i++)
                {
                    using var client = await httpListener.AcceptTcpClientAsync();
                    await using var stream = client.GetStream();
                    byte[] reqBuf = new byte[1024];
                    _ = await stream.ReadAsync(reqBuf);
                    string body = "ITOOLKIT_HTTP_PAYLOAD_OK";
                    byte[] bodyBytes = Encoding.UTF8.GetBytes(body);
                    string header = $"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {bodyBytes.Length}\r\nConnection: close\r\n\r\n";
                    byte[] headerBytes = Encoding.ASCII.GetBytes(header);
                    await stream.WriteAsync(headerBytes);
                    await stream.WriteAsync(bodyBytes);
                }
            });

            string url = $"http://127.0.0.1:{httpPort}/payload.txt";
            string downloadedStr = await _realNetwork.DownloadStringAsync(url);
            Assert.Equal("ITOOLKIT_HTTP_PAYLOAD_OK", downloadedStr);

            string downloadedFile = Path.Combine(_sandboxDir, "Downloads", "http_payload.txt");
            bool fileDownloaded = await _realNetwork.DownloadFileAsync(url, downloadedFile);
            Assert.True(fileDownloaded);
            Assert.Equal("ITOOLKIT_HTTP_PAYLOAD_OK", File.ReadAllText(downloadedFile));

            await serverTask;
            httpListener.Stop();
        }

        // 5. WindowsWmiService & WindowsTelemetryService: Real hardware/OS/Service/Account WMI queries
        var osWmi = _realWmi.QueryFirst("SELECT Caption, Version FROM Win32_OperatingSystem");
        Assert.NotNull(osWmi);
        Assert.True(osWmi.ContainsKey("Caption"));

        var spoolerWmi = _realWmi.QueryFirst("SELECT Name, State FROM Win32_Service WHERE Name='Spooler'");
        Assert.NotNull(spoolerWmi);
        Assert.Equal("Spooler", spoolerWmi["Name"]?.ToString(), ignoreCase: true);

        var elevationGuard = new ElevationGuard();
        var telemetryService = new WindowsTelemetryService(elevationGuard, _realFileSystem, _realWmi, _realRegistry);
        telemetryService.SetActiveTask("Deep Live Windows Verification");
        var snapshot = await telemetryService.GetSnapshotAsync();
        Assert.NotNull(snapshot);
        Assert.Equal("Deep Live Windows Verification", snapshot.ActiveTaskDescription);
        Assert.False(string.IsNullOrWhiteSpace(snapshot.OsDescription));
        Assert.False(string.IsNullOrWhiteSpace(snapshot.OsBuild));
        Assert.True(snapshot.MemoryTotalBytes > 0);
        Assert.True(snapshot.SystemDriveTotalBytes > 0);
        Assert.True(snapshot.SystemDriveFreeBytes > 0);

        // 6. ActivityLogger: Real log file creation and levels in sandbox
        _realLogger.Log(LogLevel.Info, "LiveTest", "Info entry");
        _realLogger.Log(LogLevel.Warning, "LiveTest", "Warning entry");
        _realLogger.Log(LogLevel.Error, "LiveTest", "Error entry");
        _realLogger.Log(LogLevel.Success, "LiveTest", "Success entry");
        Assert.True(File.Exists(_realLogger.LogFilePath));
        string logContent = File.ReadAllText(_realLogger.LogFilePath);
        Assert.Contains("Success entry", logContent);
    }

    [Fact]
    public async Task LiveWindows_SafetyEngines_AtomicRegistryRollbackAndResourceGuards_Verify100PercentDataSafety()
    {
        if (!OperatingSystem.IsWindows()) return;

        string regBackupDir = Path.Combine(_sandboxDir, "Backups", "Registry");
        var atomicRegistry = new AtomicRegistryService(_realRegistry, _realFileSystem, _realLogger, regBackupDir);

        // 1. Pre-populate a real HKCU sandbox key with all RegistryValueKind types, escaped strings, and nested subkeys
        string targetKey = $@"{_sandboxRegRoot}\AtomicTarget";
        string nestedKey = $@"{targetKey}\NestedChild";
        _realRegistry.CreateKey(targetKey);
        _realRegistry.CreateKey(nestedKey);

        _realRegistry.SetValue(targetKey, "", "DefaultRootValue", RegistryValueKind.String);
        _realRegistry.SetValue(targetKey, "Escaped\"Name\\Key", "Path=\"C:\\Program Files\\App\"", RegistryValueKind.String);
        _realRegistry.SetValue(targetKey, "OriginalDword", 100, RegistryValueKind.DWord);
        _realRegistry.SetValue(targetKey, "HighBitDword", unchecked((int)0x80000001), RegistryValueKind.DWord);
        _realRegistry.SetValue(targetKey, "OriginalQword", 0x0123456789ABCDEFL, RegistryValueKind.QWord);
        _realRegistry.SetValue(targetKey, "OriginalBinary", new byte[] { 0xAA, 0xBB, 0xCC, 0x00, 0xFF }, RegistryValueKind.Binary);
        _realRegistry.SetValue(targetKey, "OriginalMulti", new[] { "Alpha", "Beta", "Gamma" }, RegistryValueKind.MultiString);
        _realRegistry.SetValue(nestedKey, "ChildVal", 777, RegistryValueKind.DWord);

        // 2. Simulate a mid-transaction failure after corrupting values and adding a rogue subkey
        var failedMutation = await atomicRegistry.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _realRegistry.SetValue(targetKey, "", "CORRUPTED_DEFAULT", RegistryValueKind.String);
                _realRegistry.SetValue(targetKey, "Escaped\"Name\\Key", "CORRUPTED", RegistryValueKind.String);
                _realRegistry.SetValue(targetKey, "OriginalDword", 999, RegistryValueKind.DWord);
                _realRegistry.SetValue(targetKey, "RogueValue", "ShouldBeWiped", RegistryValueKind.String);
                _realRegistry.DeleteKey(nestedKey, recursive: true);
                _realRegistry.CreateKey($@"{targetKey}\RogueSubKey");
                throw new InvalidOperationException("Simulated mid-flight failure");
            },
            "Test Automatic Rollback on Live Windows Registry");

        Assert.False(failedMutation.Success);
        Assert.NotNull(failedMutation.BackupPath);
        Assert.True(File.Exists(failedMutation.BackupPath));

        // Verify 100% state restoration in the real Windows Registry
        Assert.Equal("DefaultRootValue", _realRegistry.GetValue<string>(targetKey, ""));
        Assert.Equal("Path=\"C:\\Program Files\\App\"", _realRegistry.GetValue<string>(targetKey, "Escaped\"Name\\Key"));
        Assert.Equal(100, _realRegistry.GetValue<int>(targetKey, "OriginalDword"));
        Assert.Equal(unchecked((int)0x80000001), _realRegistry.GetValue<int>(targetKey, "HighBitDword"));
        Assert.Equal(0x0123456789ABCDEFL, _realRegistry.GetValue<long>(targetKey, "OriginalQword"));
        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC, 0x00, 0xFF }, _realRegistry.GetValue<byte[]>(targetKey, "OriginalBinary"));
        Assert.Equal(new[] { "Alpha", "Beta", "Gamma" }, _realRegistry.GetValue<string[]>(targetKey, "OriginalMulti"));
        Assert.True(_realRegistry.KeyExists(nestedKey));
        Assert.Equal(777, _realRegistry.GetValue<int>(nestedKey, "ChildVal"));
        Assert.False(_realRegistry.ValueExists(targetKey, "RogueValue"));
        Assert.False(_realRegistry.KeyExists($@"{targetKey}\RogueSubKey"));

        // 3. Test Reversible Rollback Deletion Sentinel [-KeyPath] for non-existent key
        string nonExistentKey = $@"{_sandboxRegRoot}\CreatedDuringFailedTx";
        Assert.False(_realRegistry.KeyExists(nonExistentKey));

        var sentinelRollback = atomicRegistry.ExecuteAtomicMutation(
            nonExistentKey,
            () =>
            {
                _realRegistry.CreateKey(nonExistentKey);
                _realRegistry.SetValue(nonExistentKey, "Temp", 1, RegistryValueKind.DWord);
                return false; // Trigger rollback via false return
            },
            "Test Sentinel Deletion Rollback");

        Assert.False(sentinelRollback.Success);
        Assert.False(_realRegistry.KeyExists(nonExistentKey));

        // 4. ProcessLockGuard: Spawn a real harmless background ping process and verify termination by PID
        using (var bgProc = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "ping.exe",
            Arguments = "127.0.0.1 -n 30",
            UseShellExecute = false,
            CreateNoWindow = true
        }))
        {
            Assert.NotNull(bgProc);
            int bgPid = bgProc.Id;
            Assert.False(bgProc.HasExited);

            bool killed = _realProcessRunner.KillProcess(bgPid, entireProcessTree: true);
            Assert.True(killed);
            Assert.True(_realProcessRunner.WaitForExit(bgPid, TimeSpan.FromSeconds(5)));
        }

        // 5. ResourceGuard cryptographic manifest generation, corruption detection, and missing file detection on real disk
        var resourceGuard = new ResourceGuard(_realFileSystem, _realLogger);
        resourceGuard.ValidateDiskSpace(_sandboxDir, 1024, 1.2);
        Assert.Throws<InvalidOperationException>(() => resourceGuard.ValidateDiskSpace(_sandboxDir, long.MaxValue / 2, 1.2));

        string dataRoot = Path.Combine(_sandboxDir, "ManifestSource");
        Directory.CreateDirectory(dataRoot);
        string f1 = Path.Combine(dataRoot, "doc1.txt");
        string f2 = Path.Combine(dataRoot, "doc2.txt");
        File.WriteAllText(f1, "Document 1 Content");
        File.WriteAllText(f2, "Document 2 Content");

        var manifest = resourceGuard.GenerateCleanupManifest(dataRoot, new[] { f1, f2 });
        string manifestPath = Path.Combine(_sandboxDir, "manifest.json");
        resourceGuard.SaveManifest(manifest, manifestPath);

        var loadedManifest = resourceGuard.LoadManifest(manifestPath);
        var validCheck = resourceGuard.ValidateManifest(loadedManifest);
        Assert.True(validCheck.IsValid);
        Assert.Equal(2, validCheck.MatchedFiles);

        // Tamper with f2 and delete f1 to verify both MismatchedFiles and MissingFiles detection
        File.WriteAllText(f2, "Tampered Content!");
        File.Delete(f1);
        var tamperedCheck = resourceGuard.ValidateManifest(loadedManifest);
        Assert.False(tamperedCheck.IsValid);
        Assert.Contains("doc2.txt", tamperedCheck.MismatchedFiles);
        Assert.Contains("doc1.txt", tamperedCheck.MissingFiles);
    }

    [Fact]
    public void LiveWindows_Pillar1_SystemHealth_VerifiesBinariesAndSandboxedCleanupSafely()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. Verify native Windows system health binaries exist on this machine
        string sys32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        Assert.True(File.Exists(Path.Combine(sys32, "dism.exe")));
        Assert.True(File.Exists(Path.Combine(sys32, "sfc.exe")));
        Assert.True(File.Exists(Path.Combine(sys32, "w32tm.exe")));
        Assert.True(File.Exists(Path.Combine(sys32, "sc.exe")));
        Assert.True(File.Exists(Path.Combine(sys32, "regsvr32.exe")));
        Assert.True(File.Exists(Path.Combine(sys32, "wbem", "winmgmt.exe")));

        // 2. Execute all SystemHealthService functions against sandboxed real Windows filesystem & registry
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var safeProc = new SafeInterceptingProcessRunner();
        var atomicReg = new AtomicRegistryService(sandboxReg, sandboxFs, _realLogger, Path.Combine(_sandboxDir, "Backups", "Pillar1"));

        var healthService = new SystemHealthService(safeProc, sandboxFs, _realLogger, sandboxReg, atomicReg);

        // Verify DISM CheckHealth, ScanHealth, RestoreHealth (including custom WIM source & 3010 reboot flag), and SFC variants
        Assert.True(healthService.RunDismCheckHealth().Success);
        Assert.True(healthService.RunDismScanHealth().Success);

        safeProc.CustomHandler = (exe, args) =>
        {
            if (exe.Equals("dism.exe", StringComparison.OrdinalIgnoreCase) && args.Contains("/Source:", StringComparison.OrdinalIgnoreCase))
            {
                return new ProcessExecutionResult(3010, "The restore operation completed successfully.", string.Empty, false);
            }
            if (exe.Equals("sfc.exe", StringComparison.OrdinalIgnoreCase))
            {
                return new ProcessExecutionResult(1, "Windows Resource Protection found corrupt files and successfully repaired them.", string.Empty, false);
            }
            return new ProcessExecutionResult(0, "OK", string.Empty, false);
        };

        var (dismRes, sfcRes) = healthService.RunDismSfcPipeline(@"C:\Sources\install.wim", limitAccess: true);
        Assert.True(dismRes.Success);
        Assert.True(dismRes.NeedsReboot);
        Assert.True(sfcRes.Success);
        Assert.True(sfcRes.IntegrityViolationsFound);
        Assert.Contains(safeProc.RecordedCommands, c => c.FileName == "dism.exe" && c.Arguments.Contains("/Source:\"C:\\Sources\\install.wim\"") && c.Arguments.Contains("/LimitAccess"));

        safeProc.CustomHandler = null;

        // Seed SoftwareDistribution and catroot2 in sandbox so ResetWindowsUpdateComponents renames them on real disk
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string sdDir = Path.Combine(sysRoot, "SoftwareDistribution", "Download");
        string catrootDir = Path.Combine(sysRoot, "System32", "catroot2");
        sandboxFs.CreateDirectory(sdDir);
        sandboxFs.CreateDirectory(catrootDir);
        sandboxFs.WriteAllText(Path.Combine(sdDir, "wu_pkg.cab"), "Cached WU CAB");

        var wuReset = healthService.ResetWindowsUpdateComponents();
        Assert.True(wuReset.Success);
        Assert.Equal(35, wuReset.ReRegisteredDllCount);
        Assert.Equal(2, wuReset.RenamedDirectories.Count);

        // Verify Windows Update Blocker & Unblocker policies and WaaSMedicSvc Start=4 -> Start=3
        var blockRes = healthService.BlockWindowsUpdates();
        Assert.True(blockRes.Success);
        Assert.True(blockRes.IsBlocked);
        Assert.Equal(1, sandboxReg.GetValue<int>(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));
        Assert.Equal(1, sandboxReg.GetValue<int>(SystemHealthService.WindowsUpdateAuPolicyKey, "NoAutoUpdate"));
        Assert.Equal(4, sandboxReg.GetValue<int>(SystemHealthService.WaaSMedicServiceKey, "Start"));

        var unblockRes = healthService.UnblockWindowsUpdates();
        Assert.True(unblockRes.Success);
        Assert.False(unblockRes.IsBlocked);
        Assert.False(sandboxReg.ValueExists(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));
        Assert.Equal(0, sandboxReg.GetValue<int>(SystemHealthService.WindowsUpdateAuPolicyKey, "NoAutoUpdate"));
        Assert.Equal(3, sandboxReg.GetValue<int>(SystemHealthService.WaaSMedicServiceKey, "Start"));

        Assert.True(healthService.SyncSystemTime("time.cloudflare.com,0x9").Success);
        Assert.True(healthService.RepairWmiRepository().Success);
        Assert.True(healthService.CleanWinSxS(resetBase: false).Success);
        Assert.True(healthService.CleanWinSxS(resetBase: true).Success);
        Assert.Contains(safeProc.RecordedCommands, c => c.FileName == "dism.exe" && c.Arguments.Contains("/ResetBase"));

        // Seed all 5 storage cleanup targets on real disk inside sandbox
        string cbsDir = Path.Combine(sysRoot, "Logs", "CBS");
        string dismDir = Path.Combine(sysRoot, "Logs", "DISM");
        string winTempDir = Path.Combine(sysRoot, "Temp");
        string minidumpDir = Path.Combine(sysRoot, "Minidump");
        string doCacheDir = Path.Combine(sysRoot, "SoftwareDistribution", "DeliveryOptimization");

        sandboxFs.CreateDirectory(cbsDir);
        sandboxFs.CreateDirectory(dismDir);
        sandboxFs.CreateDirectory(winTempDir);
        sandboxFs.CreateDirectory(minidumpDir);
        sandboxFs.CreateDirectory(doCacheDir);
        sandboxFs.CreateDirectory(sdDir);

        string activeCbsLog = Path.Combine(cbsDir, "CBS.log");
        string archivedCbsLog = Path.Combine(cbsDir, "CbsPersist_20260101.log");
        string activeDismLog = Path.Combine(dismDir, "dism.log");
        string archivedDismLog = Path.Combine(dismDir, "dism.log.bak");
        string memoryDmp = Path.Combine(sysRoot, "MEMORY.DMP");
        string miniDmp = Path.Combine(minidumpDir, "010126-01.dmp");
        string doFile = Path.Combine(doCacheDir, "do_chunk.dat");
        string wuFile = Path.Combine(sdDir, "update_payload.cab");
        string recentTempFile = Path.Combine(winTempDir, "recent_active.tmp");
        string oldTempFile = Path.Combine(winTempDir, "stale_old.tmp");
        string lockedOldTempFile = Path.Combine(winTempDir, "locked_old.tmp");

        sandboxFs.WriteAllText(activeCbsLog, "Active CBS log - MUST PRESERVE");
        sandboxFs.WriteAllText(archivedCbsLog, "Archived CBS log - CAN DELETE");
        sandboxFs.WriteAllText(activeDismLog, "Active DISM log - MUST PRESERVE");
        sandboxFs.WriteAllText(archivedDismLog, "Archived DISM log - CAN DELETE");
        sandboxFs.WriteAllText(memoryDmp, "Kernel memory dump");
        sandboxFs.WriteAllText(miniDmp, "Minidump file");
        sandboxFs.WriteAllText(doFile, "Delivery optimization cache");
        sandboxFs.WriteAllText(wuFile, "WU download cache");
        sandboxFs.WriteAllText(recentTempFile, "Recent temp file (<24h) - MUST PRESERVE");
        sandboxFs.WriteAllText(oldTempFile, "Old temp file (>48h) - CAN DELETE");
        sandboxFs.WriteAllText(lockedOldTempFile, "Locked old temp file - MUST SKIP");

        File.SetLastWriteTimeUtc(sandboxFs.MapPath(oldTempFile), DateTime.UtcNow.AddHours(-48));
        File.SetLastWriteTimeUtc(sandboxFs.MapPath(lockedOldTempFile), DateTime.UtcNow.AddHours(-48));

        using (var lockHandle = new FileStream(sandboxFs.MapPath(lockedOldTempFile), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var cleanupRes = healthService.RunUnifiedDiskCleanup(24);
            Assert.True(cleanupRes.Success);
            Assert.True(cleanupRes.FilesDeleted >= 6);
            Assert.True(cleanupRes.FilesSkipped >= 2);
            Assert.True(cleanupRes.BytesReclaimed > 0);
        }

        // Verify strict data safety invariants on real disk inside sandbox
        Assert.True(sandboxFs.FileExists(activeCbsLog), "Active CBS.log must be preserved!");
        Assert.True(sandboxFs.FileExists(activeDismLog), "Active dism.log must be preserved!");
        Assert.True(sandboxFs.FileExists(recentTempFile), "Recent temp file (<24h) must be preserved!");
        Assert.True(sandboxFs.FileExists(lockedOldTempFile), "Locked temp file must be skipped safely!");
        Assert.False(sandboxFs.FileExists(archivedCbsLog));
        Assert.False(sandboxFs.FileExists(archivedDismLog));
        Assert.False(sandboxFs.FileExists(memoryDmp));
        Assert.False(sandboxFs.FileExists(miniDmp));
        Assert.False(sandboxFs.FileExists(doFile));
        Assert.False(sandboxFs.FileExists(wuFile));
        Assert.False(sandboxFs.FileExists(oldTempFile));
    }

    [Fact]
    public void LiveWindows_Pillar2_OfficeAndOutlook_VerifiesRealDiscoveryAndSandboxedRepairsSafely()
    {
        if (!OperatingSystem.IsWindows()) return;

        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var atomicReg = new AtomicRegistryService(sandboxReg, sandboxFs, _realLogger, Path.Combine(_sandboxDir, "Backups", "Pillar2"));
        var sandboxLockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);
        var sandboxResourceGuard = new ResourceGuard(sandboxFs, _realLogger);

        // 1. Seed real MAPI binary profile keys (001f6700 UTF-16LE and 001e6700 ANSI) in real Windows Registry sandbox
        string unicodePstPath = Path.Combine(_sandboxDir, "MapiStores", "UnicodeArchive.pst");
        string ansiOstPath = Path.Combine(_sandboxDir, "MapiStores", "AnsiCached.ost");
        sandboxFs.WriteAllBytes(unicodePstPath, new byte[4096]);
        sandboxFs.WriteAllBytes(ansiOstPath, new byte[8192]);

        string mapiProf1 = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375CFF0413111d3B88A00104B2A6676\00000001";
        string mapiProf2 = @"HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375CFF0413111d3B88A00104B2A6676\00000002";
        sandboxReg.CreateKey(mapiProf1);
        sandboxReg.SetValue(mapiProf1, "001f6700", Encoding.Unicode.GetBytes(unicodePstPath + "\0"), RegistryValueKind.Binary);
        sandboxReg.SetValue(mapiProf1, "001f3001", Encoding.Unicode.GetBytes("Corporate PST Store\0"), RegistryValueKind.Binary);
        sandboxReg.SetValue(mapiProf1, "001f3006", Encoding.Unicode.GetBytes("Personal Folders\0"), RegistryValueKind.Binary);

        sandboxReg.CreateKey(mapiProf2);
        sandboxReg.SetValue(mapiProf2, "001e6700", Encoding.ASCII.GetBytes(ansiOstPath + "\0"), RegistryValueKind.Binary);

        var stubCom = new StubOutlookComService();
        var outlookService = new OutlookService(sandboxReg, atomicReg, sandboxFs, sandboxLockGuard, sandboxResourceGuard, stubCom, _realLogger);
        var discoveredStores = outlookService.DiscoverDataFiles();
        Assert.Equal(2, discoveredStores.Count);
        Assert.Contains(discoveredStores, s => s.FilePath.Equals(unicodePstPath, StringComparison.OrdinalIgnoreCase) && s.DisplayName == "Corporate PST Store" && s.IsPst);
        Assert.Contains(discoveredStores, s => s.FilePath.Equals(ansiOstPath, StringComparison.OrdinalIgnoreCase) && s.IsOst);

        // 2. Test OfficeSuiteService functions: ClickToRun, Identity/WAM reset, Hardware Acceleration, Word/Excel/PPT repairs, GDI audit, and Scrub
        var officeService = new OfficeSuiteService(safeProc, sandboxFs, sandboxReg, atomicReg, sandboxLockGuard, _realLogger);

        string c2rDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Microsoft", "ClickToRun", "ProductReleases");
        string zeroXml = Path.Combine(c2rDir, "corrupt_empty.xml");
        string validXml = Path.Combine(c2rDir, "valid_release.xml");
        sandboxFs.WriteAllBytes(zeroXml, Array.Empty<byte>());
        sandboxFs.WriteAllText(validXml, "<Release />");
        Assert.True(officeService.RepairClickToRunService());
        Assert.False(sandboxFs.FileExists(zeroXml));
        Assert.True(sandboxFs.FileExists(validXml));

        Assert.Equal(0, officeService.RunClickToRunRepair(online: false).ExitCode);
        Assert.Equal(0, officeService.RunClickToRunRepair(online: true).ExitCode);

        string idKey = @"HKCU\Software\Microsoft\Office\16.0\Common\Identity\Identities";
        string oneAuthDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "OneAuth");
        sandboxReg.CreateKey(idKey);
        sandboxFs.CreateDirectory(oneAuthDir);
        sandboxFs.WriteAllText(Path.Combine(oneAuthDir, "token.Cache"), "token");
        var idReset = officeService.ResetOfficeIdentityCache();
        Assert.True(idReset.Success);
        Assert.False(sandboxReg.KeyExists(idKey));
        Assert.False(sandboxFs.DirectoryExists(oneAuthDir));

        Assert.True(officeService.SetHardwareAcceleration(disable: true).Success);
        Assert.Equal(1, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Common\Graphics", "DisableHardwareAcceleration"));
        Assert.Equal(1, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\PowerPoint\Options", "DisableSlideShowHardwareAcceleration"));

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        // Word Quick Repair: Normal.dotm, startup add-ins (.dotm/.wll), Word\Data registry, and locked vs unlocked ~$*.docx / *.asd files
        string normalDotm = Path.Combine(appData, "Microsoft", "Templates", "Normal.dotm");
        string wordStartup = Path.Combine(appData, "Microsoft", "Word", "STARTUP");
        string wordAddIn = Path.Combine(wordStartup, "FaultyMacro.dotm");
        string unlockedLockFile = Path.Combine(appData, "Microsoft", "Word", "~$OrphanDoc.docx");
        string lockedLockFile = Path.Combine(appData, "Microsoft", "Word", "~$ActiveOpenDoc.docx");
        string asdFile = Path.Combine(appData, "Microsoft", "Word", "Autorecover.asd");

        sandboxFs.WriteAllText(normalDotm, "Corrupt Normal.dotm");
        sandboxFs.WriteAllText(wordAddIn, "Faulty Startup AddIn");
        sandboxFs.WriteAllText(unlockedLockFile, "Orphan lock");
        sandboxFs.WriteAllText(lockedLockFile, "Active lock");
        sandboxFs.WriteAllText(asdFile, "Orphan ASD");
        sandboxReg.CreateKey(@"HKCU\Software\Microsoft\Office\16.0\Word\Data");

        using (var wordLockStream = new FileStream(sandboxFs.MapPath(lockedLockFile), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var wordRes = officeService.WordQuickRepair();
            Assert.True(wordRes.Success);
            Assert.True(wordRes.NormalDotmReset);
            Assert.Equal(1, wordRes.AddInsDisabledCount);
            Assert.Equal(2, wordRes.LocksRemovedCount);
        }
        Assert.True(sandboxFs.FileExists(wordAddIn + ".disabled"));
        Assert.False(sandboxFs.FileExists(unlockedLockFile));
        Assert.False(sandboxFs.FileExists(asdFile));
        Assert.True(sandboxFs.FileExists(lockedLockFile), "Active locked Word file must not be deleted!");

        // Excel Quick Repair: PERSONAL.XLSB preserved + backed up, rogue add-in isolated, UI cache & resiliency cleared
        string xlStartDir = Path.Combine(appData, "Microsoft", "Excel", "XLSTART");
        string personalXlsb = Path.Combine(xlStartDir, "PERSONAL.XLSB");
        string rogueAddIn = Path.Combine(xlStartDir, "BadAddIn.xlam");
        string excelXlb = Path.Combine(appData, "Microsoft", "Excel", "Excel16.xlb");
        sandboxFs.WriteAllText(personalXlsb, "User Macro Workbook - MUST PRESERVE");
        sandboxFs.WriteAllText(rogueAddIn, "Rogue Add-In");
        sandboxFs.WriteAllText(excelXlb, "Corrupt toolbar cache");
        sandboxReg.CreateKey(@"HKCU\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems");

        var excelRes = officeService.ExcelQuickRepair();
        Assert.True(excelRes.Success);
        Assert.Equal(1, excelRes.AddInsDisabledCount);
        Assert.True(sandboxFs.FileExists(personalXlsb), "Personal.xlsb must remain intact in XLSTART!");
        Assert.Contains(sandboxFs.EnumerateFiles(xlStartDir, "PERSONAL.XLSB.bak_*"), _ => true);
        Assert.False(sandboxFs.FileExists(excelXlb));
        Assert.Equal(0, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options", "IgnoreRemoteRequests"));
        Assert.Equal(1, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Excel\Options", "Calculation"));
        Assert.False(sandboxReg.KeyExists(@"HKCU\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems"));

        // PowerPoint Quick Repair & Office Scrub in sandbox
        string pptCache = Path.Combine(localAppData, "Microsoft", "Office", "16.0", "PowerPoint", "Cache");
        sandboxFs.CreateDirectory(pptCache);
        Assert.True(officeService.PowerPointQuickRepair().Success);
        Assert.False(sandboxFs.DirectoryExists(pptCache));
        Assert.True(officeService.ScrubOfficeSuiteCleanly().Success);

        // 3. Outlook Quick Mail Repair (Stream_Autocomplete_*.dat preservation, SRS & NavPane reset)
        string roamCache = Path.Combine(localAppData, "Microsoft", "Outlook", "RoamCache");
        string nk2Stream = Path.Combine(roamCache, "Stream_Autocomplete_0_123456.dat");
        string staleCache = Path.Combine(roamCache, "Stream_Weather_0_999.dat");
        string srsFile = Path.Combine(appData, "Microsoft", "Outlook", "Outlook.srs");
        string navXml = Path.Combine(appData, "Microsoft", "Outlook", "Outlook.xml");
        sandboxFs.WriteAllText(nk2Stream, "Critical User Autocomplete Contacts - MUST PRESERVE");
        sandboxFs.WriteAllText(staleCache, "Stale cache");
        sandboxFs.WriteAllText(srsFile, "Corrupt SRS");
        sandboxFs.WriteAllText(navXml, "Corrupt NavPane XML");

        var mailRepair = outlookService.QuickMailAndCacheRepair("Outlook");
        Assert.True(mailRepair.Success);
        Assert.True(mailRepair.SrsReset);
        Assert.True(mailRepair.RoamCacheCleaned);
        Assert.True(mailRepair.AutocompletePreserved);
        Assert.True(mailRepair.NavPaneReset);
        Assert.True(sandboxFs.FileExists(nk2Stream), "Stream_Autocomplete_*.dat must never be deleted!");
        Assert.False(sandboxFs.FileExists(staleCache));
        Assert.False(sandboxFs.FileExists(srsFile));
        Assert.False(sandboxFs.FileExists(navXml));

        // 4. 100GB PST expansion, New Default PST Pipeline with COM folder/rule migration, Backup, Restore (valid + tampered rejection), Relocate (.pst & .ost), and Compact
        string newPstPath = Path.Combine(_sandboxDir, "OutlookTest", "NewArchive.pst");
        var pstPipeline = outlookService.RunNewDefaultPstPipeline(newPstPath, unicodePstPath);
        Assert.True(pstPipeline.Success);
        Assert.Equal(7, pstPipeline.FoldersClonedCount);
        Assert.Equal(4, pstPipeline.RulesMigratedCount);
        Assert.True(sandboxFs.FileExists(newPstPath));
        Assert.Equal(102400, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Outlook\PST", "MaxLargeFileSize"));

        string pstBackupDir = Path.Combine(_sandboxDir, "OutlookBackup");
        var backupRes = outlookService.BackupDataFile(newPstPath, pstBackupDir);
        Assert.True(backupRes.Success);

        string expectedHash = sandboxResourceGuard.ComputeSha256(newPstPath);
        string restoredPstPath = Path.Combine(_sandboxDir, "OutlookRestored", "RestoredArchive.pst");
        var badRestore = outlookService.RestoreDataFile(Path.Combine(pstBackupDir, "NewArchive.pst"), restoredPstPath, "0000000000000000000000000000000000000000000000000000000000000000");
        Assert.False(badRestore.Success);

        var restoreRes = outlookService.RestoreDataFile(Path.Combine(pstBackupDir, "NewArchive.pst"), restoredPstPath, expectedHash);
        Assert.True(restoreRes.Success);
        Assert.Equal(expectedHash, sandboxResourceGuard.ComputeSha256(restoredPstPath));

        string relocateDir = Path.Combine(_sandboxDir, "OutlookRelocated");
        var relocatePstRes = outlookService.RelocateDataFile(restoredPstPath, relocateDir);
        Assert.True(relocatePstRes.Success);
        Assert.True(relocatePstRes.Sha256Matched);

        var relocateOstRes = outlookService.RelocateDataFile(ansiOstPath, relocateDir);
        Assert.True(relocateOstRes.Success);
        Assert.True(relocateOstRes.SymlinkCreated);

        Assert.True(outlookService.CompactDataFile(relocatePstRes.DestinationPath).Success);
    }

    [Fact]
    public void LiveWindows_Pillar3_ConnectivityAndPrinters_VerifiesLiveDiagnosticsAndSandboxedRemediation()
    {
        if (!OperatingSystem.IsWindows()) return;

        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxNet = new SandboxedNetworkService(_realNetwork, sandboxFs);
        var atomicReg = new AtomicRegistryService(sandboxReg, sandboxFs, _realLogger, Path.Combine(_sandboxDir, "Backups", "Pillar3"));
        var lockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);

        // 1. Live read-only diagnostics on real Windows host (Spooler WMI/SC status, Point & Print audit, Loopback port check)
        var livePrinterService = new PrinterService(_realProcessRunner, _realFileSystem, _realRegistry, atomicReg, lockGuard, _realWmi, _realLogger, _realNetwork);
        var spoolerStatus = livePrinterService.GetSpoolerStatus();
        Assert.NotNull(spoolerStatus);
        Assert.False(string.IsNullOrWhiteSpace(spoolerStatus.ServiceStatus));
        Assert.False(string.IsNullOrWhiteSpace(spoolerStatus.SpoolDirectory));

        var liveConnectivity = new ConnectivityService(sandboxNet, safeProc, sandboxReg, atomicReg, _realLogger);
        var portDiag = liveConnectivity.DiagnosePrinterPortConnectivity("127.0.0.1");
        Assert.True(portDiag.IsPingSuccessful);

        // 2. Sandboxed network remediation & SMB configuration (including NetBT interface subkeys)
        string netbtIfKey = @"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{11111111-2222-3333-4444-555555555555}";
        sandboxReg.CreateKey(netbtIfKey);

        var netRemediate = liveConnectivity.RemediateNetworkStack();
        Assert.True(netRemediate.Success);
        Assert.Equal(0, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable"));

        var smbRes = liveConnectivity.ConfigureSmbSharing();
        Assert.True(smbRes.Success);
        Assert.Equal(1, sandboxReg.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters", "AllowInsecureGuestAuth"));
        Assert.Equal(1, sandboxReg.GetValue<int>(netbtIfKey, "NetbiosOptions"));
        Assert.True(liveConnectivity.RestartAdapter("Ethernet"));

        // 3. Sandboxed PrinterService: Spooler queue purge, NeXX port cleanup, Point & Print posture transition, 12 error codes, 18 granular tokens, and stale UNC printer cleanup
        var sandboxPrinterService = new PrinterService(safeProc, sandboxFs, sandboxReg, atomicReg, lockGuard, null, _realLogger, sandboxNet);

        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        sandboxFs.CreateDirectory(spoolDir);
        string stuckSpl = Path.Combine(spoolDir, "00001.SPL");
        string stuckShd = Path.Combine(spoolDir, "00001.SHD");
        string keepTxt = Path.Combine(spoolDir, "keep_readme.txt");
        sandboxFs.WriteAllText(stuckSpl, "Stuck SPL");
        sandboxFs.WriteAllText(stuckShd, "Stuck SHD");
        sandboxFs.WriteAllText(keepTxt, "Keep non-spool file");

        var purgeRes = sandboxPrinterService.PurgeSpoolerQueue();
        Assert.True(purgeRes.Success);
        Assert.Equal(2, purgeRes.PurgedFilesCount);
        Assert.False(sandboxFs.FileExists(stuckSpl));
        Assert.False(sandboxFs.FileExists(stuckShd));
        Assert.True(sandboxFs.FileExists(keepTxt));

        // Seed active printer in Devices and orphaned NeXX printer in PrinterPorts
        string devicesKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\Devices";
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        sandboxReg.CreateKey(devicesKey);
        sandboxReg.CreateKey(portsKey);
        sandboxReg.SetValue(devicesKey, "ActiveOfficePrinter", "winspool,Ne01:", RegistryValueKind.String);
        sandboxReg.SetValue(portsKey, "ActiveOfficePrinter", "winspool,Ne01:,15,45", RegistryValueKind.String);
        sandboxReg.SetValue(portsKey, "OrphanedGhostPrinter", "winspool,Ne09:,15,45", RegistryValueKind.String);

        int removedNe = sandboxPrinterService.ResetNePortBindings();
        Assert.Equal(1, removedNe);
        Assert.True(sandboxReg.ValueExists(portsKey, "ActiveOfficePrinter"));
        Assert.False(sandboxReg.ValueExists(portsKey, "OrphanedGhostPrinter"));

        // Point & Print Preset -> Audit posture verification
        Assert.True(sandboxPrinterService.ApplyPointAndPrintPreset(PointAndPrintPreset.Compatibility));
        var compatAudit = sandboxPrinterService.AuditPointAndPrintPolicy();
        Assert.True(compatAudit.IsVulnerableToCVE20211678);

        Assert.True(sandboxPrinterService.ApplyPointAndPrintPreset(PointAndPrintPreset.StrictAdminOnly));
        var strictAudit = sandboxPrinterService.AuditPointAndPrintPolicy();
        Assert.False(strictAudit.IsVulnerableToCVE20211678);
        Assert.True(strictAudit.RestrictDriverInstallationToAdministrators);

        // Execute all 12 canonical error codes and all 18 granular tokens
        foreach (var code in sandboxPrinterService.GetSupportedErrorCodes())
        {
            var errRes = sandboxPrinterService.RemediatePrinterError(code);
            Assert.True(errRes.Success, $"Remediation failed for printer error code '{code}'");
        }
        foreach (var token in sandboxPrinterService.GetSupportedGranularTokens())
        {
            var tokRes = sandboxPrinterService.RemediatePrinterError(token);
            Assert.True(tokRes.Success, $"Remediation failed for granular token '{token}'");
        }

        // Seed reachable (\\127.0.0.1\LivePrinter) and unreachable (\\192.0.2.1\DeadPrinter) UNC connections
        string connRoot = @"HKCU\Printers\Connections";
        string liveUncKey = $@"{connRoot}\,,127.0.0.1,LivePrinter";
        string deadUncKey = $@"{connRoot}\,,192.0.2.1,DeadPrinter";
        sandboxReg.CreateKey(liveUncKey);
        sandboxReg.CreateKey(deadUncKey);

        var connReset = sandboxPrinterService.ResetPrinterConnections();
        Assert.True(connReset.Success);
        Assert.Equal(2, connReset.DiscoveredPrinters);
        Assert.Equal(1, connReset.ReconnectedPrinters);
        Assert.Equal(1, connReset.RemovedStalePrinters);
        Assert.True(sandboxReg.KeyExists(liveUncKey));
        Assert.False(sandboxReg.KeyExists(deadUncKey));

        Assert.True(sandboxPrinterService.RemediateAll().Success);
    }

    [Fact]
    public void LiveWindows_Pillar4_IdentityAndBackup_VerifiesAccountGuardrailsAndRealRobocopyPipeline()
    {
        if (!OperatingSystem.IsWindows()) return;

        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxNet = new SandboxedNetworkService(_realNetwork, sandboxFs);

        // 1. Live read-only enumeration of local Windows accounts & SID -500 built-in Administrator
        var liveIdentity = new IdentityService(_realProcessRunner, sandboxFs, sandboxReg, _realNetwork, _realWmi, _realLogger);
        var accounts = liveIdentity.GetLocalAccounts();
        Assert.NotEmpty(accounts);

        var builtInAdmin = liveIdentity.GetBuiltInAdministrator();
        Assert.NotNull(builtInAdmin);
        Assert.EndsWith("-500", builtInAdmin.Sid);

        // 2. CRITICAL SAFETY GUARDRAILS: Verify active user and SID -500 Admin deletion is strictly blocked on live Windows
        string currentUserName = Environment.UserName;
        string? currentUserSid = WindowsIdentity.GetCurrent()?.User?.Value;

        Assert.Throws<InvalidOperationException>(() => liveIdentity.RemoveLocalAccount("Administrator"));
        Assert.Throws<InvalidOperationException>(() => liveIdentity.RemoveLocalAccount(builtInAdmin.Username, builtInAdmin.Sid));
        Assert.Throws<InvalidOperationException>(() => liveIdentity.RemoveLocalAccount(currentUserName));
        if (!string.IsNullOrEmpty(currentUserSid))
        {
            Assert.Throws<InvalidOperationException>(() => liveIdentity.RemoveLocalAccount("AliasForActiveUser", currentUserSid));
        }

        // 3. Sandboxed Account CRUD, Domain Reachability, and Domain Disjoin Lockout Defense
        var sandboxIdentity = new IdentityService(safeProc, sandboxFs, sandboxReg, sandboxNet, null, _realLogger);
        Assert.True(sandboxIdentity.CreateLocalAccount("TempLabUser", "SafePass#2026", "Lab User", addToAdminGroup: true));
        Assert.True(sandboxIdentity.UnlockLocalAccount("TempLabUser"));
        Assert.True(sandboxIdentity.SetAccountEnabled("TempLabUser", false));
        Assert.True(sandboxIdentity.EnableBuiltInAdministrator());
        Assert.True(sandboxIdentity.ResetBuiltInAdministratorPassword("NewAdminPass#2026"));

        string dummyProfileDir = @"C:\Users\TempLabUser";
        string dummyProfReg = @"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-999-1009";
        sandboxFs.CreateDirectory(dummyProfileDir);
        sandboxReg.CreateKey(dummyProfReg);
        Assert.True(sandboxIdentity.RemoveLocalAccount("TempLabUser", "S-1-5-21-999-1009"));
        Assert.False(sandboxFs.DirectoryExists(dummyProfileDir));
        Assert.False(sandboxReg.KeyExists(dummyProfReg));

        // Verify Domain Disjoin Lockout Defense throws when no enabled local admin exists
        safeProc.CustomHandler = (exe, args) => new ProcessExecutionResult(1, string.Empty, "Failed", false);
        Assert.Throws<InvalidOperationException>(() => sandboxIdentity.DisjoinDomain("WORKGROUP"));
        safeProc.CustomHandler = null;

        // 4. BackupService: Bookmarks JSON parsing, Certificate export, real Robocopy sync, SHA-256 manifest, and Profile Restore
        var realResourceGuard = new ResourceGuard(_realFileSystem, _realLogger);
        var liveBackup = new BackupService(_realProcessRunner, _realFileSystem, _realRegistry, realResourceGuard, null, _realLogger);

        var profileMap = liveBackup.GetUserProfileMap();
        Assert.Equal(currentUserName, profileMap.Username);

        // Seed Chrome and Edge bookmarks in sandbox and verify JSON URL counting & SHA-256 export
        var sandboxResourceGuard = new ResourceGuard(sandboxFs, _realLogger);
        var sandboxBackup = new BackupService(_realProcessRunner, sandboxFs, sandboxReg, sandboxResourceGuard, null, _realLogger);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string chromeDefault = Path.Combine(localAppData, "Google", "Chrome", "User Data", "Default");
        string edgeProfile1 = Path.Combine(localAppData, "Microsoft", "Edge", "User Data", "Profile 1");
        sandboxFs.WriteAllText(Path.Combine(chromeDefault, "Bookmarks"), """{"roots":{"bookmark_bar":{"children":[{"type":"url","url":"https://example.com"},{"type":"url","url":"https://google.com"}]}}}""");
        sandboxFs.WriteAllText(Path.Combine(edgeProfile1, "Bookmarks"), """{"roots":{"bookmark_bar":{"children":[{"type":"url","url":"https://microsoft.com"}]}}}""");

        string bookmarkExportDir = Path.Combine(_sandboxDir, "ExportedBookmarks");
        var exportedBookmarks = sandboxBackup.ExportBrowserBookmarks(bookmarkExportDir);
        Assert.Equal(2, exportedBookmarks.Count);
        Assert.Equal(2, exportedBookmarks.First(b => b.Browser == "Chrome").EntryCount);
        Assert.Equal(1, exportedBookmarks.First(b => b.Browser == "Edge").EntryCount);

        string certExportDir = Path.Combine(_sandboxDir, "ExportedCerts");
        var certResult = liveBackup.ExportCertificates("My", certExportDir, "iToolKitSafePass!2026");
        Assert.True(certResult.Success);
        Assert.True(File.Exists(certResult.ExportPath));

        // Real Windows robocopy.exe sync + SHA-256 manifest validation + sandboxed RestoreProfileData
        string robosource = Path.Combine(_sandboxDir, "RoboSource");
        string robodest = Path.Combine(_sandboxDir, "RoboDest");
        Directory.CreateDirectory(Path.Combine(robosource, "Desktop"));
        File.WriteAllText(Path.Combine(robosource, "Desktop", "work_report.txt"), "Important User Document 12345");
        File.WriteAllText(Path.Combine(robosource, "notes.txt"), "Root user notes");

        var roboSync = liveBackup.RunRobocopySync(robosource, robodest, mirror: false);
        Assert.True(roboSync.IsSuccess, $"Robocopy exited with {roboSync.ExitCode}: {roboSync.ErrorOutput}");
        Assert.True(File.Exists(Path.Combine(robodest, "Desktop", "work_report.txt")));

        string manifestPath = Path.Combine(robodest, BackupService.ManifestFileName);
        var manifestData = liveBackup.CreateBackupManifest(robodest, manifestPath);
        Assert.Equal(2, manifestData.Files.Count);

        var validation = liveBackup.ValidateBackupManifest(robodest, manifestPath);
        Assert.True(validation.IsIntact);
        Assert.Equal(2, validation.MatchedCount);

        // Verify RestoreProfileData into sandboxed C:\Users\<user>
        var restoreRes = sandboxBackup.RestoreProfileData(robodest, manifestPath, "RestoredTestUser");
        Assert.True(restoreRes.Success);
        Assert.Equal(2, restoreRes.FilesRestored);
        Assert.True(sandboxFs.FileExists(@"C:\Users\RestoredTestUser\Desktop\work_report.txt"));

        // Tamper with backup file and verify RestoreProfileData blocks restore on pre-flight SHA-256 mismatch
        File.WriteAllText(Path.Combine(robodest, "notes.txt"), "CORRUPTED_AFTER_MANIFEST");
        var blockedRestore = sandboxBackup.RestoreProfileData(robodest, manifestPath, "RestoredTestUser");
        Assert.False(blockedRestore.Success);
    }

    [Fact]
    public void LiveWindows_Pillar5_SoftwareAndOptimization_VerifiesWingetAndSandboxedCatalog()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. Live read-only Winget status check on this Windows host
        var liveOpt = new OptimizationService(_realProcessRunner, _realFileSystem, _realNetwork, _realLogger);
        var wingetStatus = liveOpt.GetWingetStatus();
        Assert.NotNull(wingetStatus);

        // 2. Sandboxed OptimizationService: verify HTTPS & whitelist enforcement, HTML landing page rejection, and temp .ps1 cleanup
        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxNet = new SandboxedNetworkService(_realNetwork, sandboxFs);
        var lockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);

        var sandboxOpt = new OptimizationService(safeProc, sandboxFs, sandboxNet, _realLogger);
        Assert.Throws<SecurityException>(() => sandboxOpt.ExecuteDebloatScript("InsecureHttp", "http://debloat.raphi.re/script.ps1"));
        Assert.Throws<SecurityException>(() => sandboxOpt.ExecuteDebloatScript("UntrustedDomain", "https://evil.example.com/script.ps1"));

        // Verify HTML 404/landing page payload is rejected with ExitCode -2 and temp script cleaned
        sandboxNet.CustomDownloadStringHandler = _ => "<!DOCTYPE html><html><body>404 Not Found</body></html>";
        var htmlReject = sandboxOpt.ExecuteDebloatScript("HtmlPayloadTest", "https://debloat.raphi.re/");
        Assert.False(htmlReject.SyntaxValid);
        Assert.False(htmlReject.ExecutionSuccess);
        Assert.Equal(-2, htmlReject.ExitCode);
        Assert.True(htmlReject.TempCleanedUp);

        // Verify valid PowerShell script payload executes and cleans up temp .ps1 file
        sandboxNet.CustomDownloadStringHandler = _ => "Write-Host 'Valid debloat script'";
        var validDebloat = sandboxOpt.LaunchWin11Debloat();
        Assert.True(validDebloat.SyntaxValid);
        Assert.True(validDebloat.ExecutionSuccess);
        Assert.True(validDebloat.TempCleanedUp);

        // 3. Sandboxed 8-app catalog: Winget-first, Winget-fallback to DirectDownload, and UniKey ZIP ArchiveExtract
        var appInstaller = new AppInstallerService(safeProc, sandboxFs, sandboxReg, lockGuard, sandboxNet, _realLogger);
        var catalog = appInstaller.GetCatalog();
        Assert.Equal(8, catalog.Count);

        // Prepare a real ZIP archive for UniKey extraction test
        string dummyUniKeyZipSource = Path.Combine(_sandboxDir, "UniKeyZipBuild");
        Directory.CreateDirectory(dummyUniKeyZipSource);
        File.WriteAllText(Path.Combine(dummyUniKeyZipSource, "UniKeyNT.exe"), "MZ_UNIKEY_BINARY");
        string prebuiltZip = Path.Combine(_sandboxDir, "unikey_valid.zip");
        ZipFile.CreateFromDirectory(dummyUniKeyZipSource, prebuiltZip);

        sandboxNet.CustomDownloadFileHandler = (url, dst) =>
        {
            if (url.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                sandboxFs.CopyFile(prebuiltZip, dst, overwrite: true);
                return true;
            }
            sandboxFs.WriteAllText(dst, "MZ_INSTALLER_BINARY");
            return true;
        };

        var unikeyRes = appInstaller.InstallApplication("UniKey");
        Assert.True(unikeyRes.Success);
        Assert.Equal("ArchiveExtract", unikeyRes.MethodUsed);
        Assert.True(unikeyRes.TempCleanedUp);
        Assert.True(sandboxFs.FileExists(@"C:\Program Files\UniKey\UniKeyNT.exe"));

        // Test Winget failure -> DirectDownload fallback for Chrome
        safeProc.CustomHandler = (exe, args) =>
            exe.Equals("winget.exe", StringComparison.OrdinalIgnoreCase)
                ? new ProcessExecutionResult(1, string.Empty, "Winget source error", false)
                : new ProcessExecutionResult(0, "Installed via direct setup", string.Empty, false);

        var chromeFallback = appInstaller.InstallApplication("Chrome");
        Assert.True(chromeFallback.Success);
        Assert.Equal("DirectDownload", chromeFallback.MethodUsed);
        Assert.True(chromeFallback.TempCleanedUp);

        safeProc.CustomHandler = null;

        var batchRes = appInstaller.InstallBatch(new[] { "Chrome", "VCRedistAIO", "FoxitReader" });
        Assert.Equal(3, batchRes.Count);
        Assert.Equal("VCRedistAIO", batchRes[0].AppId);

        Assert.True(appInstaller.SetDefaultBrowser());
        Assert.True(appInstaller.SetDefaultPdfViewer());
        Assert.True(appInstaller.ConfigureUblockOriginLitePolicy());
        Assert.Equal("ChromeHTML", sandboxReg.GetValue<string>(@"HKCU\Software\Classes\.html", ""));
        Assert.Equal("FoxitPDFReader.Document", sandboxReg.GetValue<string>(@"HKCU\Software\Classes\.pdf", ""));
    }

    [Fact]
    public async Task LiveWindows_EndToEnd_ProductionDiContainerAndAllViewModelCommands_ExecuteSafely()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. Verify production DI container registration & full read-only system scan on live Windows
        var prodServices = new ServiceCollection();
        ServiceRegistration.ConfigureServices(prodServices);
        prodServices.AddSingleton<IActivityLogger>(_realLogger);

        await using (var prodProvider = prodServices.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        }))
        {
            var prodMainVm = prodProvider.GetRequiredService<MainViewModel>();
            prodMainVm.TelemetryHeader.StopPolling();
            prodMainVm.DashboardViewModel.StopPolling();

            await prodMainVm.RunSystemScanAsync();

            Assert.False(prodMainVm.IsScanning);
            Assert.Equal(100, prodMainVm.ScanProgressPercentage);
            Assert.Contains("System scan complete:", prodMainVm.DashboardViewModel.StatusMessage);
            Assert.NotEmpty(prodMainVm.IdentityBackupViewModel.Accounts);
            Assert.NotEmpty(prodMainVm.SoftwareOptimizationViewModel.CatalogApps);
        }

        // 2. Deep execution of all ViewModel commands across all 8 ViewModels using sandboxed infrastructure
        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxNet = new SandboxedNetworkService(_realNetwork, sandboxFs);
        var confirmSvc = new ConfigurableConfirmationService { NextResult = true };
        var dialogSvc = new ConfigurableDialogService
        {
            NextFileResult = Path.Combine(_sandboxDir, "DialogSelected.pst"),
            NextFolderResult = Path.Combine(_sandboxDir, "DialogFolder")
        };

        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);
        services.AddSingleton<IActivityLogger>(_realLogger);
        services.AddSingleton<IRegistryService>(sandboxReg);
        services.AddSingleton<IFileSystemService>(sandboxFs);
        services.AddSingleton<IProcessRunner>(safeProc);
        services.AddSingleton<INetworkService>(sandboxNet);
        services.AddSingleton<ISafetyConfirmationService>(confirmSvc);
        services.AddSingleton<IDialogService>(dialogSvc);
        services.AddSingleton(sp => new AtomicRegistryService(
            sp.GetRequiredService<IRegistryService>(),
            sp.GetRequiredService<IFileSystemService>(),
            sp.GetRequiredService<IActivityLogger>(),
            Path.Combine(_sandboxDir, "Backups", "VmTests")));

        await using var provider = services.BuildServiceProvider();
        var mainVm = provider.GetRequiredService<MainViewModel>();
        mainVm.TelemetryHeader.StopPolling();
        mainVm.DashboardViewModel.StopPolling();

        // Navigation across all 6 views + toggle nav rail
        foreach (var tab in new[] { "SystemHealth", "OfficeOutlook", "Connectivity", "IdentityBackup", "SoftwareOptimization", "Dashboard" })
        {
            mainVm.NavigateCommand.Execute(tab);
            Assert.Equal(tab, mainVm.CurrentPillarName);
        }
        mainVm.ToggleNavRailCommand.Execute(null);
        Assert.False(mainVm.IsNavRailExpanded);

        // Pillar 1 ViewModel Commands (including cancel vs confirm for WinSxS ResetBase)
        var shVm = mainVm.SystemHealthViewModel;
        shVm.BrowseWimSourceCommand.Execute(null);
        shVm.OpenWimFolderCommand.Execute(null);
        await shVm.RunDismSfcPipelineCommand.ExecuteAsync(null);
        await shVm.RunSfcScanCommand.ExecuteAsync(null);
        await shVm.RunDismRestoreHealthCommand.ExecuteAsync(null);
        await shVm.ResetWindowsUpdateCommand.ExecuteAsync(null);
        await shVm.BlockWindowsUpdatesCommand.ExecuteAsync(null);
        await shVm.UnblockWindowsUpdatesCommand.ExecuteAsync(null);
        await shVm.SyncSystemTimeCommand.ExecuteAsync(null);
        await shVm.RepairWmiCommand.ExecuteAsync(null);
        shVm.WinSxSResetBase = true;
        confirmSvc.NextResult = false;
        await shVm.CleanWinSxSCommand.ExecuteAsync(null);
        Assert.Contains("cancelled", shVm.LastCleanupSummary, StringComparison.OrdinalIgnoreCase);
        confirmSvc.NextResult = true;
        await shVm.CleanWinSxSCommand.ExecuteAsync(null);
        await shVm.RunUnifiedDiskCleanupCommand.ExecuteAsync(null);

        // Pillar 2 ViewModel Commands
        var offVm = mainVm.OfficeOutlookViewModel;
        offVm.TargetPstPath = Path.Combine(_sandboxDir, "VmOutlook", "Target.pst");
        offVm.RelocationDestinationDir = Path.Combine(_sandboxDir, "VmOutlookRelocated");
        offVm.BackupDirectory = Path.Combine(_sandboxDir, "VmOutlookBackup");
        await offVm.RepairC2RCommand.ExecuteAsync(null);
        await offVm.RepairC2RServiceCommand.ExecuteAsync(null);
        await offVm.ResetOfficeIdentityCommand.ExecuteAsync(null);
        await offVm.ToggleHardwareAccelerationCommand.ExecuteAsync(null);
        await offVm.TerminateOfficeProcessesCommand.ExecuteAsync(null);
        await offVm.ScrubOfficeSuiteCommand.ExecuteAsync(null);
        await offVm.WordQuickRepairCommand.ExecuteAsync(null);
        await offVm.ExcelQuickRepairCommand.ExecuteAsync(null);
        await offVm.PowerPointQuickRepairCommand.ExecuteAsync(null);
        await offVm.QuickMailRepairCommand.ExecuteAsync(null);
        await offVm.Expand100GBCommand.ExecuteAsync(null);
        await offVm.RunPstPipelineCommand.ExecuteAsync(null);
        offVm.SelectedDataFile = new MapiDataFileInfo(offVm.TargetPstPath, "Target.pst", "Outlook", false, true, 1024, "HKCU", true);
        await offVm.BackupPstCommand.ExecuteAsync(null);
        await offVm.CompactPstCommand.ExecuteAsync(null);
        await offVm.RelocatePstCommand.ExecuteAsync(null);

        // Pillar 3 ViewModel Commands
        var connVm = mainVm.ConnectivityViewModel;
        connVm.PrinterDiagnosticsHost = "127.0.0.1";
        await connVm.RefreshAdaptersCommand.ExecuteAsync(null);
        await connVm.FlushDnsCommand.ExecuteAsync(null);
        await connVm.RenewDhcpCommand.ExecuteAsync(null);
        await connVm.ClearArpCommand.ExecuteAsync(null);
        await connVm.ResetWinsockCommand.ExecuteAsync(null);
        await connVm.ResetTcpIpCommand.ExecuteAsync(null);
        await connVm.RemediateNetworkStackCommand.ExecuteAsync(null);
        await connVm.ConfigureSmbSharingCommand.ExecuteAsync(null);
        await connVm.RestartAdapterCommand.ExecuteAsync(null);
        await connVm.PurgeSpoolerCommand.ExecuteAsync(null);
        await connVm.RegisterSpoolerCommand.ExecuteAsync(null);
        await connVm.ResetNePortsCommand.ExecuteAsync(null);
        await connVm.ApplyPointAndPrintCommand.ExecuteAsync(null);
        await connVm.RemediatePrinterErrorCommand.ExecuteAsync(null);
        await connVm.DiagnosePrinterHostCommand.ExecuteAsync(null);
        await connVm.RemediateClientBatchCommand.ExecuteAsync(null);
        await connVm.RemediateServerBatchCommand.ExecuteAsync(null);
        await connVm.RemediateAllPrintersCommand.ExecuteAsync(null);
        await connVm.AuditPointAndPrintPolicyCommand.ExecuteAsync(null);
        await connVm.RefreshPrinterConnectionsCommand.ExecuteAsync(null);
        await connVm.InspectSpoolerStatusCommand.ExecuteAsync(null);

        // Pillar 4 ViewModel Commands
        var idVm = mainVm.IdentityBackupViewModel;
        idVm.NewAdminPassword = "SafeAdminPassword!123";
        idVm.NewAccountUsername = "VmCreatedUser";
        idVm.NewAccountPassword = "SafeUserPassword!123";
        idVm.DomainTestName = "127.0.0.1";
        idVm.DomainUserSamName = "jdoe";
        await idVm.EnableBuiltInAdminCommand.ExecuteAsync(null);
        await idVm.ResetAdminPasswordCommand.ExecuteAsync(null);
        await idVm.CreateAccountCommand.ExecuteAsync(null);
        await idVm.TestDomainReachabilityCommand.ExecuteAsync(null);
        await idVm.UnlockDomainUserCommand.ExecuteAsync(null);

        // Pillar 5 ViewModel Commands
        var swVm = mainVm.SoftwareOptimizationViewModel;
        swVm.SelectAllCommand.Execute(null);
        Assert.All(swVm.CatalogApps, a => Assert.True(a.IsSelected));
        swVm.DeselectAllCommand.Execute(null);
        swVm.CatalogApps.First().IsSelected = true;
        await swVm.BatchInstallCommand.ExecuteAsync(null);
        await swVm.SetDefaultBrowserCommand.ExecuteAsync(null);
        await swVm.SetDefaultPdfViewerCommand.ExecuteAsync(null);
        await swVm.ConfigureUblockPolicyCommand.ExecuteAsync(null);
        await swVm.CheckWingetStatusCommand.ExecuteAsync(null);
        await swVm.RepairWingetCommand.ExecuteAsync(null);
        await swVm.UpgradeAllPackagesCommand.ExecuteAsync(null);
        await swVm.LaunchWin11DebloatCommand.ExecuteAsync(null);
        await swVm.LaunchBrowserDebloatCommand.ExecuteAsync(null);

        // ActivityConsoleViewModel filtering, copy, and clear commands
        var consoleVm = mainVm.ActivityConsole;
        Assert.True(consoleVm.TotalCount > 0);
        consoleVm.SetFilterCommand.Execute("Info");
        consoleVm.SearchFilter = "Live";
        consoleVm.CopyLogCommand.Execute(null);
        consoleVm.ToggleAutoScrollCommand.Execute(null);
        consoleVm.ToggleExpandedCommand.Execute(null);
        consoleVm.DismissCompletionCommand.Execute(null);
        consoleVm.ClearLogCommand.Execute(null);
        Assert.Equal(0, consoleVm.TotalCount);
    }
}
