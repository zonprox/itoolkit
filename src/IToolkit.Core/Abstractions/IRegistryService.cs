namespace IToolkit.Core.Abstractions;

using Microsoft.Win32;

/// <summary>
/// Abstraction for Windows Registry operations enabling testability and cross-platform verification.
/// </summary>
public interface IRegistryService
{
    /// <summary>
    /// Checks if a registry key exists at the given path.
    /// </summary>
    bool KeyExists(string keyPath);

    /// <summary>
    /// Checks if a named value exists under the specified registry key.
    /// </summary>
    bool ValueExists(string keyPath, string valueName);

    /// <summary>
    /// Retrieves the raw object value for a given registry key and value name.
    /// </summary>
    object? GetValue(string keyPath, string valueName);

    /// <summary>
    /// Retrieves a typed value from the registry.
    /// </summary>
    T? GetValue<T>(string keyPath, string valueName);

    /// <summary>
    /// Retrieves the registry data type for a specified value.
    /// </summary>
    RegistryValueKind GetValueKind(string keyPath, string valueName);

    /// <summary>
    /// Sets a registry value with the specified data kind.
    /// </summary>
    bool SetValue(string keyPath, string valueName, object value, RegistryValueKind kind);

    /// <summary>
    /// Deletes a named value from a registry key.
    /// </summary>
    bool DeleteValue(string keyPath, string valueName);

    /// <summary>
    /// Creates a registry key at the specified path.
    /// </summary>
    bool CreateKey(string keyPath);

    /// <summary>
    /// Deletes a registry key and optionally all of its subkeys.
    /// </summary>
    bool DeleteKey(string keyPath, bool recursive = true);

    /// <summary>
    /// Enumerates subkey names directly under the specified key path.
    /// </summary>
    IEnumerable<string> GetSubKeyNames(string keyPath);

    /// <summary>
    /// Enumerates value names stored directly under the specified key path.
    /// </summary>
    IEnumerable<string> GetValueNames(string keyPath);
}
