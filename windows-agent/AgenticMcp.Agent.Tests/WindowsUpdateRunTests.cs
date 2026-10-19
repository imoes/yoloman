using System.Text.Json;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Tests;

/// <summary>windows_update's selection (over the recorded bossman-wintest answer) and its result verification.</summary>
public class WindowsUpdateRunTests
{
    private static List<IReadOnlyDictionary<string, object?>> Recorded()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "windows_update", "wintest-2026-10-17.json");
        var d = WindowsUpdateFacts.Interpret(JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone());
        return ((List<Dictionary<string, object?>>)d["pending"]!).Cast<IReadOnlyDictionary<string, object?>>().ToList();
    }

    [Fact]
    public void TheDefaultCategoriesTakeSecurityAndRollupsButNotDefinitions()
    {
        var (sel, skip) = WindowsUpdateSelection.Select(Recorded(), null, null, null);
        Assert.Equal(["KB890830", "KB5128928", "KB5122882"], sel.Select(c => c.Kb));
        var defender = Assert.Single(skip);
        Assert.Equal("KB2267602", defender.Kb);
        Assert.Contains("not among category_names", defender.Reason);
    }

    [Fact]
    public void AnAcceptListWorksWithinTheCategoriesAsInAnsible()
    {
        var (none, _) = WindowsUpdateSelection.Select(Recorded(), null, ["KB2267602"], null);
        Assert.Empty(none);                                            // definitions are not a default category
        var (sel, skip) = WindowsUpdateSelection.Select(Recorded(), ["DefinitionUpdates"], ["2267602"], null);
        Assert.Equal("KB2267602", Assert.Single(sel).Kb);
        Assert.Equal(3, skip.Count);
        Assert.All(skip, s => Assert.NotNull(s.Reason));               // every update is in exactly one list, with a reason
    }

    [Fact]
    public void TheRejectListWinsAndATitlePatternMatches()
    {
        var (sel, skip) = WindowsUpdateSelection.Select(Recorded(), ["*"], null, ["Kumulatives Update"]);
        Assert.Equal(["KB890830", "KB2267602"], sel.Select(c => c.Kb));
        Assert.All(skip, s => Assert.StartsWith("on the reject_list", s.Reason));
    }

    private static JsonElement Install(string json) => JsonDocument.Parse(json).RootElement.Clone();

    private static Dictionary<string, object?> After(bool stillPending, string? historyResult) => new()
    {
        ["pending"] = stillPending ? new List<Dictionary<string, object?>> { new() { ["update_id"] = "u1" } } : new List<Dictionary<string, object?>>(),
        ["history"] = historyResult is null ? new List<Dictionary<string, object?>>()
            : new List<Dictionary<string, object?>> { new() { ["update_id"] = "u1", ["result"] = historyResult } },
    };

    private const string Ok = """{"found":1,"updates":[{"update_id":"u1","kb":"KB2267602","title":"defs","download_code":2,"download_hresult":0,"install_code":2,"install_hresult":0,"reboot_required":false}]}""";

    [Fact]
    public void InstalledOnlyWhenANewReadConfirmsIt()
    {
        Assert.Equal("installed", State(WindowsUpdateRun.Interpret(Install(Ok), After(false, "Succeeded"), true)));
        var stale = WindowsUpdateRun.Interpret(Install(Ok), After(true, "Succeeded"), true);
        Assert.Equal("unverified", State(stale));
        Assert.Contains("still lists", Why(stale));
        Assert.Equal("unverified", State(WindowsUpdateRun.Interpret(Install(Ok), After(false, null), true)));
    }

    [Fact]
    public void ANeededRebootIsItsOwnOutcome()
    {
        var r = WindowsUpdateRun.Interpret(Install(Ok.Replace("\"reboot_required\":false", "\"reboot_required\":true")), After(false, "Succeeded"), true);
        Assert.Equal("reboot_required", State(r));
        Assert.Equal(true, r["reboot_required"]);
    }

    [Fact]
    public void AFailureCarriesWindowsResultAndHresult()
    {
        var failed = Ok.Replace("\"install_code\":2,\"install_hresult\":0", "\"install_code\":4,\"install_hresult\":-2145124329");
        var r = WindowsUpdateRun.Interpret(Install(failed), After(true, "Failed"), true);
        Assert.Equal("failed", State(r));
        Assert.Contains("Failed 0x80240017 (WU_E_NOT_APPLICABLE", Why(r));
        var notDownloaded = Ok.Replace("\"download_code\":2", "\"download_code\":5").Replace("\"install_code\":2,\"install_hresult\":0", "\"install_code\":null,\"install_hresult\":null");
        Assert.Contains("the download ended Aborted", Why(WindowsUpdateRun.Interpret(Install(notDownloaded), After(true, null), true)));
    }

    private static List<Dictionary<string, object?>> Results(Dictionary<string, object?> r) => (List<Dictionary<string, object?>>)r["results"]!;
    private static string? State(Dictionary<string, object?> r) => (string?)Results(r)[0]["state"];
    private static string Why(Dictionary<string, object?> r) => (string?)Results(r)[0]["why"] ?? "";

    [Fact]
    public void TheCodeMetOnTheRealHostIsNamed()
    {
        // bossman-wintest, 2026-10-17: KB5122882 while the .NET update's reboot was pending
        var r = WindowsUpdateRun.Interpret(Install(Ok.Replace("\"install_code\":2,\"install_hresult\":0", "\"install_code\":4,\"install_hresult\":-2145116147")), After(true, null), true);
        Assert.Contains("0x8024200D (WU_E_UH_NEEDANOTHERDOWNLOAD", Why(r));
    }

    // --- state=removed: the rollback through DISM ---

    private static List<Dictionary<string, object?>> Removed(string kbsJson) =>
        (List<Dictionary<string, object?>>)WindowsUpdateRemoval.Interpret(JsonDocument.Parse("{\"kbs\":" + kbsJson + "}").RootElement.Clone())["results"]!;

    [Fact]
    public void DismOutcomesAreDecidedByAFreshReadOfThePackage()
    {
        const string roll = "Package_for_RollupFix~31bf3856ad364e35~amd64~~20348.5761.1.34";
        var r = Removed($$"""
            [
              {"kb":"KB5126655","package":"{{roll}}","state_before":"Installed","exit_code":3010,"state_after":"Uninstall Pending"},
              {"kb":"KB5015446","package":"Package_for_KB5015446~x","state_before":"Installed","exit_code":0,"state_after":null},
              {"kb":"KB5122882","package":"Package_for_RollupFix~old","state_before":"Superseded"},
              {"kb":"KB5000001","package":"Package_for_KB5000001~x","state_before":"Installed","exit_code":0,"state_after":"Installed"},
              {"kb":"KB5000002","package":null,"hotfix":false},
              {"kb":"KB5000003","package":null,"hotfix":true},
              {"kb":"KB5000004","package":"Package_for_KB5000004~x","state_before":"Installed","exit_code":-2146498523,"state_after":"Installed"},
              {"kb":"KB5000005","package":"Package_for_KB5000005~x","state_before":"Installed","dry_run":true},
              {"kb":"KB5128928","package":"Package_for_DotNetRollup~x","via":"KB5127687","state_before":"Installed","dry_run":true},
              {"kb":"KB5000006","package":null,"hotfix":false,"wua_installed":true}
            ]
            """);
        Assert.Equal(["reboot_required", "removed", "refused", "unverified", "not_installed", "refused", "failed", "would_remove",
                      "would_remove", "refused"],
            r.Select(x => (string?)x["state"]));
        Assert.Contains("Superseded", (string)r[2]["why"]!);
        Assert.Contains("CBS_E_CANNOT_UNINSTALL", (string)r[6]["why"]!);
        Assert.Contains("/packagename:Package_for_KB5000005", (string)r[7]["why"]!);
        Assert.Contains("bundled KB5127687", (string)r[8]["why"]!);              // the .NET rollup, measured
        Assert.Contains("Windows Update lists it as installed", (string)r[9]["why"]!);
    }
}
