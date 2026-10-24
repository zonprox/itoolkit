namespace IToolkit.Core.Abstractions;

/// <summary>
/// Abstraction for checking and asserting administrative elevation status.
/// </summary>
public interface IElevationService
{
    /// <summary>
    /// Returns true if the current execution context holds local Administrator privileges.
    /// </summary>
    bool IsElevated();

    /// <summary>
    /// Throws UnauthorizedAccessException if the process does not possess elevated privileges.
    /// </summary>
    void AssertElevated(string operationName);
}
