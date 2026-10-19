using System.Text.Json;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The update rules over snapshots (the `upd.` catalogue). Every case is also a contract test: the document must hold
/// (<see cref="Validator"/>) and round-trip as JSON. Pure logic — runs on the Linux dev host.
/// </summary>
public class UpdateRulesTests
{
    private static readonly DateTime T0 = new(2026, 10, 18, 16, 0, 0, DateTimeKind.Utc);

    private static UpdateSnapshot Snap(Action<UpdateSnapshot>? mod = null)
    {
        var s = new UpdateSnapshot
        {
            Host = "bossman-wintest", Platform = "windows", SearchResult = "Succeeded", SearchComplete = true,
            Server = "windows_update", LastSearchSuccess = T0.AddMinutes(-2), CollectedAt = T0,
        };
        mod?.Invoke(s);
        return s;
    }

    private static DiagnosisDocument Run(UpdateSnapshot s)
    {
        var d = UpdateRules.Diagnose(s, "t", "bossman-wintest");
        var json = JsonSerializer.Serialize(d);
        Assert.Empty(Validator.Validate(JsonSerializer.Deserialize<DiagnosisDocument>(json)!));
        return d;
    }

    private static string Lead(DiagnosisDocument d) =>
        d.Findings.Count == 0 ? d.Status : $"{d.Findings[0].RuleId}/{d.Findings[0].Certainty}";

    private static Finding? ByRule(DiagnosisDocument d, string rule) => d.Findings.FirstOrDefault(f => f.RuleId == rule);

    [Fact]
    public void UpToDateWhenNothingPendingAndSearchClean()
    {
        var d = Run(Snap());
        Assert.Equal("up-to-date", d.Status);
        Assert.Equal("upd.up_to_date/Proven", Lead(d));
    }

    [Fact]
    public void BehindListsTheSecurityCount()
    {
        var d = Run(Snap(s => s.Pending =
        [
            new PendingUpdate { Kb = "KB1", MsrcSeverity = "Critical" },
            new PendingUpdate { Kb = "KB2", MsrcSeverity = "Important" },
            new PendingUpdate { Kb = "KB3", MsrcSeverity = "unrated" },
        ]));
        Assert.Equal("behind", d.Status);
        Assert.Equal("upd.behind/Proven", Lead(d));
        Assert.Contains("2 of them Critical/Important", ByRule(d, "upd.behind")!.Claim);
    }

    [Fact]
    public void AFailedInstallLeadsOverBehindAndReboot()
    {
        var d = Run(Snap(s =>
        {
            s.Pending = [new PendingUpdate { Kb = "KB5126655", MsrcSeverity = "Critical" }];
            s.RebootRequired = true;
            s.RebootReasons = ["Component Based Servicing RebootPending"];
            s.History = [new UpdateHistoryEntry { Date = T0.AddHours(-1), Operation = "Installation", Result = "Failed",
                Hresult = "0x8024200D (WU_E_UH_NEEDANOTHERDOWNLOAD)", Kb = "KB5126655", Title = "2026-10 Cumulative Update" }];
        }));
        Assert.Equal("behind", d.Status);
        Assert.Equal("upd.install_failed/Proven", Lead(d));            // failure ranks first
        Assert.NotNull(ByRule(d, "upd.reboot_pending"));
        Assert.NotNull(ByRule(d, "upd.behind"));
        Assert.Contains("0x8024200D", ByRule(d, "upd.install_failed")!.Claim);
    }

    [Fact]
    public void AnUnreachableWsusIsLikely()
    {
        var d = Run(Snap(s => { s.Server = "wsus"; s.WsusServer = "http://wsus.local:8530"; s.SearchComplete = false; s.SearchResult = "Failed"; s.IncompleteReason = "the search ended Failed"; }));
        var f = ByRule(d, "upd.wsus_unreachable");
        Assert.NotNull(f);
        Assert.Equal(Certainty.Likely, f!.Certainty);
        Assert.Equal("behind", d.Status);
    }

    [Fact]
    public void FromFactsMapsTheWindowsUpdateFactsOutput()
    {
        // Shaped like WindowsUpdateFacts.Interpret's output.
        var facts = new Dictionary<string, object?>
        {
            ["search_result"] = "Succeeded", ["complete"] = true, ["server"] = "windows_update",
            ["reboot_required"] = true, ["reboot_reasons"] = new List<object?> { "Component Based Servicing RebootPending" },
            ["last_search_success"] = "2026-10-18T15:58:00Z",
            ["pending"] = new List<object?>
            {
                new Dictionary<string, object?> { ["kb"] = "KB5126655", ["title"] = "Cumulative Update", ["msrc_severity"] = "Critical", ["needs_reboot"] = true },
            },
            ["history"] = new List<object?>
            {
                new Dictionary<string, object?> { ["date"] = "2026-10-18T15:00:00Z", ["operation"] = "Installation", ["result"] = "Failed", ["hresult"] = "0x8024200D (WU_E_UH_NEEDANOTHERDOWNLOAD)", ["kb"] = "KB5126655", ["title"] = "Cumulative Update" },
            },
        };
        var snap = UpdateRules.FromFacts(facts, "bossman-wintest", T0);
        Assert.True(snap.SearchComplete);
        Assert.True(snap.RebootRequired);
        Assert.Single(snap.Pending);
        Assert.Equal("Critical", snap.Pending[0].MsrcSeverity);
        Assert.Single(snap.History);
        Assert.Equal("Failed", snap.History[0].Result);
        Assert.Equal(new DateTime(2026, 10, 18, 15, 0, 0, DateTimeKind.Utc), snap.History[0].Date!.Value.ToUniversalTime());

        var d = Run(snap);
        Assert.Equal("upd.install_failed/Proven", Lead(d));   // the recorded failure leads
        Assert.Contains("WU_E_UH_NEEDANOTHERDOWNLOAD", ByRule(d, "upd.install_failed")!.Claim);
    }

    [Fact]
    public void AnIncompleteWindowsUpdateSearchWithNothingElseIsAGapNotEmpty()
    {
        var d = Run(Snap(s => { s.SearchComplete = false; s.SearchResult = "Aborted"; s.IncompleteReason = "the search ended Aborted"; }));
        // no pending, no failure, no reboot, not WSUS → behind with a named gap + upd.unexplained, never empty
        Assert.Equal("behind", d.Status);
        Assert.NotNull(ByRule(d, "upd.unexplained"));
        Assert.NotEmpty(d.Gaps);
    }
}
