namespace IToolkit.Tests.TestDoubles;

using IToolkit.Core.Abstractions;

/// <summary>
/// In-memory test double for IOutlookComService.
/// </summary>
public class MockOutlookComService : IOutlookComService
{
    private readonly Dictionary<string, List<string>> _storeFolders = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, List<string>> _storeRules = new(StringComparer.OrdinalIgnoreCase);

    public bool OutlookAvailable { get; set; } = true;
    public bool DefaultStoreSet { get; private set; }
    public string? LastDefaultStorePath { get; private set; }
    public bool CompactInvoked { get; private set; }

    public void AddStoreFolder(string pstPath, string folderPath)
    {
        if (!_storeFolders.TryGetValue(pstPath, out var list))
        {
            list = new List<string>();
            _storeFolders[pstPath] = list;
        }
        list.Add(folderPath);
    }

    public void AddStoreRule(string pstPath, string ruleName)
    {
        if (!_storeRules.TryGetValue(pstPath, out var list))
        {
            list = new List<string>();
            _storeRules[pstPath] = list;
        }
        list.Add(ruleName);
    }

    public void SeedFolder(string pstPath, string folderPath) => AddStoreFolder(pstPath, folderPath);

    public void SeedRule(string pstPath, string ruleName) => AddStoreRule(pstPath, ruleName);

    public bool IsOutlookAvailable() => OutlookAvailable;

    public IReadOnlyList<string> GetStoreFolders(string pstPath) =>
        _storeFolders.TryGetValue(pstPath, out var list) ? list : Array.Empty<string>();

    public int CloneFolderHierarchy(string sourcePstPath, string targetPstPath, IEnumerable<string>? excludedFolders = null)
    {
        var excluded = new HashSet<string>(excludedFolders ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        if (!_storeFolders.TryGetValue(sourcePstPath, out var folders))
        {
            return 0;
        }

        int cloned = 0;
        foreach (var folder in folders)
        {
            if (!excluded.Contains(folder))
            {
                AddStoreFolder(targetPstPath, folder);
                cloned++;
            }
        }
        return cloned;
    }

    public int MigrateRules(string sourcePstPath, string targetPstPath)
    {
        if (!_storeRules.TryGetValue(sourcePstPath, out var rules))
        {
            return 0;
        }

        foreach (var r in rules)
        {
            AddStoreRule(targetPstPath, r);
        }
        return rules.Count;
    }

    public bool SetDefaultDeliveryStore(string pstPath)
    {
        DefaultStoreSet = true;
        LastDefaultStorePath = pstPath;
        return true;
    }

    public bool CompactStore(string pstPath)
    {
        CompactInvoked = true;
        return true;
    }
}
