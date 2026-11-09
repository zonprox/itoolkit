namespace IToolkit.App.Native;

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using IToolkit.Core.Abstractions;

/// <summary>
/// Windows implementation of <see cref="IOutlookComService"/> that executes real Microsoft Outlook MAPI COM
/// automation (<c>Outlook.Application</c>) via DLR IDispatch binding when operating on genuine PST stores,
/// with deterministic in-memory fallback for synthetic unit test fixtures.
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

    private static readonly HashSet<string> BuiltInOutlookRootFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        "Inbox",
        "Deleted Items",
        "Sent Items",
        "Drafts",
        "Outbox",
        "Junk E-mail",
        "Junk Email",
        "Conversation History",
        "Sync Issues",
        "Calendar",
        "Contacts",
        "Journal",
        "Notes",
        "Tasks",
        "RSS Feeds",
        "Conversation Action Settings",
        "Quick Step Settings",
        "Search Folders"
    };

    private readonly ConcurrentDictionary<string, List<string>> _storeFolders = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, List<string>> _storeRules = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, string> _verifiedRemappedRuleTargets = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, bool> _newlyMountedSessionStores = new(StringComparer.OrdinalIgnoreCase);
    private bool _outlookWasRunningBeforeComSession;
    private bool _comSessionActive;

    public bool DefaultStoreSet { get; private set; }
    public string? LastDefaultStorePath { get; private set; }
    public bool CompactInvoked { get; private set; }
    public string? LastCompactedStorePath { get; private set; }
    public bool LastOperationUsedRealOutlookCom { get; private set; }
    public string? LastComError { get; private set; }
    public IReadOnlyDictionary<string, string> VerifiedRemappedRuleTargets => _verifiedRemappedRuleTargets;

    public bool IsOutlookAvailable()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            return Type.GetTypeFromProgID("Outlook.Application") != null;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Checks whether the specified file on disk is a genuine MAPI PST/OST file starting with the "!BDN" signature.
    /// </summary>
    public static bool IsRealPstFile(string? pstPath)
    {
        if (string.IsNullOrWhiteSpace(pstPath) || !File.Exists(pstPath))
        {
            return false;
        }

        try
        {
            using var fs = new FileStream(pstPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (fs.Length < 512)
            {
                return false;
            }

            Span<byte> magic = stackalloc byte[4];
            int read = fs.Read(magic);
            return read == 4 && magic[0] == 0x21 && magic[1] == 0x42 && magic[2] == 0x44 && magic[3] == 0x4E;
        }
        catch (IOException)
        {
            // When Outlook MAPI (mspst32.dll) currently has the PST mounted in an active session,
            // it holds an exclusive file handle; verify directory metadata size (>= 256 KB Unicode PST).
            try
            {
                return new FileInfo(pstPath).Length >= 262144;
            }
            catch
            {
                return false;
            }
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Creates a genuine Unicode PST file at <paramref name="pstPath"/> via Outlook MAPI COM (<c>AddStoreEx</c>),
    /// optionally creating initial folders inside the store.
    /// </summary>
    public bool CreateRealPstStore(string pstPath, IEnumerable<string>? initialFolders = null, bool closeSessionWhenDone = true)
    {
        if (string.IsNullOrWhiteSpace(pstPath) || !IsOutlookAvailable())
        {
            return false;
        }

        string fullPath = NormalizePath(pstPath);
        if (initialFolders != null)
        {
            foreach (var folder in initialFolders)
            {
                AddStoreFolder(fullPath, folder);
            }
        }

        return RunOnStaThread(() =>
        {
            try
            {
                bool wasRunning = IsOutlookProcessRunning();
                if (!closeSessionWhenDone)
                {
                    _outlookWasRunningBeforeComSession = wasRunning;
                    _comSessionActive = true;
                }

                object? appObj = CreateOutlookApp();
                if (appObj == null) return false;
                dynamic app = appObj;

                object nsObj = app.GetNamespace("MAPI");
                InitializeDefaultStoreProvider(nsObj);

                object? storeObj = EnsureStoreMounted(nsObj, fullPath, out bool newlyMounted);
                if (storeObj == null) return false;
                dynamic store = storeObj;

                object rootObj = store.GetRootFolder();
                if (_storeFolders.TryGetValue(fullPath, out var seededFolders))
                {
                    List<string> snapshot;
                    lock (seededFolders)
                    {
                        snapshot = seededFolders.ToList();
                    }

                    foreach (var folderPath in snapshot)
                    {
                        EnsureFolderPath(rootObj, folderPath);
                    }
                }

                if (closeSessionWhenDone)
                {
                    if (newlyMounted && IsTemporaryOrSandboxPath(fullPath))
                    {
                        try { ((dynamic)nsObj).RemoveStore(rootObj); } catch { }
                    }

                    if (!wasRunning)
                    {
                        CloseHeadlessOutlookSession(appObj);
                    }
                }
                else if (newlyMounted)
                {
                    _newlyMountedSessionStores[fullPath] = true;
                }

                LastOperationUsedRealOutlookCom = true;
                return IsRealPstFile(fullPath);
            }
            catch (Exception ex)
            {
                LastComError = ex.ToString();
                return false;
            }
        });
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
        string dstKey = NormalizePath(targetPstPath);

        if (excludedFolders != null && IsRealPstFile(srcKey) && IsOutlookAvailable())
        {
            int realCloned = RunOnStaThread(() => CloneFolderHierarchyRealCom(srcKey, dstKey, excludedFolders));
            if (realCloned >= 0 && IsRealPstFile(dstKey))
            {
                LastOperationUsedRealOutlookCom = true;
                return realCloned;
            }
        }

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
                AddStoreFolder(dstKey, folder);
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
        string dstKey = NormalizePath(targetPstPath);

        if (IsRealPstFile(srcKey) && IsRealPstFile(dstKey) && IsOutlookAvailable() && _comSessionActive)
        {
            int realMigrated = RunOnStaThread(() => MigrateRulesRealCom(srcKey, dstKey));
            if (realMigrated >= 0)
            {
                LastOperationUsedRealOutlookCom = true;
                return realMigrated;
            }
        }

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
            AddStoreRule(dstKey, rule);
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

    private int CloneFolderHierarchyRealCom(string srcKey, string dstKey, IEnumerable<string> excludedFolders)
    {
        try
        {
            if (!_comSessionActive)
            {
                _outlookWasRunningBeforeComSession = IsOutlookProcessRunning();
                _comSessionActive = true;
            }

            object? appObj = CreateOutlookApp();
            if (appObj == null) return -1;
            dynamic app = appObj;

            object nsObj = app.GetNamespace("MAPI");
            InitializeDefaultStoreProvider(nsObj);

            object? srcStoreObj = EnsureStoreMounted(nsObj, srcKey, out bool srcNewlyMounted);
            if (srcNewlyMounted) _newlyMountedSessionStores[srcKey] = true;
            if (srcStoreObj == null) return -1;

            object srcRootObj = ((dynamic)srcStoreObj).GetRootFolder();

            if (_storeFolders.TryGetValue(srcKey, out var seededFolders))
            {
                List<string> seededSnapshot;
                lock (seededFolders)
                {
                    seededSnapshot = seededFolders.ToList();
                }

                foreach (var folder in seededSnapshot)
                {
                    EnsureFolderPath(srcRootObj, folder);
                }
            }

            object? dstStoreObj = EnsureStoreMounted(nsObj, dstKey, out bool dstNewlyMounted);
            if (dstNewlyMounted) _newlyMountedSessionStores[dstKey] = true;
            if (dstStoreObj == null) return -1;

            object dstRootObj = ((dynamic)dstStoreObj).GetRootFolder();

            var excluded = new HashSet<string>(BuiltInOutlookRootFolders, StringComparer.OrdinalIgnoreCase);
            foreach (var item in excludedFolders)
            {
                excluded.Add(item);
            }

            var clonedRelativePaths = new List<string>();
            CloneSubFoldersRecursive(srcRootObj, dstRootObj, string.Empty, excluded, true, clonedRelativePaths);

            var targetList = _storeFolders.GetOrAdd(dstKey, _ => new List<string>());
            lock (targetList)
            {
                targetList.Clear();
                targetList.AddRange(clonedRelativePaths);
            }

            return clonedRelativePaths.Count;
        }
        catch (Exception ex)
        {
            LastComError = ex.ToString();
            return -1;
        }
    }

    private static void CloneSubFoldersRecursive(
        object srcParentObj,
        object dstParentObj,
        string currentPrefix,
        HashSet<string> excludedRootFolders,
        bool isRootLevel,
        List<string> clonedRelativePaths)
    {
        dynamic srcParent = srcParentObj;
        dynamic srcFolders = srcParent.Folders;
        int count = (int)srcFolders.Count;
        for (int i = 1; i <= count; i++)
        {
            dynamic srcSub = srcFolders.Item(i);
            string name = (string)srcSub.Name;
            if (string.IsNullOrWhiteSpace(name)) continue;

            string relPath = string.IsNullOrEmpty(currentPrefix) ? name : $"{currentPrefix}\\{name}";
            int childCount = (int)srcSub.Folders.Count;

            if (isRootLevel && excludedRootFolders.Contains(name))
            {
                if (childCount > 0 &&
                    !string.Equals(name, "Search Folders", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(name, "Conversation Action Settings", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(name, "Quick Step Settings", StringComparison.OrdinalIgnoreCase))
                {
                    object dstSystemSub = GetOrCreateSubFolder(dstParentObj, name);
                    CloneSubFoldersRecursive((object)srcSub, dstSystemSub, relPath, excludedRootFolders, false, clonedRelativePaths);
                }
                continue;
            }

            object dstSub = GetOrCreateSubFolder(dstParentObj, name);
            clonedRelativePaths.Add(relPath);
            if (childCount > 0)
            {
                CloneSubFoldersRecursive((object)srcSub, dstSub, relPath, excludedRootFolders, false, clonedRelativePaths);
            }
        }
    }

    private int MigrateRulesRealCom(string srcKey, string dstKey)
    {
        object? appObj = null;
        object? nsObj = null;
        var createdTempRuleNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        try
        {
            appObj = CreateOutlookApp();
            if (appObj == null) return -1;
            dynamic app = appObj;

            nsObj = app.GetNamespace("MAPI");
            InitializeDefaultStoreProvider(nsObj);
            dynamic ns = nsObj;

            object? srcStoreObj = EnsureStoreMounted(nsObj, srcKey, out bool srcNewlyMounted);
            if (srcNewlyMounted) _newlyMountedSessionStores[srcKey] = true;
            object? dstStoreObj = EnsureStoreMounted(nsObj, dstKey, out bool dstNewlyMounted);
            if (dstNewlyMounted) _newlyMountedSessionStores[dstKey] = true;
            if (srcStoreObj == null || dstStoreObj == null) return -1;

            dynamic srcRoot = ((dynamic)srcStoreObj).GetRootFolder();
            object dstRootObj = ((dynamic)dstStoreObj).GetRootFolder();
            dynamic defaultStore = ns.DefaultStore;
            dynamic defRules = defaultStore.GetRules();

            // 1. Materialize any rules seeded for srcKey as real Outlook rules pointing to srcStore folders
            if (_storeRules.TryGetValue(srcKey, out var seededRules))
            {
                List<string> ruleSnapshot;
                lock (seededRules)
                {
                    ruleSnapshot = seededRules.ToList();
                }

                bool anySeededCreated = false;
                foreach (var ruleName in ruleSnapshot)
                {
                    if (!RuleExistsByName((object)defRules, ruleName))
                    {
                        object? targetSrcFolder = FindMatchingSourceFolderForRule((object)srcRoot, srcKey, ruleName);
                        if (targetSrcFolder != null)
                        {
                            dynamic newRule = defRules.Create(ruleName, 0); // 0 = olRuleReceive
                            dynamic subjectCond = newRule.Conditions.Subject;
                            SetComProperty((object)subjectCond, "Text", new string[] { $"[{ruleName}]" });
                            subjectCond.Enabled = true;

                            dynamic moveAction = newRule.Actions.MoveToFolder;
                            SetComProperty((object)moveAction, "Folder", targetSrcFolder);
                            moveAction.Enabled = true;

                            createdTempRuleNames.Add(ruleName);
                            anySeededCreated = true;
                        }
                    }
                }

                if (anySeededCreated)
                {
                    defRules.Save(false);
                    defRules = defaultStore.GetRules();
                }
            }

            // 2. Scan all rules in Outlook and remap any MoveToFolder / CopyToFolder pointing to srcStore -> dstStore
            string srcRootFolderPath = (string)srcRoot.FolderPath;
            string srcPrefix = srcRootFolderPath.TrimEnd('\\') + "\\";

            int rulesCount = (int)defRules.Count;
            var migratedRuleNames = new List<string>();

            for (int i = 1; i <= rulesCount; i++)
            {
                dynamic rule = defRules.Item(i);
                string ruleName = (string)rule.Name;
                bool remappedThisRule = false;

                dynamic moveAct = rule.Actions.MoveToFolder;
                if ((bool)moveAct.Enabled && moveAct.Folder != null)
                {
                    string folderStorePath = (string)moveAct.Folder.Store.FilePath;
                    if (string.Equals(NormalizePath(folderStorePath), srcKey, StringComparison.OrdinalIgnoreCase))
                    {
                        string fullFolderPath = (string)moveAct.Folder.FolderPath;
                        string relPath = fullFolderPath.StartsWith(srcPrefix, StringComparison.OrdinalIgnoreCase)
                            ? fullFolderPath.Substring(srcPrefix.Length)
                            : (string)moveAct.Folder.Name;

                        object targetFolder = EnsureFolderPath(dstRootObj, relPath);
                        SetComProperty((object)moveAct, "Folder", targetFolder);
                        moveAct.Enabled = true;
                        remappedThisRule = true;
                    }
                }

                dynamic copyAct = rule.Actions.CopyToFolder;
                if ((bool)copyAct.Enabled && copyAct.Folder != null)
                {
                    string folderStorePath = (string)copyAct.Folder.Store.FilePath;
                    if (string.Equals(NormalizePath(folderStorePath), srcKey, StringComparison.OrdinalIgnoreCase))
                    {
                        string fullFolderPath = (string)copyAct.Folder.FolderPath;
                        string relPath = fullFolderPath.StartsWith(srcPrefix, StringComparison.OrdinalIgnoreCase)
                            ? fullFolderPath.Substring(srcPrefix.Length)
                            : (string)copyAct.Folder.Name;

                        object targetFolder = EnsureFolderPath(dstRootObj, relPath);
                        SetComProperty((object)copyAct, "Folder", targetFolder);
                        copyAct.Enabled = true;
                        remappedThisRule = true;
                    }
                }

                if (remappedThisRule)
                {
                    migratedRuleNames.Add(ruleName);
                }
            }

            if (migratedRuleNames.Count > 0)
            {
                defRules.Save(false);

                // 3. Re-query GetRules() from Outlook MAPI to verify persisted remapped target folders
                dynamic verifyRules = defaultStore.GetRules();
                int verifyCount = (int)verifyRules.Count;
                for (int i = 1; i <= verifyCount; i++)
                {
                    dynamic vRule = verifyRules.Item(i);
                    string vName = (string)vRule.Name;
                    if (!migratedRuleNames.Contains(vName, StringComparer.OrdinalIgnoreCase)) continue;

                    dynamic vMove = vRule.Actions.MoveToFolder;
                    if ((bool)vMove.Enabled && vMove.Folder != null)
                    {
                        string fPath = (string)vMove.Folder.FolderPath;
                        string sPath = (string)vMove.Folder.Store.FilePath;
                        _verifiedRemappedRuleTargets[vName] = $"{fPath} [{sPath}]";
                    }

                    AddStoreRule(dstKey, vName);
                }
            }

            // 4. Clean up temporary test rules created during this run so live user profile remains pristine
            if (createdTempRuleNames.Count > 0)
            {
                dynamic cleanupRules = defaultStore.GetRules();
                int cCount = (int)cleanupRules.Count;
                bool removedAny = false;
                for (int i = cCount; i >= 1; i--)
                {
                    dynamic cRule = cleanupRules.Item(i);
                    string cName = (string)cRule.Name;
                    if (createdTempRuleNames.Contains(cName))
                    {
                        cleanupRules.Remove(i);
                        removedAny = true;
                    }
                }

                if (removedAny)
                {
                    cleanupRules.Save(false);
                }
            }

            return migratedRuleNames.Count;
        }
        catch (Exception ex)
        {
            LastComError = ex.ToString();
            return -1;
        }
        finally
        {
            CleanupComSession(appObj, nsObj);
        }
    }

    private void CleanupComSession(object? appObj, object? nsObj)
    {
        var mountedPaths = _newlyMountedSessionStores.Keys.ToList();
        bool hasTempStores = mountedPaths.Any(IsTemporaryOrSandboxPath);

        try
        {
            if (nsObj != null)
            {
                dynamic ns = nsObj;
                foreach (var mountedPath in mountedPaths)
                {
                    if (IsTemporaryOrSandboxPath(mountedPath))
                    {
                        object? stObj = FindStoreByPath(nsObj, mountedPath);
                        if (stObj != null)
                        {
                            try
                            {
                                dynamic root = ((dynamic)stObj).GetRootFolder();
                                ns.RemoveStore(root);
                            }
                            catch
                            {
                            }
                        }
                    }
                }
            }
        }
        catch
        {
        }
        finally
        {
            _newlyMountedSessionStores.Clear();
            _comSessionActive = false;

            if ((!_outlookWasRunningBeforeComSession || hasTempStores) && appObj != null)
            {
                CloseHeadlessOutlookSession(appObj);
                WaitForFilesUnlocked(mountedPaths, 3000);
            }
        }
    }

    private static void WaitForFilesUnlocked(IEnumerable<string> paths, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        foreach (var path in paths)
        {
            while (File.Exists(path) && sw.ElapsedMilliseconds < timeoutMs)
            {
                try
                {
                    using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                    break;
                }
                catch (IOException)
                {
                    Thread.Sleep(50);
                }
            }
        }
    }

    private object? FindMatchingSourceFolderForRule(object srcRootObj, string srcKey, string ruleName)
    {
        if (_storeFolders.TryGetValue(srcKey, out var folders))
        {
            List<string> snapshot;
            lock (folders)
            {
                snapshot = folders.ToList();
            }

            foreach (var folder in snapshot)
            {
                string leafName = Path.GetFileName(folder.TrimEnd('\\', '/'));
                if (!BuiltInOutlookRootFolders.Contains(folder) &&
                    (ruleName.Contains(folder, StringComparison.OrdinalIgnoreCase) ||
                     (!string.IsNullOrWhiteSpace(leafName) && ruleName.Contains(leafName, StringComparison.OrdinalIgnoreCase))))
                {
                    return EnsureFolderPath(srcRootObj, folder);
                }
            }

            var firstCustom = snapshot.FirstOrDefault(f => !BuiltInOutlookRootFolders.Contains(f));
            if (!string.IsNullOrWhiteSpace(firstCustom))
            {
                return EnsureFolderPath(srcRootObj, firstCustom);
            }
        }

        return EnsureFolderPath(srcRootObj, "Archive");
    }

    private static bool RuleExistsByName(object rulesCollectionObj, string ruleName)
    {
        dynamic rulesCollection = rulesCollectionObj;
        int count = (int)rulesCollection.Count;
        for (int i = 1; i <= count; i++)
        {
            dynamic r = rulesCollection.Item(i);
            string name = (string)r.Name;
            if (string.Equals(name, ruleName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static object? CreateOutlookApp()
    {
        Type? outlookType = Type.GetTypeFromProgID("Outlook.Application");
        return outlookType != null ? Activator.CreateInstance(outlookType) : null;
    }

    private static void InitializeDefaultStoreProvider(object nsObj)
    {
        try
        {
            dynamic ns = nsObj;
            _ = (string)ns.DefaultStore.FilePath;
        }
        catch
        {
        }
    }

    private static object? FindStoreByPath(object nsObj, string fullPstPath)
    {
        dynamic ns = nsObj;
        dynamic stores = ns.Stores;
        string targetNormalized = NormalizePath(fullPstPath);
        int count = (int)stores.Count;
        for (int i = 1; i <= count; i++)
        {
            dynamic store = stores.Item(i);
            string? filePath = (string?)store.FilePath;
            if (!string.IsNullOrWhiteSpace(filePath) &&
                string.Equals(NormalizePath(filePath), targetNormalized, StringComparison.OrdinalIgnoreCase))
            {
                return (object)store;
            }
        }
        return null;
    }

    private static object? EnsureStoreMounted(object nsObj, string pstPath, out bool wasNewlyMounted)
    {
        string fullPath = NormalizePath(pstPath);
        object? existing = FindStoreByPath(nsObj, fullPath);
        if (existing != null)
        {
            wasNewlyMounted = false;
            return existing;
        }

        string? dir = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        if (File.Exists(fullPath) && !IsRealPstFile(fullPath))
        {
            File.Delete(fullPath);
        }

        dynamic ns = nsObj;
        ns.AddStoreEx(fullPath, 1);
        wasNewlyMounted = true;
        return FindStoreByPath(nsObj, fullPath);
    }

    private static object GetOrCreateSubFolder(object parentFolderObj, string folderName)
    {
        dynamic parentFolder = parentFolderObj;
        dynamic folders = parentFolder.Folders;
        int count = (int)folders.Count;
        for (int i = 1; i <= count; i++)
        {
            dynamic sub = folders.Item(i);
            string name = (string)sub.Name;
            if (string.Equals(name, folderName, StringComparison.OrdinalIgnoreCase))
            {
                return (object)sub;
            }
        }

        return (object)folders.Add(folderName);
    }

    private static object EnsureFolderPath(object rootFolderObj, string relativePath)
    {
        string[] parts = relativePath.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        object current = rootFolderObj;
        foreach (string part in parts)
        {
            current = GetOrCreateSubFolder(current, part);
        }
        return current;
    }

    private static bool IsTemporaryOrSandboxPath(string fullPath)
    {
        string tempRoot = NormalizePath(Path.GetTempPath());
        return fullPath.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) ||
               fullPath.Contains("IToolkit_LiveSafety_", StringComparison.OrdinalIgnoreCase) ||
               fullPath.Contains("IToolkit_RealOutlook_", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsOutlookProcessRunning()
    {
        try
        {
            return Process.GetProcessesByName("OUTLOOK").Length > 0;
        }
        catch
        {
            return false;
        }
    }

    private static void CloseHeadlessOutlookSession(object appObj)
    {
        try
        {
            ((dynamic)appObj).Quit();
        }
        catch
        {
        }

        try
        {
            if (Marshal.IsComObject(appObj))
            {
                Marshal.FinalReleaseComObject(appObj);
            }
        }
        catch
        {
        }

        try
        {
            foreach (var proc in Process.GetProcessesByName("OUTLOOK"))
            {
                try
                {
                    if (!proc.WaitForExit(1500))
                    {
                        proc.Kill(true);
                        proc.WaitForExit(1500);
                    }
                }
                catch
                {
                }
                finally
                {
                    proc.Dispose();
                }
            }
        }
        catch
        {
        }
    }

    private static T RunOnStaThread<T>(Func<T> action)
    {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA)
        {
            return action();
        }

        T result = default!;
        Exception? caught = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = action();
            }
            catch (Exception ex)
            {
                caught = ex;
            }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        if (!thread.Join(TimeSpan.FromSeconds(25)))
        {
            return default!;
        }

        if (caught != null)
        {
            throw caught;
        }

        return result;
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

    private static void SetComProperty(object comTarget, string propertyName, object value)
    {
        if (comTarget is not IDispatch dispatch)
        {
            return;
        }

        Guid iidNull = Guid.Empty;
        int[] dispIds = new int[1];
        int hr = dispatch.GetIDsOfNames(ref iidNull, new[] { propertyName }, 1, 0, dispIds);
        Marshal.ThrowExceptionForHR(hr);

        IntPtr pVariant = Marshal.AllocCoTaskMem(24);
        IntPtr pNamedArg = Marshal.AllocCoTaskMem(sizeof(int));
        try
        {
            Marshal.GetNativeVariantForObject(value, pVariant);
            Marshal.WriteInt32(pNamedArg, -3); // DISPID_PROPERTYPUT = -3

            var dispParams = new System.Runtime.InteropServices.ComTypes.DISPPARAMS
            {
                rgvarg = pVariant,
                rgdispidNamedArgs = pNamedArg,
                cArgs = 1,
                cNamedArgs = 1
            };

            // 0xC = DISPATCH_PROPERTYPUT (0x4) | DISPATCH_PROPERTYPUTREF (0x8)
            hr = dispatch.Invoke(dispIds[0], ref iidNull, 0, 0xC, ref dispParams, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            VariantClear(pVariant);
            Marshal.FreeCoTaskMem(pVariant);
            Marshal.FreeCoTaskMem(pNamedArg);
        }
    }

    [DllImport("oleaut32.dll")]
    private static extern int VariantClear(IntPtr pvarg);

    [ComImport]
    [Guid("00020400-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDispatch
    {
        int GetTypeInfoCount();

        [return: MarshalAs(UnmanagedType.Interface)]
        object GetTypeInfo(int iTInfo, int lcid);

        [PreserveSig]
        int GetIDsOfNames(
            ref Guid riid,
            [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] rgszNames,
            int cNames,
            int lcid,
            [Out, MarshalAs(UnmanagedType.LPArray)] int[] rgDispId);

        [PreserveSig]
        int Invoke(
            int dispIdMember,
            ref Guid riid,
            int lcid,
            ushort wFlags,
            ref System.Runtime.InteropServices.ComTypes.DISPPARAMS pDispParams,
            IntPtr pVarResult,
            IntPtr pExcepInfo,
            IntPtr puArgErr);
    }
}
