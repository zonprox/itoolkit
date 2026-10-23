namespace IToolkit.Tests.TestDoubles;

using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using IToolkit.Core.Abstractions;

/// <summary>
/// In-memory test double for IFileSystemService enabling filesystem testing without disk side-effects.
/// </summary>
public class MockFileSystemService : IFileSystemService
{
    private readonly Dictionary<string, byte[]> _files = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _directories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, bool> _lockedFiles = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DateTime> _lastWriteTimes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Action<string>> _zipExtractionHandlers = new(StringComparer.OrdinalIgnoreCase);

    public long AvailableFreeSpace { get; set; } = 100L * 1024 * 1024 * 1024; // 100 GB default

    public void SetAvailableFreeSpace(long bytes) => AvailableFreeSpace = bytes;

    public void SetFileLocked(string path, bool isLocked) => _lockedFiles[Normalize(path)] = isLocked;

    public void SetLastWriteTime(string path, DateTime time) => _lastWriteTimes[Normalize(path)] = time;

    public void SetZipExtractionHandler(string zipFilePath, Action<string> handler) => _zipExtractionHandlers[Normalize(zipFilePath)] = handler;

    public bool FileExists(string path) => _files.ContainsKey(Normalize(path));

    public bool DirectoryExists(string path) => _directories.Contains(Normalize(path));

    public void CreateDirectory(string path)
    {
        string norm = Normalize(path);
        _directories.Add(norm);
        string? parent = Path.GetDirectoryName(norm);
        while (!string.IsNullOrEmpty(parent) && !_directories.Contains(parent))
        {
            _directories.Add(parent);
            parent = Path.GetDirectoryName(parent);
        }
    }

    public void DeleteFile(string path)
    {
        string norm = Normalize(path);
        _files.Remove(norm);
        _lockedFiles.Remove(norm);
        _lastWriteTimes.Remove(norm);
    }

    public void DeleteDirectory(string path, bool recursive = true)
    {
        string norm = Normalize(path);
        _directories.Remove(norm);

        if (recursive)
        {
            string prefix = norm.EndsWith(Path.DirectorySeparatorChar) ? norm : norm + Path.DirectorySeparatorChar;
            var filesToDelete = _files.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList();
            foreach (var f in filesToDelete) DeleteFile(f);

            var dirsToDelete = _directories.Where(d => d.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList();
            foreach (var d in dirsToDelete) _directories.Remove(d);
        }
    }

    public void CopyFile(string source, string destination, bool overwrite = true)
    {
        string normSrc = Normalize(source);
        string normDst = Normalize(destination);

        if (!_files.TryGetValue(normSrc, out var data))
        {
            throw new FileNotFoundException($"Source file not found: {source}");
        }

        if (_files.ContainsKey(normDst) && !overwrite)
        {
            throw new IOException($"Destination file exists: {destination}");
        }

        _files[normDst] = (byte[])data.Clone();
        _lastWriteTimes[normDst] = DateTime.UtcNow;
    }

    public void MoveFile(string source, string destination)
    {
        CopyFile(source, destination, overwrite: true);
        DeleteFile(source);
    }

    public void MoveDirectory(string source, string destination)
    {
        string normSrc = Normalize(source);
        string normDst = Normalize(destination);

        if (!_directories.Contains(normSrc))
        {
            throw new DirectoryNotFoundException($"Source directory not found: {source}");
        }

        _directories.Remove(normSrc);
        CreateDirectory(normDst);

        string srcPrefix = normSrc + "/";
        string dstPrefix = normDst + "/";

        // Move child directories
        var childDirs = _directories.Where(d => d.StartsWith(srcPrefix, StringComparison.OrdinalIgnoreCase)).ToList();
        foreach (var d in childDirs)
        {
            _directories.Remove(d);
            string newDir = dstPrefix + d[srcPrefix.Length..];
            _directories.Add(newDir);
        }

        // Move child files
        var childFiles = _files.Where(f => f.Key.StartsWith(srcPrefix, StringComparison.OrdinalIgnoreCase)).ToList();
        foreach (var (oldPath, bytes) in childFiles)
        {
            _files.Remove(oldPath);
            _lockedFiles.Remove(oldPath);
            _lastWriteTimes.Remove(oldPath);

            string newPath = dstPrefix + oldPath[srcPrefix.Length..];
            _files[newPath] = bytes;
            _lastWriteTimes[newPath] = DateTime.UtcNow;
        }
    }

    public void ExtractZipArchive(string zipFilePath, string destinationDirectory, bool overwrite = true)
    {
        string normZip = Normalize(zipFilePath);
        if (_zipExtractionHandlers.TryGetValue(normZip, out var handler))
        {
            CreateDirectory(destinationDirectory);
            handler(destinationDirectory);
            return;
        }

        if (!_files.TryGetValue(normZip, out var zipBytes))
        {
            throw new FileNotFoundException($"Zip file not found: {zipFilePath}");
        }

        CreateDirectory(destinationDirectory);
        using var mem = new MemoryStream(zipBytes);
        using var zip = new ZipArchive(mem, ZipArchiveMode.Read);
        foreach (var entry in zip.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
            {
                CreateDirectory(Path.Combine(destinationDirectory, entry.FullName));
                continue;
            }
            string outPath = Path.Combine(destinationDirectory, entry.FullName);
            using var s = entry.Open();
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            WriteAllBytes(outPath, ms.ToArray());
        }
    }

    public long GetFileSize(string path)
    {
        string norm = Normalize(path);
        if (_files.TryGetValue(norm, out var data))
        {
            return data.Length;
        }
        throw new FileNotFoundException($"File not found: {path}");
    }

    public long GetAvailableFreeSpace(string path) => AvailableFreeSpace;

    public bool CheckDiskSpace(string path, long requiredBytes, double safetyMultiplier = 1.2)
    {
        long threshold = (long)Math.Ceiling(requiredBytes * safetyMultiplier);
        return AvailableFreeSpace >= threshold;
    }

    public string ComputeSha256(string path)
    {
        string norm = Normalize(path);
        if (!_files.TryGetValue(norm, out var data))
        {
            throw new FileNotFoundException($"File not found: {path}");
        }

        byte[] hash = SHA256.HashData(data);
        return Convert.ToHexString(hash);
    }

    public Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken = default)
    {
        return Task.FromResult(ComputeSha256(path));
    }

    public bool IsFileLocked(string path)
    {
        string norm = Normalize(path);
        return _lockedFiles.TryGetValue(norm, out bool locked) && locked;
    }

    public void CreateSymbolicLink(string linkPath, string targetPath)
    {
        CreateDirectory(Path.GetDirectoryName(linkPath) ?? string.Empty);
        WriteAllText(linkPath, $"[SYMLINK -> {targetPath}]");
    }

    public string ReadAllText(string path, Encoding? encoding = null)
    {
        byte[] bytes = ReadAllBytes(path);
        return (encoding ?? Encoding.UTF8).GetString(bytes);
    }

    public void WriteAllText(string path, string contents, Encoding? encoding = null)
    {
        byte[] bytes = (encoding ?? Encoding.UTF8).GetBytes(contents);
        WriteAllBytes(path, bytes);
    }

    public byte[] ReadAllBytes(string path)
    {
        string norm = Normalize(path);
        if (_files.TryGetValue(norm, out var bytes))
        {
            return (byte[])bytes.Clone();
        }
        throw new FileNotFoundException($"File not found: {path}");
    }

    public void WriteAllBytes(string path, byte[] bytes)
    {
        string norm = Normalize(path);
        string? dir = Path.GetDirectoryName(norm);
        if (!string.IsNullOrEmpty(dir))
        {
            _directories.Add(dir);
        }

        _files[norm] = (byte[])bytes.Clone();
        _lastWriteTimes[norm] = DateTime.UtcNow;
    }

    public Stream OpenRead(string path)
    {
        return new MemoryStream(ReadAllBytes(path), writable: false);
    }

    public DateTime GetLastWriteTimeUtc(string path)
    {
        string norm = Normalize(path);
        return _lastWriteTimes.TryGetValue(norm, out var dt) ? dt : DateTime.UtcNow;
    }

    public IEnumerable<string> EnumerateFiles(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly)
    {
        string normDir = Normalize(path);
        string prefix = normDir.EndsWith('/') ? normDir : normDir + "/";

        return _files.Keys.Where(k =>
        {
            if (!k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
            string relative = k[prefix.Length..];
            if (searchOption == SearchOption.TopDirectoryOnly && (relative.Contains('/') || relative.Contains(Path.DirectorySeparatorChar)))
            {
                return false;
            }

            if (!string.IsNullOrEmpty(searchPattern) && searchPattern != "*" && searchPattern != "*.*")
            {
                string fileName = Path.GetFileName(k);
                if (!System.IO.Enumeration.FileSystemName.MatchesSimpleExpression(searchPattern, fileName, ignoreCase: true))
                {
                    return false;
                }
            }
            return true;
        }).ToList();
    }

    public IEnumerable<string> EnumerateDirectories(string path, string searchPattern = "*", SearchOption searchOption = SearchOption.TopDirectoryOnly)
    {
        string normDir = Normalize(path);
        string prefix = normDir + "/";

        return _directories.Where(d =>
        {
            if (!d.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
            string relative = d[prefix.Length..];
            if (searchOption == SearchOption.TopDirectoryOnly && relative.Contains('/')) return false;

            if (!string.IsNullOrEmpty(searchPattern) && searchPattern != "*")
            {
                string dirName = relative.Contains('/') ? relative[..relative.IndexOf('/')] : relative;
                if (searchPattern.EndsWith("*"))
                {
                    string patternPrefix = searchPattern[..^1];
                    if (!dirName.StartsWith(patternPrefix, StringComparison.OrdinalIgnoreCase)) return false;
                }
                else if (!dirName.Equals(searchPattern, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
            }

            return true;
        }).ToList();
    }

    private static string Normalize(string path)
    {
        return path.Replace('\\', '/').TrimEnd('/');
    }
}
