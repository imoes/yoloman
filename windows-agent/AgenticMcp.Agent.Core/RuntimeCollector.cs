using System.Diagnostics;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// The platform-neutral floor: what .NET itself can measure on any OS.
///
/// <para>This is NOT a stand-in for the WMI collector and does not overlap it — it reports what the runtime
/// knows (mounted volumes, processor count, this process' own footprint, uptime), and the WMI collector
/// reports what Windows knows. A host runs both and the store merges them, because they answer different
/// questions.</para>
///
/// <para>Its second job is what made the whole first milestone provable: it runs on the Linux dev host, so
/// "Bossman can enrol this agent and poll it" was demonstrated against the live server before any Windows VM
/// existed. Every disagreement about the wire contract surfaced there, where a rebuild costs two seconds.</para>
/// </summary>
public sealed class RuntimeMetricCollector : IMetricCollector
{
    public string Name => "runtime";

    public Task<CollectionResult> CollectAsync(CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var samples = new List<MetricSample>();
        var absences = new List<CollectionAbsence>();
        var attempts = 0;

        attempts++;
        // The PROCESS start time, not a static field set on first use. A static initialiser runs when the
        // field is first touched — which is after `now` was read a few microseconds earlier — and the first
        // reading came out as -5.25E-05 seconds of uptime. A negative uptime is not a rounding artefact, it
        // is a wrong answer about which of two events happened first.
        using (var self = Process.GetCurrentProcess())
        {
            samples.Add(new MetricSample("agent_uptime_seconds",
                (now - new DateTimeOffset(self.StartTime.ToUniversalTime(), TimeSpan.Zero)).TotalSeconds, now,
                Source: "System.Diagnostics.Process.StartTime"));
        }

        attempts++;
        samples.Add(new MetricSample("cpu_count", Environment.ProcessorCount, now,
            Source: "System.Environment.ProcessorCount"));

        attempts++;
        using (var self = Process.GetCurrentProcess())
        {
            samples.Add(new MetricSample("agent_rss_bytes", self.WorkingSet64, now,
                Source: "System.Diagnostics.Process.WorkingSet64"));
        }

        // VOLUMES ONLY WHERE NOTHING BETTER EXISTS — i.e. not on Windows, where the WMI collector reports
        // them from Win32_LogicalDisk.
        //
        // Measured on the first real Windows run: both collectors reported the same volume and the database
        // ended up with `disk_free_bytes {mount: "C:"}` from WMI and `disk_free_bytes {mount: "C:\"}` from
        // here — ONE FACT UNDER TWO NAMES, which is the identity rule broken by my own code, and it would
        // have shown up as a host with twice as many disks as it has. Normalising the label would have
        // treated the symptom; two sources for one fact is the defect. WMI is the better source anyway
        // (DriveType filtering, the filesystem label), so this collector stands down on Windows and keeps
        // what only it knows: the agent's own uptime and footprint.
        if (OperatingSystem.IsWindows())
        {
            return Task.FromResult(new CollectionResult(samples, attempts, absences));
        }

        // DriveInfo is the same API on both platforms; on Linux it is the only one here.
        foreach (var drive in DriveInfo.GetDrives())
        {
            attempts++;
            try
            {
                if (!drive.IsReady || drive.TotalSize <= 0)
                {
                    // NAMED, not skipped: an empty optical drive is a different fact from a volume nobody
                    // looked at, and only one of the two is worth an operator's attention.
                    absences.Add(new CollectionAbsence("disk_usage_percent", "System.IO.DriveInfo",
                        $"{drive.Name} reports no media or no size"));
                    continue;
                }

                var labels = new Dictionary<string, string>
                {
                    ["mount"] = drive.Name,
                    ["fs"] = drive.DriveFormat,
                };
                var used = drive.TotalSize - drive.AvailableFreeSpace;
                samples.Add(new MetricSample("disk_usage_percent", 100.0 * used / drive.TotalSize, now, labels,
                    "System.IO.DriveInfo"));
                samples.Add(new MetricSample("disk_free_bytes", drive.AvailableFreeSpace, now, labels,
                    "System.IO.DriveInfo"));
                samples.Add(new MetricSample("disk_total_bytes", drive.TotalSize, now, labels,
                    "System.IO.DriveInfo"));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                absences.Add(new CollectionAbsence("disk_usage_percent", "System.IO.DriveInfo",
                    $"{drive.Name}: {ex.GetType().Name}"));
            }
        }

        return Task.FromResult(new CollectionResult(samples, attempts, absences));
    }
}
