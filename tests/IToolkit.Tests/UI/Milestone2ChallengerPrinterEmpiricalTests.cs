namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;
using Moq;
using Xunit;

public class Milestone2ChallengerPrinterEmpiricalTests : IDisposable
{
    private readonly Mock<IConnectivityService> _connectivityMock;
    private readonly Mock<IPrinterService> _printerMock;
    private readonly Mock<IActivityLogger> _loggerMock;
    private readonly Mock<ISafetyConfirmationService> _confirmationMock;

    public Milestone2ChallengerPrinterEmpiricalTests()
    {
        _connectivityMock = new Mock<IConnectivityService>();
        _printerMock = new Mock<IPrinterService>();
        _loggerMock = new Mock<IActivityLogger>();
        _confirmationMock = new Mock<ISafetyConfirmationService>();

        _printerMock.Setup(p => p.GetSupportedErrorCodes()).Returns(new[] { "0x0000011b", "0x00000709" });
    }

    public void Dispose()
    {
        ViewModelBase.ResetOperationEvents();
    }

    private ConnectivityViewModel CreateViewModel()
    {
        return new ConnectivityViewModel(
            _connectivityMock.Object,
            _printerMock.Object,
            _loggerMock.Object,
            networkService: null,
            confirmationService: _confirmationMock.Object,
            dialogService: null);
    }

    // =========================================================================
    // 1. ISBUSY CONCURRENT RE-ENTRY PREVENTION TESTS
    // =========================================================================

    [Fact]
    public async Task AllSixNewCommands_WhenIsBusyIsTrue_CanExecuteReturnsFalseAndExecutionIsBlocked()
    {
        var vm = CreateViewModel();
        vm.IsBusy = true;

        IAsyncRelayCommand[] commands =
        {
            vm.RemediateAllPrintersCommand,
            vm.RemediateClientBatchCommand,
            vm.RemediateServerBatchCommand,
            vm.AuditPointAndPrintPolicyCommand,
            vm.RefreshPrinterConnectionsCommand,
            vm.InspectSpoolerStatusCommand
        };

        foreach (var cmd in commands)
        {
            Assert.False(cmd.CanExecute(null), $"Command {cmd.GetType().Name} should have CanExecute=false when IsBusy=true");
            await cmd.ExecuteAsync(null);
        }

        // Verify that zero service calls were made while busy
        _printerMock.Verify(p => p.RemediateAll(), Times.Never);
        _printerMock.Verify(p => p.RemediateRole(It.IsAny<PrinterRemediationRole>()), Times.Never);
        _printerMock.Verify(p => p.AuditPointAndPrintPolicy(), Times.Never);
        _printerMock.Verify(p => p.ResetPrinterConnections(It.IsAny<bool>(), It.IsAny<string?>()), Times.Never);
        _printerMock.Verify(p => p.GetSpoolerStatus(), Times.Never);
        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task ConcurrentReentry_WhileOperationIsRunning_BlocksAllOtherCommandsAndPreventsRaceConditions()
    {
        var vm = CreateViewModel();
        var tcs = new TaskCompletionSource<BatchPrinterRemediationResult>();

        _confirmationMock
            .Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(true);

        _printerMock
            .Setup(p => p.RemediateAll())
            .Returns(() => tcs.Task.GetAwaiter().GetResult());

        // Launch RemediateAll on a background thread so it awaits the TCS
        var runTask = Task.Run(async () => await vm.RemediateAllPrintersCommand.ExecuteAsync(null));

        // Spin-wait until IsBusy becomes true
        for (int i = 0; i < 50 && !vm.IsBusy; i++)
        {
            await Task.Delay(20);
        }

        Assert.True(vm.IsBusy, "ViewModel should be in IsBusy state during execution");

        // Verify that all 6 commands have CanExecute=false while running
        Assert.False(vm.RemediateAllPrintersCommand.CanExecute(null));
        Assert.False(vm.RemediateClientBatchCommand.CanExecute(null));
        Assert.False(vm.RemediateServerBatchCommand.CanExecute(null));
        Assert.False(vm.AuditPointAndPrintPolicyCommand.CanExecute(null));
        Assert.False(vm.RefreshPrinterConnectionsCommand.CanExecute(null));
        Assert.False(vm.InspectSpoolerStatusCommand.CanExecute(null));

        // Attempt concurrent execution of all commands while busy
        var concurrentTasks = new[]
        {
            vm.RemediateAllPrintersCommand.ExecuteAsync(null),
            vm.RemediateClientBatchCommand.ExecuteAsync(null),
            vm.RemediateServerBatchCommand.ExecuteAsync(null),
            vm.AuditPointAndPrintPolicyCommand.ExecuteAsync(null),
            vm.RefreshPrinterConnectionsCommand.ExecuteAsync(null),
            vm.InspectSpoolerStatusCommand.ExecuteAsync(null)
        };

        await Task.WhenAll(concurrentTasks);

        // Complete the long-running task
        tcs.SetResult(new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Both,
            ActionsExecuted: new[] { "AllFixes" },
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: new[] { "C:\\backup.reg" },
            SpoolerRestarted: true,
            Success: true,
            Message: "All done"));

        await runTask;

        Assert.False(vm.IsBusy, "ViewModel should reset IsBusy to false upon completion");
        _printerMock.Verify(p => p.RemediateAll(), Times.Once);
        _printerMock.Verify(p => p.RemediateRole(It.IsAny<PrinterRemediationRole>()), Times.Never);
        _printerMock.Verify(p => p.AuditPointAndPrintPolicy(), Times.Never);
        _printerMock.Verify(p => p.ResetPrinterConnections(It.IsAny<bool>(), It.IsAny<string?>()), Times.Never);
        _printerMock.Verify(p => p.GetSpoolerStatus(), Times.Never);
    }

    // =========================================================================
    // 2. USER CANCELLATION FLOW TESTS
    // =========================================================================

    [Fact]
    public async Task RemediateAllPrintersCommand_WhenCancelledByUser_SetsStatusAndLogsWarningWithoutExecuting()
    {
        var vm = CreateViewModel();

        _confirmationMock
            .Setup(c => c.ConfirmAsync(
                "Confirm Full Printer Remediation",
                It.Is<string>(m => m.Contains("Full Printer Remediation will apply")),
                It.Is<string>(w => w.Contains("Active print jobs will be lost"))))
            .ReturnsAsync(false);

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateAll(), Times.Never);
        Assert.Equal("Full printer remediation cancelled by user.", vm.LastPrinterStatus);
        Assert.False(vm.IsBusy);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("cancelled by user"))), Times.Once);
    }

    [Fact]
    public async Task RemediateAllPrintersCommand_WhenConfirmationServiceNull_ProceedsDirectly()
    {
        var vm = new ConnectivityViewModel(
            _connectivityMock.Object,
            _printerMock.Object,
            _loggerMock.Object,
            networkService: null,
            confirmationService: null,
            dialogService: null);

        var batchResult = new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Both,
            ActionsExecuted: new[] { "Action1" },
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: Array.Empty<string>(),
            SpoolerRestarted: true,
            Success: true,
            Message: "Executed directly");

        _printerMock.Setup(p => p.RemediateAll()).Returns(batchResult);

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        _printerMock.Verify(p => p.RemediateAll(), Times.Once);
        Assert.Contains("Remediate All completed", vm.LastPrinterStatus);
    }

    [Fact]
    public async Task RemediateAllPrintersCommand_WhileConfirmationPending_IsExecutingBlocksDuplicateTriggers()
    {
        var vm = CreateViewModel();
        var confirmTcs = new TaskCompletionSource<bool>();

        _confirmationMock
            .Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .Returns(confirmTcs.Task);

        var firstExecution = vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        // Command is actively awaiting confirmation
        Assert.True(vm.RemediateAllPrintersCommand.IsExecuting);
        Assert.False(vm.RemediateAllPrintersCommand.CanExecute(null));

        // Second click attempt while confirmation dialog is open
        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        // Confirm dialog was only prompted once
        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Once);

        // Release confirmation with cancellation
        confirmTcs.SetResult(false);
        await firstExecution;

        Assert.False(vm.RemediateAllPrintersCommand.IsExecuting);
        Assert.True(vm.RemediateAllPrintersCommand.CanExecute(null));
        _printerMock.Verify(p => p.RemediateAll(), Times.Never);
    }

    // =========================================================================
    // 3. SERVICE FAILURE HANDLING (SUCCESS = FALSE) ACROSS ALL 6 COMMANDS
    // =========================================================================

    [Fact]
    public async Task RemediateAllPrintersCommand_ServiceFailure_SurfacesInLastPrinterStatusAndLogsError()
    {
        var vm = CreateViewModel();
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>())).ReturnsAsync(true);

        _printerMock.Setup(p => p.RemediateAll()).Returns(new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Both,
            ActionsExecuted: Array.Empty<string>(),
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: Array.Empty<string>(),
            SpoolerRestarted: false,
            Success: false,
            Message: "Spooler service failed to start"));

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        Assert.Contains("Remediate All failed: Spooler service failed to start", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogError(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("Remediate All failed"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RemediateClientBatchCommand_ServiceFailure_SurfacesInLastPrinterStatusAndLogsError()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.RemediateRole(PrinterRemediationRole.Client)).Returns(new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Client,
            ActionsExecuted: Array.Empty<string>(),
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: Array.Empty<string>(),
            SpoolerRestarted: false,
            Success: false,
            Message: "Client registry access denied"));

        await vm.RemediateClientBatchCommand.ExecuteAsync(null);

        Assert.Contains("Client Batch failed: Client registry access denied", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogError(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("Client Batch failed"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RemediateServerBatchCommand_ServiceFailure_SurfacesInLastPrinterStatusAndLogsError()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.RemediateRole(PrinterRemediationRole.Server)).Returns(new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Server,
            ActionsExecuted: Array.Empty<string>(),
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: Array.Empty<string>(),
            SpoolerRestarted: false,
            Success: false,
            Message: "RPC protocols configuration failed"));

        await vm.RemediateServerBatchCommand.ExecuteAsync(null);

        Assert.Contains("Server Batch failed: RPC protocols configuration failed", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogError(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("Server Batch failed"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task RefreshPrinterConnectionsCommand_ServiceFailure_SurfacesInLastPrinterStatusAndLogsError()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.ResetPrinterConnections(true, null)).Returns(new PrinterConnectionResetResult(
            DiscoveredPrinters: 0,
            ReconnectedPrinters: 0,
            RemovedStalePrinters: 0,
            Details: Array.Empty<string>(),
            Success: false,
            Message: "WMI service unreachable"));

        await vm.RefreshPrinterConnectionsCommand.ExecuteAsync(null);

        Assert.Contains("Printer connection refresh failed: WMI service unreachable", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogError(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("Printer connection refresh failed"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task AuditPointAndPrintPolicyCommand_VulnerableState_SurfacesInLastPrinterStatusAndLogsWarning()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.AuditPointAndPrintPolicy()).Returns(new PointAndPrintPolicyAuditResult(
            RpcAuthnLevelPrivacyEnabled: false,
            RestrictDriverInstallationToAdministrators: false,
            NoWarningNoElevationOnInstall: true,
            UpdatePromptSettings: 2,
            IsVulnerableToCVE20211678: true,
            PostureDescription: "Critically vulnerable to PrintNightmare and unauthenticated RPC",
            Recommendations: new[] { "Enable RestrictDriverInstallationToAdministrators", "Enable RpcAuthnLevelPrivacyEnabled" }));

        await vm.AuditPointAndPrintPolicyCommand.ExecuteAsync(null);

        Assert.Contains("Posture=Vulnerable", vm.LastPrinterStatus);
        Assert.Contains("CVE-2021-1678=Vulnerable", vm.LastPrinterStatus);
        Assert.Contains("RpcAuthn=Disabled", vm.LastPrinterStatus);
        Assert.Contains("RestrictAdmin=Disabled", vm.LastPrinterStatus);
        Assert.Contains("Critically vulnerable", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogWarning(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("CVE-2021-1678=Vulnerable"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task InspectSpoolerStatusCommand_StalledJobs_SurfacesInLastPrinterStatusAndLogsInfo()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.GetSpoolerStatus()).Returns(new SpoolerServiceStatus(
            IsRunning: true,
            ServiceStatus: "Running",
            SpoolDirectory: "C:\\Windows\\System32\\spool\\PRINTERS",
            PendingJobFileCount: 14,
            TotalQueueSizeBytes: 1048576,
            HasStalledJobs: true,
            Pid: 5432,
            StartupType: "Automatic",
            Summary: "Print spooler running with stalled print jobs detected."));

        await vm.InspectSpoolerStatusCommand.ExecuteAsync(null);

        Assert.Contains("Running (PID 5432)", vm.LastPrinterStatus);
        Assert.Contains("14 file(s) (1048576 bytes)", vm.LastPrinterStatus);
        Assert.Contains("[Stalled Jobs Detected]", vm.LastPrinterStatus);
        _loggerMock.Verify(l => l.LogInfo(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains("[Stalled Jobs Detected]"))), Times.Once);
        Assert.False(vm.IsBusy);
    }

    // =========================================================================
    // 4. UNHANDLED EXCEPTION RESILIENCE ACROSS ALL 6 COMMANDS
    // =========================================================================

    [Theory]
    [InlineData(1, "Remediate All Printers (Client + Server)")]
    [InlineData(2, "Remediate Client Printers")]
    [InlineData(3, "Remediate Server Printers")]
    [InlineData(4, "Audit Point & Print Policy")]
    [InlineData(5, "Refresh Printer Connections")]
    [InlineData(6, "Inspect Spooler Status")]
    public async Task AllSixNewCommands_WhenServiceThrowsUnhandledException_ExecuteAsyncCatchesAndLogsWithoutCrashing(
        int commandIndex,
        string expectedOperationName)
    {
        var vm = CreateViewModel();
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>())).ReturnsAsync(true);

        var catastrophicException = new InvalidOperationException($"Catastrophic service crash in {expectedOperationName}");

        _printerMock.Setup(p => p.RemediateAll()).Throws(catastrophicException);
        _printerMock.Setup(p => p.RemediateRole(PrinterRemediationRole.Client)).Throws(catastrophicException);
        _printerMock.Setup(p => p.RemediateRole(PrinterRemediationRole.Server)).Throws(catastrophicException);
        _printerMock.Setup(p => p.AuditPointAndPrintPolicy()).Throws(catastrophicException);
        _printerMock.Setup(p => p.ResetPrinterConnections(It.IsAny<bool>(), It.IsAny<string?>())).Throws(catastrophicException);
        _printerMock.Setup(p => p.GetSpoolerStatus()).Throws(catastrophicException);

        IAsyncRelayCommand targetCommand = commandIndex switch
        {
            1 => vm.RemediateAllPrintersCommand,
            2 => vm.RemediateClientBatchCommand,
            3 => vm.RemediateServerBatchCommand,
            4 => vm.AuditPointAndPrintPolicyCommand,
            5 => vm.RefreshPrinterConnectionsCommand,
            6 => vm.InspectSpoolerStatusCommand,
            _ => throw new ArgumentOutOfRangeException(nameof(commandIndex))
        };

        // Execution MUST complete cleanly without throwing out of ExecuteAsync
        var executionTask = targetCommand.ExecuteAsync(null);
        await executionTask;

        // Verify state is clean
        Assert.False(vm.IsBusy, $"IsBusy must reset to false after exception in {expectedOperationName}");
        Assert.Contains($"{expectedOperationName} failed", vm.StatusMessage);
        Assert.Contains("Catastrophic service crash", vm.StatusMessage);

        // Verify error was logged through IActivityLogger
        _loggerMock.Verify(l => l.LogError(
            nameof(ConnectivityViewModel),
            It.Is<string>(m => m.Contains($"Operation '{expectedOperationName}' failed"))), Times.Once);
    }

    // =========================================================================
    // 5. EDGE CASE TESTS: NULL / EMPTY METRICS IN MODELS
    // =========================================================================

    [Fact]
    public async Task RemediateAllPrintersCommand_WithNullBackupPathsAndEmptyActions_FormatsStatusSafely()
    {
        var vm = CreateViewModel();
        _confirmationMock.Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>())).ReturnsAsync(true);

        _printerMock.Setup(p => p.RemediateAll()).Returns(new BatchPrinterRemediationResult(
            Role: PrinterRemediationRole.Both,
            ActionsExecuted: Array.Empty<string>(),
            Results: Array.Empty<PrinterRemediationResult>(),
            BackupPaths: Array.Empty<string>(),
            SpoolerRestarted: true,
            Success: true,
            Message: "Success with empty lists"));

        await vm.RemediateAllPrintersCommand.ExecuteAsync(null);

        Assert.Contains("Remediate All completed: 0 action(s) executed, 0 backup(s) saved, 0 queue job(s) purged, 0 Ne port(s) cleaned.", vm.LastPrinterStatus);
        Assert.False(vm.IsBusy);
    }

    [Fact]
    public async Task InspectSpoolerStatusCommand_WhenPidIsNull_FormatsStatusCleanlyWithoutPidToken()
    {
        var vm = CreateViewModel();

        _printerMock.Setup(p => p.GetSpoolerStatus()).Returns(new SpoolerServiceStatus(
            IsRunning: true,
            ServiceStatus: "Running",
            SpoolDirectory: "C:\\Windows\\System32\\spool\\PRINTERS",
            PendingJobFileCount: 0,
            TotalQueueSizeBytes: 0,
            HasStalledJobs: false,
            Pid: null,
            StartupType: "Manual",
            Summary: "Print spooler running normally."));

        await vm.InspectSpoolerStatusCommand.ExecuteAsync(null);

        Assert.Equal("Spooler Status: Running, Queue: 0 file(s) (0 bytes), Directory: C:\\Windows\\System32\\spool\\PRINTERS. [Queue Clean]", vm.LastPrinterStatus);
        Assert.DoesNotContain("PID", vm.LastPrinterStatus);
        Assert.False(vm.IsBusy);
    }
}
