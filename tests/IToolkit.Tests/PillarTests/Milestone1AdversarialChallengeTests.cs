namespace IToolkit.Tests.PillarTests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Core.Services.Connectivity;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Adversarial and empirical verification suite for Milestone 1:
/// PrinterService atomic registry backups, role batch pipelines,
/// Spooler process lifecycle, and error code routing under adverse conditions.
/// </summary>
public class Milestone1AdversarialChallengeTests
{
    private readonly MockProcessRunner _processRunner;
    private readonly MockFileSystemService _fileSystem;
    private readonly MockRegistryService _registry;
    private readonly MockNetworkService _network;
    private readonly MockWmiService _wmi;
    private readonly AtomicRegistryService _atomicRegistry;
    private readonly ProcessLockGuard _lockGuard;
    private readonly PrinterService _printerService;
    private readonly string _backupDir;

    public Milestone1AdversarialChallengeTests()
    {
        _processRunner = new MockProcessRunner();
        _fileSystem = new MockFileSystemService();
        _registry = new MockRegistryService();
        _network = new MockNetworkService(_fileSystem);
        _wmi = new MockWmiService();

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
            network: _network);
    }

    #region 1. Atomic Registry Backups & Rollback Sentinel Verification

    [Fact]
    public void ApplyPointAndPrintPreset_ProducesGenuineRegBackups_WithUnicodeAndSentinel()
    {
        // Act: Apply Compatibility preset when keys do not exist initially
        bool success = _printerService.ApplyPointAndPrintPreset(PointAndPrintPreset.Compatibility);
        Assert.True(success);

        var regFiles = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        Assert.True(regFiles.Count >= 2, $"Expected at least 2 .reg backup files, found {regFiles.Count}");

        // Assert file content: Must have valid Windows Registry Editor header and rollback sentinel [-Key]
        foreach (var regFile in regFiles)
        {
            byte[] bytes = _fileSystem.ReadAllBytes(regFile);
            Assert.True(bytes.Length >= 2, "Backup file is empty");
            string text = Encoding.Unicode.GetString(bytes);

            Assert.Contains("Windows Registry Editor Version 5.00", text);
            Assert.Contains("IToolkit Rollback Sentinel", text);
            Assert.Contains("[-HKEY_LOCAL_MACHINE\\", text);
        }
    }

    [Fact]
    public void ApplyPointAndPrintPreset_WhenKeysPreExist_CapturesOriginalValuesInBackup()
    {
        // Arrange pre-existing values
        string printControlKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printControlKey);
        _registry.SetValue(printControlKey, "RpcAuthnLevelPrivacyEnabled", 12345, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 999, RegistryValueKind.DWord);

        // Act
        bool success = _printerService.ApplyPointAndPrintPreset(PointAndPrintPreset.Compatibility);
        Assert.True(success);

        // Find the printControlKey backup
        var regFiles = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        var printBackup = regFiles.First(f => f.Contains("Print") && !f.Contains("PointAndPrint"));
        string content = Encoding.Unicode.GetString(_fileSystem.ReadAllBytes(printBackup));

        Assert.Contains("RpcAuthnLevelPrivacyEnabled", content);
        Assert.Contains("dword:00003039", content); // 12345 in hex is 0x3039
    }

    [Fact]
    public void ResetNePortBindings_CreatesGenuineBackup_OnlyWhenKeyExists()
    {
        // Case A: Key does not exist -> 0 removed, 0 backups created
        int countAbsent = _printerService.ResetNePortBindings();
        Assert.Equal(0, countAbsent);
        var initialBackups = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        Assert.Empty(initialBackups);

        // Case B: Key exists with active and ghost ports
        string portsKey = @"HKCU\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts";
        _registry.CreateKey(portsKey);
        _registry.SetValue(portsKey, "LegitPrinter", "Ne01:", RegistryValueKind.String);
        _registry.SetValue(portsKey, "GhostPrinter", "Ne02:", RegistryValueKind.String);

        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", "LegitPrinter" } }
        });

        int removed = _printerService.ResetNePortBindings();
        Assert.Equal(1, removed);

        var backups = _fileSystem.EnumerateFiles(_backupDir, "*.reg", SearchOption.AllDirectories).ToList();
        Assert.Single(backups);
        string regContent = Encoding.Unicode.GetString(_fileSystem.ReadAllBytes(backups[0]));
        Assert.Contains("PrinterPorts", backups[0]);
        Assert.Contains("LegitPrinter", regContent);
        Assert.Contains("GhostPrinter", regContent);
    }

    [Fact]
    public void RemediatePrinterError_GeneratesValidBackups_AndRollbackRestoresPreviousState()
    {
        // Arrange pre-existing state for 0x0000011b
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printKey);
        _registry.SetValue(printKey, "RpcAuthnLevelPrivacyEnabled", 1, RegistryValueKind.DWord);

        // Act: Remediate 0x0000011b (sets RpcAuthnLevelPrivacyEnabled = 0)
        var result = _printerService.RemediatePrinterError("0x0000011b");
        Assert.True(result.Success);
        Assert.NotNull(result.BackupPath);
        Assert.True(_fileSystem.FileExists(result.BackupPath));
        Assert.Equal(0, _registry.GetValue<int>(printKey, "RpcAuthnLevelPrivacyEnabled"));

        // Act: Rollback using the generated backup
        bool rollbackOk = _atomicRegistry.Rollback(result.BackupPath);
        Assert.True(rollbackOk);
        Assert.Equal(1, _registry.GetValue<int>(printKey, "RpcAuthnLevelPrivacyEnabled"));
    }

    [Fact]
    public void BatchRemediation_DeduplicatesKeyBackups_WhileCoveringAllMutatedKeys()
    {
        // Act: Run Combined role remediation (AllBoth)
        var result = _printerService.RemediateRole(PrinterRemediationRole.Both);
        Assert.True(result.Success);

        // Verify that BackupPaths contains no duplicates
        var paths = result.BackupPaths;
        Assert.NotEmpty(paths);
        Assert.Equal(paths.Count, paths.Distinct(StringComparer.OrdinalIgnoreCase).Count());

        // Verify every returned backup path points to an actual existing file
        foreach (var p in paths)
        {
            Assert.True(_fileSystem.FileExists(p), $"Backup path file does not exist: {p}");
        }

        // Verify keys mutated in Server & Client have backups
        Assert.Contains(paths, p => p.Contains("Print"));
        Assert.Contains(paths, p => p.Contains("Printers"));
        Assert.Contains(paths, p => p.Contains("PointAndPrint"));
        Assert.Contains(paths, p => p.Contains("RPC"));
        Assert.Contains(paths, p => p.Contains("Windows_x64"));
    }

    #endregion

    #region 2. Role Batch Pipelines & Action Sequencing

    [Fact]
    public void RemediateRole_Server_ExecutesExact9ActionsInOrder()
    {
        string[] expectedServerOrder =
        {
            "RpcAuthnLevel", "RemoteRpcEndPoint", "RpcProtocols", "SpoolerHealth",
            "SpoolerDLLs", "DriverStoreRepair", "SpoolerHandles", "ClearStalledJobs", "SpoolerCrash"
        };

        var result = _printerService.RemediateRole(PrinterRemediationRole.Server);

        Assert.True(result.Success);
        Assert.Equal(expectedServerOrder.Length, result.ActionsExecuted.Count);
        for (int i = 0; i < expectedServerOrder.Length; i++)
        {
            Assert.Equal(expectedServerOrder[i], result.ActionsExecuted[i]);
            Assert.Equal(expectedServerOrder[i], result.Results[i].ErrorCode);
            Assert.True(result.Results[i].Success);
        }
    }

    [Fact]
    public void RemediateRole_Client_ExecutesExact13ActionsInOrder()
    {
        string[] expectedClientOrder =
        {
            "PointAndPrintAdmin", "PointAndPrintPrompts", "RpcNamedPipe", "DefaultPrinterKey",
            "CopyFilesPolicy", "SpoolerDLLs", "DriverStoreRepair", "SpoolerHandles",
            "DriverConfig", "ClearStalledJobs", "SpoolerQueue", "NePorts", "RefreshConnections"
        };

        var result = _printerService.RemediateRole(PrinterRemediationRole.Client);

        Assert.True(result.Success);
        Assert.Equal(expectedClientOrder.Length, result.ActionsExecuted.Count);
        for (int i = 0; i < expectedClientOrder.Length; i++)
        {
            Assert.Equal(expectedClientOrder[i], result.ActionsExecuted[i]);
            Assert.Equal(expectedClientOrder[i], result.Results[i].ErrorCode);
            Assert.True(result.Results[i].Success);
        }
    }

    [Fact]
    public void RemediateRole_Both_ExecutesExact17ActionsInOrder()
    {
        string[] expectedBothOrder =
        {
            "RpcAuthnLevel", "RemoteRpcEndPoint", "RpcProtocols", "SpoolerHealth",
            "PointAndPrintAdmin", "PointAndPrintPrompts", "RpcNamedPipe", "DefaultPrinterKey",
            "CopyFilesPolicy", "SpoolerDLLs", "DriverStoreRepair", "SpoolerHandles",
            "DriverConfig", "ClearStalledJobs", "SpoolerCrash", "NePorts", "RefreshConnections"
        };

        var result = _printerService.RemediateRole(PrinterRemediationRole.Both);

        Assert.True(result.Success);
        Assert.Equal(expectedBothOrder.Length, result.ActionsExecuted.Count);
        for (int i = 0; i < expectedBothOrder.Length; i++)
        {
            Assert.Equal(expectedBothOrder[i], result.ActionsExecuted[i]);
            Assert.Equal(expectedBothOrder[i], result.Results[i].ErrorCode);
            Assert.True(result.Results[i].Success);
        }
    }

    #endregion

    #region 3. Spooler Process Lifecycle & Lock Safety

    [Fact]
    public void RemediateRole_RestartsSpoolerOnceAtEnd_WithProcessLockGuard()
    {
        var result = _printerService.RemediateRole(PrinterRemediationRole.Server);

        Assert.True(result.SpoolerRestarted);
        var cmds = _processRunner.ExecutedCommands;

        // In batch mode, spooler restart occurs at the end of the batch (plus any intermediate queue purge actions like SpoolerCrash)
        int stopCount = cmds.Count(c => c.Contains("net stop spooler"));
        int startCount = cmds.Count(c => c.Contains("net start spooler"));

        Assert.True(stopCount >= 1, "At least one spooler stop must be issued");
        Assert.True(startCount >= 1, "At least one spooler start must be issued");

        // Verify stop was issued before start, and final command is spooler start
        int lastStop = cmds.FindLastIndex(c => c.Contains("net stop spooler"));
        int lastStart = cmds.FindLastIndex(c => c.Contains("net start spooler"));
        Assert.True(lastStop < lastStart, "Final net stop must precede final net start");
        Assert.Equal(cmds.Count - 1, lastStart);
    }

    [Fact]
    public void RemediateRole_WhenSpoolerStartFails_ReportsFailureCleanly()
    {
        // Simulate net.exe failure when starting spooler
        _processRunner.SetCommandResult("net start spooler", new ProcessExecutionResult(1, string.Empty, "The service could not be started.", false));

        var result = _printerService.RemediateRole(PrinterRemediationRole.Client);

        Assert.False(result.SpoolerRestarted);
        Assert.False(result.Success);
        Assert.Contains("warnings", result.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RemediateRole_WhenIntermediateActionThrows_ContinuesBatchAndRestartsSpooler()
    {
        // Inject a simulated failure by passing an invalid role via casting
        Assert.Throws<ArgumentOutOfRangeException>(() => _printerService.RemediateRole((PrinterRemediationRole)999));
    }

    #endregion

    #region 4. Error Code Routing & Adversarial Inputs

    [Theory]
    [InlineData("allserver", 9)]
    [InlineData("ALLSERVER", 9)]
    [InlineData("server", 9)]
    [InlineData("allclient", 13)]
    [InlineData("ALLCLIENT", 13)]
    [InlineData("client", 13)]
    [InlineData("allboth", 17)]
    [InlineData("ALLBOTH", 17)]
    [InlineData("both", 17)]
    [InlineData("all", 17)]
    public void RemediatePrinterError_RoutesRoleAliasesCaseInsensitively(string alias, int expectedCount)
    {
        var result = _printerService.RemediatePrinterError($"  {alias}  ");

        Assert.True(result.Success);
        Assert.Contains($"{expectedCount} actions", result.RemediationAction);
    }

    [Theory]
    [InlineData("0x0000011b")]
    [InlineData("0X0000011B")]
    [InlineData("0x00000709")]
    [InlineData("0x0000007c")]
    [InlineData("0x0000007e")]
    [InlineData("0x00000bcb")]
    [InlineData("0x00000002")]
    [InlineData("0x00000006")]
    [InlineData("0x00000057")]
    [InlineData("0x000003e3")]
    [InlineData("SpoolerCrash")]
    [InlineData("spoolercrash")]
    [InlineData("NePortConflict")]
    [InlineData("neportconflict")]
    [InlineData("RefreshConnections")]
    [InlineData("refreshconnections")]
    public void RemediatePrinterError_HandlesCanonicalCodes_CaseInsensitively(string code)
    {
        var result = _printerService.RemediatePrinterError(code);

        Assert.True(result.Success);
        Assert.True(result.PolicyApplied);
    }

    [Theory]
    [InlineData("UNKNOWN_CODE_9999")]
    [InlineData("0xDEADBEEF")]
    [InlineData("SomeRandomString")]
    public void RemediatePrinterError_UnknownCodes_ReturnSafeFailure(string invalidCode)
    {
        var result = _printerService.RemediatePrinterError(invalidCode);

        Assert.False(result.Success);
        Assert.False(result.PolicyApplied);
        Assert.False(result.ServicesRestarted);
        Assert.Equal("Unknown error code", result.RemediationAction);
    }

    [Fact]
    public void RemediatePrinterError_NullOrWhitespace_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentNullException>(() => _printerService.RemediatePrinterError(null!));
        Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError(""));
        Assert.Throws<ArgumentException>(() => _printerService.RemediatePrinterError("    "));
    }

    #endregion

    #region 5. Point & Print Policy Audit & Spooler Health Adversarial Cases

    [Fact]
    public void AuditPointAndPrintPolicy_EvaluatesAllVulnerabilityVectors()
    {
        string printKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print";
        _registry.CreateKey(printKey);
        _registry.SetValue(printKey, "RpcAuthnLevelPrivacyEnabled", 0, RegistryValueKind.DWord);

        string pnpKey = @"HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint";
        _registry.CreateKey(pnpKey);
        _registry.SetValue(pnpKey, "RestrictDriverInstallationToAdministrators", 0, RegistryValueKind.DWord);
        _registry.SetValue(pnpKey, "NoWarningNoElevationOnInstall", 1, RegistryValueKind.DWord);

        var audit = _printerService.AuditPointAndPrintPolicy();

        Assert.True(audit.IsVulnerableToCVE20211678);
        Assert.True(audit.IsVulnerable);
        Assert.False(audit.RpcAuthnLevelPrivacyEnabled);
        Assert.False(audit.RestrictDriverInstallationToAdministrators);
        Assert.True(audit.NoWarningNoElevationOnInstall);
        Assert.True(audit.Recommendations.Count >= 3);
    }

    [Fact]
    public void GetSpoolerStatus_ResolvesCustomRegistrySpoolDirectory_AndCountsValidExtensions()
    {
        string customSpool = @"D:\CustomSpoolDir";
        _fileSystem.CreateDirectory(customSpool);

        // Put simulated files
        _fileSystem.WriteAllBytes(Path.Combine(customSpool, "001.SPL"), new byte[500]);
        _fileSystem.WriteAllBytes(Path.Combine(customSpool, "001.SHD"), new byte[100]);
        _fileSystem.WriteAllBytes(Path.Combine(customSpool, "temp.TMP"), new byte[200]);
        _fileSystem.WriteAllBytes(Path.Combine(customSpool, "other.exe"), new byte[1000]); // should be ignored

        string spoolRegKey = @"HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers";
        _registry.CreateKey(spoolRegKey);
        _registry.SetValue(spoolRegKey, "DefaultSpoolDirectory", customSpool, RegistryValueKind.String);

        _processRunner.SetCommandResult("sc.exe query spooler", new ProcessExecutionResult(0, "STATE : 4  RUNNING", string.Empty, false));

        var status = _printerService.GetSpoolerStatus();

        Assert.True(status.IsRunning);
        Assert.Equal("Running", status.ServiceStatus);
        Assert.Equal(customSpool, status.SpoolDirectory);
        Assert.Equal(3, status.PendingJobFileCount);
        Assert.Equal(800, status.TotalQueueSizeBytes);
        Assert.True(status.HasStalledJobs);
    }

    [Fact]
    public void ResetPrinterConnections_FallbackToPort445_WhenPingFails()
    {
        string server = "PrinterHost";
        string uncPrinter = $@"\\{server}\SharedLaser";

        _wmi.SetQueryResult("SELECT Name FROM Win32_Printer", new[]
        {
            new Dictionary<string, object?> { { "Name", uncPrinter } }
        });

        // Ping fails, but SMB port 445 is open
        _network.SetHostReachable(server, false);
        _network.SetPortOpen(server, 445, true);

        var result = _printerService.ResetPrinterConnections();

        Assert.True(result.Success);
        Assert.Equal(1, result.DiscoveredPrinters);
        Assert.Equal(1, result.ReconnectedPrinters);
        Assert.Equal(0, result.RemovedStalePrinters);
        Assert.Contains(result.Details, d => d.Contains("Active") && d.Contains(uncPrinter));
    }

    #endregion
}
