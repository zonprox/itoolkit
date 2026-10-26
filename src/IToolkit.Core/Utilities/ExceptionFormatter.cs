namespace IToolkit.Core.Utilities;

using System;
using System.Text;

/// <summary>
/// Formats exception hierarchies into diagnostic strings for structured logging and error reports.
/// </summary>
public static class ExceptionFormatter
{
    /// <summary>
    /// Formats an exception including its type, message, recursive inner exceptions, and stack trace.
    /// </summary>
    /// <param name="ex">The exception to format.</param>
    /// <returns>A formatted diagnostic string, or an empty string if null.</returns>
    public static string FormatException(Exception? ex)
    {
        return FormatException(null, ex);
    }

    /// <summary>
    /// Formats an exception with an optional context message.
    /// </summary>
    /// <param name="contextMessage">Optional context prefix message.</param>
    /// <param name="ex">The exception to format.</param>
    /// <returns>A formatted diagnostic string.</returns>
    public static string FormatException(string? contextMessage, Exception? ex)
    {
        if (ex == null)
        {
            return contextMessage ?? string.Empty;
        }

        var sb = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(contextMessage))
        {
            sb.Append(contextMessage).Append(" | ");
        }

        string typeName = ex.GetType().FullName ?? ex.GetType().Name;
        sb.Append('[').Append(typeName).Append("] ").Append(ex.Message);

        int depth = 1;
        Exception? current = ex.InnerException;
        while (current != null && depth <= 20)
        {
            sb.AppendLine();
            string innerTypeName = current.GetType().FullName ?? current.GetType().Name;
            sb.Append("  ---> (Inner Exception #").Append(depth).Append(") [").Append(innerTypeName).Append("] ").Append(current.Message);
            current = current.InnerException;
            depth++;
        }

        if (ex is AggregateException agg && agg.InnerExceptions.Count > 1)
        {
            int aggIndex = 1;
            foreach (var child in agg.InnerExceptions)
            {
                if (child != ex.InnerException)
                {
                    sb.AppendLine();
                    string childTypeName = child.GetType().FullName ?? child.GetType().Name;
                    sb.Append("  ---> (Aggregate Inner #").Append(aggIndex).Append(") [").Append(childTypeName).Append("] ").Append(child.Message);
                    aggIndex++;
                }
            }
        }

        if (!string.IsNullOrWhiteSpace(ex.StackTrace))
        {
            sb.AppendLine();
            sb.Append("Stack Trace:").AppendLine().Append(ex.StackTrace);
        }

        return SanitizeToAscii(sb.ToString());
    }

    /// <summary>
    /// Ensures output is strictly 100% 7-bit ASCII characters.
    /// </summary>
    private static string SanitizeToAscii(string input)
    {
        if (string.IsNullOrEmpty(input))
        {
            return string.Empty;
        }

        bool hasNonAscii = false;
        for (int i = 0; i < input.Length; i++)
        {
            if (input[i] > 127)
            {
                hasNonAscii = true;
                break;
            }
        }

        if (!hasNonAscii)
        {
            return input;
        }

        var sb = new StringBuilder(input.Length);
        foreach (char c in input)
        {
            sb.Append(c <= 127 ? c : '?');
        }

        return sb.ToString();
    }
}
