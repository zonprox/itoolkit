namespace IToolkit.Tests.Services;

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Tests.StaticAnalysis;
using IToolkit.Tests.TestDoubles;
using Xunit;

/// <summary>
/// Unit and integration tests for IDialogService and ISafetyConfirmationService logging behavior,
/// reflection instantiation, file/folder pickers, Windows Explorer launches, and safety confirmation prompts.
/// </summary>
public class DialogLoggingTests
{
    private readonly TestActivityLogger _logger = new();

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
    // 1. REFLECTION INSTANTIATION VIA PARAMETERLESS CONSTRUCTORS
    // =========================================================================

    [Fact]
    public void MockDialogService_ActivatorCreateInstance_Parameterless_Succeeds()
    {
        Type type = typeof(MockDialogService);
        var ctor = type.GetConstructor(Type.EmptyTypes);
        Assert.NotNull(ctor);

        object? instance = Activator.CreateInstance(type);
        Assert.NotNull(instance);
        Assert.IsType<MockDialogService>(instance);

        var service = (MockDialogService)instance;
        Assert.True(service.ConfirmationResult);
        Assert.True(service.OpenFolderInExplorerResult);
        Assert.Equal(0, service.ShowOpenFileDialogCallCount);
        Assert.Equal(0, service.ShowSaveFileDialogCallCount);
        Assert.Equal(0, service.ShowOpenFolderDialogCallCount);
        Assert.Equal(0, service.OpenFolderInExplorerCallCount);
        Assert.Equal(0, service.ConfirmCallCount);
        Assert.Equal(0, service.ConfirmAsyncCallCount);
        Assert.Empty(service.OpenedInExplorerPaths);
        Assert.Empty(service.ConfirmationRequests);
    }

    [Fact]
    public void MockDialogService_ActivatorCreateInstance_WithLogger_Succeeds()
    {
        Type type = typeof(MockDialogService);
        var ctor = type.GetConstructor(new[] { typeof(IActivityLogger) });
        Assert.NotNull(ctor);

        object? instance = Activator.CreateInstance(type, new object?[] { _logger });
        Assert.NotNull(instance);
        Assert.IsType<MockDialogService>(instance);
    }

    [Fact]
    public void WpfDialogService_MetadataInspection_HasParameterlessAndSingleParamConstructors()
    {
        string assemblyPath = GetAppAssemblyPath();
        Assert.True(File.Exists(assemblyPath), $"Assembly must exist at: {assemblyPath}");

        using var stream = File.OpenRead(assemblyPath);
        using var peReader = new PEReader(stream);
        MetadataReader reader = peReader.GetMetadataReader();

        bool typeFound = false;
        bool hasParameterlessCtor = false;
        bool hasSingleParamCtor = false;
        var implementedInterfaces = new List<string>();
        var methods = new List<string>();

        foreach (var typeHandle in reader.TypeDefinitions)
        {
            var typeDef = reader.GetTypeDefinition(typeHandle);
            string name = reader.GetString(typeDef.Name);
            string ns = reader.GetString(typeDef.Namespace);

            if (name == "WpfDialogService" && ns == "IToolkit.App.Services")
            {
                typeFound = true;

                foreach (var ifaceHandle in typeDef.GetInterfaceImplementations())
                {
                    var iface = reader.GetInterfaceImplementation(ifaceHandle);
                    string ifaceName = iface.Interface.Kind switch
                    {
                        HandleKind.TypeReference => reader.GetString(reader.GetTypeReference((TypeReferenceHandle)iface.Interface).Name),
                        HandleKind.TypeDefinition => reader.GetString(reader.GetTypeDefinition((TypeDefinitionHandle)iface.Interface).Name),
                        _ => string.Empty
                    };
                    implementedInterfaces.Add(ifaceName);
                }

                foreach (var methodHandle in typeDef.GetMethods())
                {
                    var methodDef = reader.GetMethodDefinition(methodHandle);
                    string methodName = reader.GetString(methodDef.Name);
                    methods.Add(methodName);

                    if (methodName == ".ctor")
                    {
                        var sigReader = reader.GetBlobReader(methodDef.Signature);
                        sigReader.ReadByte(); // calling convention
                        int paramCount = sigReader.ReadCompressedInteger();
                        if (paramCount == 0) hasParameterlessCtor = true;
                        if (paramCount == 1) hasSingleParamCtor = true;
                    }
                }
                break;
            }
        }

        Assert.True(typeFound, "WpfDialogService must be defined in iToolKit.dll.");
        Assert.True(hasParameterlessCtor, "WpfDialogService must define a parameterless constructor.");
        Assert.True(hasSingleParamCtor, "WpfDialogService must define a constructor accepting IActivityLogger?.");
        Assert.Contains("IDialogService", implementedInterfaces);
        Assert.Contains("ISafetyConfirmationService", implementedInterfaces);
        Assert.Contains("ShowOpenFileDialog", methods);
        Assert.Contains("ShowSaveFileDialog", methods);
        Assert.Contains("ShowOpenFolderDialog", methods);
        Assert.Contains("OpenFolderInExplorer", methods);
        Assert.Contains("Confirm", methods);
        Assert.Contains("ConfirmAsync", methods);
    }

    [Fact]
    public void WpfDialogService_SourceCode_PreservesParameterlessConstructorDelegation()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string sourcePath = Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs");
        Assert.True(File.Exists(sourcePath), $"File not found: {sourcePath}");

        string content = File.ReadAllText(sourcePath);
        Assert.Contains("public WpfDialogService() : this(null)", content);
        Assert.Contains("public WpfDialogService(IActivityLogger? logger = null)", content);
    }

    // =========================================================================
    // 2. FILE AND FOLDER PICKER LOGGING
    // =========================================================================

    [Fact]
    public void ShowOpenFileDialog_WhenUserSelectsFile_LogsStartAndSelection()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedOpenFilePath = @"C:\ISO\Windows11_Install.iso"
        };

        string? result = service.ShowOpenFileDialog("Select Windows ISO", "ISO files (*.iso)|*.iso", @"C:\ISO");

        Assert.Equal(@"C:\ISO\Windows11_Install.iso", result);
        Assert.Equal(1, service.ShowOpenFileDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("Showing OpenFileDialog: Title='Select Windows ISO', Filter='ISO files (*.iso)|*.iso', DefaultPath='C:\\ISO'.", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("OpenFileDialog selected: 'C:\\ISO\\Windows11_Install.iso' (Title='Select Windows ISO').", entries[1].Message);
    }

    [Fact]
    public void ShowOpenFileDialog_WhenUserCancels_LogsStartAndCancellation()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedOpenFilePath = null
        };

        string? result = service.ShowOpenFileDialog("Open Config", "JSON (*.json)|*.json", null);

        Assert.Null(result);
        Assert.Equal(1, service.ShowOpenFileDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("Showing OpenFileDialog: Title='Open Config', Filter='JSON (*.json)|*.json', DefaultPath=''.", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("OpenFileDialog cancelled by user (Title='Open Config').", entries[1].Message);
    }

    [Fact]
    public void ShowSaveFileDialog_WhenUserSelectsFile_LogsStartAndSelection()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedSaveFilePath = @"D:\Backups\Outlook_Archive.pst"
        };

        string? result = service.ShowSaveFileDialog(
            "Export PST Archive",
            "Outlook Data File (*.pst)|*.pst",
            "Outlook_Archive.pst",
            @"D:\Backups");

        Assert.Equal(@"D:\Backups\Outlook_Archive.pst", result);
        Assert.Equal(1, service.ShowSaveFileDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("Showing SaveFileDialog: Title='Export PST Archive', Filter='Outlook Data File (*.pst)|*.pst', DefaultFileName='Outlook_Archive.pst', DefaultPath='D:\\Backups'.", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("SaveFileDialog selected: 'D:\\Backups\\Outlook_Archive.pst' (Title='Export PST Archive').", entries[1].Message);
    }

    [Fact]
    public void ShowSaveFileDialog_WhenUserCancels_LogsStartAndCancellation()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedSaveFilePath = null
        };

        string? result = service.ShowSaveFileDialog("Export Registry", "REG (*.reg)|*.reg", "backup.reg", @"C:\Temp");

        Assert.Null(result);
        Assert.Equal(1, service.ShowSaveFileDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Contains("Showing SaveFileDialog", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("SaveFileDialog cancelled by user (Title='Export Registry').", entries[1].Message);
    }

    [Fact]
    public void ShowOpenFolderDialog_WhenUserSelectsFolder_LogsStartAndSelection()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedFolderPath = @"C:\Users\Admin\Documents\iToolKit"
        };

        string? result = service.ShowOpenFolderDialog("Select Target Directory", @"C:\Users\Admin");

        Assert.Equal(@"C:\Users\Admin\Documents\iToolKit", result);
        Assert.Equal(1, service.ShowOpenFolderDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("Showing OpenFolderDialog: Title='Select Target Directory', DefaultPath='C:\\Users\\Admin'.", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("OpenFolderDialog selected: 'C:\\Users\\Admin\\Documents\\iToolKit' (Title='Select Target Directory').", entries[1].Message);
    }

    [Fact]
    public void ShowOpenFolderDialog_WhenUserCancels_LogsStartAndCancellation()
    {
        var service = new MockDialogService(_logger)
        {
            SelectedFolderPath = null
        };

        string? result = service.ShowOpenFolderDialog("Select Destination Folder", null);

        Assert.Null(result);
        Assert.Equal(1, service.ShowOpenFolderDialogCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("Showing OpenFolderDialog: Title='Select Destination Folder', DefaultPath=''.", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("DialogService", entries[1].Component);
        Assert.Equal("OpenFolderDialog cancelled by user (Title='Select Destination Folder').", entries[1].Message);
    }

    // =========================================================================
    // 3. WINDOWS EXPLORER LAUNCH LOGGING
    // =========================================================================

    [Fact]
    public void OpenFolderInExplorer_ValidPath_LogsInfoAndRecordsCall()
    {
        var service = new MockDialogService(_logger);
        string folder = @"C:\ProgramData\iToolKit\Logs";

        bool result = service.OpenFolderInExplorer(folder);

        Assert.True(result);
        Assert.Equal(1, service.OpenFolderInExplorerCallCount);
        Assert.Single(service.OpenedInExplorerPaths);
        Assert.Equal(folder, service.OpenedInExplorerPaths[0]);

        var entries = _logger.CapturedEntries;
        Assert.Single(entries);
        Assert.Equal(LogLevel.Info, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal($"Launching Windows Explorer for folder: '{folder}'.", entries[0].Message);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void OpenFolderInExplorer_NullOrWhitespace_LogsWarning(string? invalidPath)
    {
        var service = new MockDialogService(_logger);

        service.OpenFolderInExplorer(invalidPath!);

        var entries = _logger.CapturedEntries;
        Assert.Single(entries);
        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("DialogService", entries[0].Component);
        Assert.Equal("OpenFolderInExplorer called with null or empty path.", entries[0].Message);
    }

    [Fact]
    public void WpfDialogService_SourceCode_VerifiesExplorerValidationAndExceptionLogging()
    {
        string repoRoot = StaticAnalysisHelper.GetRepoRoot();
        string sourcePath = Path.Combine(repoRoot, "src", "IToolkit.App", "Services", "WpfDialogService.cs");
        string content = File.ReadAllText(sourcePath);

        // Verify null check warning
        Assert.Contains("OpenFolderInExplorer called with null or empty path.", content);

        // Verify missing directory warning
        Assert.Contains("Directory does not exist for Explorer launch:", content);

        // Verify explorer launch info log
        Assert.Contains("Launching Windows Explorer for folder:", content);

        // Verify explorer launch error log on exception
        Assert.Contains("Failed to launch Windows Explorer for folder", content);
    }

    // =========================================================================
    // 4. SAFETY CONFIRMATION PROMPTS LOGGING
    // =========================================================================

    [Fact]
    public void Confirm_WhenUserConfirms_LogsPromptWarningAndConfirmationInfo()
    {
        var service = new MockDialogService(_logger)
        {
            ConfirmationResult = true
        };

        bool confirmed = service.Confirm(
            "Purge Shadow Copies",
            "Are you sure you want to delete all VSS shadow copies?",
            "System restore points will be permanently destroyed.");

        Assert.True(confirmed);
        Assert.Equal(1, service.ConfirmCallCount);
        Assert.Single(service.ConfirmationRequests);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        // Log 1: Prompt displayed (Warning)
        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("SafetyConfirmation", entries[0].Component);
        Assert.Contains("Safety confirmation prompt displayed: 'Purge Shadow Copies' - 'Are you sure you want to delete all VSS shadow copies?\n\nWARNING:\nSystem restore points will be permanently destroyed.'.", entries[0].Message);

        // Log 2: User Confirmed (Info)
        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("SafetyConfirmation", entries[1].Component);
        Assert.Equal("Safety confirmation 'Purge Shadow Copies' result: Confirmed (Yes).", entries[1].Message);
    }

    [Fact]
    public void Confirm_WhenUserDismisses_LogsPromptWarningAndDismissalWarning()
    {
        var service = new MockDialogService(_logger)
        {
            ConfirmationResult = false
        };

        bool confirmed = service.Confirm(
            "Disable Firewall",
            "Disable Windows Defender Firewall completely?",
            "Your PC will be unprotected on public networks.");

        Assert.False(confirmed);
        Assert.Equal(1, service.ConfirmCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        // Log 1: Prompt displayed (Warning)
        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("SafetyConfirmation", entries[0].Component);
        Assert.Contains("Safety confirmation prompt displayed: 'Disable Firewall'", entries[0].Message);

        // Log 2: User Dismissed (Warning)
        Assert.Equal(LogLevel.Warning, entries[1].Level);
        Assert.Equal("SafetyConfirmation", entries[1].Component);
        Assert.Equal("Safety confirmation 'Disable Firewall' result: Dismissed (No).", entries[1].Message);
    }

    [Fact]
    public async Task ConfirmAsync_WhenUserConfirms_LogsPromptWarningAndConfirmationInfo()
    {
        var service = new MockDialogService(_logger)
        {
            ConfirmationResult = true
        };

        bool confirmed = await service.ConfirmAsync(
            "Flush DNS & Winsock Reset",
            "Reset network stack to defaults?",
            "Active network connections will disconnect.");

        Assert.True(confirmed);
        Assert.Equal(1, service.ConfirmAsyncCallCount);
        Assert.Equal(1, service.ConfirmCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("SafetyConfirmation", entries[0].Component);
        Assert.Contains("Flush DNS & Winsock Reset", entries[0].Message);

        Assert.Equal(LogLevel.Info, entries[1].Level);
        Assert.Equal("SafetyConfirmation", entries[1].Component);
        Assert.Equal("Safety confirmation 'Flush DNS & Winsock Reset' result: Confirmed (Yes).", entries[1].Message);
    }

    [Fact]
    public async Task ConfirmAsync_WhenUserDismisses_LogsPromptWarningAndDismissalWarning()
    {
        var service = new MockDialogService(_logger)
        {
            ConfirmationResult = false
        };

        bool confirmed = await service.ConfirmAsync(
            "Reset Office Credentials",
            "Wipe all cached MAPI profiles and tokens?",
            "Users must re-enter credentials upon next Outlook launch.");

        Assert.False(confirmed);
        Assert.Equal(1, service.ConfirmAsyncCallCount);

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);

        Assert.Equal(LogLevel.Warning, entries[0].Level);
        Assert.Equal("SafetyConfirmation", entries[0].Component);
        Assert.Contains("Reset Office Credentials", entries[0].Message);

        Assert.Equal(LogLevel.Warning, entries[1].Level);
        Assert.Equal("SafetyConfirmation", entries[1].Component);
        Assert.Equal("Safety confirmation 'Reset Office Credentials' result: Dismissed (No).", entries[1].Message);
    }

    [Fact]
    public void Confirm_WithoutWarningDetails_LogsPlainMessageWithoutWarningPrefix()
    {
        var service = new MockDialogService(_logger)
        {
            ConfirmationResult = true
        };

        service.Confirm("Restart Service", "Do you wish to restart the print spooler?", "");

        var entries = _logger.CapturedEntries;
        Assert.Equal(2, entries.Count);
        Assert.Equal("Safety confirmation prompt displayed: 'Restart Service' - 'Do you wish to restart the print spooler?'.", entries[0].Message);
        Assert.DoesNotContain("WARNING:", entries[0].Message);
    }
}
