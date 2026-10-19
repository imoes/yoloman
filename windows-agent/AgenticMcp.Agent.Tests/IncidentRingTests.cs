using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The incident ring and the incident→evidence mapping (plan docs/etw-ringbuffer-plan.md), E0. Pure logic, no ETW —
/// so it runs on the Linux dev host like the rest of AgenticMcp.Agent.Diagnosis. The ring must stay bounded both ways
/// (count and age), filter correctly, and give every incident a stable evidence id.
/// </summary>
public class IncidentRingTests
{
    private static Incident Exit(int pid, DateTime at, int code = 1, string image = @"C:\svc\probe.exe") =>
        new(IncidentKind.ProcessExit, at, pid, image, ExitCode: code);

    [Fact]
    public void Evicts_the_oldest_once_over_capacity()
    {
        var ring = new IncidentRing(capacity: 3);
        var t = new DateTime(2026, 10, 18, 3, 0, 0, DateTimeKind.Utc);
        for (var i = 0; i < 5; i++) ring.Add(Exit(100 + i, t.AddSeconds(i)));
        var recent = ring.Recent();
        Assert.Equal(3, recent.Count);
        Assert.Equal(new[] { 104, 103, 102 }, recent.Select(r => r.Pid).ToArray());   // newest first, two oldest gone
    }

    [Fact]
    public void Drops_entries_older_than_max_age()
    {
        var now = new DateTime(2026, 10, 18, 12, 0, 0, DateTimeKind.Utc);
        var ring = new IncidentRing(capacity: 100, maxAge: TimeSpan.FromMinutes(10)) { Now = () => now };
        ring.Add(Exit(1, now.AddMinutes(-30)));   // too old
        ring.Add(Exit(2, now.AddMinutes(-5)));    // within window
        var recent = ring.Recent();
        Assert.Single(recent);
        Assert.Equal(2, recent[0].Pid);
    }

    [Fact]
    public void Recent_filters_by_pid_and_image_newest_first()
    {
        var now = new DateTime(2026, 10, 18, 12, 0, 0, DateTimeKind.Utc);
        var ring = new IncidentRing() { Now = () => now };
        ring.Add(Exit(10, now.AddSeconds(-30), image: @"C:\a\svc.exe"));
        ring.Add(Exit(10, now.AddSeconds(-20), image: @"C:\a\svc.exe"));
        ring.Add(Exit(99, now.AddSeconds(-10), image: @"C:\b\other.exe"));

        Assert.Equal(2, ring.Recent(pid: 10).Count);
        // image match is by file name, case-insensitive, regardless of directory
        var byImage = ring.Recent(image: @"D:\elsewhere\SVC.EXE");
        Assert.Equal(2, byImage.Count);
        Assert.True(byImage[0].At > byImage[1].At);   // newest first
        Assert.Empty(ring.Recent(within: TimeSpan.FromSeconds(5)));   // all older than 5s
    }

    [Fact]
    public void Evidence_id_is_stable_and_maps_to_evidence()
    {
        var at = new DateTime(2026, 10, 18, 3, 0, 0, DateTimeKind.Utc);
        var inc = new Incident(IncidentKind.Exception, at, 4242, @"C:\svc\probe.exe",
            ExceptionType: "System.InvalidOperationException");
        var id = inc.EvidenceId;
        Assert.Equal(id, inc.EvidenceId);                       // stable across calls
        Assert.StartsWith("etw:exception:4242:", id);
        var ev = inc.ToEvidence();
        Assert.Equal(id, ev.Id);
        Assert.Equal("etw-incident-ring", ev.Source);
        Assert.Contains("System.InvalidOperationException", ev.Fact);
        Assert.Equal("4242", ev.Raw!["pid"]!.ToString());
    }

    [Fact]
    public void A_linux_incident_carries_the_ebpf_source()
    {
        var inc = new Incident(IncidentKind.OomKill, DateTime.UtcNow, 7, "/usr/bin/svc", Source: "ebpf");
        Assert.StartsWith("ebpf:oom-kill:7:", inc.EvidenceId);
        Assert.Equal("ebpf-incident-ring", inc.ToEvidence().Source);
    }

    [Fact]
    public void Persists_and_reloads_across_a_restart()
    {
        var now = new DateTime(2026, 10, 18, 12, 0, 0, DateTimeKind.Utc);
        var path = Path.Combine(Path.GetTempPath(), $"ring-{Guid.NewGuid():N}.json");
        try
        {
            var a = new IncidentRing() { Now = () => now };
            a.Add(Exit(1, now.AddMinutes(-3), image: @"C:\svc\probe.exe"));
            a.Add(new Incident(IncidentKind.Exception, now.AddMinutes(-2), 1, @"C:\svc\probe.exe",
                ExceptionType: "System.InvalidOperationException"));
            a.SaveTo(path);

            var b = new IncidentRing() { Now = () => now };   // a "restarted" agent
            b.LoadFrom(path);
            var recent = b.Recent();
            Assert.Equal(2, recent.Count);
            Assert.Equal(new[] { IncidentKind.Exception, IncidentKind.ProcessExit }, recent.Select(r => r.Kind).ToArray());
            Assert.Equal("System.InvalidOperationException", recent[0].ExceptionType);
            Assert.Equal(a.All()[0].EvidenceId, recent[0].EvidenceId);   // ids survive the round-trip
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Load_drops_entries_older_than_max_age()
    {
        var now = new DateTime(2026, 10, 18, 12, 0, 0, DateTimeKind.Utc);
        var path = Path.Combine(Path.GetTempPath(), $"ring-{Guid.NewGuid():N}.json");
        try
        {
            var a = new IncidentRing() { Now = () => now };
            a.Add(Exit(1, now.AddMinutes(-3)));
            a.SaveTo(path);
            // The file was written three minutes ago; a day later only the still-fresh-enough survive the load.
            var later = new IncidentRing(maxAge: TimeSpan.FromMinutes(10)) { Now = () => now.AddHours(24) };
            later.LoadFrom(path);
            Assert.Empty(later.Recent());
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_missing_or_corrupt_file_leaves_the_ring_empty_and_does_not_throw()
    {
        var ring = new IncidentRing();
        ring.LoadFrom(Path.Combine(Path.GetTempPath(), $"nope-{Guid.NewGuid():N}.json"));   // missing
        Assert.Empty(ring.Recent());
        var bad = Path.Combine(Path.GetTempPath(), $"bad-{Guid.NewGuid():N}.json");
        File.WriteAllText(bad, "{ this is not json");
        try { ring.LoadFrom(bad); Assert.Empty(ring.Recent()); }
        finally { File.Delete(bad); }
    }

    [Fact]
    public void Concurrent_adds_stay_bounded_and_do_not_throw()
    {
        var ring = new IncidentRing(capacity: 50);
        var t = new DateTime(2026, 10, 18, 3, 0, 0, DateTimeKind.Utc);
        Parallel.For(0, 1000, i => ring.Add(Exit(i, t.AddMilliseconds(i))));
        Assert.True(ring.Count <= 50);
        Assert.Equal(50, ring.Recent().Count);
    }
}
