namespace AgenticMcp.Agent.Diagnosis;

/// <summary>
/// Decides which raw ETW signals become incidents (plan docs/etw-ringbuffer-plan.md; user decision 2026-10-19:
/// <b>only FATAL exceptions</b>).
///
/// <para>The CLR Exception provider fires on EVERY thrown .NET exception, and almost all of them are caught and
/// handled — gpresult, SIHClient, PowerShell and the agent itself throw and swallow exceptions constantly as part of
/// normal operation. Recording each one floods the incident ring with routine noise (measured: 199 of 200 ring entries
/// were handled exceptions, burying the one real process-exit). So a .NET exception becomes an incident ONLY when the
/// same process then exits ABNORMALLY within <paramref name="maxLag"/> — i.e. the exception that actually killed it. A
/// handled exception whose process keeps running, or whose process later exits cleanly, is not an incident and is
/// discarded.</para>
///
/// <para>Abnormal process exits (non-zero exit code, or an NTSTATUS crash code) are always incidents in their own
/// right, with or without a preceding exception. Clean exits (code 0) are never incidents.</para>
///
/// <para>Pure and deterministic — no ETW, no Win32 — so the correlation is unit-tested on the Linux dev host. The
/// <see cref="EtwIncidentCollector"/> feeds it ETW events and adds the incidents it returns to the ring.</para>
/// </summary>
public sealed class IncidentCorrelator(TimeSpan? maxLag = null)
{
    private readonly TimeSpan _maxLag = maxLag ?? TimeSpan.FromSeconds(60);
    // pid → the most recent exception that process threw (type + when). One entry per live pid; consumed or discarded
    // on exit, replaced on a newer throw, cleared when the pid is reused by a new process.
    private readonly Dictionary<int, (DateTime At, string Type)> _pending = new();
    private readonly Lock _gate = new();

    /// <summary>A process threw a .NET exception. Buffered, NOT recorded — it only matters if the process then dies.</summary>
    public void OnException(int pid, DateTime at, string type)
    {
        lock (_gate) { _pending[pid] = (at, type); }
    }

    /// <summary>A new process started under this pid. A pid is reused after an exit, so any exception buffered against
    /// the old owner must not be attributed to this one.</summary>
    public void OnProcessStart(int pid)
    {
        lock (_gate) { _pending.Remove(pid); }
    }

    /// <summary>
    /// A process exited. Returns the incidents it produces, newest cause last:
    /// <list type="bullet">
    /// <item>a clean exit (code 0) → nothing, and its buffered exception is discarded (it was handled);</item>
    /// <item>an abnormal exit → the exit/crash incident, plus — if the process threw within <c>maxLag</c> before
    ///   dying — the fatal exception that explains it.</item>
    /// </list>
    /// The buffered exception for the pid is always cleared.
    /// </summary>
    public IReadOnlyList<Incident> OnProcessExit(int pid, DateTime at, string image, int exitStatus)
    {
        (DateTime At, string Type)? pending;
        lock (_gate)
        {
            pending = _pending.TryGetValue(pid, out var p) ? p : null;
            _pending.Remove(pid);
        }
        if (exitStatus == 0)
            return [];   // a clean exit is not an incident, and any exception it threw was handled

        var result = new List<Incident>(2);
        // An NTSTATUS failure (top two bits set, e.g. 0xC0000005 access violation) means the process was killed by a
        // fault, not that it chose to exit with that code — record it as a crash.
        var isCrash = (uint)exitStatus >= 0xC0000000u;
        result.Add(isCrash
            ? new Incident(IncidentKind.ImageCrash, at, pid, image, Detail: $"exit status 0x{(uint)exitStatus:X8}")
            : new Incident(IncidentKind.ProcessExit, at, pid, image, ExitCode: exitStatus));
        // The exception that killed it: thrown no earlier than maxLag before the exit, and not after it.
        if (pending is { } pe && at >= pe.At && at - pe.At <= _maxLag)
            result.Add(new Incident(IncidentKind.Exception, pe.At, pid, image, ExceptionType: pe.Type));
        return result;
    }
}
