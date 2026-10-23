namespace IToolkit.Core.Utilities;

using System.Text.RegularExpressions;

/// <summary>
/// Utility to normalize registry keys and produce filesystem-safe slugs for backup filenames.
/// </summary>
public static class RegistryPathNormalizer
{
    private static readonly Dictionary<string, string> HiveMap = new(StringComparer.OrdinalIgnoreCase)
    {
        { "HKLM", "HKEY_LOCAL_MACHINE" },
        { "HKLM:", "HKEY_LOCAL_MACHINE" },
        { "HKEY_LOCAL_MACHINE", "HKEY_LOCAL_MACHINE" },
        { "HKCU", "HKEY_CURRENT_USER" },
        { "HKCU:", "HKEY_CURRENT_USER" },
        { "HKEY_CURRENT_USER", "HKEY_CURRENT_USER" },
        { "HKCR", "HKEY_CLASSES_ROOT" },
        { "HKCR:", "HKEY_CLASSES_ROOT" },
        { "HKEY_CLASSES_ROOT", "HKEY_CLASSES_ROOT" },
        { "HKU", "HKEY_USERS" },
        { "HKU:", "HKEY_USERS" },
        { "HKEY_USERS", "HKEY_USERS" },
        { "HKCC", "HKEY_CURRENT_CONFIG" },
        { "HKCC:", "HKEY_CURRENT_CONFIG" },
        { "HKEY_CURRENT_CONFIG", "HKEY_CURRENT_CONFIG" }
    };

    /// <summary>
    /// Normalizes any registry path format (PowerShell drive style, abbreviated or standard) to canonical Windows Registry standard path.
    /// </summary>
    public static string ToStandardFormat(string keyPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyPath);

        string cleaned = keyPath.Trim().Replace('/', '\\');

        int firstSlash = cleaned.IndexOf('\\');
        string root = firstSlash >= 0 ? cleaned[..firstSlash] : cleaned;
        string subKey = firstSlash >= 0 ? cleaned[(firstSlash + 1)..].Trim('\\') : string.Empty;

        if (HiveMap.TryGetValue(root, out string? standardHive))
        {
            return string.IsNullOrEmpty(subKey) ? standardHive : $"{standardHive}\\{subKey}";
        }

        return cleaned.TrimEnd('\\');
    }

    /// <summary>
    /// Converts a registry path into a safe filename slug for .reg backups.
    /// </summary>
    public static string ToSafeFileNameSlug(string keyPath)
    {
        string standard = ToStandardFormat(keyPath);
        string sanitized = Regex.Replace(standard, @"[\\/:*?""<>| ]", "_");
        return Regex.Replace(sanitized, @"_+", "_").Trim('_');
    }

    /// <summary>
    /// Splits a canonical registry path into its top-level root hive and relative subkey path.
    /// </summary>
    public static bool TrySplitHiveAndSubKey(string standardPath, out string hive, out string subKey)
    {
        string normalized = ToStandardFormat(standardPath);
        int firstSlash = normalized.IndexOf('\\');
        if (firstSlash >= 0)
        {
            hive = normalized[..firstSlash];
            subKey = normalized[(firstSlash + 1)..].Trim('\\');
            return true;
        }

        hive = normalized;
        subKey = string.Empty;
        return true;
    }
}
