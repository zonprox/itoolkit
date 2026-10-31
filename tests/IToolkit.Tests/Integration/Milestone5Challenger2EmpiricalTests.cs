namespace IToolkit.Tests.Integration;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
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
using IToolkit.Tests.TestDoubles;
using Moq;
using Xunit;

/// <summary>
/// Milestone 5 Adversarial Challenger 2 Test Suite (Connectivity & Dashboard Domains).
/// Rigorously validates:
/// 1. Per-Adapter configuration vs Global Network Stack Remediation
/// 2. Non-Interference: Adapter A vs Adapter B isolation & concurrency
/// 3. Static IP preservation through global stack remediation
/// 4. Printer queue isolation: Purge Printer A vs Printer B vs Global Spooler Purge
/// 5. Dashboard Telemetry high-frequency concurrent polling & thread-safety
/// 6. Global quick actions isolation from per-entity mutations
/// 7. Boundary, malformed inputs, and fault injection resiliency
/// </summary>
public class Milestone5Challenger2EmpiricalTests
{
    private readonly MockNetworkService _network;
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly MockWmiService _wmi;
    private readonly TestActivityLogger _logger;
    private readonly ConnectivityService _connectivityService;
    private readonly PrinterService _printerService;

    public Milestone5Challenger2EmpiricalTests()
    {
        _network = new MockNetworkService();
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _wmi = new MockWmiService();
        _logger = new TestActivityLogger();

        _connectivityService = new ConnectivityService(
            _network,
            _processRunner,
            _registry,
            _atomicRegistry,
            _logger);

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

    // =========================================================================
    // 1. PER-ADAPTER CONFIG VS GLOBAL NETWORK STACK REMEDIATION
    // =========================================================================

    [Fact]
    public void GlobalNetworkRemediation_DoesNotWipeOrMutateStaticIpOrDnsOnSpecificAdapters()
    {
        // Arrange: Configure Adapter A with static IP, DNS, and custom MTU
        string adapterA = "Ethernet 1 (Corporate)";
        var staticIpConfig = new AdapterIpConfig(
            UseDhcp: false,
            IpAddress: "192.168.10.50",
            SubnetMask: "255.255.255.0",
            DefaultGateway: "192.168.10.1");

        var staticDnsConfig = new AdapterDnsConfig(
            UseDhcp: false,
            PreferredDns: "1.1.1.1",
            AlternateDns: "8.8.8.8");

        const int customMtu = 1420;

        // Configure Adapter B with DHCP
        string adapterB = "Wi-Fi (Guest)";
        var dhcpIpConfig = new AdapterIpConfig(UseDhcp: true);
        var dhcpDnsConfig = new AdapterDnsConfig(UseDhcp: true);

        // Apply per-adapter configurations
        Assert.True(_connectivityService.SetAdapterIpConfiguration(adapterA, staticIpConfig));
        Assert.True(_connectivityService.SetAdapterDnsConfiguration(adapterA, staticDnsConfig));
        Assert.True(_connectivityService.SetAdapterMtu(adapterA, customMtu));

        Assert.True(_connectivityService.SetAdapterIpConfiguration(adapterB, dhcpIpConfig));
        Assert.True(_connectivityService.SetAdapterDnsConfiguration(adapterB, dhcpDnsConfig));

        // Act: Execute Global Network Stack Remediation
        var remediationResult = _connectivityService.RemediateNetworkStack();

        // Assert: Global remediation succeeded
        Assert.True(remediationResult.Success);
        Assert.True(remediationResult.DnsFlushed);
        Assert.True(remediationResult.WinsockReset);
        Assert.True(remediationResult.TcpIpReset);
        Assert.True(remediationResult.ArpCleared);
        Assert.True(remediationResult.ProxyReset);
        Assert.True(remediationResult.RequiresReboot);

        // CRITICAL CONTRACT: Adapter A's static IP and DNS MUST NOT be wiped or reverted to DHCP
        Assert.True(_network.ConfiguredIpAdapters.ContainsKey(adapterA));
        var postRemediationIp = _network.ConfiguredIpAdapters[adapterA];
        Assert.False(postRemediationIp.UseDhcp);
        Assert.Equal("192.168.10.50", postRemediationIp.IpAddress);
        Assert.Equal("255.255.255.0", postRemediationIp.SubnetMask);
        Assert.Equal("192.168.10.1", postRemediationIp.DefaultGateway);

        Assert.True(_network.ConfiguredDnsAdapters.ContainsKey(adapterA));
        var postRemediationDns = _network.ConfiguredDnsAdapters[adapterA];
        Assert.False(postRemediationDns.UseDhcp);
        Assert.Equal("1.1.1.1", postRemediationDns.PreferredDns);
        Assert.Equal("8.8.8.8", postRemediationDns.AlternateDns);

        Assert.True(_network.ConfiguredMtuAdapters.ContainsKey(adapterA));
        Assert.Equal(customMtu, _network.ConfiguredMtuAdapters[adapterA]);

        // Adapter B remains DHCP
        Assert.True(_network.ConfiguredIpAdapters[adapterB].UseDhcp);
        Assert.True(_network.ConfiguredDnsAdapters[adapterB].UseDhcp);

        // Global remediation MUST NOT have called RestartAdapter for any specific adapter
        Assert.Empty(_network.RestartedAdapters);
    }

    [Fact]
    public void PerAdapterOperations_StrictIsolation_AdapterAMutationsDoNotAffectAdapterB()
    {
        string adapterA = "Intel Ethernet Primary";
        string adapterB = "Broadcom Wi-Fi Secondary";
        string adapterC = "VirtualBox Host-Only Network";

        // Step 1: Restart Adapter A only
        Assert.True(_connectivityService.RestartAdapter(adapterA));
        Assert.Contains(adapterA, _network.RestartedAdapters);
        Assert.DoesNotContain(adapterB, _network.RestartedAdapters);
        Assert.DoesNotContain(adapterC, _network.RestartedAdapters);

        // Step 2: Enable Adapter A and Disable Adapter B
        Assert.True(_connectivityService.EnableAdapter(adapterA));
        Assert.True(_connectivityService.DisableAdapter(adapterB));

        Assert.Contains(adapterA, _network.EnabledAdapters);
        Assert.DoesNotContain(adapterB, _network.EnabledAdapters);
        Assert.Contains(adapterB, _network.DisabledAdapters);
        Assert.DoesNotContain(adapterA, _network.DisabledAdapters);

        // Step 3: Configure MTU on Adapter A only
        Assert.True(_connectivityService.SetAdapterMtu(adapterA, 1400));
        Assert.Equal(1400, _network.ConfiguredMtuAdapters[adapterA]);
        Assert.False(_network.ConfiguredMtuAdapters.ContainsKey(adapterB));
        Assert.False(_network.ConfiguredMtuAdapters.ContainsKey(adapterC));

        // Step 4: Renew DHCP on Adapter A only
        Assert.True(_connectivityService.ReleaseRenewAdapterDhcp(adapterA));
        Assert.Contains(adapterA, _network.RenewedDhcpAdapters);
        Assert.DoesNotContain(adapterB, _network.RenewedDhcpAdapters);
    }

    [Fact]
    public void ConcurrentAdapterConfigurations_50ParallelThreads_ExecuteSafelyWithoutCrossAdapterBleed()
    {
        // Arrange: 50 distinct adapters and thread-safe test doubles
        var threadSafeNetwork = new ThreadSafeNetworkDouble();
        var threadSafeRunner = new ThreadSafeProcessRunnerDouble();
        var service = new ConnectivityService(
            threadSafeNetwork,
            threadSafeRunner,
            _registry,
            _atomicRegistry,
            _logger);

        const int adapterCount = 50;
        var adapters = Enumerable.Range(1, adapterCount)
            .Select(i => $"vEthernet_Slot_{i:D2}")
            .ToList();

        var exceptions = new ConcurrentBag<Exception>();

        // Act: Concurrently configure IP, DNS, and MTU on each adapter simultaneously across 50 threads
        Parallel.ForEach(adapters, adapter =>
        {
            try
            {
                int id = int.Parse(adapter.Split('_').Last());
                var ipConfig = new AdapterIpConfig(
                    UseDhcp: false,
                    IpAddress: $"10.0.{id}.100",
                    SubnetMask: "255.255.255.0",
                    DefaultGateway: $"10.0.{id}.1");

                var dnsConfig = new AdapterDnsConfig(
                    UseDhcp: false,
                    PreferredDns: $"10.0.{id}.254",
                    AlternateDns: "1.1.1.1");

                int mtu = 1400 + id;

                bool ipOk = service.SetAdapterIpConfiguration(adapter, ipConfig);
                bool dnsOk = service.SetAdapterDnsConfiguration(adapter, dnsConfig);
                bool mtuOk = service.SetAdapterMtu(adapter, mtu);

                if (!ipOk || !dnsOk || !mtuOk)
                {
                    exceptions.Add(new InvalidOperationException($"Configuration failed for adapter {adapter}"));
                }
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        });

        // Assert: Zero exceptions and all 50 configurations cleanly mapped without bleed
        Assert.Empty(exceptions);
        Assert.Equal(adapterCount, threadSafeNetwork.ConfiguredIpAdapters.Count);
        Assert.Equal(adapterCount, threadSafeNetwork.ConfiguredDnsAdapters.Count);
        Assert.Equal(adapterCount, threadSafeNetwork.ConfiguredMtuAdapters.Count);

        foreach (var adapter in adapters)
        {
            int id = int.Parse(adapter.Split('_').Last());
            Assert.Equal($"10.0.{id}.100", threadSafeNetwork.ConfiguredIpAdapters[adapter].IpAddress);
            Assert.Equal($"10.0.{id}.254", threadSafeNetwork.ConfiguredDnsAdapters[adapter].PreferredDns);
            Assert.Equal(1400 + id, threadSafeNetwork.ConfiguredMtuAdapters[adapter]);
        }
    }

    private sealed class ThreadSafeNetworkDouble : INetworkService
    {
        public ConcurrentDictionary<string, AdapterIpConfig> ConfiguredIpAdapters { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, AdapterDnsConfig> ConfiguredDnsAdapters { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentDictionary<string, int> ConfiguredMtuAdapters { get; } = new(StringComparer.OrdinalIgnoreCase);
        public ConcurrentBag<string> RestartedAdapters { get; } = new();

        public bool SetAdapterIpConfiguration(string adapterName, AdapterIpConfig config)
        {
            ConfiguredIpAdapters[adapterName] = config;
            return true;
        }

        public bool SetAdapterDnsConfiguration(string adapterName, AdapterDnsConfig config)
        {
            ConfiguredDnsAdapters[adapterName] = config;
            return true;
        }

        public bool SetAdapterMtu(string adapterName, int mtu)
        {
            ConfiguredMtuAdapters[adapterName] = mtu;
            return true;
        }

        public bool RestartAdapter(string adapterName)
        {
            RestartedAdapters.Add(adapterName);
            return true;
        }

        public bool PingHost(string host, int timeoutMs = 2000) => true;
        public bool TestPort(string host, int port, int timeoutMs = 2000) => true;
        public IEnumerable<NetworkAdapterInfo> GetAdapters() => Enumerable.Empty<NetworkAdapterInfo>();
        public bool FlushDns() => true;
        public bool ResetWinsock() => true;
        public bool ResetTcpIp() => true;
        public bool ReleaseRenewDhcp() => true;
        public bool DownloadFile(string url, string destinationPath) => true;
        public Task<bool> DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken = default) => Task.FromResult(true);
        public string DownloadString(string url) => string.Empty;
        public Task<string> DownloadStringAsync(string url, CancellationToken cancellationToken = default) => Task.FromResult(string.Empty);
    }

    private sealed class ThreadSafeProcessRunnerDouble : IProcessRunner
    {
        private readonly MockProcessRunner _inner = new();
        private readonly object _lock = new();

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000)
        {
            lock (_lock)
            {
                return _inner.Run(fileName, arguments, workingDirectory, timeoutMs);
            }
        }

        public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default)
        {
            lock (_lock)
            {
                return _inner.RunAsync(fileName, arguments, workingDirectory, timeoutMs, cancellationToken);
            }
        }

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName)
        {
            lock (_lock)
            {
                return _inner.GetProcessesByName(processName);
            }
        }

        public bool CloseMainWindow(int processId) => true;
        public bool WaitForExit(int processId, TimeSpan timeout) => true;
        public bool KillProcess(int processId, bool entireProcessTree = true) => true;
        public bool StopProcess(string processName, int timeoutSeconds = 5, bool forceKill = true) => true;
        public bool IsProcessRunning(string processName) => false;
        public bool StartProcess(string fileName, string? arguments = null) => true;
    }

    // =========================================================================
    // 2. PRINTER ISOLATION & GLOBAL SPOOLER PURGE VS PER-PRINTER QUEUE PURGE
    // =========================================================================

    [Fact]
    public void GlobalSpoolerPurge_IsDistinctFromPerPrinterQueuePurge()
    {
        // Arrange spool directory with pending global print spool files
        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string spoolDir = Path.Combine(systemRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);
        string file1 = Path.Combine(spoolDir, "FP00010.SHD");
        string file2 = Path.Combine(spoolDir, "FP00010.SPL");
        string file3 = Path.Combine(spoolDir, "FP00011.TMP");
        _fileSystem.WriteAllText(file1, "Job 10 shadow");
        _fileSystem.WriteAllText(file2, "Job 10 spool");
        _fileSystem.WriteAllText(file3, "Job 11 temp");

        // Act 1: Per-Printer queue purge for "Office Canon"
        bool perPrinterResult = _printerService.PurgePrinterQueue("Office Canon");

        // Assert 1: Per-printer purge MUST NOT stop the spooler service or wipe system spool files
        Assert.True(perPrinterResult);
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains("net stop spooler /y"));
        Assert.True(_fileSystem.FileExists(file1), "Per-printer queue purge must not delete global spooler SHD files.");
        Assert.True(_fileSystem.FileExists(file2), "Per-printer queue purge must not delete global spooler SPL files.");
        Assert.True(_fileSystem.FileExists(file3), "Per-printer queue purge must not delete global spooler TMP files.");

        // Act 2: Global Spooler Queue Purge
        var globalResult = _printerService.PurgeSpoolerQueue();

        // Assert 2: Global spooler purge stops the service, deletes files, and restarts spooler
        Assert.True(globalResult.Success);
        Assert.True(globalResult.SpoolerStopped);
        Assert.True(globalResult.SpoolerRestarted);
        Assert.Equal(3, globalResult.PurgedFilesCount);
        Assert.False(_fileSystem.FileExists(file1));
        Assert.False(_fileSystem.FileExists(file2));
        Assert.False(_fileSystem.FileExists(file3));

        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net stop spooler /y"));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void PrinterIsolation_GetPrinterJobs_QueriesTargetPrinterOnly()
    {
        // Arrange: Populate WMI with jobs for two distinct printers
        string queryA = "SELECT JobId, Document, Owner, Size, Status, TimeSubmitted FROM Win32_PrintJob WHERE Name LIKE 'Canon C5535i%'";
        string queryB = "SELECT JobId, Document, Owner, Size, Status, TimeSubmitted FROM Win32_PrintJob WHERE Name LIKE 'HP LaserJet M605%'";

        var jobsA = new List<IDictionary<string, object?>>
        {
            new Dictionary<string, object?>
            {
                ["JobId"] = 101,
                ["Document"] = "Financial_Q3.pdf",
                ["Owner"] = "CFO",
                ["Size"] = 5242880L,
                ["Status"] = "Printing"
            },
            new Dictionary<string, object?>
            {
                ["JobId"] = 102,
                ["Document"] = "Payroll.xlsx",
                ["Owner"] = "HR",
                ["Size"] = 1048576L,
                ["Status"] = "Spooling"
            }
        };

        var jobsB = new List<IDictionary<string, object?>>
        {
            new Dictionary<string, object?>
            {
                ["JobId"] = 201,
                ["Document"] = "Shipping_Labels.zpl",
                ["Owner"] = "Warehouse",
                ["Size"] = 65536L,
                ["Status"] = "Paused"
            }
        };

        _wmi.SetQueryResult(queryA, jobsA);
        _wmi.SetQueryResult(queryB, jobsB);

        // Act
        var resultA = _printerService.GetPrinterJobs("Canon C5535i").ToList();
        var resultB = _printerService.GetPrinterJobs("HP LaserJet M605").ToList();

        // Assert: Jobs are strictly isolated per printer
        Assert.Equal(2, resultA.Count);
        Assert.Equal("Financial_Q3.pdf", resultA[0].DocumentName);
        Assert.Equal("CFO", resultA[0].Owner);
        Assert.Equal("Payroll.xlsx", resultA[1].DocumentName);

        Assert.Single(resultB);
        Assert.Equal("Shipping_Labels.zpl", resultB[0].DocumentName);
        Assert.Equal("Warehouse", resultB[0].Owner);

        // Verify queries executed had proper target filtering
        Assert.Contains(_wmi.ExecutedQueries, q => q.Contains("Canon C5535i"));
        Assert.Contains(_wmi.ExecutedQueries, q => q.Contains("HP LaserJet M605"));
    }

    // =========================================================================
    // 3. SYSTEM DASHBOARD & TELEMETRY CONCURRENCY & THREAD-SAFETY
    // =========================================================================

    [Fact]
    public async Task TelemetryService_HighConcurrencyStress_50ConcurrentTasks_ZeroDeadlocksOrExceptions()
    {
        // Arrange
        var elevationMock = new Mock<IElevationService>();
        elevationMock.Setup(e => e.IsElevated()).Returns(true);

        var fileSystemMock = new Mock<IFileSystemService>();
        fileSystemMock.Setup(f => f.GetAvailableFreeSpace(It.IsAny<string>()))
            .Returns(500L * 1024 * 1024 * 1024);

        var telemetryService = new WindowsTelemetryService(
            elevationMock.Object,
            fileSystemMock.Object,
            _wmi,
            _registry);

        const int taskCount = 50;
        var exceptions = new ConcurrentBag<Exception>();
        var snapshots = new ConcurrentBag<TelemetrySnapshot>();

        // Act: 50 concurrent tasks invoking synchronous GetSnapshot and asynchronous GetSnapshotAsync
        var tasks = Enumerable.Range(0, taskCount).Select(i => Task.Run(async () =>
        {
            try
            {
                if (i % 2 == 0)
                {
                    var snap = telemetryService.GetSnapshot();
                    snapshots.Add(snap);
                }
                else
                {
                    var snap = await telemetryService.GetSnapshotAsync();
                    snapshots.Add(snap);
                }
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        // Assert
        Assert.Empty(exceptions);
        Assert.Equal(taskCount, snapshots.Count);

        foreach (var snap in snapshots)
        {
            Assert.NotNull(snap);
            Assert.True(snap.IsElevated);
            Assert.False(string.IsNullOrEmpty(snap.ComputerName));
            Assert.True(snap.SystemDriveFreeBytes >= 0);
            Assert.True(snap.MemoryTotalBytes > 0);
        }
    }

    [Fact]
    public async Task DashboardViewModel_ConcurrentPollingAndQuickActions_PreservesThreadSafetyAndEntityIsolation()
    {
        // Arrange
        var healthMock = new Mock<ISystemHealthService>();
        var officeMock = new Mock<IOfficeSuiteService>();
        var outlookMock = new Mock<IOutlookService>();
        var connMock = new Mock<IConnectivityService>();
        var backupMock = new Mock<IBackupService>();
        var optMock = new Mock<IOptimizationService>();
        var telemetryMock = new Mock<ISystemTelemetryService>();

        healthMock.Setup(h => h.RunDismSfcPipeline(null, false))
            .Returns((DismScanResult.Successful("Healthy"), SfcScanResult.Clean("Clean")));

        outlookMock.Setup(o => o.RepairGlobalMailSettings())
            .Returns(OperationResult.Succeeded("Repaired"));

        connMock.Setup(c => c.RemediateNetworkStack())
            .Returns(new NetworkRemediationResult(true, true, true, true, true, true, true, true, false, "Ready"));

        healthMock.Setup(h => h.RunUnifiedDiskCleanup(It.IsAny<int>()))
            .Returns(new StorageCleanupResult(true, 100L * 1024 * 1024, 5, 0, Array.Empty<string>(), Array.Empty<string>()));

        optMock.Setup(o => o.UpdateAllPackages())
            .Returns(new ProcessExecutionResult(0, "OK", "", false));

        backupMock.Setup(b => b.GetUserProfileMap(It.IsAny<string?>()))
            .Returns(new UserProfileMap("user", @"C:\Users\user", @"C:\Users\user\Desktop", @"C:\Users\user\Documents", @"C:\Users\user\Downloads", @"C:\Users\user\Favorites", @"C:\Users\user\Pictures", false));
        backupMock.Setup(b => b.RunRobocopySync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<bool>()))
            .Returns(new RobocopySyncResult(@"C:\Users\user", @"D:\UserBackups\user", 0, true, "OK"));

        var sampleSnapshot = new TelemetrySnapshot(
            OsDescription: "Windows 11 Pro",
            OsBuild: "26100",
            IsElevated: true,
            CpuUsagePercentage: 25.0,
            MemoryUsedBytes: 8L * 1024 * 1024 * 1024,
            MemoryTotalBytes: 16L * 1024 * 1024 * 1024,
            SystemDriveFreeBytes: 100L * 1024 * 1024 * 1024,
            SystemDriveTotalBytes: 500L * 1024 * 1024 * 1024,
            NetworkConnected: true,
            ActiveTaskDescription: "Idle");

        telemetryMock.Setup(t => t.GetSnapshotAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(sampleSnapshot);

        using var vm = new DashboardViewModel(
            healthMock.Object,
            officeMock.Object,
            outlookMock.Object,
            connMock.Object,
            backupMock.Object,
            optMock.Object,
            telemetryMock.Object,
            _logger);

        // Start fast background polling (every 10ms)
        vm.StartPolling(10);

        // Act: 30 parallel tasks firing telemetry refresh and quick actions concurrently
        var exceptions = new ConcurrentBag<Exception>();
        var actions = new Func<Task>[]
        {
            () => vm.RefreshTelemetryCommand.ExecuteAsync(null),
            () => vm.QuickSystemRepairCommand.ExecuteAsync(null),
            () => vm.QuickMailRepairCommand.ExecuteAsync(null),
            () => vm.QuickNetworkResetCommand.ExecuteAsync(null),
            () => vm.QuickDiskCleanupCommand.ExecuteAsync(null),
            () => vm.QuickSoftwareUpgradeCommand.ExecuteAsync(null),
            () => vm.QuickProfileBackupCommand.ExecuteAsync(null)
        };

        var tasks = Enumerable.Range(0, 35).Select(i => Task.Run(async () =>
        {
            try
            {
                await actions[i % actions.Length]();
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        // Assert: Zero unhandled concurrency exceptions
        Assert.Empty(exceptions);

        // CONTRACT VERIFICATION: Parameterless quick actions did NOT trigger any per-entity mutations
        connMock.Verify(c => c.RestartAdapter(It.IsAny<string>()), Times.Never);
        connMock.Verify(c => c.SetAdapterIpConfiguration(It.IsAny<string>(), It.IsAny<AdapterIpConfig>()), Times.Never);
        connMock.Verify(c => c.SetAdapterDnsConfiguration(It.IsAny<string>(), It.IsAny<AdapterDnsConfig>()), Times.Never);
        connMock.Verify(c => c.SetAdapterMtu(It.IsAny<string>(), It.IsAny<int>()), Times.Never);

        outlookMock.Verify(o => o.QuickMailAndCacheRepair(It.IsAny<string>()), Times.Never);
        outlookMock.Verify(o => o.RelocateDataFile(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        outlookMock.Verify(o => o.CompactDataFile(It.IsAny<string>()), Times.Never);

        // Telemetry properties stay within valid, stable ranges
        Assert.Equal(25.0, vm.CpuUsagePercentage);
        Assert.Equal(50.0, vm.MemoryPercentage);
        Assert.Equal("25%", vm.CpuUsageText);
        Assert.Equal("50%", vm.MemoryPercentageText);
        Assert.True(vm.IsNotBusy);
    }

    // =========================================================================
    // 4. BOUNDARY, MALFORMED INPUTS, AND FAULT INJECTION RESILIENCY
    // =========================================================================

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void PerAdapterMethods_NullOrWhitespaceAdapterName_ReturnsFalseGracefully(string? invalidName)
    {
        var dummyIp = new AdapterIpConfig(true);
        var dummyDns = new AdapterDnsConfig(true);

        Assert.False(_connectivityService.RestartAdapter(invalidName!));
        Assert.False(_connectivityService.EnableAdapter(invalidName!));
        Assert.False(_connectivityService.DisableAdapter(invalidName!));
        Assert.False(_connectivityService.ReleaseRenewAdapterDhcp(invalidName!));
        Assert.False(_connectivityService.SetAdapterIpConfiguration(invalidName!, dummyIp));
        Assert.False(_connectivityService.SetAdapterDnsConfiguration(invalidName!, dummyDns));
        Assert.False(_connectivityService.SetAdapterMtu(invalidName!, 1500));
    }

    [Theory]
    [InlineData(-100)]
    [InlineData(0)]
    [InlineData(575)]  // Below IPv4 standard minimum MTU of 576
    [InlineData(9001)] // Above jumbo frame max of 9000
    [InlineData(65535)]
    public void SetAdapterMtu_ExtremeInvalidMtuValues_ReturnsFalseWithoutThrowing(int invalidMtu)
    {
        bool result = _connectivityService.SetAdapterMtu("Ethernet 1", invalidMtu);
        Assert.False(result);
        Assert.False(_network.ConfiguredMtuAdapters.ContainsKey("Ethernet 1"));
    }

    [Theory]
    [InlineData(576)]   // Minimum valid IPv4 MTU
    [InlineData(1492)]  // Standard PPPoE MTU
    [InlineData(1500)]  // Standard Ethernet MTU
    [InlineData(9000)]  // Jumbo frame MTU
    public void SetAdapterMtu_ValidBoundaryValues_Succeeds(int validMtu)
    {
        bool result = _connectivityService.SetAdapterMtu("Ethernet 1", validMtu);
        Assert.True(result);
        Assert.Equal(validMtu, _network.ConfiguredMtuAdapters["Ethernet 1"]);
    }

    [Fact]
    public void SetAdapterIpConfiguration_MissingIpOrMaskWhenStatic_ReturnsFalseSafely()
    {
        var missingIp = new AdapterIpConfig(false, IpAddress: null, SubnetMask: "255.255.255.0");
        var missingMask = new AdapterIpConfig(false, IpAddress: "192.168.1.50", SubnetMask: "");

        Assert.False(_connectivityService.SetAdapterIpConfiguration("Ethernet 1", missingIp));
        Assert.False(_connectivityService.SetAdapterIpConfiguration("Ethernet 1", missingMask));
        Assert.False(_network.ConfiguredIpAdapters.ContainsKey("Ethernet 1"));
    }

    [Fact]
    public void SetAdapterDnsConfiguration_MissingPreferredDnsWhenStatic_ReturnsFalseSafely()
    {
        var missingDns = new AdapterDnsConfig(false, PreferredDns: null);
        var whitespaceDns = new AdapterDnsConfig(false, PreferredDns: "   ");

        Assert.False(_connectivityService.SetAdapterDnsConfiguration("Ethernet 1", missingDns));
        Assert.False(_connectivityService.SetAdapterDnsConfiguration("Ethernet 1", whitespaceDns));
        Assert.False(_network.ConfiguredDnsAdapters.ContainsKey("Ethernet 1"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void PerPrinterMethods_NullOrWhitespacePrinterName_ReturnsSafeDefaultsWithoutThrowing(string? invalidPrinter)
    {
        Assert.False(_printerService.PurgePrinterQueue(invalidPrinter!));
        Assert.False(_printerService.PrintTestPage(invalidPrinter!));
        Assert.False(_printerService.SetDefaultPrinter(invalidPrinter!));
        Assert.Empty(_printerService.GetPrinterJobs(invalidPrinter!));
    }
}
