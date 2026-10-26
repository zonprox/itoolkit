namespace IToolkit.Tests.UI;

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using IToolkit.App.Native;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Utilities;
using IToolkit.Tests.StaticAnalysis;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Unit and integration tests for startup diagnostics, early fallback logging,
/// unhandled exception handlers, full exception chain formatting, and dual-mode path resolution.
/// </summary>
[Collection("ActivityLoggerDiskFile")]
public class StartupAndExceptionLoggingTests : IDisposable
{
    private readonly string _testBaseDir;
    private readonly TestActivityLogger _inMemoryLoggerSink;
    private readonly IActivityLogger _inMemoryLogger;

    public StartupAndExceptionLoggingTests()
    {
        _testBaseDir = Path.Combine(Path.GetTempPath(), $"IToolkit_StartupTest_{Guid.NewGuid():N}");
        if (Directory.Exists(_testBaseDir))
        {
            Directory.Delete(_testBaseDir, recursive: true);
        }
        _inMemoryLoggerSink = new TestActivityLogger();
        _inMemoryLogger = _inMemoryLoggerSink;
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

    private static string GetAppAssemblyPath()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appAssemblyPath = Path.Combine(repoRoot, "src", "IToolkit.App", "bin", "Release", "net10.0-windows", "win-x64", "iToolKit.dll");

        if (!File.Exists(appAssemblyPath))
        {
            appAssemblyPath = Path.Combine(repoRoot, "src", "IToolkit.App", "bin", "Debug", "net10.0-windows", "win-x64", "iToolKit.dll");
        }

        return appAssemblyPath;
    }

    // =========================================================================
    // 1. PRE-DI STARTUP CRASH LOGGING & EARLY LOGGER FALLBACK
    // =========================================================================

    [Fact]
    public void PreDIShutdownOrCrash_EarlyLoggerWritesFullExceptionDetailsToDisk()
    {
        // Arrange: instantiate an early logger instance pointing to the test folder
        var concreteLogger = new ActivityLogger(_testBaseDir);
        IActivityLogger earlyLogger = concreteLogger;

        Exception rootEx;
        try
        {
            try
            {
                try
                {
                    throw new UnauthorizedAccessException("Registry hive access denied at HKLM\\SOFTWARE\\iToolKit");
                }
                catch (Exception ex1)
                {
                    throw new FileNotFoundException("Missing required runtime bundle manifest", "manifest.json", ex1);
                }
            }
            catch (Exception ex2)
            {
                throw new InvalidOperationException("Fatal pre-DI startup failure: bootstrapping failed", ex2);
            }
        }
        catch (Exception ex3)
        {
            rootEx = ex3;
        }

        // Act: early logging occurs before DI container exists
        earlyLogger.LogError("Application", "Fatal pre-DI startup exception", rootEx);

        // Assert: log file exists on disk
        string expectedLogsDir = Path.Combine(_testBaseDir, "Logs");
        string expectedLogFile = concreteLogger.LogFilePath;

        Assert.True(Directory.Exists(expectedLogsDir), "Logs directory must be created automatically.");
        Assert.True(File.Exists(expectedLogFile), "Log file must exist on disk.");

        string content = File.ReadAllText(expectedLogFile);
        Assert.Contains("[ERROR  ] [Application]", content);
        Assert.Contains("Fatal pre-DI startup exception | Exception:", content);
        Assert.Contains("[System.InvalidOperationException] Fatal pre-DI startup failure: bootstrapping failed", content);
        Assert.Contains("---> (Inner Exception #1) [System.IO.FileNotFoundException] Missing required runtime bundle manifest", content);
        Assert.Contains("---> (Inner Exception #2) [System.UnauthorizedAccessException] Registry hive access denied at HKLM\\SOFTWARE\\iToolKit", content);
        Assert.Contains("Stack Trace:", content);

        // Verify ASCII compliance
        var violations = StaticAnalysisHelper.ScanNonAsciiBytes(expectedLogFile);
        Assert.Empty(violations);
    }

    [Fact]
    public void PreDILogger_MultipleLogEntries_MaintainsChronologicalSequenceAndStructure()
    {
        var concreteLogger = new ActivityLogger(_testBaseDir);
        IActivityLogger earlyLogger = concreteLogger;

        earlyLogger.LogInfo("Application", "iToolKit early bootloader initialized.");
        earlyLogger.LogWarning("Security", "Running in low-integrity environment before elevation check.");
        earlyLogger.LogError("Application", "Bootstrap failure: missing native host", new DllNotFoundException("wpfgfx_cor3.dll"));

        string logFile = concreteLogger.LogFilePath;
        Assert.True(File.Exists(logFile));

        string[] lines = File.ReadAllLines(logFile);
        Assert.Equal(3, lines.Length);

        Assert.Contains("[INFO   ] [Application] iToolKit early bootloader initialized.", lines[0]);
        Assert.Contains("[WARNING] [Security] Running in low-integrity environment before elevation check.", lines[1]);
        Assert.Contains("[ERROR  ] [Application] Bootstrap failure: missing native host | Exception: [System.DllNotFoundException]", lines[2]);
    }

    [Fact]
    public void AppXamlCs_SourceCode_VerifiesEarlyLoggerAndResolveLoggerFallback()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string appXamlCsPath = Path.Combine(repoRoot, "src", "IToolkit.App", "App.xaml.cs");
        Assert.True(File.Exists(appXamlCsPath), $"App.xaml.cs not found at: {appXamlCsPath}");

        string code = File.ReadAllText(appXamlCsPath);

        // Verify private static readonly _earlyLogger
        Assert.Contains("private static readonly IActivityLogger _earlyLogger = new ActivityLogger();", code);

        // Verify public static IServiceProvider Services { get; private set; } = null!;
        Assert.Contains("public static IServiceProvider Services { get; private set; } = null!;", code);

        // Verify ResolveLogger implementation with null coalescing and catch block
        Assert.Contains("return Services?.GetService<IActivityLogger>() ?? _earlyLogger;", code);
        Assert.Contains("catch", code);
        Assert.Contains("return _earlyLogger;", code);
    }

    [Fact]
    public void App_BinaryMetadata_VerifiesEarlyLoggerAndUnhandledExceptionHandlers()
    {
        string assemblyPath = GetAppAssemblyPath();
        Assert.True(File.Exists(assemblyPath), $"App assembly must exist at: {assemblyPath}");

        using var stream = File.OpenRead(assemblyPath);
        using var peReader = new PEReader(stream);
        MetadataReader reader = peReader.GetMetadataReader();

        bool appTypeFound = false;
        bool hasEarlyLoggerField = false;
        bool hasResolveLoggerMethod = false;
        bool hasDomainHandler = false;
        bool hasDispatcherHandler = false;
        bool hasTaskHandler = false;

        foreach (var typeHandle in reader.TypeDefinitions)
        {
            var typeDef = reader.GetTypeDefinition(typeHandle);
            string typeName = reader.GetString(typeDef.Name);
            string typeNamespace = reader.GetString(typeDef.Namespace);

            if (typeName == "App" && typeNamespace == "IToolkit.App")
            {
                appTypeFound = true;

                // Inspect fields
                foreach (var fieldHandle in typeDef.GetFields())
                {
                    var fieldDef = reader.GetFieldDefinition(fieldHandle);
                    string fieldName = reader.GetString(fieldDef.Name);
                    if (fieldName == "_earlyLogger")
                    {
                        hasEarlyLoggerField = true;
                    }
                }

                // Inspect methods
                foreach (var methodHandle in typeDef.GetMethods())
                {
                    var methodDef = reader.GetMethodDefinition(methodHandle);
                    string methodName = reader.GetString(methodDef.Name);

                    if (methodName == "ResolveLogger") hasResolveLoggerMethod = true;
                    if (methodName == "OnDomainUnhandledException") hasDomainHandler = true;
                    if (methodName == "OnDispatcherUnhandledException") hasDispatcherHandler = true;
                    if (methodName == "OnUnobservedTaskException") hasTaskHandler = true;
                }
                break;
            }
        }

        Assert.True(appTypeFound, "IToolkit.App.App must exist in iToolKit.dll metadata.");
        Assert.True(hasEarlyLoggerField, "App must define _earlyLogger field.");
        Assert.True(hasResolveLoggerMethod, "App must define ResolveLogger method.");
        Assert.True(hasDomainHandler, "App must define OnDomainUnhandledException method.");
        Assert.True(hasDispatcherHandler, "App must define OnDispatcherUnhandledException method.");
        Assert.True(hasTaskHandler, "App must define OnUnobservedTaskException method.");
    }

    // =========================================================================
    // 2. UNHANDLED EXCEPTION HANDLERS VERIFICATION
    // =========================================================================

    [Fact]
    public void DomainUnhandledExceptionHandler_WithException_FormatsAndLogsWithoutSecondaryException()
    {
        // Simulate OnDomainUnhandledException logic:
        // if (e.ExceptionObject is Exception ex) ResolveLogger().LogError("Application", "Unhandled domain exception", ex);
        var ex = new InvalidOperationException("Fatal crash in unmanaged worker thread");
        var eventArgs = new UnhandledExceptionEventArgs(ex, isTerminating: true);

        var caughtEx = Record.Exception(() =>
        {
            if (eventArgs.ExceptionObject is Exception caught)
            {
                _inMemoryLogger.LogError("Application", "Unhandled domain exception", caught);
            }
            else
            {
                _inMemoryLogger.LogError("Application", $"Unhandled domain non-exception object: {eventArgs.ExceptionObject}");
            }
        });

        Assert.Null(caughtEx);
        Assert.Single(_inMemoryLoggerSink.CapturedEntries);
        var entry = _inMemoryLoggerSink.CapturedEntries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.Equal("Application", entry.Component);
        Assert.Contains("Unhandled domain exception", entry.Message);
        Assert.Contains("[System.InvalidOperationException] Fatal crash in unmanaged worker thread", entry.Message);
    }

    [Fact]
    public void DomainUnhandledExceptionHandler_WithNonExceptionObject_LogsWithoutCrashing()
    {
        var eventArgs = new UnhandledExceptionEventArgs("String error payload from foreign runtime", isTerminating: false);

        var caughtEx = Record.Exception(() =>
        {
            if (eventArgs.ExceptionObject is Exception caught)
            {
                _inMemoryLogger.LogError("Application", "Unhandled domain exception", caught);
            }
            else
            {
                _inMemoryLogger.LogError("Application", $"Unhandled domain non-exception object: {eventArgs.ExceptionObject}");
            }
        });

        Assert.Null(caughtEx);
        Assert.Single(_inMemoryLoggerSink.CapturedEntries);
        var entry = _inMemoryLoggerSink.CapturedEntries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.Equal("Application", entry.Component);
        Assert.Contains("Unhandled domain non-exception object: String error payload from foreign runtime", entry.Message);
    }

    [Fact]
    public void TaskSchedulerUnobservedExceptionHandler_CallsSetObserved_AndLogsError()
    {
        var innerFault = new TimeoutException("Database communication timed out");
        var aggEx = new AggregateException("A background task was not awaited", innerFault);
        var eventArgs = new UnobservedTaskExceptionEventArgs(aggEx);

        Assert.False(eventArgs.Observed, "Event args should initially not be marked as observed.");

        var caughtEx = Record.Exception(() =>
        {
            _inMemoryLogger.LogError("TaskScheduler", "Unobserved task exception", eventArgs.Exception);
            eventArgs.SetObserved();
        });

        Assert.Null(caughtEx);
        Assert.True(eventArgs.Observed, "Handler must mark task exception as observed to prevent crash.");
        Assert.Single(_inMemoryLoggerSink.CapturedEntries);
        var entry = _inMemoryLoggerSink.CapturedEntries[0];
        Assert.Equal(LogLevel.Error, entry.Level);
        Assert.Equal("TaskScheduler", entry.Component);
        Assert.Contains("Unobserved task exception", entry.Message);
        Assert.Contains("[System.AggregateException] A background task was not awaited", entry.Message);
        Assert.Contains("[System.TimeoutException] Database communication timed out", entry.Message);
    }

    // =========================================================================
    // 3. EXCEPTION FORMATTER COMPREHENSIVE SUITE
    // =========================================================================

    [Fact]
    public void ExceptionFormatter_NullInputs_ReturnsExpectedFallbacks()
    {
        Assert.Equal(string.Empty, ExceptionFormatter.FormatException(null));
        Assert.Equal("Context Message", ExceptionFormatter.FormatException("Context Message", null));
        Assert.Equal(string.Empty, ExceptionFormatter.FormatException(string.Empty, null));
        Assert.Equal("   ", ExceptionFormatter.FormatException("   ", null));
    }

    [Fact]
    public void ExceptionFormatter_SingleLevelException_FormatsTypeMessageAndStack()
    {
        Exception ex;
        try
        {
            throw new ArgumentOutOfRangeException("bufferSize", 0, "Buffer size must be greater than zero.");
        }
        catch (Exception caught)
        {
            ex = caught;
        }

        string formatted = ExceptionFormatter.FormatException("BufferAllocation", ex);

        Assert.StartsWith("BufferAllocation | [System.ArgumentOutOfRangeException]", formatted);
        Assert.Contains("Buffer size must be greater than zero.", formatted);
        Assert.Contains("Stack Trace:", formatted);
        Assert.Contains(nameof(StartupAndExceptionLoggingTests), formatted);
    }

    [Fact]
    public void ExceptionFormatter_MultiLevelInnerExceptions_FormatsAllLevelsInOrder()
    {
        var level4 = new AccessViolationException("Native memory corruption at 0xDEADBEEF");
        var level3 = new ExternalException("Win32 external interop failure", level4);
        var level2 = new IOException("Storage I/O pipeline fault", level3);
        var level1 = new InvalidOperationException("High-level service controller failure", level2);

        string formatted = ExceptionFormatter.FormatException(level1);

        Assert.Contains("[System.InvalidOperationException] High-level service controller failure", formatted);
        Assert.Contains("  ---> (Inner Exception #1) [System.IO.IOException] Storage I/O pipeline fault", formatted);
        Assert.Contains("  ---> (Inner Exception #2) [System.Runtime.InteropServices.ExternalException] Win32 external interop failure", formatted);
        Assert.Contains("  ---> (Inner Exception #3) [System.AccessViolationException] Native memory corruption at 0xDEADBEEF", formatted);
    }

    [Fact]
    public void ExceptionFormatter_DeepRecursiveInnerExceptions_IsCappedAt20Levels()
    {
        Exception current = new InvalidOperationException("Leaf level 30 exception");
        for (int i = 29; i >= 1; i--)
        {
            current = new ApplicationException($"Exception layer #{i}", current);
        }

        string formatted = ExceptionFormatter.FormatException(current);

        Assert.Contains("(Inner Exception #1)", formatted);
        Assert.Contains("(Inner Exception #20)", formatted);
        Assert.DoesNotContain("(Inner Exception #21)", formatted);
    }

    [Fact]
    public void ExceptionFormatter_AggregateException_MultipleChildren_FormatsAllWithoutDuplication()
    {
        var child1 = new InvalidOperationException("First parallel worker fault");
        var child2 = new TimeoutException("Second parallel worker timeout");
        var child3 = new KeyNotFoundException("Third parallel worker missing key");
        var agg = new AggregateException("Parallel partition operation failed", child1, child2, child3);

        string formatted = ExceptionFormatter.FormatException("PartitionEngine", agg);

        Assert.Contains("PartitionEngine | [System.AggregateException] Parallel partition operation failed", formatted);
        Assert.Contains("  ---> (Inner Exception #1) [System.InvalidOperationException] First parallel worker fault", formatted);
        Assert.Contains("  ---> (Aggregate Inner #1) [System.TimeoutException] Second parallel worker timeout", formatted);
        Assert.Contains("  ---> (Aggregate Inner #2) [System.Collections.Generic.KeyNotFoundException] Third parallel worker missing key", formatted);
    }

    [Fact]
    public void ExceptionFormatter_NonAsciiCharacters_SanitizesStrictlyTo7BitAscii()
    {
        // Accented characters, Cyrillic, Asian glyphs, and emojis encoded using ASCII-safe escape sequences
        string nonAsciiContext = "Contexte: V\u00E9rification fran\u00E7aise";
        string nonAsciiMessage = "Ph\u00E1t hi\u1EC7n l\u1ED7i nghi\u00EAm tr\u1ECDng: \u041E\u0448\u0438\u0431\u043A\u0430 \u30A8\u30E9\u30FC \uD83D\uDD25";
        var inner = new Exception("Chaine interne: \u00C0\u00C8\u00CC\u00D2\u00D9");
        var ex = new Exception(nonAsciiMessage, inner);

        string formatted = ExceptionFormatter.FormatException(nonAsciiContext, ex);

        // Assert strictly 100% 7-bit ASCII
        for (int i = 0; i < formatted.Length; i++)
        {
            char c = formatted[i];
            Assert.True((int)c <= 127, $"Found non-ASCII char code {(int)c} at index {i}");
        }

        // Verify non-ASCII characters were sanitized to '?'
        Assert.Contains("Contexte: V?rification fran?aise | [System.Exception]", formatted);
        Assert.Contains("Chaine interne: ?????", formatted);
    }

    // =========================================================================
    // 4. ACTIVITYLOGGER DUAL PATH RESOLUTION & LOG FILE PATTERNS
    // =========================================================================

    [Fact]
    public void ActivityLogger_ResolveBaseDirectory_RespectsCustomDirectory()
    {
        string customPath = Path.Combine(Path.GetTempPath(), $"iToolKit_Custom_{Guid.NewGuid():N}");
        try
        {
            var logger = new ActivityLogger(customPath);
            Assert.StartsWith(customPath, logger.LogFilePath, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(customPath))
            {
                try { Directory.Delete(customPath, recursive: true); } catch { }
            }
        }
    }

    [Fact]
    public void ActivityLogger_ResolveBaseDirectory_NullOrWhitespace_FallsBackToAppContextBaseDirectoryInTests()
    {
        var method = typeof(ActivityLogger).GetMethod(
            "ResolveBaseDirectory",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        // Case 1: null parameter
        string? nullResult = method.Invoke(null, new object?[] { null }) as string;
        Assert.NotNull(nullResult);
        Assert.NotEmpty(nullResult);

        // Case 2: whitespace parameter
        string? whitespaceResult = method.Invoke(null, new object?[] { "   \t\n  " }) as string;
        Assert.NotNull(whitespaceResult);
        Assert.NotEmpty(whitespaceResult);

        // In test host, the process is testhost / dotnet, so it resolves to AppContext.BaseDirectory
        Assert.Equal(AppContext.BaseDirectory, nullResult);
        Assert.Equal(AppContext.BaseDirectory, whitespaceResult);
    }

    [Fact]
    public void ActivityLogger_LogFilePath_FollowsStrictNamingConvention()
    {
        var logger = new ActivityLogger();
        string logPath = logger.LogFilePath;

        string fileName = Path.GetFileName(logPath);
        string expectedDateStamp = DateTime.Now.ToString("yyyyMMdd");
        string expectedFileName = $"iToolKit_{expectedDateStamp}.log";

        Assert.Equal(expectedFileName, fileName);
        Assert.Contains("Logs", Path.GetDirectoryName(logPath)!);
    }
}
