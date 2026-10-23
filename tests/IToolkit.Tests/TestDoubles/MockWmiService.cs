namespace IToolkit.Tests.TestDoubles;

using IToolkit.Core.Abstractions;

/// <summary>
/// In-memory test double for IWmiService.
/// </summary>
public class MockWmiService : IWmiService
{
    private readonly Dictionary<string, List<IDictionary<string, object?>>> _queryResults = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, int> _methodResults = new(StringComparer.OrdinalIgnoreCase);

    public List<string> ExecutedQueries { get; } = new();
    public List<string> ExecutedMethods { get; } = new();

    public void SetQueryResult(string query, IEnumerable<IDictionary<string, object?>> results)
    {
        _queryResults[query.Trim()] = results.ToList();
    }

    public void SetMethodResult(string className, string methodName, int returnCode)
    {
        _methodResults[$"{className}::{methodName}".Trim()] = returnCode;
    }

    public IEnumerable<IDictionary<string, object?>> Query(string wqlQuery, string wmiNamespace = @"root\cimv2")
    {
        string trimmed = wqlQuery.Trim();
        ExecutedQueries.Add(trimmed);

        if (_queryResults.TryGetValue(trimmed, out var results))
        {
            return results;
        }

        // Fuzzy match if exact query not found
        foreach (var kvp in _queryResults)
        {
            if (trimmed.Contains(kvp.Key, StringComparison.OrdinalIgnoreCase) ||
                kvp.Key.Contains(trimmed, StringComparison.OrdinalIgnoreCase))
            {
                return kvp.Value;
            }
        }

        return Enumerable.Empty<IDictionary<string, object?>>();
    }

    public IDictionary<string, object?>? QueryFirst(string wqlQuery, string wmiNamespace = @"root\cimv2")
    {
        return Query(wqlQuery, wmiNamespace).FirstOrDefault();
    }

    public int ExecuteMethod(string className, string methodName, IDictionary<string, object?>? inParams = null, string wmiNamespace = @"root\cimv2")
    {
        string key = $"{className}::{methodName}".Trim();
        ExecutedMethods.Add(key);

        if (_methodResults.TryGetValue(key, out int code))
        {
            return code;
        }

        return 0; // Default success
    }
}
