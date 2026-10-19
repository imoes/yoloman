using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// Only FATAL exceptions become incidents (user decision 2026-10-19). The CLR Exception provider fires on every throw,
/// almost all handled — so an exception is an incident only when the same process then dies abnormally. These tests pin
/// that rule without ETW (pure correlation), the way the ring/rules are tested on the Linux dev host.
/// </summary>
public class IncidentCorrelatorTests
{
    private static readonly DateTime T = new(2026, 10, 19, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void A_handled_exception_whose_process_keeps_running_is_not_an_incident()
    {
        var c = new IncidentCorrelator();
        c.OnException(1000, T, "System.IO.FileNotFoundException");
        // no exit → nothing was ever produced; the exception stays buffered and unrecorded.
        // (The only way incidents appear is through OnProcessExit, which was never called.)
        Assert.Empty(c.OnProcessExit(9999, T, "other.exe", 0));   // an unrelated clean exit produces nothing either
    }

    [Fact]
    public void A_handled_exception_then_a_clean_exit_is_discarded()
    {
        var c = new IncidentCorrelator();
        c.OnException(1000, T, "System.Management.Automation.ItemNotFoundException");
        Assert.Empty(c.OnProcessExit(1000, T.AddSeconds(2), "powershell.exe", 0));   // clean exit: not an incident
    }

    [Fact]
    public void An_exception_then_an_abnormal_exit_yields_both_the_crash_and_the_fatal_exception()
    {
        var c = new IncidentCorrelator();
        c.OnException(1000, T, "System.InvalidOperationException");
        var inc = c.OnProcessExit(1000, T.AddSeconds(1), "probe.exe", unchecked((int)0xC0000409u));
        Assert.Equal(2, inc.Count);
        Assert.Equal(IncidentKind.ImageCrash, inc[0].Kind);               // the crash itself
        Assert.Equal(IncidentKind.Exception, inc[1].Kind);               // the exception that killed it
        Assert.Equal("System.InvalidOperationException", inc[1].ExceptionType);
        Assert.Equal(T, inc[1].At);                                       // dated when thrown, not when it exited
    }

    [Fact]
    public void An_abnormal_exit_with_no_exception_is_still_an_incident()
    {
        var c = new IncidentCorrelator();
        var inc = c.OnProcessExit(1000, T, "svc.exe", 42);
        Assert.Single(inc);
        Assert.Equal(IncidentKind.ProcessExit, inc[0].Kind);
        Assert.Equal(42, inc[0].ExitCode);
    }

    [Fact]
    public void An_exception_too_long_before_the_exit_is_not_counted_as_the_cause()
    {
        var c = new IncidentCorrelator(TimeSpan.FromSeconds(30));
        c.OnException(1000, T, "System.Exception");
        var inc = c.OnProcessExit(1000, T.AddMinutes(5), "svc.exe", 1);   // 5 min later — unrelated
        Assert.Single(inc);
        Assert.Equal(IncidentKind.ProcessExit, inc[0].Kind);             // only the exit, the stale exception is dropped
    }

    [Fact]
    public void A_reused_pid_does_not_inherit_the_previous_owners_exception()
    {
        var c = new IncidentCorrelator();
        c.OnException(1000, T, "System.Exception");          // old process throws
        c.OnProcessStart(1000);                              // pid reused by a new process
        var inc = c.OnProcessExit(1000, T.AddSeconds(1), "new.exe", 1);
        Assert.Single(inc);                                  // only the exit — the pre-start exception is not attributed here
        Assert.Equal(IncidentKind.ProcessExit, inc[0].Kind);
    }

    [Fact]
    public void A_consumed_exception_is_not_reused_for_a_later_exit_of_the_same_pid()
    {
        var c = new IncidentCorrelator();
        c.OnException(1000, T, "System.Exception");
        Assert.Equal(2, c.OnProcessExit(1000, T.AddSeconds(1), "a.exe", 1).Count);   // crash + exception
        // pid reused, new process exits abnormally but threw nothing: the earlier exception must not resurface.
        Assert.Single(c.OnProcessExit(1000, T.AddSeconds(2), "b.exe", 1));
    }
}
