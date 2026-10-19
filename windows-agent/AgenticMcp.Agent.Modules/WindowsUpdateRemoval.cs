using System.Text.Json;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// The rollback of an installed update — <c>windows_update</c> with state=removed (plan B13, "Rückweg"). The pure half:
/// DISM's answer in Windows' own words, and the verification by a fresh read of the package's state.
///
/// <para>THROUGH DISM, NOT wusa. The first version used <c>wusa /uninstall /quiet</c>; on bossman-wintest it exited 87
/// for a cumulative update — and Microsoft documents that quiet wusa uninstalls are deprecated on Server 2016 and later
/// and that a combined servicing stack + cumulative update can only be removed with DISM by its package name. The
/// collection script maps a KB to its CBS package (<c>Package_for_KB…</c>, or a <c>Package_for_RollupFix</c> /
/// <c>DotNetRollup</c> whose description reads "Fix for KB…", measured) and removes that.</para>
///
/// <para>Refused with the reason, not tried: a package that is Superseded (a later cumulative update replaced it —
/// removing it changes nothing; the newer one is what to remove), and a KB Get-HotFix knows but DISM has no package
/// for. DISM's exit codes: 0 removed, 3010 removed at the next boot (<c>reboot_required</c>), 0x800F0825 the package
/// is permanent, 0x800F080C no such package. A removal counts only when a fresh read shows the package gone, staged
/// or "Uninstall Pending" (then reboot_required).</para>
/// </summary>
public static class WindowsUpdateRemoval
{
    public static readonly IReadOnlyDictionary<long, string> DismExitCodes = new Dictionary<long, string>
    {
        [0] = "removed",
        [3010] = "removed; Windows finishes it at the next boot (ERROR_SUCCESS_REBOOT_REQUIRED)",
        [unchecked((int)0x800F0825)] = "CBS_E_CANNOT_UNINSTALL: the package is permanent and cannot be removed",
        [unchecked((int)0x800F080C)] = "CBS_E_UNKNOWN_UPDATE: DISM does not know this package",
        [87] = "DISM rejected the arguments (ERROR_INVALID_PARAMETER)",
        [5] = "access denied (ERROR_ACCESS_DENIED)",
        [1618] = "another installation is in progress (ERROR_INSTALL_ALREADY_RUNNING)",
    };

    private static string? S(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s ? s : null;

    private static long? N(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var x) ? x : null;

    private static bool B(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Code(long code) =>
        DismExitCodes.TryGetValue(code, out var w) ? w : DismExitCodes.TryGetValue(unchecked((int)code), out var w2) ? w2
            : $"0x{unchecked((uint)code):X8}";

    /// <summary>
    /// <paramref name="answer"/>: per KB {kb, package, state_before, hotfix, exit_code, state_after, dry_run}.
    /// state_* are DISM's package states ("Installed", "Superseded", "Uninstall Pending", "Staged", or absent).
    /// </summary>
    public static Dictionary<string, object?> Interpret(JsonElement answer)
    {
        var results = new List<Dictionary<string, object?>>();
        IEnumerable<JsonElement> items = answer.ValueKind == JsonValueKind.Object && answer.TryGetProperty("kbs", out var k)
            ? k.ValueKind == JsonValueKind.Array ? k.EnumerateArray().ToList() : k.ValueKind == JsonValueKind.Object ? [k] : []
            : [];
        foreach (var u in items)
        {
            var kb = S(u, "kb") ?? "?";
            var pkg = S(u, "package");
            var before = S(u, "state_before");
            var after = S(u, "state_after");
            var code = N(u, "exit_code");
            string state, why;
            if (pkg is null)
            {
                (state, why) = B(u, "hotfix") || B(u, "wua_installed")
                    ? ("refused", "Windows " + (B(u, "wua_installed") ? "Update" : "(Get-HotFix)") + " lists it as installed, but no DISM package "
                                  + "carries its number or that of an update it bundles — there is nothing DISM could remove by name")
                    : ("not_installed", "neither DISM nor Windows Update lists it as installed — there is nothing to remove");
            }
            else if (before == "Superseded")
            {
                state = "refused";
                why = $"{pkg} is Superseded: a later cumulative update replaced it, so removing it changes nothing — remove the newer one";
            }
            else if (before != "Installed")
            {
                state = "refused";
                why = $"{pkg} is {before ?? "in an unknown state"}, not Installed";
            }
            else if (B(u, "dry_run"))
            {
                state = "would_remove";
                why = $"dry run: dism /online /remove-package /packagename:{pkg} would run";
            }
            else if (code is 0 or 3010 && (after is null or "Staged" or "Uninstall Pending" or "Superseded"))
            {
                state = code == 3010 || after == "Uninstall Pending" ? "reboot_required" : "removed";
                why = Code(code.Value) + (after is null ? "; the package is gone" : $"; the package is now {after}");
            }
            else if (code is 0 or 3010)
            {
                state = "unverified";
                why = $"DISM exited {code}, but the package is still {after}";
            }
            else
            {
                state = "failed";
                why = code is null ? "DISM did not run" : $"DISM exited {code}: {Code(code.Value)}";
            }
            if (S(u, "via") is { } via && pkg is not null) why += $" (its package carries the bundled {via})";
            results.Add(new Dictionary<string, object?>
            {
                ["kb"] = kb, ["package"] = pkg, ["via"] = S(u, "via"), ["state"] = state, ["why"] = why, ["exit_code"] = code,
                ["package_state_before"] = before, ["package_state_after"] = after,
            });
        }
        return new Dictionary<string, object?>
        {
            ["results"] = results,
            ["reboot_required"] = results.Any(r => (string?)r["state"] == "reboot_required"),
        };
    }
}
