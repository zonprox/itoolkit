namespace IToolkit.Core.Safety;

using System.Globalization;
using System.Text;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Utilities;

/// <summary>
/// Provides atomic registry modifications with automatic pre-mutation .reg backups,
/// automatic rollback on failure, reversible deletion sentinels, and cross-platform .reg parsing.
/// </summary>
public class AtomicRegistryService
{
    private readonly IRegistryService _registryService;
    private readonly IFileSystemService _fileSystem;
    private readonly IActivityLogger? _logger;
    private readonly string _backupRoot;

    public AtomicRegistryService(
        IRegistryService registryService,
        IFileSystemService fileSystem,
        IActivityLogger? logger = null,
        string? backupDirectory = null)
    {
        _registryService = registryService ?? throw new ArgumentNullException(nameof(registryService));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _logger = logger;
        _backupRoot = backupDirectory ?? Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Backups", "Registry");
    }

    /// <summary>
    /// Executes a registry mutation asynchronously with automatic backup and rollback on failure.
    /// </summary>
    public async Task<OperationResult> ExecuteAtomicMutationAsync(
        string keyPath,
        Func<Task<bool>> mutationAction,
        string operationDescription)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyPath);
        ArgumentNullException.ThrowIfNull(mutationAction);

        _fileSystem.CreateDirectory(_backupRoot);
        string backupPath = ExportKeyBackup(keyPath);
        _logger?.LogInfo(nameof(AtomicRegistryService), $"Created pre-mutation backup for '{keyPath}' at: {backupPath}");

        try
        {
            bool success = await mutationAction();
            if (!success)
            {
                _logger?.LogWarning(nameof(AtomicRegistryService), $"Mutation reported failure for '{operationDescription}'. Initiating automatic rollback...");
                bool rolledBack = Rollback(backupPath);
                return OperationResult.Failed(
                    $"Operation '{operationDescription}' failed. State rolled back ({rolledBack}) from: {backupPath}",
                    backupPath);
            }

            _logger?.LogSuccess(nameof(AtomicRegistryService), $"Operation '{operationDescription}' completed successfully.");
            return OperationResult.Succeeded(
                $"Operation '{operationDescription}' applied successfully. Backup: {backupPath}",
                backupPath);
        }
        catch (Exception ex)
        {
            _logger?.LogError(nameof(AtomicRegistryService), $"Exception during '{operationDescription}': {ex.Message}. Initiating automatic rollback...");
            bool rolledBack = Rollback(backupPath);
            return OperationResult.Failed(
                $"Exception during '{operationDescription}': {ex.Message}. Automatic rollback ({rolledBack}) completed from: {backupPath}",
                backupPath,
                ex);
        }
    }

    /// <summary>
    /// Executes a registry mutation synchronously with automatic backup and rollback on failure.
    /// </summary>
    public OperationResult ExecuteAtomicMutation(
        string keyPath,
        Func<bool> mutationAction,
        string operationDescription)
    {
        return ExecuteAtomicMutationAsync(keyPath, () => Task.FromResult(mutationAction()), operationDescription).GetAwaiter().GetResult();
    }

    /// <summary>
    /// Exports the key state or writes a deletion sentinel if the key does not exist.
    /// </summary>
    public string ExportKeyBackup(string keyPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyPath);

        string standardPath = RegistryPathNormalizer.ToStandardFormat(keyPath);
        string safeSlug = RegistryPathNormalizer.ToSafeFileNameSlug(standardPath);
        string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture);
        string backupFilePath = Path.Combine(_backupRoot, $"RegistryBackup_{safeSlug}_{timestamp}.reg");

        _fileSystem.CreateDirectory(_backupRoot);

        bool keyExists = _registryService.KeyExists(standardPath);
        if (!keyExists)
        {
            // Reversible Rollback Deletion Sentinel:
            // When key does not exist prior to modification, restore removes this key.
            string sentinelContent =
                "Windows Registry Editor Version 5.00\r\n\r\n" +
                "; IToolkit Rollback Sentinel\r\n" +
                "; Key did not exist prior to modification. Restore removes this key.\r\n" +
                $"[-{standardPath}]\r\n";

            _fileSystem.WriteAllText(backupFilePath, sentinelContent, Encoding.Unicode);
            return backupFilePath;
        }

        // Key exists: export full key and subkey values to standard .reg format
        string regContent = GenerateRegContent(standardPath);
        _fileSystem.WriteAllText(backupFilePath, regContent, Encoding.Unicode);
        return backupFilePath;
    }

    /// <summary>
    /// Restores registry state from the specified backup .reg file.
    /// </summary>
    public bool Rollback(string backupFilePath)
    {
        if (string.IsNullOrWhiteSpace(backupFilePath) || !_fileSystem.FileExists(backupFilePath))
        {
            _logger?.LogError(nameof(AtomicRegistryService), $"Backup file not found for rollback: {backupFilePath}");
            return false;
        }

        try
        {
            byte[] bytes = _fileSystem.ReadAllBytes(backupFilePath);
            if (bytes.Length == 0)
            {
                _logger?.LogWarning(nameof(AtomicRegistryService), $"Backup file is empty: {backupFilePath}");
                return false;
            }

            string content;
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            {
                // UTF-16 LE with BOM (standard Windows .reg export)
                content = Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            }
            else if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            {
                // UTF-8 with BOM
                content = Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
            }
            else
            {
                // No BOM present: verify if decoding as Unicode yields a valid .reg header
                string unicodeCandidate = Encoding.Unicode.GetString(bytes);
                if (IsValidRegHeader(unicodeCandidate))
                {
                    content = unicodeCandidate;
                }
                else
                {
                    // Fallback to UTF-8
                    content = Encoding.UTF8.GetString(bytes);
                }
            }

            return ApplyRegContent(content);
        }
        catch (Exception ex)
        {
            _logger?.LogError(nameof(AtomicRegistryService), $"Failed to rollback registry from '{backupFilePath}': {ex.Message}");
            return false;
        }
    }

    private static bool IsValidRegHeader(string text)
    {
        return text.Contains("Windows Registry Editor", StringComparison.OrdinalIgnoreCase) ||
               text.Contains("REGEDIT4", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Generates standard Windows Registry Editor Version 5.00 export content in pure C#.
    /// </summary>
    public string GenerateRegContent(string rootKeyPath)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Windows Registry Editor Version 5.00");
        sb.AppendLine();

        string standardPath = RegistryPathNormalizer.ToStandardFormat(rootKeyPath);
        if (RegistryPathNormalizer.TrySplitHiveAndSubKey(standardPath, out _, out string subKey) && !string.IsNullOrEmpty(subKey))
        {
            // Reversible Rollback Sentinel: Wipes any rogue values or subkeys added during a failed transaction before recreating pre-mutation state
            sb.AppendLine($"[-{standardPath}]");
            sb.AppendLine();
        }

        ExportKeyRecursive(standardPath, sb);
        return sb.ToString();
    }

    private void ExportKeyRecursive(string keyPath, StringBuilder sb)
    {
        string standardPath = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (!_registryService.KeyExists(standardPath)) return;

        sb.AppendLine($"[{standardPath}]");

        var valueNames = _registryService.GetValueNames(standardPath);
        foreach (var valueName in valueNames)
        {
            object? val = _registryService.GetValue(standardPath, valueName);
            RegistryValueKind kind = _registryService.GetValueKind(standardPath, valueName);

            string formattedValue = FormatRegValue(valueName, val, kind);
            if (!string.IsNullOrEmpty(formattedValue))
            {
                sb.AppendLine(formattedValue);
            }
        }

        sb.AppendLine();

        var subKeys = _registryService.GetSubKeyNames(standardPath);
        foreach (var subKey in subKeys)
        {
            string childPath = $"{standardPath}\\{subKey}";
            ExportKeyRecursive(childPath, sb);
        }
    }

    private static string FormatRegValue(string valueName, object? val, RegistryValueKind kind)
    {
        string prefix = string.IsNullOrEmpty(valueName) ? "@" : $"\"{EscapeString(valueName)}\"";

        if (val == null) return $"{prefix}=\"\"";

        switch (kind)
        {
            case RegistryValueKind.DWord:
                uint dwordVal = val switch
                {
                    uint uVal => uVal,
                    int iVal => unchecked((uint)iVal),
                    long lVal => unchecked((uint)lVal),
                    ulong ulVal => unchecked((uint)ulVal),
                    short sVal => unchecked((uint)sVal),
                    ushort usVal => usVal,
                    byte bVal => bVal,
                    sbyte sbVal => unchecked((uint)sbVal),
                    _ => unchecked((uint)Convert.ToInt64(val, CultureInfo.InvariantCulture))
                };
                return $"{prefix}=dword:{dwordVal:x8}";

            case RegistryValueKind.QWord:
                ulong qwordVal = val switch
                {
                    ulong ulVal2 => ulVal2,
                    long lVal2 => unchecked((ulong)lVal2),
                    uint uVal2 => uVal2,
                    int iVal2 => unchecked((ulong)(long)iVal2),
                    short sVal2 => unchecked((ulong)(long)sVal2),
                    ushort usVal2 => usVal2,
                    byte bVal2 => bVal2,
                    sbyte sbVal2 => unchecked((ulong)(long)sbVal2),
                    _ => ulong.TryParse(val.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedUl)
                        ? parsedUl
                        : unchecked((ulong)Convert.ToInt64(val, CultureInfo.InvariantCulture))
                };
                byte[] qwordBytes = BitConverter.GetBytes(qwordVal);
                return $"{prefix}=hex(b):{FormatBytes(qwordBytes)}";

            case RegistryValueKind.Binary:
                byte[] binBytes = val is byte[] rawBytes ? rawBytes : Array.Empty<byte>();
                return $"{prefix}=hex:{FormatBytes(binBytes)}";

            case RegistryValueKind.MultiString:
                string[] multiStrs = val is string[] sa ? sa : (val is IEnumerable<string> es ? es.ToArray() : new[] { val.ToString() ?? string.Empty });
                byte[] multiBytes = EncodeMultiString(multiStrs);
                return $"{prefix}=hex(7):{FormatBytes(multiBytes)}";

            case RegistryValueKind.ExpandString:
                string expStr = val.ToString() ?? string.Empty;
                byte[] expBytes = Encoding.Unicode.GetBytes(expStr + "\0");
                return $"{prefix}=hex(2):{FormatBytes(expBytes)}";

            case RegistryValueKind.String:
            default:
                string strVal = val.ToString() ?? string.Empty;
                return $"{prefix}=\"{EscapeString(strVal)}\"";
        }
    }

    private static string FormatBytes(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0) return string.Empty;
        var parts = new string[bytes.Length];
        for (int i = 0; i < bytes.Length; i++)
        {
            parts[i] = bytes[i].ToString("x2", CultureInfo.InvariantCulture);
        }
        return string.Join(",", parts);
    }

    private static byte[] EncodeMultiString(string[] strings)
    {
        var ms = new MemoryStream();
        foreach (var s in strings)
        {
            byte[] bytes = Encoding.Unicode.GetBytes(s + "\0");
            ms.Write(bytes, 0, bytes.Length);
        }
        // Multi_sz ends with extra null terminator
        byte[] finalNull = Encoding.Unicode.GetBytes("\0");
        ms.Write(finalNull, 0, finalNull.Length);
        return ms.ToArray();
    }

    private static string EscapeString(string input)
    {
        return input.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static string UnescapeString(string input)
    {
        var sb = new StringBuilder(input.Length);
        bool escaping = false;
        for (int i = 0; i < input.Length; i++)
        {
            char c = input[i];
            if (escaping)
            {
                sb.Append(c);
                escaping = false;
            }
            else if (c == '\\')
            {
                escaping = true;
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    /// <summary>
    /// Pure C# parser and applier for Windows Registry .reg files (Version 5.00).
    /// Works cross-platform without requiring reg.exe.
    /// </summary>
    public bool ApplyRegContent(string regContent)
    {
        if (string.IsNullOrWhiteSpace(regContent)) return false;

        using var reader = new StringReader(regContent);
        string? currentKey = null;
        string? line;
        var lineAccumulator = new StringBuilder();

        while ((line = reader.ReadLine()) != null)
        {
            string trimmed = line.Trim();

            // Ignore comments and empty lines when not accumulating multiline values
            if (lineAccumulator.Length == 0 && (trimmed.StartsWith(';') || string.IsNullOrWhiteSpace(trimmed)))
            {
                continue;
            }

            // Check multiline continuation (ends with backslash)
            if (trimmed.EndsWith('\\'))
            {
                lineAccumulator.Append(trimmed[..^1].TrimEnd());
                continue;
            }

            string fullLine = lineAccumulator.Length > 0
                ? lineAccumulator.Append(trimmed).ToString()
                : trimmed;
            lineAccumulator.Clear();

            // Check for key header: [HKEY_...] or [-HKEY_...]
            if (fullLine.StartsWith('[') && fullLine.EndsWith(']'))
            {
                string headerContent = fullLine.Substring(1, fullLine.Length - 2).Trim();

                if (headerContent.StartsWith('-'))
                {
                    // Reversible Sentinel Deletion: [-KeyPath]
                    string keyToDelete = RegistryPathNormalizer.ToStandardFormat(headerContent[1..].Trim());
                    if (RegistryPathNormalizer.TrySplitHiveAndSubKey(keyToDelete, out _, out string subKey) && !string.IsNullOrEmpty(subKey))
                    {
                        _registryService.DeleteKey(keyToDelete, recursive: true);
                    }
                    currentKey = null;
                }
                else
                {
                    currentKey = RegistryPathNormalizer.ToStandardFormat(headerContent);
                    _registryService.CreateKey(currentKey);
                }
                continue;
            }

            // If we are within a key section, parse value definitions
            if (!string.IsNullOrEmpty(currentKey))
            {
                ApplyValueLine(currentKey, fullLine);
            }
        }

        return true;
    }

    private void ApplyValueLine(string keyPath, string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return;

        string valueName;
        string valueData;

        if (line.StartsWith("@="))
        {
            valueName = string.Empty; // default value
            valueData = line[2..];
        }
        else if (line.StartsWith('"'))
        {
            int closingQuote = -1;
            bool escaping = false;
            for (int i = 1; i < line.Length; i++)
            {
                if (escaping)
                {
                    escaping = false;
                }
                else if (line[i] == '\\')
                {
                    escaping = true;
                }
                else if (line[i] == '"')
                {
                    closingQuote = i;
                    break;
                }
            }

            if (closingQuote <= 0 || closingQuote + 1 >= line.Length || line[closingQuote + 1] != '=')
            {
                return; // invalid value line
            }

            valueName = UnescapeString(line.Substring(1, closingQuote - 1));
            valueData = line[(closingQuote + 2)..];
        }
        else
        {
            return;
        }

        // Value deletion: "Name"=-
        if (valueData == "-")
        {
            _registryService.DeleteValue(keyPath, valueName);
            return;
        }

        // String value: "string_content"
        if (valueData.StartsWith('"') && valueData.EndsWith('"') && valueData.Length >= 2)
        {
            string strValue = UnescapeString(valueData.Substring(1, valueData.Length - 2));
            _registryService.SetValue(keyPath, valueName, strValue, RegistryValueKind.String);
            return;
        }

        // DWORD value: dword:00000001
        if (valueData.StartsWith("dword:", StringComparison.OrdinalIgnoreCase))
        {
            string hexStr = valueData[6..];
            if (uint.TryParse(hexStr, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out uint dwordVal))
            {
                _registryService.SetValue(keyPath, valueName, unchecked((int)dwordVal), RegistryValueKind.DWord);
            }
            return;
        }

        // QWORD value: hex(b):01,00,...
        if (valueData.StartsWith("hex(b):", StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = ParseHexBytes(valueData[7..]);
            if (bytes.Length == 8)
            {
                long qwordVal = BitConverter.ToInt64(bytes, 0);
                _registryService.SetValue(keyPath, valueName, qwordVal, RegistryValueKind.QWord);
            }
            return;
        }

        // Multi-string: hex(7):...
        if (valueData.StartsWith("hex(7):", StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = ParseHexBytes(valueData[7..]);
            string[] strings = DecodeMultiString(bytes);
            _registryService.SetValue(keyPath, valueName, strings, RegistryValueKind.MultiString);
            return;
        }

        // Expand-string: hex(2):...
        if (valueData.StartsWith("hex(2):", StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = ParseHexBytes(valueData[7..]);
            string str = Encoding.Unicode.GetString(bytes).TrimEnd('\0');
            _registryService.SetValue(keyPath, valueName, str, RegistryValueKind.ExpandString);
            return;
        }

        // Binary: hex:...
        if (valueData.StartsWith("hex:", StringComparison.OrdinalIgnoreCase))
        {
            byte[] bytes = ParseHexBytes(valueData[4..]);
            _registryService.SetValue(keyPath, valueName, bytes, RegistryValueKind.Binary);
            return;
        }
    }

    private static byte[] ParseHexBytes(string hexCsv)
    {
        if (string.IsNullOrWhiteSpace(hexCsv)) return Array.Empty<byte>();
        var tokens = hexCsv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var bytes = new List<byte>(tokens.Length);
        foreach (var token in tokens)
        {
            if (byte.TryParse(token, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte b))
            {
                bytes.Add(b);
            }
        }
        return bytes.ToArray();
    }

    private static string[] DecodeMultiString(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0) return Array.Empty<string>();
        string full = Encoding.Unicode.GetString(bytes);
        // Split by null characters and filter out the final empty strings
        return full.Split('\0', StringSplitOptions.RemoveEmptyEntries);
    }
}
