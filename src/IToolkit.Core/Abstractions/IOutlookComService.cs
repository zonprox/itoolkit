namespace IToolkit.Core.Abstractions;

/// <summary>
/// Abstraction for Outlook COM automation: store enumeration, folder hierarchy cloning,
/// rule migration, and default delivery store assignment.
/// </summary>
public interface IOutlookComService
{
    /// <summary>
    /// Checks whether the Outlook application or COM automation server is installed and available.
    /// </summary>
    bool IsOutlookAvailable();

    /// <summary>
    /// Enumerates folder paths from a specified PST/OST data file or store.
    /// </summary>
    IReadOnlyList<string> GetStoreFolders(string pstPath);

    /// <summary>
    /// Clones custom user folders from source store to target store, skipping standard system folders.
    /// Returns the count of cloned folders.
    /// </summary>
    int CloneFolderHierarchy(string sourcePstPath, string targetPstPath, IEnumerable<string>? excludedFolders = null);

    /// <summary>
    /// Migrates or imports rules from source store to target store.
    /// Returns the count of migrated rules.
    /// </summary>
    int MigrateRules(string sourcePstPath, string targetPstPath);

    /// <summary>
    /// Sets the specified data file as the default delivery store in Outlook MAPI profile.
    /// </summary>
    bool SetDefaultDeliveryStore(string pstPath);

    /// <summary>
    /// Triggers compact operation on the specified PST store via Outlook COM.
    /// </summary>
    bool CompactStore(string pstPath);
}
