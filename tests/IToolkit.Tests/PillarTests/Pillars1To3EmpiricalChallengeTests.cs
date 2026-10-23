namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Core.Services.Software;
using IToolkit.Core.Services.SystemHealth;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge test suite for Pillars 1-3:
/// - Pillar 1: Software & Applications (AppInstallerService)
/// - Pillar 2: System Health & Maintenance (OptimizationService, SystemHealthService)
/// - Pillar 3: Network & Connectivity (ConnectivityService)
/// </summary>
public class Pillars1To3EmpiricalChallengeTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly ProcessLockGuard _lockGuard;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly AppInstallerService _appInstaller;
    private readonly OptimizationService _optimizationService;
    private readonly SystemHealthService _systemHealthService;
    private readonly ConnectivityService _connectivityService;

    public Pillars1To3EmpiricalChallengeTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);

        _appInstaller = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, _network);
        _optimizationService = new OptimizationService(_processRunner, _fileSystem, _network);
        _systemHealthService = new SystemHealthService(_processRunner, _fileSystem);
        _connectivityService = new ConnectivityService(_network, _processRunner, _registry, _atomicRegistry);
    }

    #region Pillar 1: AppInstallerService Empirical Challenges

    [Fact]
    public void AppInstaller_DownloadFailure_ReturnsFailure_AndCleansTempFile()
    {
        var faultyNet = new ConfigurableNetworkService(_network)
        {
            DownloadFileResult = false
        };
        var installer = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, faultyNet);

        // Test UniKey archive download failure
        var unikeyRes = installer.InstallApplication("UniKey");
        Assert.False(unikeyRes.Success);
        Assert.Equal("ArchiveExtract", unikeyRes.MethodUsed);
        Assert.Contains("Failed to download archive", unikeyRes.Message);
        Assert.True(unikeyRes.TempCleanedUp);
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*"));

        // Test UltraVNC direct download failure
        var uvncRes = installer.InstallApplication("UltraVNC");
        Assert.False(uvncRes.Success);
        Assert.Equal("DirectDownload", uvncRes.MethodUsed);
        Assert.Contains("Failed to download installer binary", uvncRes.Message);
        Assert.True(uvncRes.TempCleanedUp);
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UltraVNC*"));
    }

    [Fact]
    public void AppInstaller_NetworkException_GuaranteesTempFileCleanupInFinally()
    {
        var faultyNet = new ConfigurableNetworkService(_network)
        {
            ThrowOnDownloadFile = new IOException("Network connection timed out.")
        };
        var installer = new AppInstallerService(_processRunner, _fileSystem, _registry, _lockGuard, faultyNet);

        // When download throws, verify exception propagates but finally block deletes temp file
        Assert.Throws<IOException>(() => installer.InstallApplication("UniKey"));
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*"));

        Assert.Throws<IOException>(() => installer.InstallApplication("UltraVNC"));
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UltraVNC*"));
    }

    [Fact]
    public void AppInstaller_CorruptZipExtraction_CleansTempZipInFinally()
    {
        // Provide invalid, corrupted zip data
        byte[] corruptZipBytes = Encoding.UTF8.GetBytes("THIS_IS_NOT_A_VALID_ZIP_ARCHIVE_DATA");
        _network.SetSimulatedDownload("https://www.unikey.org/assets/release/unikey43RC5-200929-win64.zip", corruptZipBytes);

        // Extraction should return failed result gracefully, and temp file must be deleted in finally
        var result = _appInstaller.InstallApplication("UniKey");

        Assert.False(result.Success);
        Assert.True(result.TempCleanedUp);
        // Verify temp zip was cleaned up in finally block
        var lingeringZips = _fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*.zip");
        Assert.Empty(lingeringZips);
    }

    [Fact]
    public void AppInstaller_CorruptZipExtraction_ReturnsFailedInstallResult_WithoutCrashing()
    {
        byte[] corruptZipBytes = Encoding.UTF8.GetBytes("THIS_IS_NOT_A_VALID_ZIP_ARCHIVE_DATA");
        _network.SetSimulatedDownload("https://www.unikey.org/assets/release/unikey43RC5-200929-win64.zip", corruptZipBytes);

        // Expected contract: Service should handle corrupt archive gracefully and return failed result rather than crashing
        var result = _appInstaller.InstallApplication("UniKey");

        Assert.False(result.Success);
        Assert.True(result.TempCleanedUp);
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*.zip"));
    }

    [Fact]
    public void AppInstaller_EmptyZipExtraction_SucceedsWithoutCrashing()
    {
        // Create an empty valid zip archive (0 entries)
        using var mem = new MemoryStream();
        using (var zip = new ZipArchive(mem, ZipArchiveMode.Create, true))
        {
            // No entries added
        }
        _network.SetSimulatedDownload("https://www.unikey.org/assets/release/unikey43RC5-200929-win64.zip", mem.ToArray());

        var result = _appInstaller.InstallApplication("UniKey");

        Assert.True(result.Success);
        Assert.True(result.TempCleanedUp);
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*.zip"));
    }

    [Fact]
    public void AppInstaller_UniKey_NonWingetFullLifecycle_Verified()
    {
        // 1. Setup conflicting processes running
        _processRunner.AddProcess(301, "UniKeyNT");
        _processRunner.AddProcess(302, "UniKey");

        // 2. Execute installation
        var result = _appInstaller.InstallApplication("UniKey");

        // 3. Verify lifecycle:
        Assert.True(result.Success);
        Assert.Equal("ArchiveExtract", result.MethodUsed);
        Assert.True(result.TempCleanedUp);

        // Processes closed
        Assert.False(_processRunner.IsProcessRunning("UniKeyNT"));
        Assert.False(_processRunner.IsProcessRunning("UniKey"));

        // Winget was NOT invoked
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("winget.exe"));

        // Extracted to target directory
        Assert.True(_fileSystem.FileExists(@"C:\Program Files\UniKey\UniKeyNT.exe"));

        // Shortcut created on Desktop
        string? userProfile = Environment.GetEnvironmentVariable("USERPROFILE");
        string desktop = !string.IsNullOrEmpty(userProfile) ? Path.Combine(userProfile, "Desktop") : @"C:\Users\Default\Desktop";
        Assert.True(_fileSystem.FileExists(Path.Combine(desktop, "UniKey.lnk")));

        // Temp file cleaned up
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "*UniKey*"));
    }

    [Fact]
    public void AppInstaller_InstallerExecutionException_GuaranteesTempExeCleanupInFinally()
    {
        // Setup ProcessRunner to throw on execution of UltraVNC installer
        var faultyRunner = new FaultyProcessRunner(_processRunner)
        {
            ThrowOnCommandMatch = "UltraVNC",
            ExceptionToThrow = new InvalidOperationException("Process execution failed abruptly.")
        };
        var installer = new AppInstallerService(faultyRunner, _fileSystem, _registry, _lockGuard, _network);

        Assert.Throws<InvalidOperationException>(() => installer.InstallApplication("UltraVNC"));

        // Verify temp file is cleaned up despite process launch exception
        var lingeringInstallers = _fileSystem.EnumerateFiles(Path.GetTempPath(), "*UltraVNC*");
        Assert.Empty(lingeringInstallers);
    }

    [Fact]
    public void AppInstaller_NonExistentApp_ReturnsNotFoundResult()
    {
        var result = _appInstaller.InstallApplication("UnknownAppXYZ");

        Assert.False(result.Success);
        Assert.Equal("None", result.MethodUsed);
        Assert.Contains("not found", result.Message);
    }

    #endregion

    #region Pillar 2: OptimizationService Empirical Challenges

    [Theory]
    [InlineData("<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>404 Page Not Found</body></html>")]
    [InlineData("<html><body><h1>Access Denied</h1></body></html>")]
    [InlineData("<!doctype html><html><head><meta charset='utf-8'></head><body>Cloudflare DDoS Protection</body></html>")]
    [InlineData("<HTML><BODY>Under Maintenance</BODY></HTML>")]
    public void OptimizationService_DebloatScript_RejectsAllHtmlPayloads(string htmlPayload)
    {
        _network.SetHostReachable("1.1.1.1", true);
        _network.SetSimulatedDownload("https://debloat.raphi.re/", htmlPayload);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.False(result.SyntaxValid);
        Assert.Equal(-2, result.ExitCode);
        Assert.Contains("HTML tags", result.Message);

        // Assert powershell was NEVER called with HTML payload
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));

        // Assert temp script is cleaned up
        Assert.Empty(_fileSystem.EnumerateFiles(Path.GetTempPath(), "iToolKit_Win11Debloat_*.ps1"));
    }

    [Theory]
    [InlineData("https://malicious.com/script.ps1")]
    [InlineData("https://evil-hacker.net/debloat.ps1")]
    [InlineData("https://debloat.raphi.re.attacker.com/script.ps1")]
    [InlineData("https://fakeraphire.re/debloat.ps1")]
    public void OptimizationService_DebloatScript_RejectsUnauthorizedDomains(string unauthorizedUrl)
    {
        _network.SetHostReachable("1.1.1.1", true);

        var ex = Assert.Throws<SecurityException>(() =>
            _optimizationService.ExecuteDebloatScript("DebloatTool", unauthorizedUrl));

        Assert.Contains("approved whitelist", ex.Message);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));
    }

    [Fact]
    public void OptimizationService_IsolatedPowerShellInvocation_Verified()
    {
        _network.SetHostReachable("1.1.1.1", true);

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.True(result.ExecutionSuccess);

        // Find the powershell command executed
        string? psCmd = _processRunner.ExecutedCommands.FirstOrDefault(c => c.Contains("powershell.exe"));
        Assert.NotNull(psCmd);

        // Verify isolation flags
        Assert.Contains("-NoProfile", psCmd);
        Assert.Contains("-NonInteractive", psCmd);
        Assert.Contains("-ExecutionPolicy Bypass", psCmd);
        Assert.Contains("-File", psCmd);
        // Verify no Invoke-Expression (IEX)
        Assert.DoesNotContain("Invoke-Expression", psCmd);
        Assert.DoesNotContain("iex", psCmd);
    }

    [Fact]
    public void OptimizationService_EmptyPayload_HandledSafely()
    {
        _network.SetHostReachable("1.1.1.1", true);
        _network.SetSimulatedDownload("https://debloat.raphi.re/", "   \r\n   ");

        var result = _optimizationService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.False(result.SyntaxValid);
        Assert.Contains("empty", result.Message);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));
    }

    [Fact]
    public void OptimizationService_DownloadException_HandledSafely()
    {
        _network.SetHostReachable("1.1.1.1", true);
        var faultyNet = new ConfigurableNetworkService(_network)
        {
            ThrowOnDownloadString = new IOException("Server closed connection prematurely.")
        };
        var optService = new OptimizationService(_processRunner, _fileSystem, faultyNet);

        var result = optService.LaunchWin11Debloat();

        Assert.False(result.ExecutionSuccess);
        Assert.Contains("Failed to download debloat script", result.Message);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("powershell.exe"));
    }

    #endregion

    #region Pillar 2: SystemHealthService Empirical Challenges

    [Fact]
    public void SystemHealthService_MoveDirectory_SoftwareDistributionAndCatroot2_ExecutedSuccessfully()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string sdPath = Path.Combine(sysRoot, "SoftwareDistribution");
        string catrootPath = Path.Combine(sysRoot, "System32", "catroot2");

        _fileSystem.CreateDirectory(sdPath);
        _fileSystem.WriteAllText(Path.Combine(sdPath, "ReportingEvents.log"), "sample log");
        _fileSystem.CreateDirectory(catrootPath);
        _fileSystem.WriteAllText(Path.Combine(catrootPath, "catalog.dat"), "sample catalog");

        var result = _systemHealthService.ResetWindowsUpdateComponents();

        Assert.True(result.Success);
        Assert.Contains(sdPath, result.RenamedDirectories);
        Assert.Contains(catrootPath, result.RenamedDirectories);

        // Verify original directories were moved
        Assert.False(_fileSystem.DirectoryExists(sdPath));
        Assert.False(_fileSystem.DirectoryExists(catrootPath));

        // Verify backup directories were created
        var backupDirs = _fileSystem.EnumerateDirectories(sysRoot, "SoftwareDistribution.bak_*");
        Assert.NotEmpty(backupDirs);
    }

    [Fact]
    public void SystemHealthService_MoveDirectory_FallbackOnFailure_HandlesLockoutGracefully()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string sdPath = Path.Combine(sysRoot, "SoftwareDistribution");
        string catrootPath = Path.Combine(sysRoot, "System32", "catroot2");

        _fileSystem.CreateDirectory(sdPath);
        _fileSystem.CreateDirectory(Path.Combine(sdPath, "Download"));
        _fileSystem.WriteAllText(Path.Combine(sdPath, "Download", "update.cab"), "cab data");
        _fileSystem.CreateDirectory(catrootPath);

        // Wrap filesystem with one that throws on MoveDirectory to test catch fallback
        var faultyFs = new FaultyFileSystemService(_fileSystem)
        {
            ThrowOnMoveDirectory = true
        };
        var healthService = new SystemHealthService(_processRunner, faultyFs);

        var result = healthService.ResetWindowsUpdateComponents();

        Assert.True(result.Success);
        // Should fall back to (Purged) for SoftwareDistribution and (InUse) for catroot2
        Assert.Contains(result.RenamedDirectories, d => d.Contains("(Purged)"));
        Assert.Contains(result.RenamedDirectories, d => d.Contains("(InUse)"));
    }

    [Fact]
    public void SystemHealthService_DismAndSfcRunnerInvocations_StrictlyVerified()
    {
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /CheckHealth",
            new ProcessExecutionResult(0, "CheckHealth OK", string.Empty, false));
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /ScanHealth",
            new ProcessExecutionResult(0, "ScanHealth OK", string.Empty, false));
        _processRunner.SetCommandResult("dism.exe /Online /Cleanup-Image /RestoreHealth",
            new ProcessExecutionResult(0, "RestoreHealth OK", string.Empty, false));
        _processRunner.SetCommandResult("sfc.exe /scannow",
            new ProcessExecutionResult(0, "SFC scannow OK", string.Empty, false));

        var checkRes = _systemHealthService.RunDismCheckHealth();
        Assert.True(checkRes.Success);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "dism.exe /Online /Cleanup-Image /CheckHealth");

        var scanRes = _systemHealthService.RunDismScanHealth();
        Assert.True(scanRes.Success);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "dism.exe /Online /Cleanup-Image /ScanHealth");

        var restoreRes = _systemHealthService.RunDismRestoreHealth();
        Assert.True(restoreRes.Success);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "dism.exe /Online /Cleanup-Image /RestoreHealth");

        var sfcRes = _systemHealthService.RunSfcScan();
        Assert.True(sfcRes.Success);
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "sfc.exe /scannow");

        // Dual pipeline executes RestoreHealth then SFC
        _processRunner.ExecutedCommands.Clear();
        var (dismPipe, sfcPipe) = _systemHealthService.RunDismSfcPipeline();
        Assert.True(dismPipe.Success);
        Assert.True(sfcPipe.Success);
        Assert.Equal(2, _processRunner.ExecutedCommands.Count);
        Assert.Contains("dism.exe", _processRunner.ExecutedCommands[0]);
        Assert.Contains("sfc.exe", _processRunner.ExecutedCommands[1]);
    }

    #endregion

    #region Pillar 3: ConnectivityService Empirical Challenges

    [Fact]
    public void ConnectivityService_FullRemediationPipeline_ExecutesExpectedResets()
    {
        var result = _connectivityService.RemediateNetworkStack();

        Assert.True(result.Success);
        Assert.True(result.DnsFlushed);
        Assert.True(result.DhcpRenewed);
        Assert.True(result.ArpCleared);
        Assert.True(result.WinsockReset);
        Assert.True(result.TcpIpReset);
        Assert.True(result.NlaReset);
        Assert.True(result.ProxyReset);
        Assert.True(result.RequiresReboot);

        // Verify underlying process executions
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "ipconfig.exe /flushdns");
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "ipconfig.exe /renew");
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "netsh.exe winsock reset catalog");
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "netsh.exe int ip reset");
        Assert.Contains(_processRunner.ExecutedCommands, c => c == "netsh.exe winhttp reset proxy");
    }

    [Fact]
    public void ConnectivityService_SmbSharing_ConfiguresGuestAuthAndNetbios()
    {
        var result = _connectivityService.ConfigureSmbSharing();

        Assert.True(result.Success);
        Assert.True(result.InsecureGuestAuthEnabled);
        Assert.True(result.NetbiosEnabled);

        int guestAuth = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters", "AllowInsecureGuestAuth");
        Assert.Equal(1, guestAuth);

        int netbios = _registry.GetValue<int>(@"HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters", "NetbiosOptions");
        Assert.Equal(1, netbios);
    }

    [Fact]
    public void ConnectivityService_DiagnosePrinterPortConnectivity_EvaluatesAllPorts()
    {
        string host = "10.0.0.50";
        _network.SetHostReachable(host, true);
        _network.SetPortOpen(host, 445, true);
        _network.SetPortOpen(host, 135, false);
        _network.SetPortOpen(host, 9100, true);

        var diag = _connectivityService.DiagnosePrinterPortConnectivity(host);

        Assert.True(diag.IsPingSuccessful);
        Assert.True(diag.IsSmbPortOpen);
        Assert.False(diag.IsRpcPortOpen);
        Assert.True(diag.IsRawPortOpen);
        Assert.Contains("RPC:135=CLOSED", diag.DiagnosticsSummary);
        Assert.Contains("RAW:9100=OPEN", diag.DiagnosticsSummary);
    }

    #endregion

    #region Helper Test Doubles

    private class ConfigurableNetworkService : INetworkService
    {
        private readonly MockNetworkService _inner;
        public bool DownloadFileResult { get; set; } = true;
        public Exception? ThrowOnDownloadFile { get; set; }
        public Exception? ThrowOnDownloadString { get; set; }

        public ConfigurableNetworkService(MockNetworkService inner) => _inner = inner;

        public bool PingHost(string host, int timeoutMs = 2000) => _inner.PingHost(host, timeoutMs);
        public bool TestPort(string host, int port, int timeoutMs = 2000) => _inner.TestPort(host, port, timeoutMs);
        public IEnumerable<NetworkAdapterInfo> GetAdapters() => _inner.GetAdapters();
        public bool RestartAdapter(string adapterName) => _inner.RestartAdapter(adapterName);
        public bool FlushDns() => _inner.FlushDns();
        public bool ResetWinsock() => _inner.ResetWinsock();
        public bool ResetTcpIp() => _inner.ResetTcpIp();
        public bool ReleaseRenewDhcp() => _inner.ReleaseRenewDhcp();

        public bool DownloadFile(string url, string destinationPath)
        {
            if (ThrowOnDownloadFile != null) throw ThrowOnDownloadFile;
            if (!DownloadFileResult) return false;
            return _inner.DownloadFile(url, destinationPath);
        }

        public Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default) =>
            Task.FromResult(DownloadFile(url, destinationPath));

        public string DownloadString(string url)
        {
            if (ThrowOnDownloadString != null) throw ThrowOnDownloadString;
            return _inner.DownloadString(url);
        }

        public Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default) =>
            Task.FromResult(DownloadString(url));
    }

    private class FaultyFileSystemService : IFileSystemService
    {
        private readonly MockFileSystemService _inner;
        public bool ThrowOnMoveDirectory { get; set; }

        public FaultyFileSystemService(MockFileSystemService inner) => _inner = inner;

        public long AvailableFreeSpace => _inner.AvailableFreeSpace;
        public bool FileExists(string path) => _inner.FileExists(path);
        public bool DirectoryExists(string path) => _inner.DirectoryExists(path);
        public void CreateDirectory(string path) => _inner.CreateDirectory(path);
        public void DeleteFile(string path) => _inner.DeleteFile(path);
        public void DeleteDirectory(string path, bool recursive = true) => _inner.DeleteDirectory(path, recursive);
        public void CopyFile(string source, string destination, bool overwrite = true) => _inner.CopyFile(source, destination, overwrite);
        public void MoveFile(string source, string destination) => _inner.MoveFile(source, destination);

        public void MoveDirectory(string source, string destination)
        {
            if (ThrowOnMoveDirectory) throw new IOException("Access is denied.");
            _inner.MoveDirectory(source, destination);
        }

        public void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true) =>
            _inner.ExtractZipArchive(zipFilePath, destinationDirectory, overwrite);

        public long GetFileSize(string path) => _inner.GetFileSize(path);
        public long GetAvailableFreeSpace(string path) => _inner.GetAvailableFreeSpace(path);
        public bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2) =>
            _inner.CheckDiskSpace(path, requiredBytes, safetyMultiplier);
        public string ComputeSha256(string path) => _inner.ComputeSha256(path);
        public Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default) =>
            _inner.ComputeSha256Async(path, cancellationToken);
        public bool IsFileLocked(string path) => _inner.IsFileLocked(path);
        public void CreateSymbolicLink(string linkPath, string targetPath) => _inner.CreateSymbolicLink(linkPath, targetPath);
        public string ReadAllText(string path, Encoding? encoding = null) => _inner.ReadAllText(path, encoding);
        public void WriteAllText(string path, string contents, Encoding? encoding = null) => _inner.WriteAllText(path, contents, encoding);
        public byte[] ReadAllBytes(string path) => _inner.ReadAllBytes(path);
        public void WriteAllBytes(string path, byte[] bytes) => _inner.WriteAllBytes(path, bytes);
        public Stream OpenRead(string path) => _inner.OpenRead(path);
        public DateTime GetLastWriteTimeUtc(string path) => _inner.GetLastWriteTimeUtc(path);
        public IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateFiles(path, searchPattern, searchOption);
        public IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateDirectories(path, searchPattern, searchOption);
    }

    private class FaultyProcessRunner : IProcessRunner
    {
        private readonly MockProcessRunner _inner;
        public string? ThrowOnCommandMatch { get; set; }
        public Exception? ExceptionToThrow { get; set; }

        public FaultyProcessRunner(MockProcessRunner inner) => _inner = inner;

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            if (ThrowOnCommandMatch != null && (fileName.Contains(ThrowOnCommandMatch) || (arguments?.Contains(ThrowOnCommandMatch) ?? false)))
            {
                throw ExceptionToThrow ?? new InvalidOperationException("Simulated process execution failure.");
            }
            return _inner.Run(fileName, arguments ?? string.Empty, workingDirectory, timeoutMs);
        }

        public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default) =>
            Task.FromResult(Run(fileName, arguments, workingDirectory, timeoutMs));

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName) => _inner.GetProcessesByName(processName);
        public bool CloseMainWindow(int processId) => _inner.CloseMainWindow(processId);
        public bool WaitForExit(int processId, TimeSpan timeout) => _inner.WaitForExit(processId, timeout);
        public bool KillProcess(int processId, bool entireProcessTree = true) => _inner.KillProcess(processId, entireProcessTree);
        public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true) => _inner.StopProcess(processName, timeoutSeconds, force);
        public bool IsProcessRunning(string processName) => _inner.IsProcessRunning(processName);
    }

    #endregion
}
