namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge and adversarial verification tests for Milestone 1:
/// PrinterService Diagnostics and Network Connection Reset.
/// Covers:
/// 1. ResetPrinterConnections (mixed UNC reachability, Ping vs TCP 445 fallback, null INetworkService, pre-deletion registry backup).
/// 2. AuditPointAndPrintPolicy (permutations of RpcAuthnLevelPrivacyEnabled & RestrictDriverInstallationToAdministrators, CVE-2021-1678 detection).
/// 3. GetSpoolerStatus (queue file counting .spl/.shd/.tmp, default vs registry spool directory resolution, non-existent directory).
/// </summary>
public class PrinterDiagnosticsEmpiricalChallengeTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly MockWmiService _wmi;
    private readonly MockNetworkService _network;
    private readonly PrinterService _printerService;

    public PrinterDiagnosticsEmpiricalChallengeTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _atomicRegistry = new AtomicRegistryService(_registry, _fileSystem);
        _lockGuard = new ProcessLockGuard(_processRunner, _fileSystem);
        _wmi = new MockWmiService();
        _network = new MockNetworkService(_fileSystem);

        _printerService = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            network: _network);
    }

    #region 1. ResetPrinterConnections Challenges

    [Fact]
    public void ResetPrinterConnections_MixedUncPrinters_DifferentiatesReachableAndUnreachableAccurately()
    {
        // Arrange
        // Mixed sources: WMI and HKCU\Printers\Connections
        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", @"\\OnlineHost1\LaserJetPro" } },
            new Dictionary<string, object?> { { "Name", @"\\OfflineHost1\OldPlotter" } },
            new Dictionary<string, object?> { { "Name", "Local PDF Printer" } } // Local printer - ignored by WMI UNC filter
        });

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        _registry.CreateKey($@"{connKey}\,,OnlineHost2,OfficeColor");
        _registry.CreateKey($@"{connKey}\,,OfflineHost2,WarehouseDotMatrix");
        _registry.CreateKey($@"{connKey}\,,SmbFallbackHost,FinanceCopier");

        // Network reachability setup:
        // OnlineHost1: Ping = true
        _network.SetHostReachable("OnlineHost1", true);

        // OnlineHost2: Ping = true
        _network.SetHostReachable("OnlineHost2", true);

        // SmbFallbackHost: Ping = false, but TCP 445 = true (fallback succeeds)
        _network.SetHostReachable("SmbFallbackHost", false);
        _network.SetPortOpen("SmbFallbackHost", 445, true);

        // OfflineHost1: Ping = false, TCP 445 = false (stale)
        _network.SetHostReachable("OfflineHost1", false);
        _network.SetPortOpen("OfflineHost1", 445, false);

        // OfflineHost2: Ping = false, TCP 445 = false (stale)
        _network.SetHostReachable("OfflineHost2", false);
        _network.SetPortOpen("OfflineHost2", 445, false);

        // Act
        var result = _printerService.ResetPrinterConnections();

        // Assert
        Assert.True(result.Success);
        // Total discovered: 5 unique UNC printers
        // (OnlineHost1\LaserJetPro, OfflineHost1\OldPlotter, OnlineHost2\OfficeColor, OfflineHost2\WarehouseDotMatrix, SmbFallbackHost\FinanceCopier)
        Assert.Equal(5, result.DiscoveredPrinters);
        Assert.Equal(3, result.ReconnectedPrinters); // OnlineHost1, OnlineHost2, SmbFallbackHost
        Assert.Equal(2, result.RemovedStalePrinters); // OfflineHost1, OfflineHost2

        // Verify active printers were re-added via printui /in
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /in /n \"\\\\OnlineHost1\\LaserJetPro\""));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /in /n \"\\\\OnlineHost2\\OfficeColor\""));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /in /n \"\\\\SmbFallbackHost\\FinanceCopier\""));

        // Verify stale printers were deleted via printui /dn
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /dn /n \"\\\\OfflineHost1\\OldPlotter\""));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("printui.dll,PrintUIEntry /dn /n \"\\\\OfflineHost2\\WarehouseDotMatrix\""));

        // Verify registry subkeys for stale printers were purged
        Assert.False(_registry.KeyExists($@"{connKey}\,,OfflineHost1,OldPlotter"));
        Assert.False(_registry.KeyExists($@"{connKey}\,,OfflineHost2,WarehouseDotMatrix"));

        // Verify registry subkeys for active printers remain intact
        Assert.True(_registry.KeyExists($@"{connKey}\,,OnlineHost2,OfficeColor"));
        Assert.True(_registry.KeyExists($@"{connKey}\,,SmbFallbackHost,FinanceCopier"));

        // Verify Print Spooler restart command was executed
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains("net start spooler"));
    }

    [Fact]
    public void ResetPrinterConnections_PingFails_TcpPort445Succeeds_EvaluatesReachableViaFallback()
    {
        // Arrange: ICMP Echo is blocked by corporate firewall, but SMB TCP 445 is listening
        string host = "FirewalledPrintServer01";
        string printer = $@"\\{host}\SecureCheckPrinter";

        _network.SetHostReachable(host, false);
        _network.SetPortOpen(host, 445, true);

        // Act
        var result = _printerService.ResetPrinterConnections(all: false, printerName: printer);

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Equal(0, result.RemovedStalePrinters);
        Assert.Contains(result.Details, d => d.Contains("verified reachable", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(_processRunner.ExecutedCommands, c => c.Contains($"/in /n \"{printer}\""));
        Assert.DoesNotContain(_processRunner.ExecutedCommands, c => c.Contains($"/dn /n \"{printer}\""));
    }

    [Fact]
    public void ResetPrinterConnections_WhenNetworkServiceIsNull_GracefullyPreservesAllConnections()
    {
        // Arrange: PrinterService instantiated without INetworkService
        var serviceWithoutNetwork = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            _wmi,
            network: null);

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        _registry.CreateKey($@"{connKey}\,,RemoteSrv1,PrinterAlpha");
        _registry.CreateKey($@"{connKey}\,,RemoteSrv2,PrinterBeta");

        // Act
        var result = serviceWithoutNetwork.ResetPrinterConnections();

        // Assert: Non-destructive fallback ensures no legitimate printer is deleted when network stack diagnostics are unavailable
        Assert.True(result.Success);
        Assert.Equal(2, result.DiscoveredPrinters);
        Assert.Equal(2, result.ReconnectedPrinters);
        Assert.Equal(0, result.RemovedStalePrinters);
        Assert.True(_registry.KeyExists($@"{connKey}\,,RemoteSrv1,PrinterAlpha"));
        Assert.True(_registry.KeyExists($@"{connKey}\,,RemoteSrv2,PrinterBeta"));
    }

    [Fact]
    public void ResetPrinterConnections_StalePrinterKeysInConnections_AreBackedUpBeforeRemoval()
    {
        // Arrange
        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        string staleSubKey = $@"{connKey}\,,DecommissionedHost,AccountingOld";
        _registry.CreateKey(staleSubKey);
        _registry.SetValue(staleSubKey, "Server", @"\\DecommissionedHost", RegistryValueKind.String);
        _registry.SetValue(staleSubKey, "Provider", "winspool", RegistryValueKind.String);

        _network.SetHostReachable("DecommissionedHost", false);
        _network.SetPortOpen("DecommissionedHost", 445, false);

        // Act
        var result = _printerService.ResetPrinterConnections();

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(0, result.ReconnectedPrinters);
        Assert.Equal(1, result.RemovedStalePrinters);
        Assert.False(_registry.KeyExists(staleSubKey), "Stale subkey must be removed from registry.");

        // Empirically verify that pre-mutation .reg backup exists in Backups/Registry
        string backupDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Backups", "Registry");
        var backupFiles = _fileSystem.EnumerateFiles(backupDir, "*.reg", SearchOption.AllDirectories).ToList();

        Assert.NotEmpty(backupFiles);
        var connBackup = backupFiles.FirstOrDefault(f => f.Contains("Printers_Connections", StringComparison.OrdinalIgnoreCase) ||
                                                         f.Contains("Connections", StringComparison.OrdinalIgnoreCase));
        Assert.NotNull(connBackup);

        // Read backup content and verify it recorded the pre-mutation state
        string backupContent = _fileSystem.ReadAllText(connBackup, System.Text.Encoding.Unicode);
        Assert.Contains("Windows Registry Editor Version 5.00", backupContent);

        // Verify reversible rollback: restoring from backup restores the deleted key!
        bool restored = _atomicRegistry.Rollback(connBackup);
        Assert.True(restored, "Atomic rollback from backup must succeed.");
        Assert.True(_registry.KeyExists(staleSubKey), "Rollback must restore the removed stale printer connection key!");
    }

    [Fact]
    public void ResetPrinterConnections_SingleNamedPrinter_TargetsOnlySpecifiedPrinter()
    {
        // Arrange
        _network.SetHostReachable("TargetServer", true);
        _network.SetHostReachable("OtherServer", false);

        string connKey = @"HKCU\Printers\Connections";
        _registry.CreateKey(connKey);
        _registry.CreateKey($@"{connKey}\,,OtherServer,DoNotTouch");

        // Act: Target single printer explicitly
        var result = _printerService.ResetPrinterConnections(all: false, printerName: @"\\TargetServer\SpecificPrinter");

        // Assert
        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Equal(0, result.RemovedStalePrinters);

        // Ensure untargeted printer in registry was never touched
        Assert.True(_registry.KeyExists($@"{connKey}\,,OtherServer,DoNotTouch"));
    }

    #endregion

    #region 2. AuditPointAndPrintPolicy Challenges

    [Theory]
    // Permutation 1: Both disabled -> Highly vulnerable to CVE-2021-1678 and non-admin driver installation
    [InlineData(0, 0, true, false, false, true)]
    // Permutation 2: RPC authn disabled, but Admin restriction enabled -> Still vulnerable to CVE-2021-1678
    [InlineData(0, 1, true, true, false, true)]
    // Permutation 3: RPC authn enabled, but Admin restriction disabled -> Vulnerable to non-admin driver install, safe from CVE-2021-1678
    [InlineData(1, 0, true, false, true, false)]
    // Permutation 4: Both enabled -> Fully Secure
    [InlineData(1, 1, false, true, true, false)]
    public void AuditPointAndPrintPolicy_AllPermutationsOfRpcAuthnAndRestrictAdmin_AuditedCorrectly(
        int rpcAuthVal,
        int restrictAdminVal,
        bool expectVulnerableOverall,
        bool expectRestrictAdmin,
        bool expectRpcAuthn,
        bool expectCVE20211678)
    {
        // Arrange
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printKey);
        _registry.SetValue(printKey, "RpcAuthnLevelPrivacyEnabled", rpcAuthVal, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", restrictAdminVal, RegistryValueKind.DWord);

        // Act
        var audit = _printerService.AuditPointAndPrintPolicy();

        // Assert
        Assert.Equal(expectRpcAuthn, audit.RpcAuthnLevelPrivacyEnabled);
        Assert.Equal(expectRestrictAdmin, audit.RestrictDriverInstallationToAdministrators);
        Assert.Equal(expectCVE20211678, audit.IsVulnerableToCVE20211678);
        Assert.Equal(expectVulnerableOverall, audit.IsVulnerable);

        if (expectVulnerableOverall)
        {
            Assert.Contains("Vulnerable", audit.PostureDescription, StringComparison.OrdinalIgnoreCase);
            Assert.NotEmpty(audit.Recommendations);
        }
        else
        {
            Assert.Contains("Secure", audit.PostureDescription, StringComparison.OrdinalIgnoreCase);
            Assert.Empty(audit.Recommendations);
        }

        if (expectCVE20211678)
        {
            Assert.Contains(audit.Recommendations, r => r.Contains("CVE-2021-1678", StringComparison.OrdinalIgnoreCase));
        }
        else
        {
            Assert.DoesNotContain(audit.Recommendations, r => r.Contains("CVE-2021-1678", StringComparison.OrdinalIgnoreCase));
        }
    }

    [Fact]
    public void AuditPointAndPrintPolicy_MissingRegistryKeys_DefaultsToSecurePosture()
    {
        // Arrange: Clean registry without any Point & Print or RPC privacy policy overrides
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.DeleteKey(printKey, recursive: true);
        _registry.DeleteKey(pnpKey, recursive: true);

        // Act
        var audit = _printerService.AuditPointAndPrintPolicy();

        // Assert: Secure-by-default behavior
        Assert.True(audit.RpcAuthnLevelPrivacyEnabled);
        Assert.True(audit.RestrictDriverInstallationToAdministrators);
        Assert.False(audit.NoWarningNoElevationOnInstall);
        Assert.Equal(0, audit.UpdatePromptSettings);
        Assert.False(audit.IsVulnerableToCVE20211678);
        Assert.False(audit.IsVulnerable);
        Assert.Contains("Secure", audit.PostureDescription, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(audit.Recommendations);
    }

    [Fact]
    public void AuditPointAndPrintPolicy_ElevationAndWarningSuppression_SurfacesInRecommendations()
    {
        // Arrange
        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "NoWarningNoElevationOnInstall", 1, RegistryValueKind.DWord);
        _registry.SetValue(pnpKey, "UpdatePromptSettings", 2, RegistryValueKind.DWord);

        // Act
        var audit = _printerService.AuditPointAndPrintPolicy();

        // Assert
        Assert.True(audit.NoWarningNoElevationOnInstall);
        Assert.Equal(2, audit.UpdatePromptSettings);
        Assert.Contains(audit.Recommendations, r => r.Contains("NoWarningNoElevationOnInstall", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void AuditPointAndPrintPolicy_NonZeroValuesGreaterThanOne_TreatedAsEnabled()
    {
        // Arrange: In Windows, any non-zero DWORD represents enabled/true
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printKey);
        _registry.SetValue(printKey, "RpcAuthnLevelPrivacyEnabled", 2, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 5, RegistryValueKind.DWord);

        // Act
        var audit = _printerService.AuditPointAndPrintPolicy();

        // Assert
        Assert.True(audit.RpcAuthnLevelPrivacyEnabled);
        Assert.True(audit.RestrictDriverInstallationToAdministrators);
        Assert.False(audit.IsVulnerableToCVE20211678);
        Assert.False(audit.IsVulnerable);
    }

    #endregion

    #region 3. GetSpoolerStatus Challenges

    [Fact]
    public void GetSpoolerStatus_EmptyDirectory_ReturnsZeroPendingJobsAndFalseHasStalledJobs()
    {
        // Arrange
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);

        // Act
        var status = _printerService.GetSpoolerStatus();

        // Assert
        Assert.Equal(0, status.PendingJobFileCount);
        Assert.Equal(0, status.TotalQueueSizeBytes);
        Assert.False(status.HasStalledJobs);
        Assert.Equal(0, status.QueueFileCount);
        Assert.Equal(0, status.QueueSizeBytes);
        Assert.Equal(spoolDir, status.SpoolDirectory);
    }

    [Fact]
    public void GetSpoolerStatus_DirectoryWithSplShdTmpAndIgnoredFiles_AccuratelyCalculatesCountsAndBytes()
    {
        // Arrange
        string sysRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        string spoolDir = Path.Combine(sysRoot, "System32", "spool", "PRINTERS");
        _fileSystem.CreateDirectory(spoolDir);

        // Target files: .spl, .shd, .tmp
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "FP00001.SPL"), new byte[50000]);
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "FP00001.SHD"), new byte[2500]);
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "spool_hang.tmp"), new byte[1500]);

        // Ignored files: .txt, .dll, .log
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "readme.txt"), new byte[400]);
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "prnres.dll"), new byte[120000]);
        _fileSystem.WriteAllBytes(Path.Combine(spoolDir, "spool.log"), new byte[1000]);

        // Act
        var status = _printerService.GetSpoolerStatus();

        // Assert
        Assert.Equal(3, status.PendingJobFileCount);
        Assert.Equal(54000, status.TotalQueueSizeBytes); // 50000 + 2500 + 1500
        Assert.True(status.HasStalledJobs);
    }

    [Fact]
    public void GetSpoolerStatus_RegistryConfiguredSpoolDirectory_OverridesDefaultLocation()
    {
        // Arrange
        string customSpoolDir = @"D:\DedicatedSpooler\Queues";
        _fileSystem.CreateDirectory(customSpoolDir);
        _fileSystem.WriteAllBytes(Path.Combine(customSpoolDir, "printjob.spl"), new byte[8192]);

        string spoolRegKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
        _registry.CreateKey(spoolRegKey);
        _registry.SetValue(spoolRegKey, "DefaultSpoolDirectory", customSpoolDir, RegistryValueKind.String);

        // Act
        var status = _printerService.GetSpoolerStatus();

        // Assert
        Assert.Equal(customSpoolDir, status.SpoolDirectory);
        Assert.Equal(customSpoolDir, status.DefaultSpoolDirectory);
        Assert.Equal(1, status.PendingJobFileCount);
        Assert.Equal(8192, status.TotalQueueSizeBytes);
        Assert.True(status.HasStalledJobs);
    }

    [Fact]
    public void GetSpoolerStatus_WhenSpoolDirectoryDoesNotExist_ReturnsZeroGracefullyWithoutThrowing()
    {
        // Arrange: Point to a non-existent directory
        string nonExistentDir = @"Z:\NonExistentDrive\Spool";
        string spoolRegKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
        _registry.CreateKey(spoolRegKey);
        _registry.SetValue(spoolRegKey, "DefaultSpoolDirectory", nonExistentDir, RegistryValueKind.String);

        // Act
        var status = _printerService.GetSpoolerStatus();

        // Assert
        Assert.NotNull(status);
        Assert.Equal(nonExistentDir, status.SpoolDirectory);
        Assert.Equal(0, status.PendingJobFileCount);
        Assert.Equal(0, status.TotalQueueSizeBytes);
        Assert.False(status.HasStalledJobs);
    }

    [Fact]
    public void GetSpoolerStatus_FallbackToProcessRunnerScExe_WhenWmiUnavailable()
    {
        // Arrange: PrinterService without WMI
        var serviceWithoutWmi = new PrinterService(
            _processRunner,
            _fileSystem,
            _registry,
            _atomicRegistry,
            _lockGuard,
            wmi: null,
            network: _network);

        // Simulate sc.exe query spooler output
        _processRunner.SetCommandResult("sc.exe query spooler", new ProcessExecutionResult(0, "SERVICE_NAME: spooler\r\n        STATE              : 4  RUNNING\r\n", "", false));

        // Act
        var status = serviceWithoutWmi.GetSpoolerStatus();

        // Assert
        Assert.True(status.IsRunning);
        Assert.Equal("Running", status.ServiceStatus);
        Assert.Contains("Running", status.Summary);
    }

    #endregion
}
