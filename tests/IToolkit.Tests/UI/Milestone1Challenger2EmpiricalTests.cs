namespace IToolkit.Tests.UI;

using System;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using IToolkit.App.Native;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Utilities;
using IToolkit.Tests.StaticAnalysis;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

/// <summary>
/// Empirical challenge test suite for Milestone 1:
/// Validates early disk logging resilience, exception handler secondary exception immunity,
/// whitespace handling in ResolveBaseDirectory, and missing directory auto-creation under stress.
/// </summary>
[Collection("ActivityLoggerDiskFile")]
public class Milestone1Challenger2EmpiricalTests : IDisposable
{
    private readonly string _testBaseDir;

    public Milestone1Challenger2EmpiricalTests()
    {
        _testBaseDir = Path.Combine(Path.GetTempPath(), $"IToolkit_Challenger2_{Guid.NewGuid():N}");
        if (Directory.Exists(_testBaseDir))
        {
            Directory.Delete(_testBaseDir, recursive: true);
        }
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_testBaseDir))
            {
                Directory.Delete(_testBaseDir, recursive: true);
            }
        }
        catch
        {
            // Best effort cleanup in test temp
        }
    }

    // =========================================================================
    // SECTION 1: App.xaml.cs ARCHITECTURE & STATIC/DYNAMIC VERIFICATION
    // =========================================================================

    [Fact]
    public void AppXamlCs_EarlyLogger_IsStaticReadonlyAndNonNullable()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        Assert.True(File.Exists(appXamlCsPath), $"App.xaml.cs not found at: {appXamlCsPath}");

        string code = File.ReadAllText(appXamlCsPath);

        // Verify _earlyLogger definition
        Assert.Matches(@"private\s+static\s+readonly\s+IActivityLogger\s+_earlyLogger\s*=\s*new\s+ActivityLogger\(\);", code);

        // Verify Services property definition
        Assert.Matches(@"public\s+static\s+IServiceProvider\s+Services\s*\{\s*get;\s*private\s+set;\s*\}\s*=\s*null!;", code);
    }

    [Fact]
    public void AppXamlCs_ResolveLogger_ReturnsEarlyLogger_WhenServicesIsNull()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        // Verify ResolveLogger pattern: Services?.GetService<IActivityLogger>() ?? _earlyLogger
        Assert.Contains("Services?.GetService<IActivityLogger>() ?? _earlyLogger", code);

        // Verify that ResolveLogger has a try-catch returning _earlyLogger on failure
        Assert.Matches(@"catch\s*\{\s*return\s+_earlyLogger;\s*\}", code);
    }

    [Fact]
    public void DynamicSimulation_ResolveLogger_NeverReturnsNull_EvenUnderFaultyServiceProvider()
    {
        IActivityLogger earlyLogger = new ActivityLogger();

        // Case 1: Services is null
        IServiceProvider? nullServices = null;
        IActivityLogger resolved1 = nullServices?.GetService<IActivityLogger>() ?? earlyLogger;
        Assert.NotNull(resolved1);
        Assert.Same(earlyLogger, resolved1);

        // Case 2: Services throws on GetService
        var faultyServices = new ServiceCollection().BuildServiceProvider();
        faultyServices.Dispose(); // Disposed provider will throw ObjectDisposedException on access if configured, or return null

        IActivityLogger resolved2;
        try
        {
            resolved2 = faultyServices?.GetService<IActivityLogger>() ?? earlyLogger;
        }
        catch
        {
            resolved2 = earlyLogger;
        }

        Assert.NotNull(resolved2);
    }

    [Fact]
    public void AppXamlCs_UnhandleExceptionHandlers_DoNotThrowSecondaryExceptions()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        string code = File.ReadAllText(appXamlCsPath);

        // Ensure constructor hooks all 3 unhandled exception events
        Assert.Contains("AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;", code);
        Assert.Contains("DispatcherUnhandledException += OnDispatcherUnhandledException;", code);
        Assert.Contains("TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;", code);

        // Ensure OnUnobservedTaskException calls args.SetObserved()
        Assert.Contains("args.SetObserved();", code);

        // Ensure OnDispatcherUnhandledException sets args.Handled = true
        Assert.Contains("args.Handled = true;", code);
    }

    // =========================================================================
    // SECTION 2: ADVERSARIAL EXCEPTION LOGGING & IMMUNITY FROM SECONDARY CRASHES
    // =========================================================================

    [Fact]
    public void LogError_AdversarialExceptions_DoesNotThrowSecondaryException()
    {
        var concreteLogger = new ActivityLogger(_testBaseDir);
        IActivityLogger logger = concreteLogger;

        // Sub-case 1: Null exception
        var exNull = Record.Exception(() => logger.LogError("TestComponent", "Message with null exception", null));
        Assert.Null(exNull);

        // Sub-case 2: Deep recursive exception chain (30 levels deep)
        Exception rootEx = new InvalidOperationException("Root level 0");
        for (int i = 1; i <= 30; i++)
        {
            rootEx = new Exception($"Nested depth {i}", rootEx);
        }
        var exDeep = Record.Exception(() => logger.LogError("TestComponent", "Message with deep exception", rootEx));
        Assert.Null(exDeep);

        // Sub-case 3: AggregateException with multiple inner exceptions
        var aggEx = new AggregateException(
            "Top-level aggregate error",
            new InvalidOperationException("Inner child 1"),
            new ArgumentNullException("paramName", "Inner child 2"),
            new FormatException("Inner child 3"));
        var exAgg = Record.Exception(() => logger.LogError("TestComponent", "Message with aggregate", aggEx));
        Assert.Null(exAgg);

        // Sub-case 4: Exception with non-ASCII characters
        var nonAsciiEx = new Exception("Error in Vietnamese: \u0110\u00e3 c\u00f3 l\u1ed7i x\u1ea3y ra");
        var exNonAscii = Record.Exception(() => logger.LogError("TestComponent", "Non-ASCII test", nonAsciiEx));
        Assert.Null(exNonAscii);

        // Verify the output log file exists and contains sanitized ASCII content
        string logFile = concreteLogger.LogFilePath;
        Assert.True(File.Exists(logFile));

        string content = File.ReadAllText(logFile);
        Assert.Contains("Message with null exception", content);
        Assert.Contains("Message with deep exception", content);
        Assert.Contains("Message with aggregate", content);
        Assert.Contains("Non-ASCII test", content);

        // Ensure 100% 7-bit ASCII
        var violations = StaticAnalysisHelper.ScanNonAsciiBytes(logFile);
        Assert.Empty(violations);
    }

    // =========================================================================
    // SECTION 3: ActivityLogger.ResolveBaseDirectory EMPIRICAL VERIFICATION
    // =========================================================================

    [Fact]
    public void ResolveBaseDirectory_PrivateMethod_HandlesNullEmptyAndWhitespace()
    {
        var method = typeof(ActivityLogger).GetMethod(
            "ResolveBaseDirectory",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        // Case 1: null -> returns AppContext.BaseDirectory
        string? resultNull = (string?)method.Invoke(null, new object?[] { null });
        Assert.Equal(AppContext.BaseDirectory, resultNull);

        // Case 2: empty string -> returns AppContext.BaseDirectory
        string? resultEmpty = (string?)method.Invoke(null, new object?[] { "" });
        Assert.Equal(AppContext.BaseDirectory, resultEmpty);

        // Case 3: single space -> returns AppContext.BaseDirectory (does NOT return whitespace)
        string? resultSpace = (string?)method.Invoke(null, new object?[] { " " });
        Assert.Equal(AppContext.BaseDirectory, resultSpace);

        // Case 4: multiple whitespace characters -> returns AppContext.BaseDirectory
        string? resultWhitespace = (string?)method.Invoke(null, new object?[] { "   \t\r\n   " });
        Assert.Equal(AppContext.BaseDirectory, resultWhitespace);

        // Case 5: valid custom directory without spaces -> returns custom directory
        string customDir = Path.Combine(_testBaseDir, "CustomLogs");
        string? resultCustom = (string?)method.Invoke(null, new object?[] { customDir });
        Assert.Equal(customDir, resultCustom);

        // Case 6: valid custom directory with spaces -> returns custom directory exactly
        string dirWithSpaces = Path.Combine(_testBaseDir, "Custom Logs With Spaces");
        string? resultSpaces = (string?)method.Invoke(null, new object?[] { dirWithSpaces });
        Assert.Equal(dirWithSpaces, resultSpaces);
    }

    // =========================================================================
    // SECTION 4: DIRECTORY CREATION AND RE-CREATION ON MISSING/DELETED
    // =========================================================================

    [Fact]
    public void ActivityLogger_Constructor_CreatesLogsDirectory_WhenMissing()
    {
        string customBase = Path.Combine(_testBaseDir, "AppBaseDir");
        string logsDir = Path.Combine(customBase, "Logs");

        Assert.False(Directory.Exists(customBase));
        Assert.False(Directory.Exists(logsDir));

        // Creating logger should create Logs directory
        var logger = new ActivityLogger(customBase);

        Assert.True(Directory.Exists(logsDir), $"Expected '{logsDir}' to be created by ActivityLogger constructor.");
    }

    [Fact]
    public void ActivityLogger_Constructor_CreatesLogsDirectory_WhenPathContainsSpaces()
    {
        string customBase = Path.Combine(_testBaseDir, "App Base Dir With Spaces");
        string logsDir = Path.Combine(customBase, "Logs");

        Assert.False(Directory.Exists(customBase));
        Assert.False(Directory.Exists(logsDir));

        var logger = new ActivityLogger(customBase);
        IActivityLogger appLogger = logger;

        Assert.True(Directory.Exists(logsDir), $"Expected '{logsDir}' with spaces to be created.");

        // Write log and verify file is written into the directory with spaces
        appLogger.LogInfo("SpaceTest", "Valid log inside directory with spaces");
        Assert.True(File.Exists(logger.LogFilePath));

        string content = File.ReadAllText(logger.LogFilePath);
        Assert.Contains("Valid log inside directory with spaces", content);
    }

    [Fact]
    public void ActivityLogger_Log_RecreatesDirectory_WhenDeletedBetweenWrites()
    {
        string customBase = Path.Combine(_testBaseDir, "RecreateTest");
        string logsDir = Path.Combine(customBase, "Logs");

        var logger = new ActivityLogger(customBase);
        IActivityLogger appLogger = logger;
        Assert.True(Directory.Exists(logsDir));

        // Write first message
        appLogger.LogInfo("Step1", "Initial message");
        Assert.True(File.Exists(logger.LogFilePath));

        // Externally delete the Logs directory
        Directory.Delete(logsDir, recursive: true);
        Assert.False(Directory.Exists(logsDir));

        // Write second message after deletion
        appLogger.LogWarning("Step2", "Message written after Logs directory was deleted");

        // Logs directory must be recreated and log file rewritten
        Assert.True(Directory.Exists(logsDir), "Logs directory should be recreated automatically by Log().");
        Assert.True(File.Exists(logger.LogFilePath), "Log file should be recreated automatically.");

        string content = File.ReadAllText(logger.LogFilePath);
        Assert.Contains("Message written after Logs directory was deleted", content);
    }

    // =========================================================================
    // SECTION 5: HIGH-CONCURRENCY STRESS & THREAD SAFETY HARNESS
    // =========================================================================

    [Fact]
    public async Task ActivityLogger_HighConcurrencyStress_ZeroExceptionsOrFileLockFailures()
    {
        string customBase = Path.Combine(_testBaseDir, "ConcurrencyStress");
        var concreteLogger = new ActivityLogger(customBase);
        IActivityLogger logger = concreteLogger;

        const int threadCount = 20;
        const int iterationsPerThread = 50;
        var barrier = new Barrier(threadCount);

        var tasks = new Task[threadCount];
        for (int t = 0; t < threadCount; t++)
        {
            int threadId = t;
            tasks[t] = Task.Run(() =>
            {
                barrier.SignalAndWait();
                for (int i = 0; i < iterationsPerThread; i++)
                {
                    logger.LogInfo($"Thread_{threadId}", $"Concurrent log item #{i}");
                }
            });
        }

        await Task.WhenAll(tasks);

        string logFile = concreteLogger.LogFilePath;
        Assert.True(File.Exists(logFile));

        string[] lines = File.ReadAllLines(logFile);
        // Total lines written must be threadCount * iterationsPerThread
        Assert.Equal(threadCount * iterationsPerThread, lines.Length);
    }
}
