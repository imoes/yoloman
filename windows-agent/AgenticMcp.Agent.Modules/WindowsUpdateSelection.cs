using System.Text.RegularExpressions;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// Which pending updates a <c>windows_update</c> run takes, and why each other one is left — the PURE half of the
/// module (plan B13 step 3), tested on Linux over the answer recorded on bossman-wintest.
///
/// <para>The parameters mean what they mean in <c>ansible.windows.win_updates</c>, so a playbook and a Bossman call
/// select the same updates: <c>category_names</c> (default CriticalUpdates, SecurityUpdates, UpdateRollups — compared
/// without spaces or case, so "Security Updates" and "SecurityUpdates" are one name; "*" for all), <c>accept_list</c>
/// (only these, AND within the categories — as in Ansible: a definition update needs DefinitionUpdates as well),
/// <c>reject_list</c> (never these, wins over everything). Every pending update ends up in exactly one of
/// <c>selected</c> or <c>skipped</c>, and a skipped one carries its reason.</para>
/// </summary>
public static class WindowsUpdateSelection
{
    public static readonly IReadOnlyList<string> DefaultCategories = ["CriticalUpdates", "SecurityUpdates", "UpdateRollups"];

    public sealed record Choice(string? UpdateId, string? Kb, string Title, string? Reason);

    private static string Norm(string s) => Regex.Replace(s, @"\s+", "").ToLowerInvariant();

    /// <summary>A KB id ("KB5066782" / "5066782") matches the update's KBs; anything else is a regex on the title.</summary>
    public static bool Matches(string pattern, IReadOnlyList<string> kbs, string title)
    {
        var p = pattern.Trim();
        if (Regex.IsMatch(p, @"^(KB)?\d{6,8}$", RegexOptions.IgnoreCase))
        {
            var kb = p.StartsWith("KB", StringComparison.OrdinalIgnoreCase) ? p.ToUpperInvariant() : "KB" + p;
            return kbs.Any(k => string.Equals(k, kb, StringComparison.OrdinalIgnoreCase));
        }
        try { return Regex.IsMatch(title, p, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)); }
        catch (ArgumentException) { return title.Contains(p, StringComparison.OrdinalIgnoreCase); }
    }

    public static (List<Choice> Selected, List<Choice> Skipped) Select(
        IEnumerable<IReadOnlyDictionary<string, object?>> pending, IReadOnlyList<string>? categoryNames,
        IReadOnlyList<string>? acceptList, IReadOnlyList<string>? rejectList)
    {
        var cats = (categoryNames is { Count: > 0 } ? categoryNames : DefaultCategories).Select(Norm).ToHashSet();
        var all = cats.Contains("*") || cats.Contains("all");
        var selected = new List<Choice>();
        var skipped = new List<Choice>();
        foreach (var u in pending)
        {
            var kbs = u.TryGetValue("kb_ids", out var k) && k is IEnumerable<string> ks ? ks.ToList() : [];
            var title = u.TryGetValue("title", out var t) ? Convert.ToString(t) ?? "" : "";
            var id = u.TryGetValue("update_id", out var i) ? Convert.ToString(i) : null;
            var kb = kbs.FirstOrDefault();
            var ucats = u.TryGetValue("categories", out var c) && c is IEnumerable<string> cs ? cs.ToList() : [];
            string? why = null;
            if (rejectList?.FirstOrDefault(r => Matches(r, kbs, title)) is { } rej)
                why = $"on the reject_list ({rej})";
            else if (!all && !ucats.Any(x => cats.Contains(Norm(x))))
                why = $"its categories ({string.Join(", ", ucats)}) are not among category_names";
            else if (acceptList is { Count: > 0 } && !acceptList.Any(a => Matches(a, kbs, title)))
                why = "not on the accept_list";
            (why is null ? selected : skipped).Add(new Choice(id, kb, title, why));
        }
        return (selected, skipped);
    }
}
