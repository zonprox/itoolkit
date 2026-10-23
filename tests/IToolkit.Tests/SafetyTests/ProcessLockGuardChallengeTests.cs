namespace IToolkit.Tests.SafetyTests;

using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class ProcessLockGuardChallengeTests
{
    private readonly MockProcessRunner _processRunner = new();
    private readonly MockFileSystemService _fileSystem = new();
    private readonly ProcessLockGuard _guard;

    public ProcessLockGuardChallengeTests()
    {
        _guard = new ProcessLockGuard(_processRunner, _fileSystem);
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_MixedProcesses_GracefulExitsWithoutKill_StubbornEscalatesToKill()
    {
        // Arrange:
        // PID 101 (WINWORD) will exit immediately upon CloseMainWindow
        _processRunner.AddProcess(101, "WINWORD", "Doc1 - Word", exitsOnClose: true);
        // PID 102 (EXCEL) resists CloseMainWindow (exitsOnClose: false)
        _processRunner.AddProcess(102, "EXCEL", "Sheet1 - Excel", exitsOnClose: false);

        var wordProc = _processRunner.SimulatedProcesses.First(p => p.Info.Id == 101);
        var excelProc = _processRunner.SimulatedProcesses.First(p => p.Info.Id == 102);

        // Act
        bool result = await _guard.EnsureProcessesClosedAsync(
            new[] { "WINWORD", "EXCEL" },
            timeout: TimeSpan.FromMilliseconds(300),
            forceKill: true);

        // Assert
        Assert.True(result);

        // WINWORD: Graceful close requested, never force-killed
        Assert.True(wordProc.CloseRequested);
        Assert.False(wordProc.KillRequested);

        // EXCEL: Graceful close requested first, then escalated to force-kill upon timeout
        Assert.True(excelProc.CloseRequested);
        Assert.True(excelProc.KillRequested);

        // Neither process is running
        Assert.False(_processRunner.IsProcessRunning("WINWORD"));
        Assert.False(_processRunner.IsProcessRunning("EXCEL"));
    }

    [Fact]
    public void EnsureProcessesClosed_SyncOverload_EscalatesToForceKillSuccessfully()
    {
        // Arrange
        _processRunner.AddProcess(201, "POWERPNT", "Slides.pptx", exitsOnClose: false);
        var proc = _processRunner.SimulatedProcesses.First();

        // Act
        bool result = _guard.EnsureProcessesClosed(
            new[] { "POWERPNT" },
            timeout: TimeSpan.FromMilliseconds(250),
            forceKill: true);

        // Assert
        Assert.True(result);
        Assert.True(proc.CloseRequested);
        Assert.True(proc.KillRequested);
        Assert.False(_processRunner.IsProcessRunning("POWERPNT"));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenCancellationTokenCanceled_ThrowsOperationCanceledException()
    {
        // Arrange: stubborn process that will make the loop poll
        _processRunner.AddProcess(301, "OUTLOOK", "Inbox", exitsOnClose: false);
        using var cts = new CancellationTokenSource();
        cts.Cancel(); // Pre-canceled

        // Act & Assert
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await _guard.EnsureProcessesClosedAsync(
                new[] { "OUTLOOK" },
                timeout: TimeSpan.FromSeconds(5),
                forceKill: true,
                cancellationToken: cts.Token);
        });
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_MultipleInstancesOfSameProcessName_HandlesAllInstances()
    {
        // Arrange: Multiple instances of chrome (PID 401, 402, 403)
        _processRunner.AddProcess(401, "chrome", "Tab 1", exitsOnClose: true);
        _processRunner.AddProcess(402, "chrome", "Tab 2", exitsOnClose: false);
        _processRunner.AddProcess(403, "chrome", "Tab 3", exitsOnClose: false);

        var p401 = _processRunner.SimulatedProcesses.First(p => p.Info.Id == 401);
        var p402 = _processRunner.SimulatedProcesses.First(p => p.Info.Id == 402);
        var p403 = _processRunner.SimulatedProcesses.First(p => p.Info.Id == 403);

        // Act
        bool result = await _guard.EnsureProcessesClosedAsync(
            new[] { "chrome" },
            timeout: TimeSpan.FromMilliseconds(300),
            forceKill: true);

        // Assert
        Assert.True(result);
        Assert.True(p401.CloseRequested && !p401.KillRequested);
        Assert.True(p402.CloseRequested && p402.KillRequested);
        Assert.True(p403.CloseRequested && p403.KillRequested);
        Assert.False(_processRunner.IsProcessRunning("chrome"));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenProcessNamesContainDuplicates_DoesNotFail()
    {
        // Arrange
        _processRunner.AddProcess(501, "WINWORD", "Doc", exitsOnClose: true);

        // Act (passing duplicate "WINWORD")
        bool result = await _guard.EnsureProcessesClosedAsync(
            new[] { "WINWORD", "WINWORD" },
            timeout: TimeSpan.FromSeconds(1),
            forceKill: true);

        // Assert
        Assert.True(result);
        Assert.False(_processRunner.IsProcessRunning("WINWORD"));
    }

    [Fact]
    public void GetLockingProcesses_ThrowsOnNullArgument()
    {
        Assert.Throws<ArgumentNullException>(() => _guard.GetLockingProcesses(null!));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenKillProcessFailsToTerminate_ReturnsFalse()
    {
        var unkillableRunner = new UnkillableProcessRunner();
        var guard = new ProcessLockGuard(unkillableRunner, _fileSystem);

        bool result = await guard.EnsureProcessesClosedAsync(
            new[] { "STUBBORN" },
            timeout: TimeSpan.FromMilliseconds(250),
            forceKill: true);

        Assert.False(result);
        Assert.True(unkillableRunner.CloseAttempted);
        Assert.True(unkillableRunner.KillAttempted);
        Assert.True(unkillableRunner.IsProcessRunning("STUBBORN"));
    }

    [Fact]
    public void IsFileLocked_ThrowsOnNullOrWhitespace()
    {
        Assert.ThrowsAny<ArgumentException>(() => _guard.IsFileLocked(null!));
        Assert.ThrowsAny<ArgumentException>(() => _guard.IsFileLocked(string.Empty));
        Assert.ThrowsAny<ArgumentException>(() => _guard.IsFileLocked("   "));
    }

    private class UnkillableProcessRunner : IProcessRunner
    {
        public bool IsRunning { get; set; } = true;
        public bool KillAttempted { get; private set; }
        public bool CloseAttempted { get; private set; }

        public IEnumerable<ProcessInfo> GetProcessesByName(string processName)
        {
            if (IsRunning && processName.Equals("STUBBORN", StringComparison.OrdinalIgnoreCase))
            {
                return new[] { new ProcessInfo(999, "STUBBORN", null) };
            }
            return Enumerable.Empty<ProcessInfo>();
        }

        public bool IsProcessRunning(string processName) =>
            IsRunning && processName.Equals("STUBBORN", StringComparison.OrdinalIgnoreCase);

        public bool CloseMainWindow(int processId)
        {
            CloseAttempted = true;
            return false;
        }

        public bool KillProcess(int processId, bool entireProcessTree = true)
        {
            KillAttempted = true;
            return false;
        }

        public ProcessExecutionResult Run(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000) =>
            new(0, "", "", false);

        public Task<ProcessExecutionResult> RunAsync(string fileName, string arguments, string? workingDirectory = null, int timeoutMs = 60000, CancellationToken cancellationToken = default) =>
            Task.FromResult(Run(fileName, arguments, workingDirectory, timeoutMs));

        public bool WaitForExit(int processId, TimeSpan timeout) => false;
        public bool StopProcess(string processName, int timeoutSeconds = 10, bool force = true) => false;
    }
}
