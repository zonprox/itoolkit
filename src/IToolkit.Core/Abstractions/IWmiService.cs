namespace IToolkit.Core.Abstractions;

/// <summary>
/// Abstraction for Windows Management Instrumentation (WMI) and CIM queries.
/// </summary>
public interface IWmiService
{
    /// <summary>
    /// Executes a WQL query and returns matching property dictionaries.
    /// </summary>
    IEnumerable<IDictionary<string, object?>> Query(string wqlQuery, string wmiNamespace = @"root\cimv2");

    /// <summary>
    /// Executes a WQL query and returns the first matching instance or null.
    /// </summary>
    IDictionary<string, object?>? QueryFirst(string wqlQuery, string wmiNamespace = @"root\cimv2");

    /// <summary>
    /// Executes a WMI class or instance method.
    /// </summary>
    int ExecuteMethod(string className, string methodName, IDictionary<string, object?>? inParams = null, string wmiNamespace = @"root\cimv2");
}
