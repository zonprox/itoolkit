namespace IToolkit.Core.Abstractions;

/// <summary>
/// Abstraction for user confirmation dialogs guarding high-impact or destructive actions.
/// </summary>
public interface ISafetyConfirmationService
{
    /// <summary>
    /// Displays a synchronous confirmation prompt with warning details.
    /// Returns true if the user confirmed, false otherwise.
    /// </summary>
    bool Confirm(string title, string message, string warningDetails);

    /// <summary>
    /// Displays an asynchronous confirmation prompt with warning details.
    /// Returns true if the user confirmed, false otherwise.
    /// </summary>
    Task<bool> ConfirmAsync(string title, string message, string warningDetails);
}
