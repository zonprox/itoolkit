namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Utilities;

public class WindowsRegistryService : IRegistryService
{
    private static RegistryKey? GetRootHive(string hiveName, bool writable = false)
    {
        var view = RegistryView.Registry64;
        return hiveName.ToUpperInvariant() switch
        {
            "HKEY_LOCAL_MACHINE" or "HKLM" => RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view),
            "HKEY_CURRENT_USER" or "HKCU" => RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, view),
            "HKEY_CLASSES_ROOT" or "HKCR" => RegistryKey.OpenBaseKey(RegistryHive.ClassesRoot, view),
            "HKEY_USERS" or "HKU" => RegistryKey.OpenBaseKey(RegistryHive.Users, view),
            "HKEY_CURRENT_CONFIG" or "HKCC" => RegistryKey.OpenBaseKey(RegistryHive.CurrentConfig, view),
            _ => null
        };
    }

    public bool KeyExists(string keyPath)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
            using var root = GetRootHive(hive);
            if (root == null) return false;
            if (string.IsNullOrEmpty(subKey)) return true;
            using var target = root.OpenSubKey(subKey, false);
            return target != null;
        }
        catch
        {
            return false;
        }
    }

    public bool ValueExists(string keyPath, string valueName)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
            using var root = GetRootHive(hive);
            using var target = root?.OpenSubKey(subKey, false);
            return target?.GetValue(valueName) != null;
        }
        catch
        {
            return false;
        }
    }

    public object? GetValue(string keyPath, string valueName)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return null;
            using var root = GetRootHive(hive);
            using var target = root?.OpenSubKey(subKey, false);
            return target?.GetValue(valueName);
        }
        catch
        {
            return null;
        }
    }

    public T? GetValue<T>(string keyPath, string valueName)
    {
        var val = GetValue(keyPath, valueName);
        if (val == null) return default;
        if (val is T typed) return typed;
        try { return (T)Convert.ChangeType(val, typeof(T)); }
        catch { return default; }
    }

    public RegistryValueKind GetValueKind(string keyPath, string valueName)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return RegistryValueKind.Unknown;
            using var root = GetRootHive(hive);
            using var target = root?.OpenSubKey(subKey, false);
            if (target?.GetValue(valueName) == null) return RegistryValueKind.Unknown;
            return target.GetValueKind(valueName);
        }
        catch
        {
            return RegistryValueKind.Unknown;
        }
    }

    public bool SetValue(string keyPath, string valueName, object value, RegistryValueKind kind)
    {
        if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
        using var root = GetRootHive(hive, true);
        if (root == null) return false;
        using var target = root.CreateSubKey(subKey, true);
        target?.SetValue(valueName, value, kind);
        return true;
    }

    public bool DeleteValue(string keyPath, string valueName)
    {
        if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
        using var root = GetRootHive(hive, true);
        using var target = root?.OpenSubKey(subKey, true);
        if (target == null) return false;
        target.DeleteValue(valueName, false);
        return true;
    }

    public bool CreateKey(string keyPath)
    {
        if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
        using var root = GetRootHive(hive, true);
        if (root == null) return false;
        using var created = root.CreateSubKey(subKey, true);
        return created != null;
    }

    public bool DeleteKey(string keyPath, bool recursive = true)
    {
        if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return false;
        using var root = GetRootHive(hive, true);
        if (root == null || string.IsNullOrEmpty(subKey)) return false;
        if (recursive) root.DeleteSubKeyTree(subKey, false);
        else root.DeleteSubKey(subKey, false);
        return true;
    }

    public IEnumerable<string> GetSubKeyNames(string keyPath)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return Array.Empty<string>();
            using var root = GetRootHive(hive);
            using var target = root?.OpenSubKey(subKey, false);
            return target?.GetSubKeyNames() ?? Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    public IEnumerable<string> GetValueNames(string keyPath)
    {
        try
        {
            if (!RegistryPathNormalizer.TrySplitHiveAndSubKey(keyPath, out var hive, out var subKey)) return Array.Empty<string>();
            using var root = GetRootHive(hive);
            using var target = root?.OpenSubKey(subKey, false);
            return target?.GetValueNames() ?? Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }
}
