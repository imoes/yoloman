using AgenticMcp.Agent.Diagnosis;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The Windows <c>recent_incidents</c> module (peer UX concept #2): it surfaces the IncidentRing as a timeline under
/// the same contract and output shape as the Linux Go module. Pure logic over a ring, no ETW — so it runs on the Linux
/// dev host. An absent/stopped ring is a NAMED ring_state, never an empty list that reads as "no crashes".
/// </summary>
public class RecentIncidentsModuleTests
{
    private static readonly DateTime Now = new(2026, 10, 19, 12, 0, 0, DateTimeKind.Utc);

    private static IncidentRing RingWith(params Incident[] items)
    {
        var ring = new IncidentRing(capacity: 1000) { Now = () => Now };
        foreach (var it in items) ring.Add(it);
        return ring;
    }

    private static Dictionary<string, object?> Run(RecentIncidentsModule m, Dictionary<string, object?>? p = null)
    {
        var res = m.RunAsync(p ?? [], dryRun: false, CancellationToken.None).GetAwaiter().GetResult();
        return (Dictionary<string, object?>)res.Data!;
    }

    [Fact]
    public void No_ring_is_a_named_not_supported_state_not_an_empty_list()
    {
        var m = new RecentIncidentsModule();   // no ring wired
        var d = Run(m);
        Assert.StartsWith("not_supported", (string)d["ring_state"]!);
        Assert.Equal(0, (int)d["count"]!);
        Assert.True((bool)d["persistent"]!);          // the Windows ring is persistent
        Assert.Empty((List<Dictionary<string, object?>>)d["incidents"]!);
    }

    [Fact]
    public void A_stopped_session_is_not_supported_even_with_a_ring()
    {
        var m = new RecentIncidentsModule(RingWith(), available: () => false);
        var d = Run(m);
        Assert.StartsWith("not_supported", (string)d["ring_state"]!);
    }

    [Fact]
    public void Lists_newest_first_with_a_stable_evidence_id_and_the_ring_metadata()
    {
        var ring = RingWith(
            new Incident(IncidentKind.ProcessExit, Now.AddMinutes(-30), 1, @"C:\svc\a.exe", ExitCode: 1),
            new Incident(IncidentKind.Exception, Now.AddMinutes(-2), 2, @"C:\svc\b.exe", ExceptionType: "System.InvalidOperationException"),
            new Incident(IncidentKind.ImageCrash, Now.AddMinutes(-5), 3, @"C:\svc\a.exe", Detail: "exit status 0xC0000005"));
        var m = new RecentIncidentsModule(ring, available: () => true, startedAt: Now.AddHours(-1), persistent: true);

        var d = Run(m);
        Assert.Equal("available", (string)d["ring_state"]!);
        Assert.Equal("etw-incident-ring", (string)d["source"]!);
        Assert.Equal(1000, (int)d["capacity"]!);
        Assert.Equal("2026-10-19T11:00:00Z", (string)d["since"]!);
        var inc = (List<Dictionary<string, object?>>)d["incidents"]!;
        Assert.Equal(3, inc.Count);
        Assert.Equal(2, (int)inc[0]["pid"]!);                                    // newest first
        Assert.Equal("System.InvalidOperationException", (string)inc[0]["detail"]!);
        Assert.False(string.IsNullOrEmpty((string)inc[0]["evidence_id"]!));     // a diagnosis cites this
    }

    [Fact]
    public void Filters_by_kind_image_and_within_minutes()
    {
        var ring = RingWith(
            new Incident(IncidentKind.ProcessExit, Now.AddMinutes(-30), 1, @"C:\svc\a.exe", ExitCode: 1),
            new Incident(IncidentKind.ImageCrash, Now.AddMinutes(-2), 2, @"C:\svc\b.exe", Detail: "boom"),
            new Incident(IncidentKind.ImageCrash, Now.AddMinutes(-5), 3, @"C:\svc\a.exe", Detail: "boom"));
        var m = new RecentIncidentsModule(ring, available: () => true, startedAt: Now.AddHours(-1));

        Assert.Equal(2, (int)Run(m, new() { ["kind"] = IncidentKind.ImageCrash })["count"]!);
        Assert.Equal(2, (int)Run(m, new() { ["image"] = "a.exe" })["count"]!);     // bare name, case-insensitive
        Assert.Equal(2, (int)Run(m, new() { ["within_minutes"] = 10 })["count"]!);
        Assert.Equal(1, (int)Run(m, new() { ["kind"] = IncidentKind.ImageCrash, ["image"] = "a.exe" })["count"]!);
    }
}
