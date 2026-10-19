using System.Text.Json;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// windows_update_facts' interpretation over the answer RECORDED on bossman-wintest (Server 2022, German locale,
/// Microsoft Update, 2026-10-17) — the collection script's real output, not a hand-written guess.
/// </summary>
public class WindowsUpdateFactsTests
{
    private static JsonElement Recorded()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "windows_update", "wintest-2026-10-17.json");
        return JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone();
    }

    private static List<Dictionary<string, object?>> Pending(Dictionary<string, object?> d) =>
        (List<Dictionary<string, object?>>)d["pending"]!;

    [Fact]
    public void ThePendingUpdatesKeepWindowsOwnWords()
    {
        var d = WindowsUpdateFacts.Interpret(Recorded());
        Assert.Equal("Succeeded", d["search_result"]);
        Assert.Equal("windows_update", d["server"]);
        Assert.Equal(4, d["pending_count"]);
        var net = Pending(d).Single(u => (string?)u["kb"] == "KB5128928");
        Assert.Equal("Important", net["msrc_severity"]);
        Assert.Equal("CanRequestReboot", net["reboot_behavior"]);
        Assert.Equal(true, net["needs_reboot"]);
        var defender = Pending(d).Single(u => (string?)u["kb"] == "KB2267602");
        Assert.Equal("unrated", defender["msrc_severity"]);           // empty in Windows' answer → a named state
        Assert.Equal("NeverReboots", defender["reboot_behavior"]);
    }

    [Fact]
    public void UpdatesWithoutCveIdsAreCountedWithTheReason()
    {
        var gap = (Dictionary<string, object?>)WindowsUpdateFacts.Interpret(Recorded())["cve_gap"]!;
        Assert.Equal(4, gap["updates_without_cve_ids"]);
        Assert.Contains("no CveIDs", (string)gap["why"]!);
    }

    [Fact]
    public void TheHistoryNamesResultsAndKbs()
    {
        var hist = (List<Dictionary<string, object?>>)WindowsUpdateFacts.Interpret(Recorded())["history"]!;
        Assert.Equal(50, hist.Count);
        Assert.All(hist, h => Assert.DoesNotContain("unknown", (string)h["result"]!));
        Assert.Equal("KB2267602", hist[0]["kb"]);
        Assert.Equal("Installation", hist[0]["operation"]);
    }

    [Fact]
    public void AWsusAssignedByPolicyIsNamed()
    {
        var raw = JsonDocument.Parse("""{"search_result":2,"pending":[],"history":[],"wsus_server":"http://wsus.example:8530","use_wsus":1}""").RootElement;
        var d = WindowsUpdateFacts.Interpret(raw);
        Assert.Equal("wsus", d["server"]);
        Assert.Equal("http://wsus.example:8530", d["wsus_server"]);
        Assert.Null(d["cve_gap"]);
    }

    [Theory]
    [InlineData("2026-10 Kumulatives Update für … (KB5066782)", "KB5066782")]
    [InlineData("Security Intelligence-Update – KB2267602 (Version 1.461.59.0)", "KB2267602")]
    [InlineData("Some driver update", null)]
    public void TheKbIsReadFromTheTitle(string title, string? kb) => Assert.Equal(kb, WindowsUpdateFacts.KbOf(title));

    [Fact]
    public void ASearchThatDidNotSucceedIsNotACompleteList()
    {
        var after = JsonDocument.Parse("""{"search_result":3,"pending":[],"history":[]}""").RootElement;   // +19 s after a reboot
        var d = WindowsUpdateFacts.Interpret(after);
        Assert.Equal("SucceededWithErrors", d["search_result"]);
        Assert.Equal(false, d["complete"]);
        Assert.Contains("may be incomplete", (string)d["incomplete_reason"]!);
        Assert.Equal(true, WindowsUpdateFacts.Interpret(Recorded())["complete"]);
    }
}
