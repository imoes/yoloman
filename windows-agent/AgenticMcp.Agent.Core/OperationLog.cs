using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// WHAT THIS HOST DID, kept so it can be asked afterwards.
///
/// <para>A module call answers whoever is waiting for it and then the answer is gone. For the two operations
/// that matter most — a feature install and a package install — the interesting part is exactly the part that
/// scrolls past: the plan the system produced for itself, the exit code, the detection rule's answer before
/// and after, and Windows' own refusal text. "What did that install actually do" has to be answerable an hour
/// later, by a person or by an AI reading the same record rather than a summary of it.</para>
///
/// <para>IN MEMORY, ON PURPOSE, AND SAID SO. This is a ring buffer inside the agent process: cheap, no disk
/// growth to manage on a host nobody logs into, and lost on restart. Bossman's table is the durable copy —
/// which is why every read carries <see cref="OperationLogPage.BootId"/> and the sequence range: a collector
/// can tell "I have everything" from "the agent restarted" from "records fell out before I got here", and the
/// third case is reported as a number rather than as silence.</para>
/// </summary>
public sealed record OperationRecord(
    [property: JsonPropertyName("seq")] long Seq,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("module")] string Module,
    /// <summary>changed | unchanged | planned | refused | error | timed-out | unknown-module. Exhaustive, and
    /// every one of them is a different thing that happened: `planned` is a dry run, which neither changed
    /// nor failed to change; `refused` is the target saying no (a fact about the host); `error` is this agent
    /// breaking (a fact about us); `timed-out` means the operation MAY HAVE COMPLETED — measured, the SNMP
    /// install did — so it must never be filed as a failure.</summary>
    [property: JsonPropertyName("outcome")] string Outcome,
    [property: JsonPropertyName("dry_run")] bool DryRun,
    [property: JsonPropertyName("params")] Dictionary<string, object?> Params,
    [property: JsonPropertyName("identity")] string? Identity,
    [property: JsonPropertyName("started_at")] string StartedAt,
    [property: JsonPropertyName("duration_ms")] double DurationMs,
    [property: JsonPropertyName("changed")] bool? Changed,
    [property: JsonPropertyName("message")] string? Message,
    /// <summary>The EVIDENCE, verbatim: the module's own data block (exit codes, before/after state, the
    /// -WhatIf plan, stdout/stderr the target produced). A verdict without it is an opinion.</summary>
    [property: JsonPropertyName("evidence")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    object? Evidence,
    [property: JsonPropertyName("error")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Error);

public sealed record OperationLogPage(
    /// <summary>This agent PROCESS. Sequence numbers restart with the process, so a cursor is only meaningful
    /// against the boot it was taken from — without this a collector silently skips or repeats a whole
    /// restart's worth of records.</summary>
    [property: JsonPropertyName("boot_id")] string BootId,
    [property: JsonPropertyName("oldest_seq")] long OldestSeq,
    [property: JsonPropertyName("newest_seq")] long NewestSeq,
    /// <summary>How many records the ring has discarded since this process started. NOTHING VANISHES
    /// SILENTLY: a collector that fell behind learns that it did, and by how much.</summary>
    [property: JsonPropertyName("dropped")] long Dropped,
    [property: JsonPropertyName("capacity")] int Capacity,
    [property: JsonPropertyName("count")] int Count,
    [property: JsonPropertyName("records")] List<OperationRecord> Records);

/// <summary>The process-wide operation log. Thread-safe; every write goes through <see cref="Record"/>.</summary>
public static class OperationLog
{
    /// <summary>1000 calls. At the fleet's real rate (a handful of writes and a few dozen reads per host per
    /// day) that is days of history in a few megabytes, and Bossman collects long before it wraps.</summary>
    public const int Capacity = 1000;

    private static readonly object Gate = new();
    private static readonly Queue<OperationRecord> Records = new();
    private static long _seq;
    private static long _dropped;

    /// <summary>Identifies this process. New on every start, by construction.</summary>
    public static string BootId { get; } = Guid.NewGuid().ToString();

    /// <summary>Parameter names whose VALUE is never written down. Matched as a substring, case-insensitively,
    /// because the interesting spellings are many (`password`, `Password`, `smb_password`, `api_key`,
    /// `client_secret`) and a log that records one of them once has already leaked it.</summary>
    private static readonly string[] SecretHints =
        ["password", "passwd", "secret", "token", "credential", "apikey", "api_key", "privatekey", "private_key"];

    public static Dictionary<string, object?> Redact(IReadOnlyDictionary<string, object?>? parameters)
    {
        var safe = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in parameters ?? new Dictionary<string, object?>())
        {
            var isSecret = SecretHints.Any(h => key.Contains(h, StringComparison.OrdinalIgnoreCase));
            // The KEY is kept even when the value is dropped: "a password was passed" is part of what
            // happened, and hiding the parameter entirely makes a call unreproducible for no extra safety.
            safe[key] = isSecret ? "***redacted***" : value;
        }
        return safe;
    }

    public static OperationRecord Record(
        string module,
        string outcome,
        bool dryRun,
        IReadOnlyDictionary<string, object?>? parameters,
        string? identity,
        DateTimeOffset startedAt,
        double durationMs,
        bool? changed = null,
        string? message = null,
        object? evidence = null,
        string? error = null)
    {
        var record = new OperationRecord(
            Seq: 0, Id: Guid.NewGuid().ToString(), Module: module, Outcome: outcome, DryRun: dryRun,
            Params: Redact(parameters), Identity: identity,
            StartedAt: startedAt.ToUniversalTime().ToString("o"), DurationMs: Math.Round(durationMs, 1),
            Changed: changed, Message: message, Evidence: evidence, Error: error);

        lock (Gate)
        {
            record = record with { Seq = ++_seq };
            Records.Enqueue(record);
            while (Records.Count > Capacity)
            {
                Records.Dequeue();
                _dropped++;
            }
        }
        return record;
    }

    /// <summary>One page of the log, newest last, filtered the way an analysis asks its question: everything
    /// after a cursor, one module, one outcome. Filters are ANDed and each is optional.</summary>
    public static OperationLogPage Page(long? sinceSeq = null, string? module = null, string? outcome = null,
                                        int limit = 200)
    {
        lock (Gate)
        {
            var all = Records.ToList();
            var matched = all
                .Where(r => sinceSeq is null || r.Seq > sinceSeq)
                .Where(r => module is null || string.Equals(r.Module, module, StringComparison.OrdinalIgnoreCase))
                .Where(r => outcome is null || string.Equals(r.Outcome, outcome, StringComparison.OrdinalIgnoreCase))
                .Take(Math.Clamp(limit, 1, Capacity))
                .ToList();
            return new OperationLogPage(
                BootId: BootId,
                // The RING's range, not the page's: a collector needs to know what the agent still holds in
                // order to tell "nothing new" from "I asked for records that are already gone".
                OldestSeq: all.Count == 0 ? 0 : all[0].Seq,
                NewestSeq: all.Count == 0 ? 0 : all[^1].Seq,
                Dropped: _dropped,
                Capacity: Capacity,
                Count: matched.Count,
                Records: matched);
        }
    }

    /// <summary>Test seam: forget everything. Not reachable over HTTP — an operation log an operator can
    /// clear is an operation log an operator can hide behind.</summary>
    public static void ResetForTests()
    {
        lock (Gate)
        {
            Records.Clear();
            _seq = 0;
            _dropped = 0;
        }
    }
}
