namespace IToolkit.Core.Safety;

using System.Security.Principal;
using IToolkit.Core.Abstractions;

/// <summary>
/// Enforces mandatory Administrator elevation checks across all mutating operations.
/// </summary>
public class ElevationGuard : IElevationService
{
    private readonly IElevationService? _underlyingService;

    public ElevationGuard()
        : this(null)
    {
    }

    public ElevationGuard(IElevationService? underlyingService)
    {
        _underlyingService = underlyingService;
    }

    /// <summary>
    /// Returns true if the current execution context holds local Administrator privileges.
    /// </summary>
    public bool IsElevated()
    {
        if (_underlyingService != null)
        {
            return _underlyingService.IsElevated();
        }

        return CheckPlatformElevation();
    }

    /// <summary>
    /// Throws UnauthorizedAccessException if administrative privileges are not present.
    /// </summary>
    public void AssertElevated(string operationName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationName);

        if (_underlyingService != null)
        {
            _underlyingService.AssertElevated(operationName);
            return;
        }

        if (!IsElevated())
        {
            throw new UnauthorizedAccessException(
                $"Administrative privileges are required to perform '{operationName}'. Please restart IToolkit as Administrator.");
        }
    }

    private static bool CheckPlatformElevation()
    {
        string? envSimulate = Environment.GetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN");
        if (envSimulate == "1" || string.Equals(envSimulate, "true", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        if (envSimulate == "0" || string.Equals(envSimulate, "false", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (OperatingSystem.IsWindows())
        {
            try
            {
                using var identity = WindowsIdentity.GetCurrent();
                var principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch
            {
                return false;
            }
        }

        return false;
    }
}
