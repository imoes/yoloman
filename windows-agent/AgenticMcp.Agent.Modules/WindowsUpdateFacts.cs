using System.Globalization;
using System.Text.Json;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// What the Windows Update Agent says about a host, turned into data — the PURE half of <c>windows_update_facts</c>
/// (plan B13). The Windows module asks the COM API (Microsoft.Update.Session) through PowerShell and hands the raw
/// answer here, so the interpretation is tested on Linux with a recorded answer.
///
/// <para>Windows' own words are kept: OperationResultCode (NotStarted … Aborted), RebootBehavior (NeverReboots,
/// AlwaysRequiresReboot, CanRequestReboot), MsrcSeverity (Critical, Important, Moderate, Low) — never mapped onto
/// another vendor's scale. A missing value is a named state ("unrated"), not an empty string.</para>
///
/// <para>CVE IDS ARE USUALLY ABSENT, and that is measured, not assumed: on bossman-wintest (Server 2022, Microsoft
/// Update, 2026-10-17) none of four pending updates — a .NET security update with MsrcSeverity "Important" among
/// them — carried a CveID. So every update without one is counted in <c>cve_gap</c> with that reason; Bossman maps
/// KB → CVE from Microsoft's published security data instead (services/cve_correlate.py).</para>
/// </summary>
public static class WindowsUpdateFacts
{
    public static readonly IReadOnlyDictionary<long, string> ResultCodes = new Dictionary<long, string>
    {
        [0] = "NotStarted", [1] = "InProgress", [2] = "Succeeded", [3] = "SucceededWithErrors", [4] = "Failed", [5] = "Aborted",
    };

    public static readonly IReadOnlyDictionary<long, string> RebootBehaviors = new Dictionary<long, string>
    {
        [0] = "NeverReboots", [1] = "AlwaysRequiresReboot", [2] = "CanRequestReboot",
    };

    private static string Word(IReadOnlyDictionary<long, string> words, long? code) =>
        code is { } c && words.TryGetValue(c, out var w) ? w : $"unknown ({code?.ToString(CultureInfo.InvariantCulture) ?? "none"})";

    private static string? Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            && v.GetString() is { Length: > 0 } s ? s : null;

    private static long? Num(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
            && v.TryGetInt64(out var n) ? n : null;

    private static bool Flag(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static List<string> List(JsonElement e, string name)
    {
        if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return [];
        return v.ValueKind switch
        {
            JsonValueKind.Array => v.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() ?? "" : x.ToString())
                .Where(x => x.Length > 0).ToList(),
            JsonValueKind.String when v.GetString() is { Length: > 0 } s => [s],
            JsonValueKind.Number => [v.ToString()],
            _ => [],
        };
    }

    private static IEnumerable<JsonElement> Items(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v)
            ? v.ValueKind == JsonValueKind.Array ? v.EnumerateArray() : v.ValueKind == JsonValueKind.Object ? [v] : []
            : [];

    /// <summary>The module's <c>data</c>, from the raw answer of the collection script.</summary>
    public static Dictionary<string, object?> Interpret(JsonElement raw)
    {
        var pending = new List<Dictionary<string, object?>>();
        var withoutCve = 0;
        foreach (var u in Items(raw, "pending"))
        {
            var kbs = List(u, "kb").Select(k => k.StartsWith("KB", StringComparison.OrdinalIgnoreCase) ? k.ToUpperInvariant() : "KB" + k).ToList();
            var cves = List(u, "cve");
            if (cves.Count == 0) withoutCve++;
            var reboot = Num(u, "reboot_behavior");
            pending.Add(new Dictionary<string, object?>
            {
                ["kb"] = kbs.FirstOrDefault(), ["kb_ids"] = kbs, ["title"] = Str(u, "title") ?? "",
                ["update_id"] = Str(u, "update_id"), ["revision"] = Num(u, "revision"),
                ["categories"] = List(u, "categories"),
                ["msrc_severity"] = Str(u, "severity") ?? "unrated",
                ["cve_ids"] = cves,
                ["reboot_behavior"] = Word(RebootBehaviors, reboot),
                ["needs_reboot"] = reboot is 1 or 2,
                ["downloaded"] = Flag(u, "downloaded"),
                ["size_bytes"] = Num(u, "max_size"),
                ["uninstallable"] = Flag(u, "can_uninstall"),
                ["published"] = Str(u, "published"),
            });
        }
        var history = Items(raw, "history").Select(h => new Dictionary<string, object?>
        {
            ["date"] = Str(h, "date"),
            ["operation"] = Num(h, "operation") switch { 1 => "Installation", 2 => "Uninstallation", var o => $"unknown ({o})" },
            ["result"] = Word(ResultCodes, Num(h, "result_code")),
            ["hresult"] = WindowsUpdateRun.Named(Num(h, "hresult")),
            ["title"] = Str(h, "title") ?? "",
            ["kb"] = KbOf(Str(h, "title")),
            ["update_id"] = Str(h, "update_id"),
        }).ToList();

        var wsus = Str(raw, "wsus_server");
        var useWsus = Num(raw, "use_wsus") == 1 && wsus is not null;
        var reasons = new List<string>();
        if (Flag(raw, "reboot_cbs")) reasons.Add("Component-Based Servicing is waiting for a reboot");
        if (Flag(raw, "reboot_wu")) reasons.Add("Windows Update has staged work for the next boot");

        var search = Word(ResultCodes, Num(raw, "search_result"));
        return new Dictionary<string, object?>
        {
            ["search_result"] = search,
            // ONLY "Succeeded" IS A COMPLETE LIST. Measured on bossman-wintest 19 s after a reboot: SucceededWithErrors with 0
            // pending — three minutes later Succeeded with 2. Read as complete, the security view showed the host clean.
            ["complete"] = search == "Succeeded",
            ["incomplete_reason"] = search == "Succeeded" ? null
                : $"the search ended {search}, so the list of pending updates may be incomplete (right after a reboot Windows "
                  + "Update answers SucceededWithErrors with an empty list for a few minutes)",
            ["server"] = useWsus ? "wsus" : "windows_update",
            ["wsus_server"] = useWsus ? wsus : null,
            ["pending"] = pending,
            ["pending_count"] = pending.Count,
            ["cve_gap"] = withoutCve == 0 ? null : new Dictionary<string, object?>
            {
                ["updates_without_cve_ids"] = withoutCve,
                ["why"] = "the Windows Update Agent supplied no CveIDs for these updates (measured: Microsoft Update leaves them "
                          + "empty for cumulative updates); the KB → CVE mapping has to come from Microsoft's published security data",
            },
            ["history"] = history,
            ["last_search_success"] = Str(raw, "last_search"),
            ["last_installation_success"] = Str(raw, "last_install"),
            ["reboot_required"] = reasons.Count > 0,
            ["reboot_reasons"] = reasons,
        };
    }

    /// <summary>The KB number in an update title ("… (KB5066782)"), or null.</summary>
    public static string? KbOf(string? title)
    {
        if (title is null) return null;
        var m = System.Text.RegularExpressions.Regex.Match(title, @"\bKB(\d{6,8})\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return m.Success ? "KB" + m.Groups[1].Value : null;
    }
}
