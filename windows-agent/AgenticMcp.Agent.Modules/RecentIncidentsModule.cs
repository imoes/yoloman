using System.Globalization;
using System.Text.Json;
using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// <c>recent_incidents</c> — the host's recent PAST incidents for a timeline, the SAME contract and output shape as the
/// Linux Go module of the same name (internal/modules/recent_incidents.go). On Windows the source is the ETW incident
/// ring (<see cref="IncidentRing"/>, filled by EtwIncidentCollector); the Linux agent fills its ring from the eBPF
/// collector. READ-ONLY.
///
/// <para>The answer always states <c>ring_state</c> (available | not_supported:&lt;reason&gt;), <c>capacity</c>,
/// <c>persistent</c> and <c>since</c>. On Windows the ring IS persistent (it survives a reboot — persisted to
/// incident-ring.json), so <c>persistent</c> is true and the list may include incidents from before <c>since</c>
/// (the moment this agent began live capture), restored from disk. An empty list is "no incidents the ring holds",
/// bounded by its capacity and retention — not a claim that nothing ever crashed.</para>
/// </summary>
public sealed class RecentIncidentsModule : IModule
{
    private readonly IncidentRing? _ring;
    private readonly Func<bool> _available;
    private readonly DateTime _startedAt;
    private readonly bool _persistent;
    private readonly string _source;

    /// <param name="ring">The incident ring to read; null means no ring on this host (→ not_supported).</param>
    /// <param name="available">Whether the producer (the ETW session) is running; null is treated as available when a
    /// ring is present.</param>
    /// <param name="startedAt">When live capture began — reported as <c>since</c>.</param>
    /// <param name="persistent">Whether the ring survives a restart (true on Windows: it is persisted to disk).</param>
    /// <param name="source">The ring's mechanism, the <c>source</c> field ("etw-incident-ring" on Windows).</param>
    public RecentIncidentsModule(IncidentRing? ring = null, Func<bool>? available = null, DateTime? startedAt = null,
        bool persistent = true, string source = "etw-incident-ring")
    {
        _ring = ring;
        _available = available ?? (() => ring is not null);
        _startedAt = startedAt ?? DateTime.UtcNow;
        _persistent = persistent;
        _source = source;
    }

    public string Name => "recent_incidents";

    public string Description =>
        "List the host's recent PAST incidents — the agent's incident ring (on Windows: abnormal process exits, image " +
        "crashes and .NET exceptions from the ETW session), newest first, for a timeline. READ-ONLY. Each incident: kind " +
        "(process-exit, image-crash, exception, oom-kill, fatal-signal), time, pid, image, detail, source and a stable " +
        "evidence_id (the same id a diagnosis cites when it reports svc.recent_incident). The answer always states source, " +
        "ring_state (available | not_supported:<reason>), capacity, whether it is persistent, and 'since' (when live " +
        "capture began). On Windows the ring is persistent, so incidents from before 'since' may appear, restored from " +
        "disk; an empty list is bounded by capacity and retention, not a claim that nothing ever crashed.\n\n" +
        "Parameters: kind, image (filters), within_minutes (only incidents newer than this), limit (default 200).\n\n" +
        "Cross-tool equivalents: none — this is the agent's own bounded event history. Same contract as the Linux agent's " +
        "recent_incidents, whose ring the eBPF collector fills.";

    public IReadOnlyDictionary<string, object> InputSchema { get; } = new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["kind"] = new Dictionary<string, object> { ["type"] = "string", ["description"] = "Only this incident kind (process-exit, image-crash, exception, oom-kill, fatal-signal)." },
            ["image"] = new Dictionary<string, object> { ["type"] = "string", ["description"] = "Only this process image (matched by bare file name, case-insensitive)." },
            ["within_minutes"] = new Dictionary<string, object> { ["type"] = "integer", ["description"] = "Only incidents from the last N minutes (0 = all the ring holds)." },
            ["limit"] = new Dictionary<string, object> { ["type"] = "integer", ["default"] = 200, ["description"] = "At most this many, newest first (default 200)." },
        },
    };

    public bool Writes => false;

    public Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        var kind = Str(parameters, "kind");
        var image = Str(parameters, "image");
        var within = Int(parameters, "within_minutes", 0);
        var limit = Int(parameters, "limit", 200);
        if (limit <= 0)
            limit = 200;

        var data = new Dictionary<string, object?>
        {
            ["source"] = _source,
            ["persistent"] = _persistent,
            ["since"] = Iso(_startedAt),
            ["capacity"] = _ring?.Capacity ?? 0,
        };

        if (_ring is null || !_available())
        {
            data["ring_state"] = "not_supported: the ETW incident session is not running on this host (needs an elevated/SYSTEM token on Windows)";
            data["incidents"] = new List<Dictionary<string, object?>>();
            data["count"] = 0;
            return Task.FromResult(new ModuleResult(false, "no incident ring on this host", data));
        }

        var within_ts = within > 0 ? TimeSpan.FromMinutes(within) : (TimeSpan?)null;
        // The ring filters by image (bare file name) and age; kind is this module's own filter so one ring serves every
        // kind. Sort by time, newest first, exactly as the Linux Go module does — the ring itself returns insertion
        // order (time order for a live ETW session), but the contract promises newest-first by timestamp.
        var items = _ring.Recent(image: string.IsNullOrEmpty(image) ? null : image, within: within_ts)
            .OrderByDescending(i => i.At).ToList();
        var outList = new List<Dictionary<string, object?>>();
        foreach (var inc in items)
        {
            if (!string.IsNullOrEmpty(kind) && inc.Kind != kind)
                continue;
            outList.Add(IncidentMap(inc));
            if (outList.Count >= limit)
                break;
        }

        data["ring_state"] = "available";
        data["incidents"] = outList;
        data["count"] = outList.Count;
        return Task.FromResult(new ModuleResult(false, outList.Count == 0 ? "no incidents in the ring" : "recent incidents listed",
            data, new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = outList.Count }));
    }

    private static Dictionary<string, object?> IncidentMap(Incident i)
    {
        var m = new Dictionary<string, object?>
        {
            ["kind"] = i.Kind,
            ["at"] = Iso(i.At),
            ["pid"] = i.Pid,
            ["image"] = i.Image,
            ["source"] = i.Source,
            ["evidence_id"] = i.EvidenceId,
        };
        // detail carries the free-text qualifier (exit status, exception type, signal) when there is one.
        var detail = i.Detail ?? i.ExceptionType ?? (i.ExitCode is { } c ? $"exit code {c}" : null);
        if (detail is not null)
            m["detail"] = detail;
        return m;
    }

    private static string Iso(DateTime t) =>
        DateTime.SpecifyKind(t, DateTimeKind.Utc).ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    private static string Str(IReadOnlyDictionary<string, object?> p, string key) =>
        (p.TryGetValue(key, out var v) ? Convert.ToString(v, CultureInfo.InvariantCulture) : null)?.Trim() ?? "";

    private static int Int(IReadOnlyDictionary<string, object?> p, string key, int fallback)
    {
        if (!p.TryGetValue(key, out var v) || v is null)
            return fallback;
        return v switch
        {
            int i => i,
            long l => (int)l,
            double d => (int)d,
            JsonElement je when je.ValueKind == JsonValueKind.Number && je.TryGetInt32(out var ji) => ji,
            string s when int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var si) => si,
            _ => fallback,
        };
    }
}
