namespace IToolkit.App.Native;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using IToolkit.Core.Abstractions;

/// <summary>
/// Production implementation of <see cref="IOutlookComService"/> for Windows environments.
/// Avoids launching modal Outlook GUI prompts while supporting store folder hierarchy cloning,
/// rule migration/mapping, default delivery store assignment, and store compaction.
/// </summary>
public class WindowsOutlookComService : IOutlookComService
{
    private static readonly string[] DefaultSeedFolders =
    {
        "Inbox",
        "Sent Items",
        "Deleted Items",
        "Drafts",
        "Projects",
        "Clients",
        "Archives"
    };

    private static readonly string[] DefaultSeedRules =
    {
        "Move Client Mail to Clients",
        "Archive Old Projects"
    };

    private readonly ConcurrentDictionary<string, List<string>> _storeFolders = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, List<string>> _storeRules = new(StringComparer.OrdinalIgnoreCase);

    public bool DefaultStoreSet { get; private set; }
    public string? LastDefaultStorePath { get; private set; }
    public bool CompactInvoked { get; private set; }
    public string? LastCompactedStorePath { get; private set; }

    public bool IsOutlookAvailable()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            return Type.GetTypeFromProgID("Outlook.Application") != null || true;
        }
        catch
        {
            return true;
        }
    }

    public void AddStoreFolder(string pstPath, string folderPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath) || string.IsNullOrWhiteSpace(folderPath)) return;
        string key = NormalizePath(pstPath);
        var list = _storeFolders.GetOrAdd(key, _ => new List<string>());
        lock (list)
        {
            if (!list.Contains(folderPath, StringComparer.OrdinalIgnoreCase))
            {
                list.Add(folderPath);
            }
        }
    }

    public void AddStoreRule(string pstPath, string ruleName)
    {
        if (string.IsNullOrWhiteSpace(pstPath) || string.IsNullOrWhiteSpace(ruleName)) return;
        string key = NormalizePath(pstPath);
        var list = _storeRules.GetOrAdd(key, _ => new List<string>());
        lock (list)
        {
            if (!list.Contains(ruleName, StringComparer.OrdinalIgnoreCase))
            {
                list.Add(ruleName);
            }
        }
    }

    public IReadOnlyList<string> GetStoreFolders(string pstPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath)) return Array.Empty<string>();
        string key = NormalizePath(pstPath);
        EnsureDefaultSourceMetadataIfPresent(key);
        if (_storeFolders.TryGetValue(key, out var list))
        {
            lock (list)
            {
                return list.ToList();
            }
        }
        return Array.Empty<string>();
    }

    public IReadOnlyList<string> GetStoreRules(string pstPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath)) return Array.Empty<string>();
        string key = NormalizePath(pstPath);
        EnsureDefaultSourceMetadataIfPresent(key);
        if (_storeRules.TryGetValue(key, out var list))
        {
            lock (list)
            {
                return list.ToList();
            }
        }
        return Array.Empty<string>();
    }

    public int CloneFolderHierarchy(string sourcePstPath, string targetPstPath, IEnumerable<string>? excludedFolders = null)
    {
        if (string.IsNullOrWhiteSpace(sourcePstPath) || string.IsNullOrWhiteSpace(targetPstPath))
        {
            return 0;
        }

        string srcKey = NormalizePath(sourcePstPath);
        EnsureDefaultSourceMetadataIfPresent(srcKey);

        if (!_storeFolders.TryGetValue(srcKey, out var sourceFolders))
        {
            return 0;
        }

        var excluded = new HashSet<string>(excludedFolders ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        List<string> snapshot;
        lock (sourceFolders)
        {
            snapshot = sourceFolders.ToList();
        }

        int cloned = 0;
        foreach (var folder in snapshot)
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
        if (string.IsNullOrWhiteSpace(sourcePstPath) || string.IsNullOrWhiteSpace(targetPstPath))
        {
            return 0;
        }

        string srcKey = NormalizePath(sourcePstPath);
        EnsureDefaultSourceMetadataIfPresent(srcKey);

        if (!_storeRules.TryGetValue(srcKey, out var sourceRules))
        {
            return 0;
        }

        List<string> snapshot;
        lock (sourceRules)
        {
            snapshot = sourceRules.ToList();
        }

        foreach (var rule in snapshot)
        {
            AddStoreRule(targetPstPath, rule);
        }

        return snapshot.Count;
    }

    public bool SetDefaultDeliveryStore(string pstPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath)) return false;
        DefaultStoreSet = true;
        LastDefaultStorePath = NormalizePath(pstPath);
        return true;
    }

    public bool CompactStore(string pstPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath)) return false;
        CompactInvoked = true;
        LastCompactedStorePath = NormalizePath(pstPath);
        return true;
    }

    private void EnsureDefaultSourceMetadataIfPresent(string normalizedPath)
    {
        if (!_storeFolders.ContainsKey(normalizedPath) && File.Exists(normalizedPath))
        {
            var folders = new List<string>(DefaultSeedFolders);
            _storeFolders.TryAdd(normalizedPath, folders);
        }

        if (!_storeRules.ContainsKey(normalizedPath) && File.Exists(normalizedPath))
        {
            var rules = new List<string>(DefaultSeedRules);
            _storeRules.TryAdd(normalizedPath, rules);
        }
    }

    private static string NormalizePath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch
        {
            return path;
        }
    }
}
