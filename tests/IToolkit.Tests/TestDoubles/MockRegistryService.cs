namespace IToolkit.Tests.TestDoubles;

using System.Globalization;
using Microsoft.Win32;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Utilities;

/// <summary>
/// In-memory test double for IRegistryService allowing full fidelity registry simulation in tests.
/// </summary>
public class MockRegistryService : IRegistryService
{
    private class KeyEntry
    {
        public Dictionary<string, (object Value, RegistryValueKind Kind)> Values { get; } =
            new(StringComparer.OrdinalIgnoreCase);
    }

    private readonly Dictionary<string, KeyEntry> _keys = new(StringComparer.OrdinalIgnoreCase);

    public bool KeyExists(string keyPath)
    {
        if (string.IsNullOrWhiteSpace(keyPath)) return false;
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        return _keys.ContainsKey(standard);
    }

    public bool ValueExists(string keyPath, string valueName)
    {
        if (string.IsNullOrWhiteSpace(keyPath)) return false;
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        return _keys.TryGetValue(standard, out var entry) && entry.Values.ContainsKey(valueName);
    }

    public object? GetValue(string keyPath, string valueName)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (_keys.TryGetValue(standard, out var entry) && entry.Values.TryGetValue(valueName, out var tuple))
        {
            return tuple.Value;
        }
        return null;
    }

    public T? GetValue<T>(string keyPath, string valueName)
    {
        object? val = GetValue(keyPath, valueName);
        if (val == null) return default;
        if (val is T typed) return typed;
        return (T)Convert.ChangeType(val, typeof(T), CultureInfo.InvariantCulture);
    }

    public RegistryValueKind GetValueKind(string keyPath, string valueName)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (_keys.TryGetValue(standard, out var entry) && entry.Values.TryGetValue(valueName, out var tuple))
        {
            return tuple.Kind;
        }
        return RegistryValueKind.None;
    }

    public bool SetValue(string keyPath, string valueName, object value, RegistryValueKind kind)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (!_keys.TryGetValue(standard, out var entry))
        {
            entry = new KeyEntry();
            _keys[standard] = entry;
        }

        entry.Values[valueName] = (value, kind);
        return true;
    }

    public bool DeleteValue(string keyPath, string valueName)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (_keys.TryGetValue(standard, out var entry))
        {
            return entry.Values.Remove(valueName);
        }
        return false;
    }

    public bool CreateKey(string keyPath)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (!_keys.ContainsKey(standard))
        {
            _keys[standard] = new KeyEntry();
        }
        return true;
    }

    public bool DeleteKey(string keyPath, bool recursive = true)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);

        if (recursive)
        {
            var keysToRemove = _keys.Keys
                .Where(k => k.Equals(standard, StringComparison.OrdinalIgnoreCase) ||
                            k.StartsWith(standard + "\\", StringComparison.OrdinalIgnoreCase))
                .ToList();

            foreach (var k in keysToRemove)
            {
                _keys.Remove(k);
            }
            return keysToRemove.Count > 0;
        }

        return _keys.Remove(standard);
    }

    public IEnumerable<string> GetSubKeyNames(string keyPath)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        string prefix = standard + "\\";

        var subKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var k in _keys.Keys)
        {
            if (k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                string relative = k[prefix.Length..];
                int slashIndex = relative.IndexOf('\\');
                string directChild = slashIndex >= 0 ? relative[..slashIndex] : relative;
                if (!string.IsNullOrEmpty(directChild))
                {
                    subKeys.Add(directChild);
                }
            }
        }
        return subKeys;
    }

    public IEnumerable<string> GetValueNames(string keyPath)
    {
        string standard = RegistryPathNormalizer.ToStandardFormat(keyPath);
        if (_keys.TryGetValue(standard, out var entry))
        {
            return entry.Values.Keys.ToList();
        }
        return Enumerable.Empty<string>();
    }
}
