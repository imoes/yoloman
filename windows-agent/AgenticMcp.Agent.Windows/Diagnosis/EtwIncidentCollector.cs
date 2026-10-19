using System.Collections.Concurrent;
using System.Runtime.Versioning;
using AgenticMcp.Agent.Diagnosis;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Parsers;
using Microsoft.Diagnostics.Tracing.Parsers.Clr;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;
using Microsoft.Diagnostics.Tracing.Session;
using Microsoft.Extensions.Logging;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// A persistent, real-time ETW session that fills the <see cref="IncidentRing"/> with the recent PAST events a
/// diagnosis looks back on (plan docs/etw-ringbuffer-plan.md, E1). Two providers:
/// <list type="bullet">
/// <item>the kernel <b>Process</b> provider — a process that EXITS, with its exit code; an abnormal exit
///   (non-zero) is kept, an NTSTATUS failure code (0xC0000005 …) is recorded as an image crash;</item>
/// <item>the CLR provider's <b>Exception</b> keyword — a managed exception, by type, but ONLY when it is fatal (the
///   process then dies); handled exceptions are routine noise and are discarded. The <see cref="IncidentCorrelator"/>
///   makes that call.</item>
/// </list>
///
/// <para>ONLY metadata is read — pid, image file name, exit code, exception type — never any payload, so nothing of a
/// process's memory is captured. Normal (zero) exits and handled exceptions are dropped on the floor; only abnormal
/// exits and the exceptions that caused them are kept, and the ring is bounded, so an always-on session stays cheap.</para>
///
/// <para>An ETW real-time session needs SYSTEM / an elevated token, which the agent's service has. If the session
/// cannot be created (not elevated, on a non-Windows host, or the name is already taken), the collector logs the
/// reason and does nothing further — it never brings the agent down.</para>
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class EtwIncidentCollector : IDisposable
{
    public const string SessionName = "YolomanIncidentRing";

    private readonly IncidentRing _ring;
    private readonly ILogger _log;
    private readonly string? _persistPath;
    private readonly ConcurrentDictionary<int, string> _imageByPid = new();   // pid → short image name, from ProcessStart
    // Only FATAL exceptions become incidents (user 2026-10-19): an exception is recorded only if its process then dies
    // abnormally. The correlator holds that cross-event state; it is pure and unit-tested on Linux.
    private readonly IncidentCorrelator _correlator = new();
    private TraceEventSession? _session;
    private Thread? _thread;
    private Timer? _flush;

    public EtwIncidentCollector(IncidentRing ring, ILogger log, string? persistPath = null)
    {
        _ring = ring;
        _log = log;
        _persistPath = persistPath;
    }

    /// <summary>Whether the ETW session is up and consuming — the ring's <c>ring_state</c> for recent_incidents. False
    /// before <see cref="Start"/>, or when the session could not be created (not elevated, non-Windows).</summary>
    public bool Running => _session is not null;

    /// <summary>When this collector began capturing (set in <see cref="Start"/>). The persisted ring can hold
    /// incidents from before this, restored from disk; live capture starts here.</summary>
    public DateTime StartedAt { get; private set; } = DateTime.UtcNow;

    /// <summary>Open the session and start consuming on a dedicated background thread. Safe to call once.</summary>
    public void Start()
    {
        if (!OperatingSystem.IsWindows())
            return;
        StartedAt = DateTime.UtcNow;   // live capture begins now; the persisted ring may reach further back
        // Seed from the last flush BEFORE the session starts, so a host reboot does not erase the recent history (E2).
        if (_persistPath is not null)
        {
            _ring.LoadFrom(_persistPath);
            // Flush periodically and keep the file current; best-effort, so a slow disk never blocks capture.
            _flush = new Timer(_ => { if (_persistPath is { } p) _ring.SaveTo(p); }, null,
                TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));
        }
        try
        {
            // A real-time session (no file). Stopping an existing instance first makes a restart of the agent clean:
            // an ETW session outlives the process that made it, so a crashed agent could leave the name taken.
            TraceEventSession.GetActiveSession(SessionName)?.Stop();
            _session = new TraceEventSession(SessionName) { StopOnDispose = true };
            _session.EnableKernelProvider(KernelTraceEventParser.Keywords.Process);
            _session.EnableProvider(ClrTraceEventParser.ProviderGuid, TraceEventLevel.Informational,
                (ulong)ClrTraceEventParser.Keywords.Exception);

            _session.Source.Kernel.ProcessStart += OnProcessStart;
            _session.Source.Kernel.ProcessStop += OnProcessStop;
            _session.Source.Clr.ExceptionStart += OnException;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "ETW incident session could not be started ({Name}); past-incident history is off", SessionName);
            _session?.Dispose();
            _session = null;
            return;
        }

        _thread = new Thread(() =>
        {
            try { _session!.Source.Process(); }
            catch (Exception ex) { _log.LogWarning(ex, "ETW incident session stopped"); }
        })
        { IsBackground = true, Name = "etw-incident-ring" };
        _thread.Start();
        _log.LogInformation("ETW incident ring started (providers: kernel Process, CLR Exception)");
    }

    private void OnProcessStart(ProcessTraceData d)
    {
        _imageByPid[d.ProcessID] = ShortImage(d);
        _correlator.OnProcessStart(d.ProcessID);   // a reused pid starts clean — drop any exception buffered against the old owner
    }

    private void OnProcessStop(ProcessTraceData d)
    {
        _imageByPid.TryRemove(d.ProcessID, out var known);
        var image = known ?? ShortImage(d);
        // The correlator decides: an abnormal exit is an incident; a .NET exception is one only if it killed this
        // process; a clean exit is nothing (and discards any handled exception the process threw).
        foreach (var inc in _correlator.OnProcessExit(d.ProcessID, d.TimeStamp.ToUniversalTime(), image, d.ExitStatus))
        {
            _ring.Add(inc);
            _log.LogInformation("incident: {Fact}", inc.Fact());
        }
    }

    private void OnException(ExceptionTraceData d)
    {
        // Buffered, not recorded: the CLR provider fires on every THROW, almost all handled. It becomes an incident
        // only if this process then dies abnormally (see IncidentCorrelator) — otherwise it is routine noise.
        _correlator.OnException(d.ProcessID, d.TimeStamp.ToUniversalTime(), d.ExceptionType);
    }

    // The kernel event carries the executable's short name (e.g. "probe.exe"); the ring matches an image by its bare
    // file name, so the short name is enough and no full-path resolution is needed.
    private static string ShortImage(ProcessTraceData d)
    {
        var name = d.ImageFileName;
        return string.IsNullOrEmpty(name) ? $"pid {d.ProcessID}" : name;
    }

    public void Dispose()
    {
        try { _flush?.Dispose(); } catch { /* best-effort */ }
        if (_persistPath is { } p) _ring.SaveTo(p);   // one last flush so a clean stop loses nothing
        try { _session?.Dispose(); } catch { /* stopping a torn-down session is best-effort */ }
        _session = null;
    }
}
