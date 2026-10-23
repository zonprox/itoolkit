namespace IToolkit.Tests.SafetyTests;

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using IToolkit.Core.Safety;
using IToolkit.Tests.TestDoubles;
using Xunit;

public class AtomicRegistryEmpiricalChallengeTests
{
    private readonly MockRegistryService _registry = new();
    private readonly MockFileSystemService _fileSystem = new();
    private const string BackupDir = "C:\\IToolkit\\Backups\\Registry";

    [Fact]
    public void VerifyBackupCreation_DefaultDirectoryAndTimestampFormat()
    {
        // 1. Verify .reg backup creation in Backups/Registry/ with timestamp format
        var defaultService = new AtomicRegistryService(_registry, _fileSystem);
        const string key = @"HKCU\Software\Empirical\TestKey";

        string backupPath = defaultService.ExportKeyBackup(key);

        Assert.True(_fileSystem.FileExists(backupPath));
        string fileName = Path.GetFileName(backupPath);

        // Expected pattern: RegistryBackup_{safeSlug}_{yyyyMMdd_HHmmss_fff}.reg
        var match = Regex.Match(fileName, @"^RegistryBackup_(?<slug>.+)_(?<ts>\d{8}_\d{6}_\d{3})\.reg$");
        Assert.True(match.Success, $"Filename '{fileName}' did not match expected timestamp pattern");

        // Verify timestamp is valid date
        string ts = match.Groups["ts"].Value;
        bool validDate = DateTime.TryParseExact(ts, "yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);
        Assert.True(validDate, $"Timestamp '{ts}' could not be parsed as yyyyMMdd_HHmmss_fff");

        // Verify directory is within Backups/Registry
        string dir = Path.GetDirectoryName(backupPath)?.Replace('\\', '/') ?? "";
        Assert.True(dir.EndsWith("Backups/Registry"), $"Backup dir '{dir}' does not end with Backups/Registry");
    }

    [Fact]
    public void VerifySentinelGenerationAndReversibleDeletion()
    {
        // 3. Verify reversible deletion sentinels [-KeyPath] are parsed and handled correctly by the pure C# parser
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string targetKey = @"HKLM\Software\Empirical\NonExistentBranch";

        Assert.False(_registry.KeyExists(targetKey));

        // Generate sentinel
        string backupPath = service.ExportKeyBackup(targetKey);
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);

        Assert.Contains("[-HKEY_LOCAL_MACHINE\\Software\\Empirical\\NonExistentBranch]", content);

        // Now simulate that the key and subkeys were created
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "TempVal", "To Be Deleted", RegistryValueKind.String);
        string childKey = targetKey + "\\ChildSubKey";
        _registry.CreateKey(childKey);
        _registry.SetValue(childKey, "ChildVal", 42, RegistryValueKind.DWord);

        Assert.True(_registry.KeyExists(targetKey));
        Assert.True(_registry.KeyExists(childKey));

        // Apply sentinel rollback
        bool rollbackResult = service.Rollback(backupPath);

        Assert.True(rollbackResult);
        Assert.False(_registry.KeyExists(targetKey), "Target key should have been deleted by sentinel rollback");
        Assert.False(_registry.KeyExists(childKey), "Child subkey should have been deleted recursively");
    }

    [Fact]
    public async Task VerifyRollbackOnFailure_RestoresPreviousRegistryStateCleanly()
    {
        // 2. Verify rollback on transaction failure restores previous registry state cleanly
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string targetKey = @"HKCU\Software\Empirical\RollbackRestoreKey";

        // Setup pre-existing state
        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "StringProp", "OriginalString", RegistryValueKind.String);
        _registry.SetValue(targetKey, "IntProp", 12345, RegistryValueKind.DWord);
        _registry.SetValue(targetKey, "BinProp", new byte[] { 0xAA, 0xBB, 0xCC }, RegistryValueKind.Binary);

        // Execute mutation that mutates values and returns false
        var result = await service.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _registry.SetValue(targetKey, "StringProp", "MutatedString", RegistryValueKind.String);
                _registry.SetValue(targetKey, "IntProp", 99999, RegistryValueKind.DWord);
                _registry.SetValue(targetKey, "BinProp", new byte[] { 0x00 }, RegistryValueKind.Binary);
                return Task.FromResult(false); // Fail transaction
            },
            "Test Mutate and Fail");

        Assert.False(result.Success);

        // Verify previous state was restored cleanly
        Assert.Equal("OriginalString", _registry.GetValue<string>(targetKey, "StringProp"));
        Assert.Equal(12345, _registry.GetValue<int>(targetKey, "IntProp"));
        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC }, _registry.GetValue<byte[]>(targetKey, "BinProp"));
    }

    [Fact]
    public async Task VerifyRollbackOnException_RestoresPreviousRegistryStateCleanly()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string targetKey = @"HKCU\Software\Empirical\RollbackExceptionKey";

        _registry.CreateKey(targetKey);
        _registry.SetValue(targetKey, "Setting", "SafeValue", RegistryValueKind.String);

        var result = await service.ExecuteAtomicMutationAsync(
            targetKey,
            () =>
            {
                _registry.SetValue(targetKey, "Setting", "CorruptedValue", RegistryValueKind.String);
                throw new ApplicationException("Simulated unexpected crash during registry write");
            },
            "Crashing Mutation");

        Assert.False(result.Success);
        Assert.NotNull(result.Exception);
        Assert.IsType<ApplicationException>(result.Exception);
        Assert.Equal("SafeValue", _registry.GetValue<string>(targetKey, "Setting"));
    }

    [Fact]
    public void StressTest_DwordHighBitValues_E_g_0xFFFFFFFF()
    {
        // Stress test DWORD values where the high bit is set (e.g. 0xFFFFFFFF, 0x80000000)
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\DwordHighBitTest";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\DwordHighBitTest]\r\n" +
            "\"MaxDword\"=dword:ffffffff\r\n" +
            "\"HighBitDword\"=dword:80000000\r\n" +
            "\"ZeroDword\"=dword:00000000\r\n";

        bool applied = service.ApplyRegContent(regContent);
        Assert.True(applied);

        Assert.True(_registry.KeyExists(key));
        // Verify whether dword:ffffffff was parsed or dropped
        object? maxVal = _registry.GetValue(key, "MaxDword");
        Assert.NotNull(maxVal);
        Assert.Equal(-1, Convert.ToInt32(maxVal));

        object? highBitVal = _registry.GetValue(key, "HighBitDword");
        Assert.NotNull(highBitVal);
        Assert.Equal(unchecked((int)0x80000000), Convert.ToInt32(highBitVal));
    }

    [Fact]
    public void StressTest_ExportDword_WhenValueIsStoredAsUintOrInt()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\ExportDwordTypeTest";
        _registry.CreateKey(key);

        _registry.SetValue(key, "SignedNegative", -1, RegistryValueKind.DWord);
        _registry.SetValue(key, "SignedInt", 100, RegistryValueKind.DWord);
        _registry.SetValue(key, "UintMax", 4294967295U, RegistryValueKind.DWord);

        string backupPath = service.ExportKeyBackup(key);
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);

        Assert.Contains("\"SignedNegative\"=dword:ffffffff", content);
        Assert.Contains("\"SignedInt\"=dword:00000064", content);
    }

    [Fact]
    public void StressTest_SpecialCharactersAndEscapedStrings()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\EscapingTest";
        _registry.CreateKey(key);

        const string originalStr = @"C:\Program Files (x86)\App\""Quote"" and \Backslash\ and " + "\u65E5\u672C\u8A9E";
        _registry.SetValue(key, "ComplexPath", originalStr, RegistryValueKind.String);

        string backupPath = service.ExportKeyBackup(key);
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);

        // Wipe registry
        _registry.DeleteKey(key);
        Assert.False(_registry.KeyExists(key));

        // Restore
        bool restored = service.Rollback(backupPath);
        Assert.True(restored);
        Assert.True(_registry.KeyExists(key));
        Assert.Equal(originalStr, _registry.GetValue<string>(key, "ComplexPath"));
    }

    [Fact]
    public void StressTest_MultilineHexContinuation()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\MultilineHex";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\MultilineHex]\r\n" +
            "\"LongBinary\"=hex:01,02,03,04,\\\r\n" +
            "  05,06,07,08,\\\r\n" +
            "  09,0a,0b,0c\r\n";

        bool applied = service.ApplyRegContent(regContent);
        Assert.True(applied);

        byte[] expected = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
        Assert.Equal(expected, _registry.GetValue<byte[]>(key, "LongBinary"));
    }

    [Fact]
    public void StressTest_ValueDeletionSentinel()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\ValueDeletion";
        _registry.CreateKey(key);
        _registry.SetValue(key, "KeepThis", "I am safe", RegistryValueKind.String);
        _registry.SetValue(key, "DeleteThis", "I should be removed", RegistryValueKind.String);

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\ValueDeletion]\r\n" +
            "\"DeleteThis\"=-\r\n";

        bool applied = service.ApplyRegContent(regContent);
        Assert.True(applied);

        Assert.True(_registry.ValueExists(key, "KeepThis"));
        Assert.False(_registry.ValueExists(key, "DeleteThis"));
    }

    [Fact]
    public void StressTest_DefaultValueOperations()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\DefaultValueTest";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\DefaultValueTest]\r\n" +
            "@=\"This is the default value\"\r\n";

        bool applied = service.ApplyRegContent(regContent);
        Assert.True(applied);

        Assert.Equal("This is the default value", _registry.GetValue<string>(key, string.Empty));
    }

    [Fact]
    public async Task VerifyRollback_WhenExistingKeyMutatedWithNewValue_DoesRollbackRemoveNewValue()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\ExistingKeyWithNewValue";
        _registry.CreateKey(key);
        _registry.SetValue(key, "ExistingVal", "KeepMe", RegistryValueKind.String);

        var result = await service.ExecuteAtomicMutationAsync(
            key,
            () =>
            {
                _registry.SetValue(key, "NewAddedVal", "ShouldBeRolledBack", RegistryValueKind.String);
                return Task.FromResult(false); // Fail transaction
            },
            "Add new value and fail");

        Assert.False(result.Success);
        Assert.True(_registry.ValueExists(key, "ExistingVal"));
        // Does NewAddedVal still exist after rollback?
        bool newValueStillExists = _registry.ValueExists(key, "NewAddedVal");
        Assert.False(newValueStillExists, "New value added during failed transaction should be removed on rollback");
    }

    [Fact]
    public async Task VerifyRollback_WhenExistingKeyMutatedWithNewSubkey_DoesRollbackRemoveNewSubkey()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\ExistingKeyWithNewSubkey";
        _registry.CreateKey(key);
        _registry.SetValue(key, "BaseVal", "KeepMe", RegistryValueKind.String);

        var result = await service.ExecuteAtomicMutationAsync(
            key,
            () =>
            {
                string newSubKey = key + "\\RogueSubkey";
                _registry.CreateKey(newSubKey);
                _registry.SetValue(newSubKey, "RogueVal", 666, RegistryValueKind.DWord);
                return Task.FromResult(false); // Fail transaction
            },
            "Add rogue subkey and fail");

        Assert.False(result.Success);
        string newSubKeyPath = key + "\\RogueSubkey";
        bool subKeyStillExists = _registry.KeyExists(newSubKeyPath);
        Assert.False(subKeyStillExists, "New subkey added during failed transaction should be removed on rollback");
    }

    [Fact]
    public void VerifyRollback_WhenBackupFileIsUtf8Encoded_FallbackRestoresValues()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\Utf8BackupKey";
        const string backupPath = "C:\\IToolkit\\Backups\\Registry\\utf8_backup.reg";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\Utf8BackupKey]\r\n" +
            "\"TestStr\"=\"ValueFromUtf8\"\r\n";

        // Save as UTF8 (without BOM)
        _fileSystem.WriteAllText(backupPath, regContent, Encoding.UTF8);

        bool rolledBack = service.Rollback(backupPath);
        Assert.True(rolledBack);
        Assert.True(_registry.KeyExists(key), "Key should have been created from UTF-8 rollback");
        Assert.Equal("ValueFromUtf8", _registry.GetValue<string>(key, "TestStr"));
    }

    [Fact]
    public void VerifyRollback_WhenBackupFileHasUtf16LeBom_RestoresValues()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\Utf16BomBackupKey";
        const string backupPath = "C:\\IToolkit\\Backups\\Registry\\utf16_bom_backup.reg";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\Utf16BomBackupKey]\r\n" +
            "\"TestStr\"=\"ValueFromUtf16Bom\"\r\n";

        // Prepend UTF-16 LE BOM (0xFF, 0xFE)
        byte[] preamble = Encoding.Unicode.GetPreamble();
        byte[] body = Encoding.Unicode.GetBytes(regContent);
        byte[] fullBytes = new byte[preamble.Length + body.Length];
        Buffer.BlockCopy(preamble, 0, fullBytes, 0, preamble.Length);
        Buffer.BlockCopy(body, 0, fullBytes, preamble.Length, body.Length);
        _fileSystem.WriteAllBytes(backupPath, fullBytes);

        bool rolledBack = service.Rollback(backupPath);
        Assert.True(rolledBack);
        Assert.True(_registry.KeyExists(key));
        Assert.Equal("ValueFromUtf16Bom", _registry.GetValue<string>(key, "TestStr"));
    }

    [Fact]
    public void VerifyRollback_WhenBackupFileHasUtf8Bom_RestoresValues()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\Utf8BomBackupKey";
        const string backupPath = "C:\\IToolkit\\Backups\\Registry\\utf8_bom_backup.reg";

        const string regContent =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\Utf8BomBackupKey]\r\n" +
            "\"TestStr\"=\"ValueFromUtf8Bom\"\r\n";

        // Prepend UTF-8 BOM (0xEF, 0xBB, 0xBF)
        byte[] preamble = Encoding.UTF8.GetPreamble();
        byte[] body = Encoding.UTF8.GetBytes(regContent);
        byte[] fullBytes = new byte[preamble.Length + body.Length];
        Buffer.BlockCopy(preamble, 0, fullBytes, 0, preamble.Length);
        Buffer.BlockCopy(body, 0, fullBytes, preamble.Length, body.Length);
        _fileSystem.WriteAllBytes(backupPath, fullBytes);

        bool rolledBack = service.Rollback(backupPath);
        Assert.True(rolledBack);
        Assert.True(_registry.KeyExists(key));
        Assert.Equal("ValueFromUtf8Bom", _registry.GetValue<string>(key, "TestStr"));
    }

    [Fact]
    public void StressTest_ExportQword_WhenValueIsStoredAsUlongMax()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\ExportQwordTypeTest";
        _registry.CreateKey(key);

        _registry.SetValue(key, "UlongMax", ulong.MaxValue, RegistryValueKind.QWord);

        string backupPath = service.ExportKeyBackup(key);
        byte[] bytes = _fileSystem.ReadAllBytes(backupPath);
        string content = Encoding.Unicode.GetString(bytes);

        Assert.Contains("\"UlongMax\"=hex(b):ff,ff,ff,ff,ff,ff,ff,ff", content);
    }

    [Fact]
    public void StressTest_RootHiveProtection_DoesNotEmitOrExecuteRootHiveDeletion()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        _registry.CreateKey("HKEY_LOCAL_MACHINE");

        // 1. Exporting root hive should not contain [-HKEY_LOCAL_MACHINE]
        string backup = service.ExportKeyBackup("HKLM\\");
        string content = _fileSystem.ReadAllText(backup, Encoding.Unicode);
        Assert.DoesNotContain("[-HKEY_LOCAL_MACHINE]", content);

        // 2. Applying content with [-HKEY_LOCAL_MACHINE] should NOT delete root hive
        const string maliciousReg =
            "Windows Registry Editor Version 5.00\r\n\r\n" +
            "[-HKEY_LOCAL_MACHINE]\r\n";
        bool applied = service.ApplyRegContent(maliciousReg);
        Assert.True(applied);
        Assert.True(_registry.KeyExists("HKEY_LOCAL_MACHINE"), "Root hive must be protected from deletion");
    }

    [Fact]
    public async Task StressTest_TrailingSlashKeyPath_InAtomicMutation_RollsBackCleanly()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string keyWithSlash = @"HKCU\Software\Empirical\TrailingSlashApp\";
        const string canonicalKey = @"HKEY_CURRENT_USER\Software\Empirical\TrailingSlashApp";

        _registry.CreateKey(canonicalKey);
        _registry.SetValue(canonicalKey, "OriginalVal", "Initial", RegistryValueKind.String);

        var result = await service.ExecuteAtomicMutationAsync(
            keyWithSlash,
            () =>
            {
                _registry.SetValue(canonicalKey, "RogueVal", "MustBeGone", RegistryValueKind.String);
                return Task.FromResult(false); // Fail transaction
            },
            "Trailing slash mutation failure");

        Assert.False(result.Success);
        Assert.True(_registry.KeyExists(canonicalKey));
        Assert.True(_registry.ValueExists(canonicalKey, "OriginalVal"));
        Assert.False(_registry.ValueExists(canonicalKey, "RogueVal"), "Rogue value must be removed on rollback");
    }

    [Fact]
    public void StressTest_DwordFromStringAndBorderValues()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\DwordBorderTest";
        _registry.CreateKey(key);

        _registry.SetValue(key, "MaxAsUintString", "4294967295", RegistryValueKind.DWord);
        _registry.SetValue(key, "ZeroDword", 0, RegistryValueKind.DWord);
        _registry.SetValue(key, "SignedIntMax", int.MaxValue, RegistryValueKind.DWord);

        string backupPath = service.ExportKeyBackup(key);
        string content = _fileSystem.ReadAllText(backupPath, Encoding.Unicode);

        Assert.Contains("\"MaxAsUintString\"=dword:ffffffff", content);
        Assert.Contains("\"ZeroDword\"=dword:00000000", content);
        Assert.Contains("\"SignedIntMax\"=dword:7fffffff", content);
    }

    [Fact]
    public void StressTest_Regedit4HeaderSupport_WithoutBom()
    {
        var service = new AtomicRegistryService(_registry, _fileSystem, backupDirectory: BackupDir);
        const string key = @"HKCU\Software\Empirical\Regedit4Key";
        const string backupPath = "C:\\IToolkit\\Backups\\Registry\\regedit4_backup.reg";

        const string regContent =
            "REGEDIT4\r\n\r\n" +
            "[HKEY_CURRENT_USER\\Software\\Empirical\\Regedit4Key]\r\n" +
            "\"LegacyVal\"=\"FromRegedit4\"\r\n";

        _fileSystem.WriteAllText(backupPath, regContent, Encoding.UTF8);

        bool rolledBack = service.Rollback(backupPath);
        Assert.True(rolledBack);
        Assert.True(_registry.KeyExists(key));
        Assert.Equal("FromRegedit4", _registry.GetValue<string>(key, "LegacyVal"));
    }
}
