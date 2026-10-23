namespace IToolkit.Tests.SafetyTests;

using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class AtomicRegistryTests
{
    private readonly MockRegistryService _registry = new();
    private readonly MockFileSystemService _fileSystem = new();
    private readonly AtomicRegistryService _service;
    private const string BackupDir = "C:\\IToolkit\\Backups\\Registry";

    public AtomicRegistryTests()
    {
        _service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
    }

    [Fact]
    public void ExportKeyBackup_WhenKeyDoesNotExist_GeneratesReversibleDeletionSentinel()
    {
        // Arrange
        const string targetKey = @"HKCU\Software\IToolkitTest\NonExistent";

        // Act
        string backupPath = _service.ExportKeyBackup(targetKey);

        // Assert
        Assert.True(_fileSystem.FileExists(backupPath));
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);
        Assert.Contains("Windows Registry Editor Version 5.00", content);
        Assert.Contains("[-HKEY_CURRENT_USER\\Software\\IToolkitTest\\NonExistent]", content);
    }

    [Fact]
    public void ExportKeyBackup_WhenKeyExists_ExportsAllValuesAndTypes()
    {
        // Arrange
        const string targetKey = @"HKCU\Software\IToolkitTest\ExistingKey";
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "StrVal", "Hello World", RegistryValueKind.String);
        _registry.SetValue(targetKey, "DwordVal", 42, RegistryValueKind.DWord);
        _registry.SetValue(targetKey, "BinVal", new byte[] { 0x01, 0x02, 0x0A }, RegistryValueKind.Binary);

        // Act
        string backupPath = _service.ExportKeyBackup(targetKey);

        // Assert
        Assert.True(_fileSystem.FileExists(backupPath));
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);
        Assert.Contains("[HKEY_CURRENT_USER\\Software\\IToolkitTest\\ExistingKey]", content);
        Assert.Contains("\"StrVal\"=\"Hello World\"", content);
        Assert.Contains("\"DwordVal\"=dword:0000002a", content);
        Assert.Contains("\"BinVal\"=hex:01,02,0a", content);
    }

    [Fact]
    public async Task ExecuteAtomicMutationAsync_WhenActionSucceeds_CommitsChangesAndReturnsSuccess()
    {
        // Arrange
        const string targetKey = @"HKCU\Software\IToolkitTest\AppKey";
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "Setting", "Initial", RegistryValueKind.String);

        // Act
        var result = await _service.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _registry.SetValue(targetKey, "Setting", "Updated", RegistryValueKind.String);
                return Task.FromResult(true);
            },
            "Update Setting");

        // Assert
        Assert.True(result.Success);
        Assert.Equal("Updated", _registry.GetValue<string>(targetKey, "Setting"));
        Assert.NotNull(result.BackupPath);
        Assert.True(_fileSystem.FileExists(result.BackupPath));
    }

    [Fact]
    public async Task ExecuteAtomicMutationAsync_WhenActionReportsFailure_AutomaticallyRollsBack()
    {
        // Arrange
        const string targetKey = @"HKCU\Software\IToolkitTest\RollbackKey";
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "ConfigVal", 100, RegistryValueKind.DWord);

        // Act
        var result = await _service.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _registry.SetValue(targetKey, "ConfigVal", 999, RegistryValueKind.DWord);
                return Task.FromResult(false); // Action reported failure
            },
            "Failed Config Update");

        // Assert
        Assert.False(result.Success);
        Assert.Contains("failed", result.Message, StringComparison.OrdinalIgnoreCase);
        // Rollback restored original value:
        Assert.Equal(100, _registry.GetValue<int>(targetKey, "ConfigVal"));
    }

    [Fact]
    public async Task ExecuteAtomicMutationAsync_WhenActionThrows_AutomaticallyRollsBackAndReturnsFailedResult()
    {
        // Arrange
        const string targetKey = @"HKCU\Software\IToolkitTest\ThrowKey";
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "Status", "Original", RegistryValueKind.String);

        // Act
        var result = await _service.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _registry.SetValue(targetKey, "Status", "Corrupted", RegistryValueKind.String);
                throw new InvalidOperationException("Simulated unexpected failure");
            },
            "Failing Mutation");

        // Assert
        Assert.False(result.Success);
        Assert.NotNull(result.Exception);
        Assert.IsType<InvalidOperationException>(result.Exception);
        // Rollback restored original value:
        Assert.Equal("Original", _registry.GetValue<string>(targetKey, "Status"));
    }

    [Fact]
    public async Task ExecuteAtomicMutationAsync_WhenNewKeyCreatedAndActionFails_SentinelRollbackDeletesKey()
    {
        // Arrange
        const string newKey = @"HKCU\Software\IToolkitTest\BrandNewSubKey";
        Assert.False(_registry.KeyExists(newKey));

        // Act
        var result = await _service.ExecuteAtomicMutationAsync(
            newKey,
            () =>
            {
                _registry.CreateKey(newKey);
                _registry.SetValue(newKey, "Temporary", "Value", RegistryValueKind.String);
                return Task.FromResult(false); // Failure
            },
            "Failed New Key Creation");

        // Assert
        Assert.False(result.Success);
        // Sentinel rollback removes the newly created key completely:
        Assert.False(_registry.KeyExists(newKey));
    }

    [Fact]
    public void ApplyRegContent_ParsesAndAppliesMultiTypeRegFileDirectly()
    {
        // Arrange
        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\DirectParserTest]\r\n" +
            "\"StringValue\"=\"Sample text with \\\"quotes\\\" and \\\\backslashes\\\\\"\r\n" +
            "\"DwordValue\"=dword:0000007b\r\n" +
            "\"BinaryValue\"=hex:de,ad,be,ef\r\n" +
            "\"MultiValue\"=hex(7):61,00,00,00,62,00,00,00,00,00\r\n\r\n" +
            "[-HKEY_CURRENT_USER\\Software\\KeyToDelete]\r\n";

        _registry.CreateKey(@"HKCU\Software\KeyToDelete");
        Assert.True(_registry.KeyExists(@"HKCU\Software\KeyToDelete"));

        // Act
        bool applied = _service.ApplyRegContent(regContent);

        // Assert
        Assert.True(applied);
        const string parsedKey = @"HKEY_CURRENT_USER\Software\DirectParserTest";
        Assert.True(_registry.KeyExists(parsedKey));
        Assert.Equal("Sample text with \"quotes\" and \\backslashes\\", _registry.GetValue<string>(parsedKey, "StringValue"));
        Assert.Equal(123, _registry.GetValue<int>(parsedKey, "DwordValue"));
        Assert.Equal(new byte[] { 0xDE, 0xAD, 0xBE, 0xEF }, _registry.GetValue<byte[]>(parsedKey, "BinaryValue"));
        Assert.Equal(new[] { "a", "b" }, _registry.GetValue<string[]>(parsedKey, "MultiValue"));

        // Key marked with [-Key] was deleted
        Assert.False(_registry.KeyExists(@"HKCU\Software\KeyToDelete"));
    }
}
