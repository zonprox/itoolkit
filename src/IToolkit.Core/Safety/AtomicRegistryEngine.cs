namespace IToolkit.Core.Safety;

using IToolkit.Core.Abstractions;

/// <summary>
/// Alias for AtomicRegistryService maintaining compatibility with architectural specifications.
/// </summary>
public class AtomicRegistryEngine : AtomicRegistryService
{
    public AtomicRegistryEngine(
        IRegistryService registryService,
        IFileSystemService fileSystem,
        IActivityLogger? logger = null,
        string? backupDirectory = null)
        : base(registryService, fileSystem, logger, backupDirectory)
    {
    }
}
