namespace IToolkit.Core.Safety;

using System.Runtime.InteropServices;
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

    /// <summary>
    /// Relaunches the current process requesting UAC elevation via 'runas'.
    /// </summary>
    public bool RestartElevated()
    {
        if (_underlyingService != null)
        {
            return _underlyingService.RestartElevated();
        }

        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        return LaunchElevatedProcess();
    }

    private static bool CheckPlatformElevation()
    {
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

        // On non-Windows development/testing hosts:
        string? envSimulate = Environment.GetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN");
        if (envSimulate == "1" || string.Equals(envSimulate, "true", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux) || RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return GetUnixEuid() == 0;
        }

        return false;
    }

    private static bool LaunchElevatedProcess()
    {
        string? exePath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exePath)) return false;

        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = exePath,
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = Environment.CurrentDirectory
        };

        try
        {
            System.Diagnostics.Process.Start(psi);
            Environment.Exit(0);
            return true;
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED (User cancelled UAC elevation prompt)
            return false;
        }
    }

    [DllImport("libc", EntryPoint = "geteuid", SetLastError = true)]
    private static extern uint GetUnixEuid();
}
