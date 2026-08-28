using AgenticMcp.Agent.Core;
using Microsoft.Management.Infrastructure;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// The monitoring data, read from WMI.
///
/// <para>Via <c>Microsoft.Management.Infrastructure</c> — the supported CIM API over the same WMI repository
/// <c>Get-CimInstance</c> uses. Not <c>System.Management</c> (the legacy wrapper) and not <c>wmic.exe</c>,
/// which has been removed from current Windows. Typed results, no text parsing.</para>
///
/// <para>EVERY READING NAMES ITS CLASS AND PROPERTY in <see cref="MetricSample.Source"/>. That is the
/// project's sufficient-reason rule applied to a number: a metric whose origin cannot be named is a metric
/// nobody can check. It is also how the mapping below stays honest — the table in
/// <c>docs/windows-agent.md</c> and the strings here are the same strings.</para>
///
/// <para>WHAT IS DELIBERATELY NOT HERE. Installed software does NOT come from <c>Win32_Product</c>: merely
/// enumerating that class triggers an MSI self-repair on every installed package, which is a write disguised
/// as a read. The event log does not come from <c>Win32_NTLogEvent</c> either — it is orders of magnitude
/// slower than <c>EventLogSession</c>. Both belong to their own collectors, and a class this one refuses is
/// refused in writing rather than by omission.</para>
/// </summary>
public sealed class WmiMetricCollector : IMetricCollector
{
    private const string Namespace = @"root\cimv2";

    public string Name => "wmi";

    /// <summary>
    /// One query, and what to do with each instance it returns. Data, not code, so the mapping can be read
    /// as a table and compared against the documented one.
    /// </summary>
    private sealed record Query(
        string Metric,
        string ClassName,
        string Wql,
        Func<CimInstance, IEnumerable<(double Value, IReadOnlyDictionary<string, string>? Labels, string Metric)>> Read);

    public async Task<CollectionResult> CollectAsync(CancellationToken ct)
    {
        var samples = new List<MetricSample>();
        var absences = new List<CollectionAbsence>();
        var now = DateTimeOffset.UtcNow;
        var attempts = 0;

        using var session = CimSession.Create(null);

        foreach (var query in Queries())
        {
            ct.ThrowIfCancellationRequested();
            attempts++;
            try
            {
                var produced = 0;
                foreach (var instance in session.QueryInstances(Namespace, "WQL", query.Wql))
                {
                    using (instance)
                    {
                        foreach (var (value, labels, metric) in query.Read(instance))
                        {
                            samples.Add(new MetricSample(metric, value, now, labels,
                                $"{query.ClassName} (WMI)"));
                            produced++;
                        }
                    }
                }

                if (produced == 0)
                {
                    // NAMED. "The class is not present on this SKU" and "the value is zero" are different
                    // answers, and a collector that returns nothing for both makes them indistinguishable —
                    // which is the whole reason data_source exists on the Go side.
                    absences.Add(new CollectionAbsence(query.Metric, query.ClassName,
                        "the query returned no instances on this host"));
                }
            }
            catch (CimException ex)
            {
                absences.Add(new CollectionAbsence(query.Metric, query.ClassName,
                    $"{ex.NativeErrorCode}: {ex.Message.Trim()}"));
            }
        }

        // Nothing above awaits: CimSession's query API is synchronous. Kept async to match the interface the
        // rest of the fleet's collectors implement, rather than giving this one a different shape.
        await Task.CompletedTask;
        return new CollectionResult(samples, attempts, absences);
    }

    private static IEnumerable<Query> Queries()
    {
        // ---- processor ---------------------------------------------------------------------------------
        // Per-core AND _Total, labelled. `Name` is "0", "1", … or "_Total"; the total is kept as its own
        // series rather than being recomputed, because the counter's own total is what Task Manager shows.
        yield return new Query("cpu_percent", "Win32_PerfFormattedData_PerfOS_Processor",
            "SELECT Name, PercentProcessorTime, PercentPrivilegedTime, PercentUserTime "
            + "FROM Win32_PerfFormattedData_PerfOS_Processor",
            i =>
            {
                var core = Text(i, "Name") ?? "?";
                var labels = new Dictionary<string, string> { ["core"] = core };
                return
                [
                    (Num(i, "PercentProcessorTime"), labels, "cpu_percent"),
                    (Num(i, "PercentPrivilegedTime"), labels, "cpu_system_percent"),
                    (Num(i, "PercentUserTime"), labels, "cpu_user_percent"),
                ];
            });

        yield return new Query("cpu_count", "Win32_ComputerSystem",
            "SELECT NumberOfLogicalProcessors FROM Win32_ComputerSystem",
            i => [(Num(i, "NumberOfLogicalProcessors"), null, "cpu_count")]);

        // ---- memory ------------------------------------------------------------------------------------
        // Win32_OperatingSystem reports KILOBYTES. Multiplied here, because a metric named _bytes that
        // carries kilobytes is the kind of unit error that survives for years behind a plausible graph.
        yield return new Query("mem_total_bytes", "Win32_OperatingSystem",
            "SELECT TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory, "
            + "LastBootUpTime FROM Win32_OperatingSystem",
            i =>
            {
                var totalKb = Num(i, "TotalVisibleMemorySize");
                var freeKb = Num(i, "FreePhysicalMemory");
                var readings = new List<(double, IReadOnlyDictionary<string, string>?, string)>
                {
                    (totalKb * 1024, null, "mem_total_bytes"),
                    (freeKb * 1024, null, "mem_available_bytes"),
                    (Num(i, "TotalVirtualMemorySize") * 1024, null, "mem_virtual_total_bytes"),
                    (Num(i, "FreeVirtualMemory") * 1024, null, "mem_virtual_free_bytes"),
                };
                if (totalKb > 0)
                {
                    readings.Add((100.0 * (totalKb - freeKb) / totalKb, null, "mem_used_percent"));
                }

                if (i.CimInstanceProperties["LastBootUpTime"]?.Value is DateTime booted)
                {
                    readings.Add(((DateTimeOffset.UtcNow - booted.ToUniversalTime()).TotalSeconds, null,
                        "uptime_seconds"));
                }

                return readings;
            });

        // The page file, not "swap": Windows does not have a swap partition, and calling it one would be a
        // name that means something different on each platform.
        yield return new Query("pagefile_used_percent", "Win32_PageFileUsage",
            "SELECT Name, AllocatedBaseSize, CurrentUsage, PeakUsage FROM Win32_PageFileUsage",
            i =>
            {
                var labels = new Dictionary<string, string> { ["file"] = Text(i, "Name") ?? "?" };
                var allocatedMb = Num(i, "AllocatedBaseSize");
                var usedMb = Num(i, "CurrentUsage");
                var readings = new List<(double, IReadOnlyDictionary<string, string>?, string)>
                {
                    (allocatedMb * 1024 * 1024, labels, "pagefile_total_bytes"),
                    (usedMb * 1024 * 1024, labels, "pagefile_used_bytes"),
                };
                if (allocatedMb > 0)
                {
                    readings.Add((100.0 * usedMb / allocatedMb, labels, "pagefile_used_percent"));
                }

                return readings;
            });

        // ---- volumes -----------------------------------------------------------------------------------
        // DriveType = 3 is a local fixed disk. Network drives and removable media are excluded on purpose:
        // a disconnected share reporting 100% full is an alert about the network, filed under storage.
        yield return new Query("disk_usage_percent", "Win32_LogicalDisk",
            "SELECT DeviceID, FileSystem, Size, FreeSpace FROM Win32_LogicalDisk WHERE DriveType = 3",
            i =>
            {
                var size = Num(i, "Size");
                if (size <= 0)
                {
                    return [];
                }

                var free = Num(i, "FreeSpace");
                var labels = new Dictionary<string, string>
                {
                    ["mount"] = Text(i, "DeviceID") ?? "?",
                    ["fs"] = Text(i, "FileSystem") ?? "unknown",
                };
                return
                [
                    (100.0 * (size - free) / size, labels, "disk_usage_percent"),
                    (free, labels, "disk_free_bytes"),
                    (size, labels, "disk_total_bytes"),
                ];
            });

        yield return new Query("disk_io_ops", "Win32_PerfFormattedData_PerfDisk_LogicalDisk",
            "SELECT Name, DiskReadsPerSec, DiskWritesPerSec, PercentDiskTime, AvgDiskQueueLength "
            + "FROM Win32_PerfFormattedData_PerfDisk_LogicalDisk",
            i =>
            {
                var labels = new Dictionary<string, string> { ["disk"] = Text(i, "Name") ?? "?" };
                return
                [
                    (Num(i, "DiskReadsPerSec"), labels, "disk_reads_per_sec"),
                    (Num(i, "DiskWritesPerSec"), labels, "disk_writes_per_sec"),
                    (Num(i, "PercentDiskTime"), labels, "disk_busy_percent"),
                    (Num(i, "AvgDiskQueueLength"), labels, "disk_queue_length"),
                ];
            });

        // ---- network -----------------------------------------------------------------------------------
        yield return new Query("net_bytes_per_sec", "Win32_PerfFormattedData_Tcpip_NetworkInterface",
            "SELECT Name, BytesReceivedPersec, BytesSentPersec, PacketsReceivedErrors, PacketsOutboundErrors "
            + "FROM Win32_PerfFormattedData_Tcpip_NetworkInterface",
            i =>
            {
                var iface = Text(i, "Name") ?? "?";
                return
                [
                    (Num(i, "BytesReceivedPersec"),
                        new Dictionary<string, string> { ["iface"] = iface, ["dir"] = "rx" },
                        "net_bytes_per_sec"),
                    (Num(i, "BytesSentPersec"),
                        new Dictionary<string, string> { ["iface"] = iface, ["dir"] = "tx" },
                        "net_bytes_per_sec"),
                    (Num(i, "PacketsReceivedErrors"),
                        new Dictionary<string, string> { ["iface"] = iface, ["dir"] = "rx" },
                        "net_errors"),
                    (Num(i, "PacketsOutboundErrors"),
                        new Dictionary<string, string> { ["iface"] = iface, ["dir"] = "tx" },
                        "net_errors"),
                ];
            });

        // ---- the processor queue, which is NOT a load average ------------------------------------------
        // Windows has no load average, and reporting one would be an invented number. The honest substitute
        // is the processor queue length under ITS OWN name, so nothing downstream can mistake the two.
        yield return new Query("processor_queue_length", "Win32_PerfFormattedData_PerfOS_System",
            "SELECT ProcessorQueueLength, ContextSwitchesPersec, SystemUpTime "
            + "FROM Win32_PerfFormattedData_PerfOS_System",
            i =>
            [
                (Num(i, "ProcessorQueueLength"), null, "processor_queue_length"),
                (Num(i, "ContextSwitchesPersec"), null, "context_switches_per_sec"),
            ]);

        // ---- services ----------------------------------------------------------------------------------
        // A count, not a row per service: the inventory of services belongs to state/discovery, and a metric
        // series per service name would be the per-PID cardinality mistake with a different label.
        yield return new Query("services_stopped_automatic", "Win32_Service",
            "SELECT Name, State, StartMode FROM Win32_Service WHERE StartMode = 'Auto' AND State = 'Stopped'",
            _ => [(1, null, "services_stopped_automatic")]);
    }

    private static double Num(CimInstance instance, string property)
    {
        var value = instance.CimInstanceProperties[property]?.Value;
        return value is null ? 0 : Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string? Text(CimInstance instance, string property) =>
        instance.CimInstanceProperties[property]?.Value?.ToString();
}
