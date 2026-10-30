namespace IToolkit.Tests.Services;

using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Tests.StaticAnalysis;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Empirical challenge test suite for Milestone 2 (Challenger 2):
/// 1. Verifies WpfDialogService and MockDialogService when _logger is null: zero NullReferenceException across all methods.
/// 2. Verifies exception handling in OpenFolderInExplorer: logs exception and returns false cleanly.
/// 3. Verifies App.xaml.cs dialog log entries: all startup and crash dialogs log strictly under component "DialogService".
/// 4. Stress tests high-concurrency invocation and verifies zero un-guarded logger dereferences.
/// </summary>
public class Milestone2Challenger2EmpiricalTests
{
    private static Type? GetWpfDialogServiceType()
    {
        try
        {
            string repoRoot = StaticAnalysisHelper.GetRepoRoot();
            string appAssemblyPath = Path.Combine(
                repoRoot, "src", "IToolkit.App", "bin", "Release", "net10.0-windows", "win-x64", "iToolKit.dll");

            if (!File.Exists(appAssemblyPath))
            {
                appAssemblyPath = Path.Combine(
                    repoRoot, "src", "IToolkit.App", "bin", "Debug", "net10.0-windows", "win-x64", "iToolKit.dll");
            }

            if (!File.Exists(appAssemblyPath))
            {
                return null;
            }

            var assembly = Assembly.LoadFrom(appAssemblyPath);
            return assembly.GetType("IToolkit.App.Services.WpfDialogService");
        }
        catch (BadImageFormatException)
        {
            // Handled when running on architecture different from win-x64 (e.g. Linux aarch64)
            return null;
        }
        catch (FileLoadException)
        {
            // Handled when assembly architecture is incompatible with current process architecture
            return null;
        }
    }

    // =========================================================================
    // 1. WpfDialogService NULL LOGGER & CONSTRUCTOR VERIFICATION
    // =========================================================================

    [Fact]
    public void WpfDialogService_ParameterlessConstructor_InstantiatesSuccessfullyWithNullLogger()
    {
        var type = GetWpfDialogServiceType();
        if (type == null)
        {
            // In cross-architecture environments (aarch64 Linux), verify via static code analysis
            VerifyWpfDialogServiceConstructorsStatically();
            return;
        }

        var instance = Activator.CreateInstance(type);
        Assert.NotNull(instance);

        var loggerField = type.GetField("_logger", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(loggerField);
        Assert.Null(loggerField.GetValue(instance));
    }

    [Fact]
    public void WpfDialogService_ExplicitNullLoggerConstructor_InstantiatesSuccessfully()
    {
        var type = GetWpfDialogServiceType();
        if (type == null)
        {
            VerifyWpfDialogServiceConstructorsStatically();
            return;
        }

        var ctor = type.GetConstructor(new[] { typeof(IActivityLogger) });
        Assert.NotNull(ctor);

        var instance = ctor.Invoke(new object?[] { null });
        Assert.NotNull(instance);

        var loggerField = type.GetField("_logger", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(loggerField);
        Assert.Null(loggerField.GetValue(instance));
    }

    [Fact]
    public void WpfDialogService_NullLogger_OpenFolderInExplorer_AllEdgeCasesReturnFalseWithoutNre()
    {
        var type = GetWpfDialogServiceType();
        if (type == null)
        {
            VerifyWpfDialogServiceNullSafetyStatically();
            return;
        }

        var instance = Activator.CreateInstance(type);
        Assert.NotNull(instance);

        var method = type.GetMethod("OpenFolderInExplorer", new[] { typeof(string) });
        Assert.NotNull(method);

        // Case 1: Null string
        object? nullResult = method.Invoke(instance, new object?[] { null });
        Assert.Equal(false, nullResult);

        // Case 2: Empty string
        object? emptyResult = method.Invoke(instance, new object?[] { string.Empty });
        Assert.Equal(false, emptyResult);

        // Case 3: Whitespace string
        object? whitespaceResult = method.Invoke(instance, new object?[] { "   \t\r\n   " });
        Assert.Equal(false, whitespaceResult);

        // Case 4: Non-existent directory
        string nonExistentDir = Path.Combine(Path.GetTempPath(), $"IToolkit_NonExistentDir_{Guid.NewGuid():N}");
        object? nonExistentDirResult = method.Invoke(instance, new object?[] { nonExistentDir });
        Assert.Equal(false, nonExistentDirResult);

        // Case 5: Non-existent file
        string nonExistentFile = Path.Combine(Path.GetTempPath(), $"IToolkit_NonExistentFile_{Guid.NewGuid():N}.txt");
        object? nonExistentFileResult = method.Invoke(instance, new object?[] { nonExistentFile });
        Assert.Equal(false, nonExistentFileResult);

        // Case 6: Invalid path characters
        object? invalidCharsResult = method.Invoke(instance, new object?[] { @"C:\Invalid|Path*?<>Chars" });
        Assert.Equal(false, invalidCharsResult);

        // Case 7: Null byte in path
        object? nullByteResult = method.Invoke(instance, new object?[] { "C:\\Invalid\0Path" });
        Assert.Equal(false, nullByteResult);

        // Case 8: Long path exceeding MAX_PATH
        string longPath = @"C:\" + new string('b', 360);
        object? longPathResult = method.Invoke(instance, new object?[] { longPath });
        Assert.Equal(false, longPathResult);

        // Case 9: Existing directory (triggers Process.Start catch block in non-Windows environment)
        if (!OperatingSystem.IsWindows())
        {
            string existingTempDir = Path.GetTempPath();
            object? existingDirResult = method.Invoke(instance, new object?[] { existingTempDir });
            Assert.Equal(false, existingDirResult);
        }
    }

    [Fact]
    public void WpfDialogService_OpenFolderInExplorer_LogsExceptionAndReturnsFalseCleanly()
    {
        var type = GetWpfDialogServiceType();
        if (type == null || OperatingSystem.IsWindows())
        {
            VerifyWpfDialogServiceExceptionHandlingStatically();
            return;
        }

        var testLogger = new TestActivityLogger();
        var ctor = type.GetConstructor(new[] { typeof(IActivityLogger) });
        Assert.NotNull(ctor);

        var instance = ctor.Invoke(new object?[] { testLogger });
        Assert.NotNull(instance);

        var method = type.GetMethod("OpenFolderInExplorer", new[] { typeof(string) });
        Assert.NotNull(method);

        string existingTempDir = Path.GetTempPath();
        object? result = method.Invoke(instance, new object?[] { existingTempDir });

        Assert.Equal(false, result);

        var entries = testLogger.CapturedEntries;
        Assert.NotEmpty(entries);

        var infoEntry = entries.FirstOrDefault(e => e.Level == LogLevel.Info && e.Component == "DialogService");
        Assert.NotNull(infoEntry);
        Assert.Contains("Launching Windows Explorer for folder", infoEntry.Message);

        var errorEntry = entries.FirstOrDefault(e => e.Level == LogLevel.Error && e.Component == "DialogService");
        Assert.NotNull(errorEntry);
        Assert.Contains("Failed to launch Windows Explorer for folder", errorEntry.Message);
        Assert.Contains("Exception:", errorEntry.Message);
    }

    // Static verification helpers for cross-platform compliance
    private static void VerifyWpfDialogServiceConstructorsStatically()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string path = Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs");
        string code = File.ReadAllText(path);

        Assert.Contains("public WpfDialogService() : this(null)", code);
        Assert.Contains("public WpfDialogService(IActivityLogger? logger = null)", code);
        Assert.Contains("_logger = logger;", code);
    }

    private static void VerifyWpfDialogServiceNullSafetyStatically()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string path = Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs");
        string[] lines = File.ReadAllLines(path);

        int loggerCallCount = 0;
        foreach (string line in lines)
        {
            string trimmed = line.Trim();
            if (trimmed.StartsWith("//") || trimmed.StartsWith("/*") || trimmed.StartsWith("*"))
            {
                continue;
            }

            if (trimmed.Contains("_logger") && !trimmed.Contains("private readonly") && !trimmed.Contains("_logger ="))
            {
                Assert.Contains("_logger?.", trimmed);
                loggerCallCount++;
            }
        }

        // Verify there are multiple logger calls and every single one uses null-conditional dereference
        Assert.True(loggerCallCount >= 10, $"Expected >= 10 logger calls in WpfDialogService.cs, found {loggerCallCount}");
    }

    private static void VerifyWpfDialogServiceExceptionHandlingStatically()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string path = Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs");
        string code = File.ReadAllText(path);

        // Verify OpenFolderInExplorer method structure
        Assert.Contains("public bool OpenFolderInExplorer(string folderPath)", code);
        Assert.Contains("_logger?.LogWarning(\"DialogService\", \"OpenFolderInExplorer called with null or empty path.\");", code);
        Assert.Contains("return false;", code);
        Assert.Contains("_logger?.LogWarning(\"DialogService\", $\"Directory does not exist for Explorer launch: '{folderPath}'.\");", code);
        Assert.Contains("_logger?.LogInfo(\"DialogService\", $\"Launching Windows Explorer for folder: '{folderPath}'.\");", code);

        // Verify try-catch block captures Exception ex, logs under "DialogService", and returns false
        Assert.Contains("catch (Exception ex)", code);
        Assert.Contains("_logger?.LogError(\"DialogService\", $\"Failed to launch Windows Explorer for folder '{folderPath}'\", ex);", code);
    }

    // =========================================================================
    // 2. MockDialogService NULL LOGGER RESILIENCE
    // =========================================================================

    [Fact]
    public void MockDialogService_NullLogger_ParameterlessConstructor_AllMethodsExecuteWithZeroNre()
    {
        var mock = new MockDialogService();

        // 1. ShowOpenFileDialog
        string? open1 = mock.ShowOpenFileDialog("Open Title", "Text (*.txt)|*.txt", @"C:\default");
        Assert.Null(open1);

        mock.SelectedOpenFilePath = @"C:\selected\file.txt";
        string? open2 = mock.ShowOpenFileDialog("Open Title", "Text (*.txt)|*.txt", @"C:\default");
        Assert.Equal(@"C:\selected\file.txt", open2);

        // 2. ShowSaveFileDialog
        string? save1 = mock.ShowSaveFileDialog("Save Title", "Text (*.txt)|*.txt", "default.txt", @"C:\default");
        Assert.Null(save1);

        mock.SelectedSaveFilePath = @"C:\saved\file.txt";
        string? save2 = mock.ShowSaveFileDialog("Save Title", "Text (*.txt)|*.txt", "default.txt", @"C:\default");
        Assert.Equal(@"C:\saved\file.txt", save2);

        // 3. ShowOpenFolderDialog
        string? folder1 = mock.ShowOpenFolderDialog("Folder Title", @"C:\default");
        Assert.Null(folder1);

        mock.SelectedFolderPath = @"C:\selected\folder";
        string? folder2 = mock.ShowOpenFolderDialog("Folder Title", @"C:\default");
        Assert.Equal(@"C:\selected\folder", folder2);

        // 4. OpenFolderInExplorer
        bool expNull = mock.OpenFolderInExplorer(null!);
        Assert.True(expNull);

        bool expEmpty = mock.OpenFolderInExplorer(string.Empty);
        Assert.True(expEmpty);

        bool expValid = mock.OpenFolderInExplorer(@"C:\Windows");
        Assert.True(expValid);

        // 5. Confirm sync
        mock.ConfirmationResult = true;
        bool confirmTrue = mock.Confirm("Title", "Message", "Warning");
        Assert.True(confirmTrue);

        mock.ConfirmationResult = false;
        bool confirmFalse = mock.Confirm("Title", "Message", "Warning");
        Assert.False(confirmFalse);

        // 6. Reset
        mock.Reset();
        Assert.Equal(0, mock.ConfirmCallCount);
        Assert.Equal(0, mock.OpenFolderInExplorerCallCount);
        Assert.Empty(mock.OpenedInExplorerPaths);
        Assert.Empty(mock.ConfirmationRequests);
    }

    [Fact]
    public async Task MockDialogService_NullLogger_ExplicitConstructor_AsyncMethodsExecuteWithZeroNre()
    {
        var mock = new MockDialogService(null);

        mock.ConfirmationResult = true;
        bool resultTrue = await mock.ConfirmAsync("Async Title", "Async Message", "Async Warning");
        Assert.True(resultTrue);

        mock.ConfirmationResult = false;
        bool resultFalse = await mock.ConfirmAsync("Async Title", "Async Message", "Async Warning");
        Assert.False(resultFalse);

        Assert.Equal(2, mock.ConfirmAsyncCallCount);
        Assert.Equal(2, mock.ConfirmCallCount);
    }

    // =========================================================================
    // 3. MockDialogService ACTIVE LOGGER COMPONENT TAGGING
    // =========================================================================

    [Fact]
    public async Task MockDialogService_ActiveLogger_LogsUnderStrictComponentTags()
    {
        var logger = new TestActivityLogger();
        var mock = new MockDialogService(logger);

        // File pickers -> DialogService
        mock.SelectedOpenFilePath = @"C:\open.txt";
        mock.ShowOpenFileDialog("Open", "*.txt");

        mock.SelectedSaveFilePath = null;
        mock.ShowSaveFileDialog("Save", "*.txt");

        mock.SelectedFolderPath = @"C:\folder";
        mock.ShowOpenFolderDialog("Folder");

        // Explorer -> DialogService
        mock.OpenFolderInExplorer(null!);
        mock.OpenFolderInExplorer(@"C:\folder");

        // Safety confirmations -> SafetyConfirmation
        mock.ConfirmationResult = true;
        mock.Confirm("Safety 1", "Proceed?", "High risk");

        mock.ConfirmationResult = false;
        await mock.ConfirmAsync("Safety 2", "Delete?", "Extreme risk");

        var entries = logger.CapturedEntries;
        Assert.True(entries.Count >= 9);

        // All picker and explorer entries must have Component == "DialogService"
        var dialogEntries = entries.Where(e => e.Component == "DialogService").ToList();
        Assert.Contains(dialogEntries, e => e.Message.Contains("Showing OpenFileDialog"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("OpenFileDialog selected"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("Showing SaveFileDialog"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("SaveFileDialog cancelled by user"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("Showing OpenFolderDialog"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("OpenFolderDialog selected"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("OpenFolderInExplorer called with null or empty path"));
        Assert.Contains(dialogEntries, e => e.Message.Contains("Launching Windows Explorer for folder"));

        // All confirmation entries must have Component == "SafetyConfirmation"
        var safetyEntries = entries.Where(e => e.Component == "SafetyConfirmation").ToList();
        Assert.Contains(safetyEntries, e => e.Message.Contains("Safety confirmation prompt displayed: 'Safety 1'"));
        Assert.Contains(safetyEntries, e => e.Message.Contains("result: Confirmed (Yes)"));
        Assert.Contains(safetyEntries, e => e.Message.Contains("Safety confirmation prompt displayed: 'Safety 2'"));
        Assert.Contains(safetyEntries, e => e.Message.Contains("result: Dismissed (No)"));

        // Ensure NO entry has any component other than "DialogService" or "SafetyConfirmation"
        Assert.All(entries, e => Assert.True(
            e.Component == "DialogService" || e.Component == "SafetyConfirmation",
            $"Unexpected component tag '{e.Component}' on message '{e.Message}'."));
    }

    // =========================================================================
    // 4. App.xaml.cs DIALOG LOG ENTRIES (TASK 3 EMPIRICAL STATIC VERIFICATION)
    // =========================================================================

    [Fact]
    public void AppXamlCs_DispatcherUnhandledException_LogsDialogsUnderDialogService()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        // Verify pre-dialog logging under "DialogService"
        Assert.Contains("logger.LogError(\"DialogService\", \"Displayed unhandled exception error dialog.\", args.Exception);", code);

        // Verify post-dialog dismissal logging under "DialogService"
        Assert.Contains("logger.LogInfo(\"DialogService\", \"User dismissed unhandled exception error dialog: [iToolKit Error] Result=OK\");", code);
    }

    [Fact]
    public void AppXamlCs_StartupElevationFailure_LogsDialogsUnderDialogService()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        // Verify pre-dialog warning under "DialogService"
        Assert.Contains("appLogger.LogWarning(\"DialogService\", \"Displayed elevation required dialog prompt.\");", code);

        // Verify post-dialog dismissal under "DialogService"
        Assert.Contains("appLogger.LogInfo(\"DialogService\", \"User dismissed elevation required dialog prompt: [iToolKit Error] Result=OK\");", code);
    }

    [Fact]
    public void AppXamlCs_StartupFatalException_LogsDialogsUnderDialogService()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        // Verify pre-dialog error under "DialogService"
        Assert.Contains("logger.LogError(\"DialogService\", \"Displayed fatal startup error dialog.\", ex);", code);

        // Verify post-dialog dismissal under "DialogService"
        Assert.Contains("logger.LogInfo(\"DialogService\", \"User dismissed fatal startup error dialog: [iToolKit Error] Result=OK\");", code);
    }

    [Fact]
    public void AppXamlCs_AllMessageBoxInvocations_ArePairedWithDialogServiceLogging()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        int messageBoxCount = code.Split("MessageBox.Show(").Length - 1;
        Assert.Equal(3, messageBoxCount);

        int dialogServiceCount = code.Split("\"DialogService\"").Length - 1;
        // Each of the 3 MessageBox calls has a pre-prompt log and a post-dismissal log = 6 occurrences
        Assert.Equal(6, dialogServiceCount);
    }

    // =========================================================================
    // 5. SOURCE CODE INTEGRITY: ZERO UNGUARDED LOGGER DEREFERENCES
    // =========================================================================

    [Fact]
    public void WpfDialogService_SourceCode_HasZeroUnguardedLoggerDereferences()
    {
        VerifyWpfDialogServiceNullSafetyStatically();
    }

    [Fact]
    public void MockDialogService_SourceCode_HasZeroUnguardedLoggerDereferences()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string filePath = Path.Combine(repoRoot, "tests", "IToolkit.Tests", "TestDoubles", "MockDialogService.cs");
        string[] lines = File.ReadAllLines(filePath);

        int count = 0;
        foreach (string line in lines)
        {
            string trimmed = line.Trim();
            if (trimmed.StartsWith("//") || trimmed.StartsWith("/*") || trimmed.StartsWith("*"))
            {
                continue;
            }

            if (trimmed.Contains("_logger") && !trimmed.Contains("private readonly") && !trimmed.Contains("_logger ="))
            {
                Assert.Contains("_logger?.", trimmed);
                count++;
            }
        }
        Assert.True(count >= 8, $"Expected >= 8 logger calls in MockDialogService.cs, found {count}");
    }

    // =========================================================================
    // 6. HIGH CONCURRENCY STRESS & THREAD-SAFETY
    // =========================================================================

    [Fact]
    public async Task MockDialogService_HighConcurrencyStress_ZeroExceptionsAcrossMixedOperations()
    {
        var testLogger = new TestActivityLogger();
        var mock = new MockDialogService(testLogger);

        const int workerCount = 20;
        const int iterationsPerWorker = 50;
        var exceptions = new ConcurrentBag<Exception>();

        var tasks = Enumerable.Range(0, workerCount).Select(workerId => Task.Run(async () =>
        {
            try
            {
                for (int i = 0; i < iterationsPerWorker; i++)
                {
                    if (i % 5 == 0)
                    {
                        mock.ShowOpenFileDialog($"Title_{workerId}_{i}", "*.txt");
                    }
                    else if (i % 5 == 1)
                    {
                        mock.ShowSaveFileDialog($"Save_{workerId}_{i}", "*.json");
                    }
                    else if (i % 5 == 2)
                    {
                        mock.ShowOpenFolderDialog($"Folder_{workerId}_{i}");
                    }
                    else if (i % 5 == 3)
                    {
                        mock.OpenFolderInExplorer(i % 2 == 0 ? $"C:\\Path_{workerId}_{i}" : string.Empty);
                    }
                    else
                    {
                        await mock.ConfirmAsync($"Confirm_{workerId}_{i}", "Test message", "Test warning");
                    }
                }
            }
            catch (Exception ex)
            {
                exceptions.Add(ex);
            }
        })).ToArray();

        await Task.WhenAll(tasks);

        Assert.Empty(exceptions);
        // Verify logger captured all concurrent calls safely
        Assert.True(testLogger.CapturedEntries.Count > 0);
    }
}
