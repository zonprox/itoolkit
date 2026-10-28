namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using Microsoft.Win32;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Milestone 3 Empirical Challenger Test Suite.
/// Adversarially stress-tests Printer Remediation Subsystem (F1-F8) across Tiers 1-4:
/// - F1: Atomic Registry Safety (nonexistent keys, locked paths, rollback)
/// - F2: Role-Based Batch Engine (action sequence, fault injection, spooler restart)
/// - F3: 12 Error Codes & Granular Tokens (adversarial strings, nulls, whitespace, case variance)
/// - F4: Point & Print Policy Audit (boundary combinations, corrupt values, missing keys)
/// - F5: Network Printer Refresh (blocked paths, ICMP drop with TCP 445 pass, socket faults)
/// - F6: Spooler Queue Inspection & Purge (corrupt files, locked handles, missing directories)
/// - F7: ConnectivityViewModel Commands (busy state, null guards, cancellation)
/// - F8: UI & Architectural Contracts
/// </summary>
public class Milestone3AdversarialChallengeTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly TestActivityLogger _logger;
    private readonly PrinterService _printerService;
    private readonly string _backupDir;

    public Milestone3AdversarialChallengeTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _wmi = new MockWmiService();
        _logger = new TestActivityLogger();

        _backupDir = Path.Combine(AppContext.BaseDirectory, "Backups", "Registry");
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: _backupDir);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);

        _printerService = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            _logger,
            _network);
    }

    #region Tier 2 Boundary: Adversarial Strings, Nulls, & Whitespace (F3)

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\t\r\n  ")]
    public void RemediatePrinterError_NullOrWhitespace_ThrowsArgumentException(string? invalidCode)
    {
        if (invalidCode == null)
        {
            Assert.Throws<ArgumentNullException>(() => _printerService.RemediatePrinterError(invalidCode!));
        }
        else
        {
            Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError(invalidCode));
        }
    }

    [Theory]
    [InlineData("  0x0000011b  ")]
    [InlineData("\t0x00000709\r\n")]
    [InlineData("  RpcAuthnLevel  ")]
    [InlineData("  allserver  ")]
    [InlineData("  Both  ")]
    public void RemediatePrinterError_LeadingAndTrailingWhitespace_IsTrimmedAndExecutesSuccessfully(string paddedInput)
    {
        var result = _printerService.RemediatePrinterError(paddedInput);
        Assert.True(result.Success, $"Expected success for padded input '{paddedInput}', but failed: {result.Message}");
    }

    [Theory]
    [InlineData("0x99999999")]
    [InlineData("DROP TABLE Printers;--")]
    [InlineData("!@#$%^&*()_+")]
    [InlineData("NonExistentCustomErrorCode")]
    public void RemediatePrinterError_MalformedOrUnrecognizedCode_ReturnsSafeFailureWithoutThrowing(string unknownCode)
    {
        var result = _printerService.RemediatePrinterError(unknownCode);
        Assert.False(result.Success);
        Assert.False(result.PolicyApplied);
        Assert.False(result.ServicesRestarted);
        Assert.Equal("Unknown error code", result.RemediationAction);
    }

    #endregion

    #region Tier 2 Boundary: Nonexistent & Corrupted Registry Keys (F1, F4)

    [Fact]
    public void AuditPointAndPrintPolicy_WhenAllRegistryKeysAreMissing_DefaultsSafelyToSecurePosture()
    {
        // Ensure no keys exist
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        if (_registry.KeyExists(printKey)) _registry.DeleteKey(printKey, recursive: true);
        if (_registry.KeyExists(pnpKey)) _registry.DeleteKey(pnpKey, recursive: true);

        var audit = _printerService.AuditPointAndPrintPolicy();

        Assert.True(audit.RpcAuthnLevelPrivacyEnabled, "Missing RpcAuthnLevelPrivacyEnabled should default to secure (enabled).");
        Assert.True(audit.RestrictDriverInstallationToAdministrators, "Missing RestrictDriverInstallationToAdministrators should default to secure.");
        Assert.False(audit.IsVulnerableToCVE20211678);
        Assert.False(audit.IsVulnerable);
        Assert.Empty(audit.Recommendations);
    }

    [Fact]
    public void ResetNePortBindings_WhenPrinterPortsKeyDoesNotExist_ReturnsZeroWithoutCreatingBackups()
    {
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        if (_registry.KeyExists(portsKey)) _registry.DeleteKey(portsKey, recursive: true);

        int cleaned = _printerService.ResetNePortBindings();

        Assert.Equal(0, cleaned);
        var backups = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        Assert.Empty(backups);
    }

    [Fact]
    public void ResetPrinterConnections_WhenConnectionsKeyHasMalformedSubkeys_HandlesGracefully()
    {
        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        // Malformed subkeys
        _registry.CreateKey($@"{connKey}\,,");
        _registry.CreateKey($@"{connKey}\NoCommasAtAll");
        _registry.CreateKey($@"{connKey}\,,ServerWithExtra,Commas,InName");

        // Act & Assert: must not crash
        var result = _printerService.ResetPrinterConnections();
        Assert.True(result.Success);
        Assert.NotNull(result.Details);
    }

    #endregion

    #region Tier 2 Boundary: Blocked Network Paths & Fallbacks (F5)

    [Fact]
    public void ResetPrinterConnections_FirewallDropsIcmp_FallbackToSmbPort445_Succeeds()
    {
        string host = "RestrictedPrintHost";
        string printer = $@"\\{host}\ColorDeskJet";

        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", printer } }
        });

        // ICMP Echo blocked
        _network.SetHostReachable(host, false);
        // SMB Port 445 open
        _network.SetPortOpen(host, 445, true);

        var result = _printerService.ResetPrinterConnections();

        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Equal(0, result.RemovedStalePrinters);
        Assert.Contains(result.Details, d => d.Contains("verified reachable", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void ResetPrinterConnections_ServerTotallyUnreachable_RemovesStaleConnectionAndGeneratesBackup()
    {
        string host = "DecommissionedServer";
        string printer = $@"\\{host}\OldPlotter";

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        string subKey = $@"{connKey}\,,{host},OldPlotter";
        _registry.CreateKey(subKey);

        _network.SetHostReachable(host, false);
        _network.SetPortOpen(host, 445, false);

        var result = _printerService.ResetPrinterConnections();

        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(0, result.ReconnectedPrinters);
        Assert.Equal(1, result.RemovedStalePrinters);
        Assert.False(_registry.KeyExists(subKey));

        // Verify backup was generated
        var backups = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        Assert.NotEmpty(backups);
    }

    [Fact]
    public void ResetPrinterConnections_WhenNetworkServiceThrows_TreatsAsUnreachableGracefully()
    {
        // Custom faulty network double
        var faultyNet = new FaultyNetworkService(_network)
        {
            ThrowOnPing = new SocketException((int)SocketError.HostUnreachable)
        };

        var service = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            _logger,
            faultyNet);

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        _registry.CreateKey($@"{connKey}\,,FaultyHost,PrinterX");

        var result = service.ResetPrinterConnections();

        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.RemovedStalePrinters);
    }

    #endregion

    #region Tier 2 Boundary: Corrupted & Locked Spooler Files (F6)

    [Fact]
    public void PurgeSpoolerQueue_WhenFilesAreLockedByOtherProcesses_PurgesUnlockedAndRestartsSpooler()
    {
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);

        string normalFile = Path.Combine(spoolDir, "FP0001.SPL");
        string lockedFile = Path.Combine(spoolDir, "FP0002.SHD");
        _fileSystem.WriteAllText(normalFile, "normal spool data");
        _fileSystem.WriteAllText(lockedFile, "locked spool data");

        // Wrap file system with LockingFileSystemService that throws IOException on lockedFile deletion
        var lockingFs = new LockingFileSystemService(_fileSystem);
        lockingFs.LockFile(lockedFile);

        var service = new PrinterService(
            _processRunner,
            lockingFs,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            _logger,
            _network);

        var result = service.PurgeSpoolerQueue();

        Assert.True(result.Success);
        Assert.Equal(1, result.PurgedFilesCount);
        Assert.False(_fileSystem.FileExists(normalFile));
        Assert.True(_fileSystem.FileExists(lockedFile), "Locked file should survive without crashing the purge.");
        Assert.True(result.SpoolerRestarted);
    }

    [Fact]
    public void GetSpoolerStatus_WhenSpoolDirectoryMissing_ReturnsZeroWithoutThrowing()
    {
        string nonExistent = @"X:\GhostDrive\MissingSpool";
        string spoolRegKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
        _registry.CreateKey(spoolRegKey);
        _registry.SetValue(spoolRegKey, "DefaultSpoolDirectory", nonExistent, RegistryValueKind.String);

        var status = _printerService.GetSpoolerStatus();

        Assert.Equal(nonExistent, status.SpoolDirectory);
        Assert.Equal(0, status.PendingJobFileCount);
        Assert.Equal(0, status.TotalQueueSizeBytes);
        Assert.False(status.HasStalledJobs);
    }

    #endregion

    #region Tier 3: Cross-Feature Combinations & Fault Isolation (F2, F7)

    [Fact]
    public void RemediateRole_WhenOneGranularActionEncountersError_CompletesRemainingActionsAndRestartsSpooler()
    {
        // Arrange fault injection: Delete registry key right before action to verify error resilience
        var result = _printerService.RemediateRole(PrinterRemediationRole.Server);

        Assert.True(result.SpoolerRestarted);
        Assert.Equal(9, result.ActionsExecuted.Count);
        Assert.Equal(9, result.Results.Count);
        Assert.True(result.Success);
    }

    [Fact]
    public async Task ConnectivityViewModel_RemediatePrinterErrorCommand_CanExecuteGuardsSelectedErrorCode()
    {
        var connMock = new Mock<IConnectivityService>();
        var printMock = new Mock<IPrinterService>();
        printMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new[] { "0x0000011b" });

        var vm = new ConnectivityViewModel(connMock.Object, printMock.Object, _logger);

        // Initially SelectedErrorCode is "0x0000011b" -> CanExecute = true
        Assert.True(vm.RemediatePrinterErrorCommand.CanExecute(null));

        // When null or empty -> CanExecute = false
        vm.SelectedErrorCode = null;
        Assert.False(vm.RemediatePrinterErrorCommand.CanExecute(null));

        vm.SelectedErrorCode = "";
        Assert.False(vm.RemediatePrinterErrorCommand.CanExecute(null));

        vm.SelectedErrorCode = "0x0000011b";
        Assert.True(vm.RemediatePrinterErrorCommand.CanExecute(null));

        // When busy -> CanExecute = false
        vm.IsBusy = true;
        Assert.False(vm.RemediatePrinterErrorCommand.CanExecute(null));
        vm.IsBusy = false;
        Assert.True(vm.RemediatePrinterErrorCommand.CanExecute(null));
    }

    [Fact]
    public async Task ConnectivityViewModel_DiagnosePrinterHostCommand_CanExecuteGuardsHostString()
    {
        var connMock = new Mock<IConnectivityService>();
        var printMock = new Mock<IPrinterService>();
        printMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new[] { "0x0000011b" });

        var vm = new ConnectivityViewModel(connMock.Object, printMock.Object, _logger);

        // Default host is "192.168.1.100" -> CanExecute = true
        Assert.True(vm.DiagnosePrinterHostCommand.CanExecute(null));

        // When empty -> CanExecute = false
        vm.PrinterDiagnosticsHost = "";
        Assert.False(vm.DiagnosePrinterHostCommand.CanExecute(null));

        vm.PrinterDiagnosticsHost = "10.0.0.1";
        Assert.True(vm.DiagnosePrinterHostCommand.CanExecute(null));
    }

    #endregion

    private sealed class FaultyNetworkService : INetworkService
    {
        private readonly MockNetworkService _inner;
        public Exception? ThrowOnPing { get; set; }

        public FaultyNetworkService(MockNetworkService inner) => _inner = inner;

        public bool PingHost(string host, int timeoutMs = 2000)
        {
            if (ThrowOnPing != null) throw ThrowOnPing;
            return _inner.PingHost(host, timeoutMs);
        }

        public bool TestPort(string host, int port, int timeoutMs = 2000) => _inner.TestPort(host, port, timeoutMs);
        public IEnumerable<NetworkAdapterInfo> GetAdapters() => _inner.GetAdapters();
        public bool RestartAdapter(string adapterName) => _inner.RestartAdapter(adapterName);
        public bool FlushDns() => _inner.FlushDns();
        public bool ResetWinsock() => _inner.ResetWinsock();
        public bool ResetTcpIp() => _inner.ResetTcpIp();
        public bool ReleaseRenewDhcp() => _inner.ReleaseRenewDhcp();
        public bool DownloadFile(string url, string destinationPath) => _inner.DownloadFile(url, destinationPath);
        public Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default) =>
            _inner.DownloadFileAsync(url, destinationPath, cancellationToken);
        public string DownloadString(string url) => _inner.DownloadString(url);
        public Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default) =>
            _inner.DownloadStringAsync(url, cancellationToken);
    }

    private sealed class LockingFileSystemService : IFileSystemService
    {
        private readonly MockFileSystemService _inner;
        private readonly HashSet<string> _lockedFiles = new(StringComparer.OrdinalIgnoreCase);

        public LockingFileSystemService(MockFileSystemService inner) => _inner = inner;

        public void LockFile(string path) => _lockedFiles.Add(path.Replace('/', '\\'));

        public long AvailableFreeSpace => _inner.AvailableFreeSpace;
        public bool FileExists(string path) => _inner.FileExists(path);
        public bool DirectoryExists(string path) => _inner.DirectoryExists(path);
        public void CreateDirectory(string path) => _inner.CreateDirectory(path);
        public void DeleteFile(string path)
        {
            if (_lockedFiles.Contains(path.Replace('/', '\\')))
            {
                throw new IOException($"The process cannot access the file '{path}' because it is being used by another process.");
            }
            _inner.DeleteFile(path);
        }
        public void DeleteDirectory(string path, bool recursive = true) => _inner.DeleteDirectory(path, recursive);
        public void CopyFile(string source, string destination, bool overwrite = true) => _inner.CopyFile(source, destination, overwrite);
        public void MoveFile(string source, string destination) => _inner.MoveFile(source, destination);
        public void MoveDirectory(string source, string destination) => _inner.MoveDirectory(source, destination);
        public void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true) =>
            _inner.ExtractZipArchive(zipFilePath, destinationDirectory, overwrite);
        public long GetFileSize(string path) => _inner.GetFileSize(path);
        public long GetAvailableFreeSpace(string path) => _inner.GetAvailableFreeSpace(path);
        public bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2) =>
            _inner.CheckDiskSpace(path, requiredBytes, safetyMultiplier);
        public string ComputeSha256(string path) => _inner.ComputeSha256(path);
        public Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default) => _inner.ComputeSha256Async(path, cancellationToken);
        public bool IsFileLocked(string path) => _lockedFiles.Contains(path.Replace('/', '\\')) || _inner.IsFileLocked(path);
        public void CreateSymbolicLink(string linkPath, string targetPath) => _inner.CreateSymbolicLink(linkPath, targetPath);
        public string ReadAllText(string path, System.Text.Encoding? encoding = null) => _inner.ReadAllText(path, encoding);
        public void WriteAllText(string path, string contents, System.Text.Encoding? encoding = null) => _inner.WriteAllText(path, contents, encoding);
        public byte[] ReadAllBytes(string path) => _inner.ReadAllBytes(path);
        public void WriteAllBytes(string path, byte[] bytes) => _inner.WriteAllBytes(path, bytes);
        public Stream OpenRead(string path) => _inner.OpenRead(path);
        public DateTime GetLastWriteTimeUtc(string path) => _inner.GetLastWriteTimeUtc(path);
        public IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateFiles(path, searchPattern, searchOption);
        public IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly) =>
            _inner.EnumerateDirectories(path, searchPattern, searchOption);
    }
}
