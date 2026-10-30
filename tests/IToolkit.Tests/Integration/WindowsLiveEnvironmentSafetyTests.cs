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
/// Comprehensive live Windows environment functional verification suite.
/// Tests all native Windows platform services, safety engines, 5 operational pillars,
/// and MVVM diagnostic workflows on a real Windows host with strict data-safety sandboxing
/// (all file writes isolated to %TEMP% and all registry mutations redirected to a temporary
/// HKCU sandbox key that is automatically purged on disposal).
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

        private string MapPath(string keyPath)
        {
            if (keyPath.StartsWith(_sandboxRoot, StringComparison.OrdinalIgnoreCase))
            {
                return keyPath;
            }

            string normalized = keyPath.Replace('/', '\\').Trim('\\');
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
            // In non-elevated Windows sessions, fallback to copy if symlink privilege is not held
            string mappedLink = MapPath(linkPath);
            string mappedTarget = MapPath(targetPath);
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
    /// Intercepts OS-mutating process commands while recording invocations and allowing safe read-only queries.
    ///Never kills or stops real user processes.
    /// </summary>
    private sealed class SafeInterceptingProcessRunner : IProcessRunner
    {
        public List<(string FileName, string Arguments)> RecordedCommands { get; } = new();

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            RecordedCommands.Add((fileName, arguments));
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

    [Fact]
    public async Task LiveWindows_NativePlatformServices_ExecuteSafelyOnRealHost()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. WindowsRegistryService: Read real OS version & full CRUD inside HKCU sandbox
        string? currentBuild = _realRegistry.GetValue<string>(@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuild");
        Assert.False(string.IsNullOrWhiteSpace(currentBuild));

        string testKey = $@"{_sandboxRegRoot}\CrudTest";
        Assert.True(_realRegistry.CreateKey(testKey));
        Assert.True(_realRegistry.KeyExists(testKey));

        Assert.True(_realRegistry.SetValue(testKey, "StrVal", "HelloWindows", RegistryValueKind.String));
        Assert.True(_realRegistry.SetValue(testKey, "DwordVal", 42, RegistryValueKind.DWord));
        Assert.True(_realRegistry.SetValue(testKey, "QwordVal", 9876543210L, RegistryValueKind.QWord));
        Assert.True(_realRegistry.SetValue(testKey, "BinVal", new byte[] { 1, 2, 3, 4 }, RegistryValueKind.Binary));
        Assert.True(_realRegistry.SetValue(testKey, "MultiVal", new[] { "Line1", "Line2" }, RegistryValueKind.MultiString));

        Assert.True(_realRegistry.ValueExists(testKey, "StrVal"));
        Assert.Equal("HelloWindows", _realRegistry.GetValue<string>(testKey, "StrVal"));
        Assert.Equal(42, _realRegistry.GetValue<int>(testKey, "DwordVal"));
        Assert.Equal(RegistryValueKind.DWord, _realRegistry.GetValueKind(testKey, "DwordVal"));
        Assert.Contains("StrVal", _realRegistry.GetValueNames(testKey));

        Assert.True(_realRegistry.DeleteValue(testKey, "StrVal"));
        Assert.False(_realRegistry.ValueExists(testKey, "StrVal"));
        Assert.True(_realRegistry.DeleteKey(testKey, recursive: true));
        Assert.False(_realRegistry.KeyExists(testKey));

        // 2. WindowsFileSystemService: Real file I/O, lock detection, ZIP extraction, SHA-256, and disk space
        string fileA = Path.Combine(_sandboxDir, "testA.txt");
        string fileB = Path.Combine(_sandboxDir, "testB.txt");
        _realFileSystem.WriteAllText(fileA, "Safe Windows Data Integrity Check", Encoding.UTF8);
        Assert.True(_realFileSystem.FileExists(fileA));
        Assert.True(_realFileSystem.GetFileSize(fileA) > 0);
        Assert.True(_realFileSystem.GetAvailableFreeSpace(_sandboxDir) > 10 * 1024 * 1024);
        Assert.True(_realFileSystem.CheckDiskSpace(_sandboxDir, 1024, 1.2));

        string hashSync = _realFileSystem.ComputeSha256(fileA);
        string hashAsync = await _realFileSystem.ComputeSha256Async(fileA);
        Assert.Equal(64, hashSync.Length);
        Assert.Equal(hashSync, hashAsync);

        // Real OS file lock detection
        Assert.False(_realFileSystem.IsFileLocked(fileA));
        using (var exclusiveStream = new FileStream(fileA, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.True(_realFileSystem.IsFileLocked(fileA));
        }
        Assert.False(_realFileSystem.IsFileLocked(fileA));

        _realFileSystem.CopyFile(fileA, fileB, overwrite: true);
        Assert.Equal(hashSync, _realFileSystem.ComputeSha256(fileB));

        // 3. WindowsProcessRunner: Safe echo command & process enumeration
        var echoRes = await _realProcessRunner.RunAsync("cmd.exe", "/c echo ITOOLKIT_SAFE_TEST");
        Assert.Equal(0, echoRes.ExitCode);
        Assert.Contains("ITOOLKIT_SAFE_TEST", echoRes.StandardOutput);

        // 4. WindowsNetworkService: Real adapters, loopback ping, and ephemeral TCP port check
        var adapters = _realNetwork.GetAdapters().ToList();
        Assert.NotEmpty(adapters);
        Assert.True(_realNetwork.PingHost("127.0.0.1", 2000));

        using (var listener = new TcpListener(IPAddress.Loopback, 0))
        {
            listener.Start();
            int ephemeralPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            Assert.True(_realNetwork.TestPort("127.0.0.1", ephemeralPort, 2000));
            listener.Stop();
        }

        // 5. WindowsWmiService & WindowsTelemetryService: Real hardware/OS snapshot
        var osWmi = _realWmi.QueryFirst("SELECT Caption, Version FROM Win32_OperatingSystem");
        Assert.NotNull(osWmi);
        Assert.True(osWmi.ContainsKey("Caption"));

        var elevationGuard = new ElevationGuard();
        var telemetryService = new WindowsTelemetryService(elevationGuard, _realFileSystem, _realWmi, _realRegistry);
        var snapshot = await telemetryService.GetSnapshotAsync();
        Assert.NotNull(snapshot);
        Assert.False(string.IsNullOrWhiteSpace(snapshot.OsDescription));
        Assert.False(string.IsNullOrWhiteSpace(snapshot.OsBuild));
        Assert.True(snapshot.MemoryTotalBytes > 0);
        Assert.True(snapshot.SystemDriveTotalBytes > 0);
        Assert.True(snapshot.SystemDriveFreeBytes > 0);

        // 6. ActivityLogger: Real log file creation in sandbox
        _realLogger.Log(LogLevel.Info, "LiveTest", "Verified native Windows services safely.");
        Assert.True(File.Exists(_realLogger.LogFilePath));
        string logContent = File.ReadAllText(_realLogger.LogFilePath);
        Assert.Contains("Verified native Windows services safely.", logContent);
    }

    [Fact]
    public void LiveWindows_SafetyEngines_AtomicRegistryRollbackAndResourceGuards_Verify100PercentDataSafety()
    {
        if (!OperatingSystem.IsWindows()) return;

        string regBackupDir = Path.Combine(_sandboxDir, "Backups", "Registry");
        var atomicRegistry = new AtomicRegistryService(_realRegistry, _realFileSystem, _realLogger, regBackupDir);

        // 1. Pre-populate a real HKCU sandbox key with diverse value types
        string targetKey = $@"{_sandboxRegRoot}\AtomicTarget";
        _realRegistry.CreateKey(targetKey);
        _realRegistry.SetValue(targetKey, "OriginalString", "SafeOriginalValue", RegistryValueKind.String);
        _realRegistry.SetValue(targetKey, "OriginalDword", 100, RegistryValueKind.DWord);
        _realRegistry.SetValue(targetKey, "HighBitDword", unchecked((int)0x80000001), RegistryValueKind.DWord);
        _realRegistry.SetValue(targetKey, "OriginalBinary", new byte[] { 0xAA, 0xBB, 0xCC }, RegistryValueKind.Binary);
        _realRegistry.SetValue(targetKey, "OriginalMulti", new[] { "Alpha", "Beta" }, RegistryValueKind.MultiString);

        // 2. Simulate a mid-transaction failure after corrupting values and adding a rogue subkey
        var failedMutation = atomicRegistry.ExecuteAtomicMutation(
            targetKey,
            () =>
            {
                _realRegistry.SetValue(targetKey, "OriginalString", "CORRUPTED", RegistryValueKind.String);
                _realRegistry.SetValue(targetKey, "OriginalDword", 999, RegistryValueKind.DWord);
                _realRegistry.SetValue(targetKey, "RogueValue", "ShouldBeWiped", RegistryValueKind.String);
                _realRegistry.CreateKey($@"{targetKey}\RogueSubKey");
                throw new InvalidOperationException("Simulated mid-flight failure");
            },
            "Test Automatic Rollback on Live Windows Registry");

        Assert.False(failedMutation.Success);
        Assert.NotNull(failedMutation.BackupPath);
        Assert.True(File.Exists(failedMutation.BackupPath));

        // Verify 100% state restoration in the real Windows Registry
        Assert.Equal("SafeOriginalValue", _realRegistry.GetValue<string>(targetKey, "OriginalString"));
        Assert.Equal(100, _realRegistry.GetValue<int>(targetKey, "OriginalDword"));
        Assert.Equal(unchecked((int)0x80000001), _realRegistry.GetValue<int>(targetKey, "HighBitDword"));
        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC }, (byte[])_realRegistry.GetValue(targetKey, "OriginalBinary")!);
        Assert.Equal(new[] { "Alpha", "Beta" }, (string[])_realRegistry.GetValue(targetKey, "OriginalMulti")!);
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
                return false; // Trigger rollback
            },
            "Test Sentinel Deletion Rollback");

        Assert.False(sentinelRollback.Success);
        Assert.False(_realRegistry.KeyExists(nonExistentKey));

        // 4. ResourceGuard cryptographic manifest generation & corruption detection on real disk
        var resourceGuard = new ResourceGuard(_realFileSystem, _realLogger);
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

        // Tamper with f2 and verify detection
        File.WriteAllText(f2, "Tampered Content!");
        var tamperedCheck = resourceGuard.ValidateManifest(loadedManifest);
        Assert.False(tamperedCheck.IsValid);
        Assert.Contains("doc2.txt", tamperedCheck.MismatchedFiles);
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

        // Seed sandboxed Windows directories to verify real file preservation/deletion rules on Windows disk
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string cbsDir = Path.Combine(sysRoot, "Logs", "CBS");
        string dismDir = Path.Combine(sysRoot, "Logs", "DISM");
        string winTempDir = Path.Combine(sysRoot, "Temp");

        sandboxFs.CreateDirectory(cbsDir);
        sandboxFs.CreateDirectory(dismDir);
        sandboxFs.CreateDirectory(winTempDir);

        string activeCbsLog = Path.Combine(cbsDir, "CBS.log");
        string archivedCbsLog = Path.Combine(cbsDir, "CbsPersist_20260101.log");
        string activeDismLog = Path.Combine(dismDir, "dism.log");
        string archivedDismLog = Path.Combine(dismDir, "dism.log.bak");
        string recentTempFile = Path.Combine(winTempDir, "recent_active.tmp");
        string oldTempFile = Path.Combine(winTempDir, "stale_old.tmp");

        sandboxFs.WriteAllText(activeCbsLog, "Active CBS log - MUST PRESERVE");
        sandboxFs.WriteAllText(archivedCbsLog, "Archived CBS log - CAN DELETE");
        sandboxFs.WriteAllText(activeDismLog, "Active DISM log - MUST PRESERVE");
        sandboxFs.WriteAllText(archivedDismLog, "Archived DISM log - CAN DELETE");
        sandboxFs.WriteAllText(recentTempFile, "Recent temp file (<24h) - MUST PRESERVE");
        sandboxFs.WriteAllText(oldTempFile, "Old temp file (>48h) - CAN DELETE");

        // Set last write time of oldTempFile on real disk to 48 hours ago
        File.SetLastWriteTimeUtc(sandboxFs.MapPath(oldTempFile), DateTime.UtcNow.AddHours(-48));

        var (dismRes, sfcRes) = healthService.RunDismSfcPipeline();
        Assert.True(dismRes.Success);
        Assert.True(sfcRes.Success);

        var wuReset = healthService.ResetWindowsUpdateComponents();
        Assert.True(wuReset.Success);
        Assert.Equal(35, wuReset.ReRegisteredDllCount);

        var blockRes = healthService.BlockWindowsUpdates();
        Assert.True(blockRes.Success);
        Assert.Equal(1, sandboxReg.GetValue<int>(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));

        var unblockRes = healthService.UnblockWindowsUpdates();
        Assert.True(unblockRes.Success);
        Assert.False(sandboxReg.ValueExists(SystemHealthService.WindowsUpdatePolicyKey, "DisableWindowsUpdateAccess"));

        var timeRes = healthService.SyncSystemTime();
        Assert.True(timeRes.Success);

        var wmiRes = healthService.RepairWmiRepository();
        Assert.True(wmiRes.Success);

        var cleanupRes = healthService.RunUnifiedDiskCleanup(24);
        Assert.True(cleanupRes.Success);

        // Verify strict data safety invariants on real disk inside sandbox
        Assert.True(sandboxFs.FileExists(activeCbsLog), "Active CBS.log must be preserved!");
        Assert.True(sandboxFs.FileExists(activeDismLog), "Active dism.log must be preserved!");
        Assert.True(sandboxFs.FileExists(recentTempFile), "Recent temp file (<24h) must be preserved!");
        Assert.False(sandboxFs.FileExists(archivedCbsLog), "Archived CbsPersist log should be cleaned.");
        Assert.False(sandboxFs.FileExists(archivedDismLog), "Archived dism.log.bak should be cleaned.");
        Assert.False(sandboxFs.FileExists(oldTempFile), "Old temp file (>24h) should be cleaned.");
    }

    [Fact]
    public void LiveWindows_Pillar2_OfficeAndOutlook_VerifiesRealDiscoveryAndSandboxedRepairsSafely()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. Read-only live discovery of Outlook MAPI stores & GDI handle audit on real Windows host
        var safeProc = new SafeInterceptingProcessRunner();
        var lockGuard = new ProcessLockGuard(safeProc, _realFileSystem, _realLogger);
        var resourceGuard = new ResourceGuard(_realFileSystem, _realLogger);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var atomicReg = new AtomicRegistryService(sandboxReg, sandboxFs, _realLogger, Path.Combine(_sandboxDir, "Backups", "Pillar2"));

        var readOnlyOutlook = new OutlookService(_realRegistry, atomicReg, _realFileSystem, lockGuard, resourceGuard, null, _realLogger);
        var discoveredStores = readOnlyOutlook.DiscoverDataFiles();
        Assert.NotNull(discoveredStores);

        var liveOfficeSuite = new OfficeSuiteService(_realProcessRunner, sandboxFs, sandboxReg, atomicReg, lockGuard, _realLogger);
        var gdiAudit = liveOfficeSuite.AuditAndMitigateGdiLeaks(warningThreshold: 999999, killThreshold: 999999);
        Assert.NotNull(gdiAudit);

        // 2. Sandboxed Office repairs: verify Personal.xlsb and Stream_Autocomplete_*.dat preservation on real Windows disk
        var sandboxLockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);
        var sandboxResourceGuard = new ResourceGuard(sandboxFs, _realLogger);
        var officeService = new OfficeSuiteService(safeProc, sandboxFs, sandboxReg, atomicReg, sandboxLockGuard, _realLogger);
        var outlookService = new OutlookService(sandboxReg, atomicReg, sandboxFs, sandboxLockGuard, sandboxResourceGuard, null, _realLogger);

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        // Seed Word Normal.dotm and Excel Personal.xlsb + add-in in sandbox
        string normalDotm = Path.Combine(appData, "Microsoft", "Templates", "Normal.dotm");
        string xlStartDir = Path.Combine(appData, "Microsoft", "Excel", "XLSTART");
        string personalXlsb = Path.Combine(xlStartDir, "PERSONAL.XLSB");
        string rogueAddIn = Path.Combine(xlStartDir, "BadAddIn.xlam");

        sandboxFs.WriteAllText(normalDotm, "Corrupt Normal.dotm");
        sandboxFs.WriteAllText(personalXlsb, "User Macro Workbook - MUST PRESERVE");
        sandboxFs.WriteAllText(rogueAddIn, "Rogue Add-In");

        var wordRes = officeService.WordQuickRepair();
        Assert.True(wordRes.Success);
        Assert.True(wordRes.NormalDotmReset);

        var excelRes = officeService.ExcelQuickRepair();
        Assert.True(excelRes.Success);
        Assert.Equal(1, excelRes.AddInsDisabledCount);
        Assert.True(sandboxFs.FileExists(personalXlsb), "Personal.xlsb must remain intact in XLSTART!");

        var pptRes = officeService.PowerPointQuickRepair();
        Assert.True(pptRes.Success);

        // Seed Outlook RoamCache with Stream_Autocomplete_*.dat and other cache files
        string roamCache = Path.Combine(localAppData, "Microsoft", "Outlook", "RoamCache");
        string nk2Stream = Path.Combine(roamCache, "Stream_Autocomplete_0_123456.dat");
        string staleCache = Path.Combine(roamCache, "Stream_Weather_0_999.dat");
        sandboxFs.WriteAllText(nk2Stream, "Critical User Autocomplete Contacts - MUST PRESERVE");
        sandboxFs.WriteAllText(staleCache, "Stale cache");

        var mailRepair = outlookService.QuickMailAndCacheRepair();
        Assert.True(mailRepair.Success);
        Assert.True(mailRepair.AutocompletePreserved);
        Assert.True(sandboxFs.FileExists(nk2Stream), "Stream_Autocomplete_*.dat must never be deleted!");
        Assert.False(sandboxFs.FileExists(staleCache));

        // 3. Test 100GB PST expansion, New Default PST Pipeline, Backup, Relocate, and Restore with SHA-256 verification
        var expandRes = outlookService.ExpandDataFileLimitsTo100GB();
        Assert.True(expandRes.Success);
        Assert.Equal(102400, sandboxReg.GetValue<int>(@"HKCU\Software\Microsoft\Office\16.0\Outlook\PST", "MaxLargeFileSize"));

        string newPstPath = Path.Combine(_sandboxDir, "OutlookTest", "NewArchive.pst");
        var pstPipeline = outlookService.RunNewDefaultPstPipeline(newPstPath);
        Assert.True(pstPipeline.Success);
        Assert.True(sandboxFs.FileExists(newPstPath));

        string pstBackupDir = Path.Combine(_sandboxDir, "OutlookBackup");
        var backupRes = outlookService.BackupDataFile(newPstPath, pstBackupDir);
        Assert.True(backupRes.Success);

        string expectedHash = sandboxResourceGuard.ComputeSha256(newPstPath);
        string restoredPstPath = Path.Combine(_sandboxDir, "OutlookRestored", "RestoredArchive.pst");
        var restoreRes = outlookService.RestoreDataFile(Path.Combine(pstBackupDir, "NewArchive.pst"), restoredPstPath, expectedHash);
        Assert.True(restoreRes.Success);
        Assert.Equal(expectedHash, sandboxResourceGuard.ComputeSha256(restoredPstPath));

        string relocateDir = Path.Combine(_sandboxDir, "OutlookRelocated");
        var relocateRes = outlookService.RelocateDataFile(restoredPstPath, relocateDir);
        Assert.True(relocateRes.Success);
        Assert.True(relocateRes.Sha256Matched);
    }

    [Fact]
    public void LiveWindows_Pillar3_ConnectivityAndPrinters_VerifiesLiveDiagnosticsAndSandboxedRemediation()
    {
        if (!OperatingSystem.IsWindows()) return;

        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var atomicReg = new AtomicRegistryService(sandboxReg, sandboxFs, _realLogger, Path.Combine(_sandboxDir, "Backups", "Pillar3"));
        var lockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);

        // 1. Live read-only diagnostics on real Windows host (Spooler WMI/SC status, Point & Print audit, Loopback port check)
        var livePrinterService = new PrinterService(_realProcessRunner, _realFileSystem, _realRegistry, atomicReg, lockGuard, _realWmi, _realLogger, _realNetwork);
        var spoolerStatus = livePrinterService.GetSpoolerStatus();
        Assert.NotNull(spoolerStatus);
        Assert.False(string.IsNullOrWhiteSpace(spoolerStatus.ServiceStatus));
        Assert.False(string.IsNullOrWhiteSpace(spoolerStatus.SpoolDirectory));

        var policyAudit = livePrinterService.AuditPointAndPrintPolicy();
        Assert.NotNull(policyAudit);
        Assert.False(string.IsNullOrWhiteSpace(policyAudit.PostureDescription));

        var liveConnectivity = new ConnectivityService(_realNetwork, safeProc, sandboxReg, atomicReg, _realLogger);
        var portDiag = liveConnectivity.DiagnosePrinterPortConnectivity("127.0.0.1");
        Assert.True(portDiag.IsPingSuccessful);

        // 2. Sandboxed network and printer remediations across all 12 error codes and role batches
        var netRemediate = liveConnectivity.RemediateNetworkStack();
        Assert.True(netRemediate.Success);

        var smbRes = liveConnectivity.ConfigureSmbSharing();
        Assert.True(smbRes.Success);
        Assert.Equal(1, sandboxReg.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters", "AllowInsecureGuestAuth"));

        var sandboxPrinterService = new PrinterService(safeProc, sandboxFs, sandboxReg, atomicReg, lockGuard, _realWmi, _realLogger, _realNetwork);
        foreach (var code in sandboxPrinterService.GetSupportedErrorCodes())
        {
            var errRes = sandboxPrinterService.RemediatePrinterError(code);
            Assert.True(errRes.Success, $"Remediation failed for printer error code '{code}'");
        }

        var clientBatch = sandboxPrinterService.RemediateRole(PrinterRemediationRole.Client);
        Assert.True(clientBatch.Success);
        Assert.NotEmpty(clientBatch.BackupPaths);

        var serverBatch = sandboxPrinterService.RemediateRole(PrinterRemediationRole.Server);
        Assert.True(serverBatch.Success);
    }

    [Fact]
    public void LiveWindows_Pillar4_IdentityAndBackup_VerifiesAccountGuardrailsAndRealRobocopyPipeline()
    {
        if (!OperatingSystem.IsWindows()) return;

        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);

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

        // 3. Live read-only User Profile Map discovery, Bookmarks export, and ReadOnly Certificate store export into sandbox
        var realResourceGuard = new ResourceGuard(_realFileSystem, _realLogger);
        var liveBackup = new BackupService(_realProcessRunner, _realFileSystem, _realRegistry, realResourceGuard, null, _realLogger);

        var profileMap = liveBackup.GetUserProfileMap();
        Assert.NotNull(profileMap);
        Assert.Equal(currentUserName, profileMap.Username);
        Assert.False(string.IsNullOrWhiteSpace(profileMap.DesktopPath));
        Assert.False(string.IsNullOrWhiteSpace(profileMap.DocumentsPath));

        string bookmarkExportDir = Path.Combine(_sandboxDir, "ExportedBookmarks");
        var exportedBookmarks = liveBackup.ExportBrowserBookmarks(bookmarkExportDir);
        Assert.NotNull(exportedBookmarks);

        string certExportDir = Path.Combine(_sandboxDir, "ExportedCerts");
        var certResult = liveBackup.ExportCertificates("My", certExportDir, "iToolKitSafePass!2026");
        Assert.True(certResult.Success);
        Assert.True(File.Exists(certResult.ExportPath));

        // 4. Real Windows robocopy.exe sync + SHA-256 manifest creation, validation, and profile restore in %TEMP% sandbox
        string robosource = Path.Combine(_sandboxDir, "RoboSource");
        string robodest = Path.Combine(_sandboxDir, "RoboDest");
        Directory.CreateDirectory(Path.Combine(robosource, "SubFolder"));
        File.WriteAllText(Path.Combine(robosource, "profile_doc.txt"), "Important User Document 12345");
        File.WriteAllText(Path.Combine(robosource, "SubFolder", "notes.txt"), "Nested user notes");

        var roboSync = liveBackup.RunRobocopySync(robosource, robodest, mirror: false);
        Assert.True(roboSync.IsSuccess, $"Robocopy exited with {roboSync.ExitCode}: {roboSync.ErrorOutput}");
        Assert.True(File.Exists(Path.Combine(robodest, "profile_doc.txt")));
        Assert.True(File.Exists(Path.Combine(robodest, "SubFolder", "notes.txt")));

        string manifestPath = Path.Combine(robodest, BackupService.ManifestFileName);
        var manifestData = liveBackup.CreateBackupManifest(robodest, manifestPath);
        Assert.Equal(2, manifestData.Files.Count);
        Assert.True(File.Exists(manifestPath));

        var validation = liveBackup.ValidateBackupManifest(robodest, manifestPath);
        Assert.True(validation.IsIntact);
        Assert.Equal(2, validation.MatchedCount);
        Assert.Equal(0, validation.CorruptedCount);
        Assert.Equal(0, validation.MissingCount);
    }

    [Fact]
    public void LiveWindows_Pillar5_SoftwareAndOptimization_VerifiesWingetAndSandboxedCatalog()
    {
        if (!OperatingSystem.IsWindows()) return;

        // 1. Live read-only Winget status check on this Windows host
        var liveOpt = new OptimizationService(_realProcessRunner, _realFileSystem, _realNetwork, _realLogger);
        var wingetStatus = liveOpt.GetWingetStatus();
        Assert.NotNull(wingetStatus);

        // 2. Verify security guardrails block insecure/untrusted debloat URLs before any network/process action
        Assert.Throws<SecurityException>(() => liveOpt.ExecuteDebloatScript("InsecureHttp", "http://debloat.raphi.re/script.ps1"));
        Assert.Throws<SecurityException>(() => liveOpt.ExecuteDebloatScript("UntrustedDomain", "https://evil.example.com/script.ps1"));

        // 3. Sandboxed 8-app catalog installation & policies
        var safeProc = new SafeInterceptingProcessRunner();
        var sandboxFs = new SandboxedWindowsFileSystemService(_realFileSystem, _sandboxDir);
        var sandboxReg = new SandboxedWindowsRegistryService(_realRegistry, _sandboxRegRoot);
        var lockGuard = new ProcessLockGuard(safeProc, sandboxFs, _realLogger);

        var appInstaller = new AppInstallerService(safeProc, sandboxFs, sandboxReg, lockGuard, _realNetwork, _realLogger);
        var catalog = appInstaller.GetCatalog();
        Assert.Equal(8, catalog.Count);

        var batchRes = appInstaller.InstallBatch(new[] { "Chrome", "VCRedistAIO", "FoxitReader" });
        Assert.Equal(3, batchRes.Count);
        Assert.Equal("VCRedistAIO", batchRes[0].AppId); // VCRedistAIO must always execute first

        Assert.True(appInstaller.SetDefaultBrowser());
        Assert.True(appInstaller.SetDefaultPdfViewer());
        Assert.True(appInstaller.ConfigureUblockOriginLitePolicy());
        Assert.Equal("ChromeHTML", sandboxReg.GetValue<string>(@"HKCU\Software\Classes\.html", ""));
        Assert.Equal("FoxitPDFReader.Document", sandboxReg.GetValue<string>(@"HKCU\Software\Classes\.pdf", ""));
    }

    [Fact]
    public async Task LiveWindows_EndToEnd_ProductionDiContainerAndFullSystemDiagnosticScan_ExecutesSafely()
    {
        if (!OperatingSystem.IsWindows()) return;

        var services = new ServiceCollection();
        ServiceRegistration.ConfigureServices(services);

        // Override IActivityLogger so diagnostic scan logs write to the isolated sandbox folder
        services.AddSingleton<IActivityLogger>(_realLogger);

        await using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        var mainVm = provider.GetRequiredService<MainViewModel>();
        mainVm.TelemetryHeader.StopPolling();
        mainVm.DashboardViewModel.StopPolling();

        // Execute full read-only system diagnostic scan across all 5 pillars on live Windows
        await mainVm.RunSystemScanAsync();

        Assert.False(mainVm.IsScanning);
        Assert.Equal(100, mainVm.ScanProgressPercentage);
        Assert.Equal("100%", mainVm.ScanProgressText);
        Assert.Contains("System scan complete:", mainVm.DashboardViewModel.StatusMessage);
        Assert.NotEmpty(mainVm.IdentityBackupViewModel.Accounts);
        Assert.NotEmpty(mainVm.SoftwareOptimizationViewModel.CatalogApps);
        Assert.NotEqual("Not Checked", mainVm.SoftwareOptimizationViewModel.WingetVersionText);
    }
}
