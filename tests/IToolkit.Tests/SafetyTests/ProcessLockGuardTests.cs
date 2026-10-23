namespace IToolkit.Tests.SafetyTests;

using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class ProcessLockGuardTests
{
    private readonly MockProcessRunner _processRunner = new();
    private readonly MockFileSystemService _fileSystem = new();
    private readonly ProcessLockGuard _guard;

    public ProcessLockGuardTests()
    {
        _guard = new ProcessLockGuard(_processRunner, _fileSystem);
    }

    [Fact]
    public void IsAnyProcessRunning_WhenTargetProcessIsRunning_ReturnsTrue()
    {
        // Arrange
        _processRunner.AddProcess(101, "OUTLOOK", "Inbox - Outlook");

        // Act
        bool isRunning = _guard.IsAnyProcessRunning(ProcessLockGuard.OfficeProcessNames);

        // Assert
        Assert.True(isRunning);
    }

    [Fact]
    public void IsAnyProcessRunning_WhenNoTargetProcessIsRunning_ReturnsFalse()
    {
        // Arrange
        _processRunner.AddProcess(202, "notepad", "Untitled - Notepad");

        // Act
        bool isRunning = _guard.IsAnyProcessRunning(ProcessLockGuard.OfficeProcessNames);

        // Assert
        Assert.False(isRunning);
    }

    [Fact]
    public void IsFileLocked_WhenFileIsMarkedLocked_ReturnsTrue()
    {
        // Arrange
        const string dataFilePath = @"C:\Users\User\AppData\Local\Microsoft\Outlook\archive.pst";
        _fileSystem.WriteAllBytes(dataFilePath, new byte[] { 0x01, 0x02 });
        _fileSystem.SetFileLocked(dataFilePath, true);

        // Act
        bool locked = _guard.IsFileLocked(dataFilePath);

        // Assert
        Assert.True(locked);
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenProcessExitsGracefully_ClosesWithoutForceKill()
    {
        // Arrange
        _processRunner.AddProcess(1001, "WINWORD", "Document1 - Word", exitsOnClose: true);
        var proc = _processRunner.SimulatedProcesses.First();

        // Act
        bool success = await _guard.EnsureProcessesClosedAsync(
            new[] { "WINWORD" },
            timeout: TimeSpan.FromSeconds(2),
            forceKill: true);

        // Assert
        Assert.True(success);
        Assert.True(proc.CloseRequested);
        Assert.False(proc.KillRequested);
        Assert.False(_processRunner.IsProcessRunning("WINWORD"));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenProcessResistsGracefulClose_EscalatesToForceKill()
    {
        // Arrange: Process resists graceful close
        _processRunner.AddProcess(2002, "EXCEL", "Budget.xlsx - Excel", exitsOnClose: false);
        var proc = _processRunner.SimulatedProcesses.First();

        // Act: Set short timeout (300ms) to trigger escalation quickly
        bool success = await _guard.EnsureProcessesClosedAsync(
            new[] { "EXCEL" },
            timeout: TimeSpan.FromMilliseconds(300),
            forceKill: true);

        // Assert
        Assert.True(success);
        Assert.True(proc.CloseRequested);
        Assert.True(proc.KillRequested);
        Assert.False(_processRunner.IsProcessRunning("EXCEL"));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenForceKillIsDisabledAndProcessResists_ReturnsFalse()
    {
        // Arrange: Process resists graceful close and forceKill is disabled
        _processRunner.AddProcess(3003, "POWERPNT", "Presentation.pptx", exitsOnClose: false);
        var proc = _processRunner.SimulatedProcesses.First();

        // Act
        bool success = await _guard.EnsureProcessesClosedAsync(
            new[] { "POWERPNT" },
            timeout: TimeSpan.FromMilliseconds(300),
            forceKill: false);

        // Assert
        Assert.False(success);
        Assert.True(proc.CloseRequested);
        Assert.False(proc.KillRequested);
        Assert.True(_processRunner.IsProcessRunning("POWERPNT"));
    }

    [Fact]
    public async Task EnsureProcessesClosedAsync_WhenNoProcessesAreRunning_ReturnsTrueImmediately()
    {
        // Act
        bool success = await _guard.EnsureProcessesClosedAsync(
            ProcessLockGuard.OfficeProcessNames,
            timeout: TimeSpan.FromSeconds(5));

        // Assert
        Assert.True(success);
    }
}
