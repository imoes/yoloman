using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Diagnosis;

// The incident ring (plan docs/etw-ringbuffer-plan.md): the agent keeps a bounded, in-memory log of the recent
// PAST events that matter for a diagnosis — a process that exited abnormally, an image crash, a .NET exception
// (Windows, from the ETW session) or an OOM kill / fatal signal (Linux, from the eBPF collector). The diagnosis
// looks back on it so a TRANSIENT failure — a service that crashed at 03:00 and restarted — is still explainable
// after the fact, when the current-state read shows nothing wrong.
//
// Only metadata is kept: time, pid, image, kind, exit code or exception type. No payloads, no memory, no dump — the
// ring is privacy-safe by construction. An incident is always Likely, never Proven: it describes a PAST invocation,
// not the present state.

public static class IncidentKind
{
    public const string ProcessExit = "process-exit";   // a process ended with a non-zero exit code
    public const string ImageCrash = "image-crash";      // the image faulted (WER / kernel fault)
    public const string Exception = "exception";         // a .NET exception was thrown
    public const string OomKill = "oom-kill";            // Linux: killed by the OOM killer
    public const string FatalSignal = "fatal-signal";    // Linux: killed by a fatal signal (SIGSEGV/SIGABRT/…)
}

/// <summary>
/// One recorded past event. Immutable; <see cref="EvidenceId"/> is stable for the same event so a diagnosis cites it
/// the same way every time. <see cref="Source"/> is the mechanism that observed it ("etw" on Windows, "ebpf" on
/// Linux) and is also the evidence-id prefix.
/// </summary>
public sealed record Incident(
    string Kind,
    DateTime At,
    int Pid,
    string Image,
    int? ExitCode = null,
    string? ExceptionType = null,
    string? Detail = null,
    string Source = "etw")
{
    private long UnixMs => new DateTimeOffset(DateTime.SpecifyKind(At, DateTimeKind.Utc)).ToUnixTimeMilliseconds();

    /// <summary>A stable evidence id: <c>&lt;source&gt;:&lt;kind&gt;:&lt;pid&gt;:&lt;unix-ms&gt;</c>. Derived, not stored —
    /// excluded from persistence so the on-disk ring round-trips through the record's constructor cleanly.</summary>
    [JsonIgnore] public string EvidenceId => $"{Source}:{Kind}:{Pid}:{UnixMs}";

    /// <summary>The human sentence the diagnosis shows and the explanation must match against.</summary>
    public string Fact()
    {
        var who = $"process {Pid} ({Image})";
        return Kind switch
        {
            IncidentKind.ProcessExit => $"{who} exited with code {ExitCode} at {Iso()}.",
            IncidentKind.ImageCrash => $"{who} crashed at {Iso()}{(Detail is null ? "" : $" ({Detail})")}.",
            IncidentKind.Exception => $"{who} threw {ExceptionType} at {Iso()}.",
            IncidentKind.OomKill => $"{who} was killed by the out-of-memory killer at {Iso()}.",
            IncidentKind.FatalSignal => $"{who} was killed by {Detail ?? "a fatal signal"} at {Iso()}.",
            _ => $"{who}: {Kind} at {Iso()}.",
        };
    }

    private string Iso() => DateTime.SpecifyKind(At, DateTimeKind.Utc).ToString("yyyy-MM-ddTHH:mm:ssZ");

    /// <summary>The incident as an <see cref="Evidence"/> record for the diagnosis document.</summary>
    public Evidence ToEvidence() => new()
    {
        Id = EvidenceId,
        Source = Source == "ebpf" ? "ebpf-incident-ring" : "etw-incident-ring",
        Observed = DateTime.SpecifyKind(At, DateTimeKind.Utc),
        Fact = Fact(),
        Raw = Raw(),
    };

    private JsonObject Raw()
    {
        var o = new JsonObject
        {
            ["kind"] = Kind,
            ["pid"] = Pid,
            ["image"] = Image,
            ["at"] = Iso(),
        };
        if (ExitCode is not null) o["exit_code"] = ExitCode;
        if (ExceptionType is not null) o["exception_type"] = ExceptionType;
        if (Detail is not null) o["detail"] = Detail;
        return o;
    }
}
