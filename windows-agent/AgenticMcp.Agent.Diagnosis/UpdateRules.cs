using System.Globalization;
using System.Text.Json.Nodes;

namespace AgenticMcp.Agent.Diagnosis;

/// <summary>
/// The rules of "why is this host behind on updates / why did an update fail" (configs/diagnosis_rules.json, the
/// `upd.` rules) over an <see cref="UpdateSnapshot"/>. A pure function, like the service rules — tested on recorded
/// snapshots on the Linux dev host. On Windows the `update_diagnose` module fills the snapshot from the read-only
/// windows_update_facts output (<see cref="FromFacts"/>); no new measurement, and nothing is changed.
/// </summary>
public static class UpdateRules
{
    private static bool Eq(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    // --- Mapping windows_update_facts' interpreted output to a snapshot (no Win32, so it is tested on Linux) --------

    private static string Str(IReadOnlyDictionary<string, object?> d, string k) => d.TryGetValue(k, out var v) ? v?.ToString() ?? "" : "";
    private static bool Bool(IReadOnlyDictionary<string, object?> d, string k) => d.TryGetValue(k, out var v) && v is bool b && b;
    private static IEnumerable<IReadOnlyDictionary<string, object?>> Rows(IReadOnlyDictionary<string, object?> d, string k) =>
        d.TryGetValue(k, out var v) && v is IEnumerable<object?> e ? e.OfType<IReadOnlyDictionary<string, object?>>() : [];
    private static DateTime? Date(string? s) =>
        DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t) ? t : null;

    /// <summary>Build a snapshot from the windows_update_facts interpreted data (the module hands this straight through).</summary>
    public static UpdateSnapshot FromFacts(IReadOnlyDictionary<string, object?> facts, string host, DateTime collectedAt)
    {
        var reasons = facts.TryGetValue("reboot_reasons", out var rr) && rr is IEnumerable<object?> re
            ? re.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToList() : [];
        return new UpdateSnapshot
        {
            Host = host, Platform = "windows",
            SearchResult = Str(facts, "search_result"),
            SearchComplete = Bool(facts, "complete"),
            IncompleteReason = facts.TryGetValue("incomplete_reason", out var ir) ? ir?.ToString() : null,
            Server = Str(facts, "server") is { Length: > 0 } sv ? sv : "windows_update",
            WsusServer = facts.TryGetValue("wsus_server", out var ws) ? ws?.ToString() : null,
            RebootRequired = Bool(facts, "reboot_required"),
            RebootReasons = reasons,
            LastSearchSuccess = Date(facts.TryGetValue("last_search_success", out var ls) ? ls?.ToString() : null),
            CollectedAt = collectedAt,
            Pending = Rows(facts, "pending").Select(p => new PendingUpdate
            {
                Kb = p.TryGetValue("kb", out var kb) ? kb?.ToString() : null,
                Title = Str(p, "title"),
                MsrcSeverity = Str(p, "msrc_severity") is { Length: > 0 } ms ? ms : "unrated",
                NeedsReboot = Bool(p, "needs_reboot"),
            }).ToList(),
            History = Rows(facts, "history").Select(h => new UpdateHistoryEntry
            {
                Date = Date(Str(h, "date")),
                Operation = Str(h, "operation"),
                Result = Str(h, "result"),
                Hresult = h.TryGetValue("hresult", out var hv) ? hv?.ToString() : null,
                Kb = h.TryGetValue("kb", out var kb) ? kb?.ToString() : null,
                Title = Str(h, "title"),
            }).ToList(),
        };
    }

    private static bool IsSecurity(string sev) => Eq(sev, "Critical") || Eq(sev, "Important");

    public static DiagnosisDocument Diagnose(UpdateSnapshot s, string id, string host)
    {
        var b = new Builder(id, host, s.Platform, new Target { Kind = "updates", Name = s.Host }, s.CollectedAt);

        var critical = s.Pending.Count(p => Eq(p.MsrcSeverity, "Critical"));
        var important = s.Pending.Count(p => Eq(p.MsrcSeverity, "Important"));
        var security = critical + important;

        var searchFact = s.SearchComplete
            ? $"The last update search succeeded; {s.Pending.Count} update(s) pending"
              + (security > 0 ? $", {security} of them Critical/Important." : ".")
            : $"The last update search ended {s.SearchResult}, so the list of pending updates may be incomplete.";
        var searchId = b.Evidence(new Evidence
        {
            Id = $"wu:search:{Builder.Key(s.Host)}", Source = "windows_update_facts", Observed = s.LastSearchSuccess,
            Fact = searchFact,
            Raw = new JsonObject { ["search_result"] = s.SearchResult, ["complete"] = s.SearchComplete, ["pending_count"] = s.Pending.Count, ["server"] = s.Server },
        });

        var findings = 0;

        // The most decisive thing: the last operation failed (newest Failed/Aborted history entry).
        var failed = s.History.FirstOrDefault(h => Eq(h.Result, "Failed") || Eq(h.Result, "Aborted"));
        if (failed is not null)
        {
            var what = failed.Kb ?? (failed.Title.Length > 0 ? failed.Title : "an update");
            var hres = failed.Hresult is null ? "" : $" with HRESULT {failed.Hresult}";
            var hid = b.Evidence(new Evidence
            {
                Id = $"wu:history:{(failed.Date?.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") ?? "unknown")}",
                Source = "windows_update_facts", Observed = failed.Date,
                Fact = $"The most recent update operation ({failed.Operation} of {what}) ended {failed.Result}{hres}.",
                Raw = new JsonObject { ["operation"] = failed.Operation, ["result"] = failed.Result, ["hresult"] = failed.Hresult, ["kb"] = failed.Kb },
            });
            if (b.Find(new Finding
            {
                RuleId = "upd.install_failed", Certainty = Certainty.Proven, EvidenceIds = [hid, searchId],
                Claim = $"The last update {(Eq(failed.Result, "Aborted") ? "operation was aborted" : "installation failed")} on {s.Host}{hres}.",
            }) is null) findings++;
        }

        // A WSUS that did not answer explains an incomplete search (Likely — the server could be up and the search
        // failed for another reason).
        if (Eq(s.Server, "wsus") && !s.SearchComplete)
            if (b.Find(new Finding
            {
                RuleId = "upd.wsus_unreachable", Certainty = Certainty.Likely, EvidenceIds = [searchId],
                Claim = $"The assigned WSUS server ({s.WsusServer}) did not answer: the search ended {s.SearchResult}.",
            }) is null) findings++;

        // A pending reboot blocks further installs.
        if (s.RebootRequired)
        {
            var rid = b.Evidence(new Evidence
            {
                Id = $"wu:reboot:{Builder.Key(s.Host)}", Source = "windows_update_facts", Observed = null,
                Fact = $"A reboot is pending ({string.Join(", ", s.RebootReasons)}), which blocks further installations.",
                Raw = new JsonObject { ["reboot_reasons"] = new JsonArray(s.RebootReasons.Select(r => (JsonNode)r!).ToArray()) },
            });
            if (b.Find(new Finding
            {
                RuleId = "upd.reboot_pending", Certainty = Certainty.Proven, EvidenceIds = [rid],
                Claim = $"A reboot is pending on {s.Host}, which blocks further update installations until it is restarted.",
            }) is null) findings++;
        }

        // The state: behind (pending) or up-to-date (clean).
        if (s.Pending.Count > 0)
        {
            var pid = b.Evidence(new Evidence
            {
                Id = $"wu:pending:{Builder.Key(s.Host)}", Source = "windows_update_facts", Observed = null,
                Fact = $"{s.Pending.Count} update(s) pending" + (security > 0 ? $": {critical} Critical, {important} Important." : "."),
                Raw = new JsonObject { ["pending_count"] = s.Pending.Count, ["critical"] = critical, ["important"] = important },
            });
            if (b.Find(new Finding
            {
                RuleId = "upd.behind", Certainty = Certainty.Proven, EvidenceIds = [pid, searchId],
                Claim = $"{s.Host} is behind on updates: {s.Pending.Count} pending" + (security > 0 ? $", {security} of them Critical/Important." : "."),
            }) is null) findings++;
            // No reversible remedy on Windows: there is no guest snapshot of the system volume like LVM/ZFS, and a KB
            // uninstall only reverses updates that are uninstallable (a combined SSU+LCU usually is not), so it is not a
            // complete rollback. Rather than offer a partial/fake rollback, the way back is named as a gap.
            b.Gap("a complete rollback for the update",
                "Windows has no guest snapshot of the system volume (unlike LVM/ZFS on Linux) and a KB uninstall reverses "
                + "only uninstallable updates — install via a patch ring or windows_update; for a real rollback take a "
                + "hypervisor/VM snapshot of the host first");
        }
        else if (s.SearchComplete && failed is null && !s.RebootRequired)
        {
            if (b.Find(new Finding
            {
                RuleId = "upd.up_to_date", Certainty = Certainty.Proven, EvidenceIds = [searchId],
                Claim = $"{s.Host} has no pending updates; the last search succeeded.",
            }) is null) findings++;
        }

        var clean = s.Pending.Count == 0 && s.SearchComplete && failed is null && !s.RebootRequired;
        var status = clean ? Status.UpToDate : Status.Behind;

        // Behind with nothing to say (e.g. an incomplete search against Windows Update, not WSUS): name the gap and
        // record it as Unknown rather than leave the state unexplained.
        if (!clean && findings == 0)
            b.Find(new Finding
            {
                RuleId = "upd.unexplained", Certainty = Certainty.Unknown, EvidenceIds = [searchId],
                Gap = s.IncompleteReason ?? $"the update state is {status} but no rule matched what windows_update_facts returned",
                Claim = $"The update state of {s.Host} could not be explained from what was read.",
            });

        if (!s.SearchComplete && !Eq(s.Server, "wsus"))
            b.Gap("the complete list of pending updates", s.IncompleteReason ?? $"the search ended {s.SearchResult}");

        return b.Build(status);
    }
}
