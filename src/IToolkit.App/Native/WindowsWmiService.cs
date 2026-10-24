namespace IToolkit.App.Native;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using IToolkit.Core.Abstractions;

public class WindowsWmiService : IWmiService
{
    public IEnumerable<IDictionary<string, object?>> Query(string wqlQuery, string wmiNamespace = @"root\cimv2")
    {
        var results = new List<IDictionary<string, object?>>();

        try
        {
            using var searcher = new ManagementObjectSearcher(wmiNamespace, wqlQuery);
            using var collection = searcher.Get();
            foreach (ManagementObject obj in collection)
            {
                var dict = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                foreach (var prop in obj.Properties)
                {
                    dict[prop.Name] = prop.Value;
                }
                results.Add(dict);
            }
        }
        catch { }

        return results;
    }

    public IDictionary<string, object?>? QueryFirst(string wqlQuery, string wmiNamespace = @"root\cimv2")
    {
        return Query(wqlQuery, wmiNamespace).FirstOrDefault();
    }

    public int ExecuteMethod(string className, string methodName, IDictionary<string, object?>? inParams = null, string wmiNamespace = @"root\cimv2")
    {
        try
        {
            using var managementClass = new ManagementClass(wmiNamespace, className, null);
            using var inParameters = inParams != null ? managementClass.GetMethodParameters(methodName) : null;
            if (inParams != null && inParameters != null)
            {
                foreach (var (k, v) in inParams)
                {
                    inParameters[k] = v;
                }
            }
            using var outParameters = managementClass.InvokeMethod(methodName, inParameters, null);
            return Convert.ToInt32(outParameters["ReturnValue"]);
        }
        catch { return -1; }
    }
}
