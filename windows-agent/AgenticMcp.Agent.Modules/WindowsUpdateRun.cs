using System.Text.Json;

namespace AgenticMcp.Agent.Modules;

/// <summary>
/// What a <c>windows_update</c> run did, in Windows' own words, and whether it is TRUE afterwards — the pure half of
/// the install step (plan B13 step 3).
///
/// <para>Two different facts per update, kept apart: what the installer RETURNED (OperationResultCode + HRESULT per
/// update) and what a fresh read SHOWS (the update's id in the history as Succeeded, and no longer pending). Only the
/// second makes an update <c>verified</c>; "the API said Succeeded" alone is not the end state. A needed reboot is the
/// named outcome <c>reboot_required</c> — not success, not failure.</para>
/// </summary>
public static class WindowsUpdateRun
{
    private static string? S(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static long? N(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var x) ? x : null;

    private static bool B(JsonElement e, string n) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Word(long? code) =>
        code is { } c && WindowsUpdateFacts.ResultCodes.TryGetValue(c, out var w) ? w : code is null ? "not run" : $"unknown ({code})";

    private static string? Hex(long? hr) => hr is { } h && h != 0 ? $"0x{unchecked((uint)h):X8}" : null;

    /// <summary>
    /// Windows' own names for the HRESULTs an update run commonly ends with (wuerror.h / winerror.h), so a failure
    /// reads as a reason. First met on bossman-wintest: 0x8024200D on a cumulative update while a reboot was pending.
    /// A code not listed stays its number — never a guessed meaning.
    /// </summary>
    public static readonly IReadOnlyDictionary<uint, string> HResultNames = new Dictionary<uint, string>
    {
        [0x8024200D] = "WU_E_UH_NEEDANOTHERDOWNLOAD: the update has to be downloaded again",
        [0x80240017] = "WU_E_NOT_APPLICABLE: the update does not apply to this computer",
        [0x80240016] = "WU_E_INSTALL_NOT_ALLOWED: another installation is in progress or a reboot is pending",
        [0x80240022] = "WU_E_ALL_UPDATES_FAILED: every update in the operation failed",
        [0x8024001E] = "WU_E_SERVICE_STOP: the Windows Update service or the system was shutting down",
        [0x80070BC2] = "ERROR_FAIL_REBOOT_REQUIRED: a reboot is required before it can be installed",
        [0x80070BC9] = "ERROR_FAIL_REBOOT_INITIATED: a reboot was started while it was installing",
        [0x800F0922] = "CBS_E_INSTALLERS_FAILED: the servicing stack's installers failed",
        [0x8024402C] = "WU_E_PT_WINHTTP_NAME_NOT_RESOLVED: the update server's name did not resolve",
        [0x80244022] = "WU_E_PT_HTTP_STATUS_SERVICE_UNAVAIL: the update server answered 503",
        [0x80072EE2] = "ERROR_INTERNET_TIMEOUT: the download timed out",
    };

    /// <summary>An HRESULT as "0x8024200D (WU_E_… : …)" when the code is known, else just the hex, else null. Public so
    /// windows_update_facts names the history's HRESULTs the same way.</summary>
    public static string? Named(long? hr) =>
        Hex(hr) is { } hex ? (HResultNames.TryGetValue(unchecked((uint)hr!.Value), out var n) ? $"{hex} ({n})" : hex) : null;

    /// <summary>
    /// <paramref name="install"/>: the install script's answer. <paramref name="after"/>: windows_update_facts' data read
    /// AFTER the run. <paramref name="wantInstalled"/>: false for state=downloaded (then only the download is judged).
    /// </summary>
    public static Dictionary<string, object?> Interpret(JsonElement install, IReadOnlyDictionary<string, object?> after, bool wantInstalled)
    {
        var history = after.TryGetValue("history", out var h) && h is IEnumerable<Dictionary<string, object?>> hs ? hs.ToList() : [];
        var pending = after.TryGetValue("pending", out var p) && p is IEnumerable<Dictionary<string, object?>> ps ? ps.ToList() : [];
        var results = new List<Dictionary<string, object?>>();
        var reboot = false;
        if (install.ValueKind == JsonValueKind.Object && install.TryGetProperty("updates", out var ups))
        {
            IEnumerable<JsonElement> list = ups.ValueKind switch
            {
                JsonValueKind.Array => ups.EnumerateArray().ToList(),
                JsonValueKind.Object => [ups],   // ConvertTo-Json writes a one-element array as the element itself
                _ => [],
            };
            foreach (var u in list)
            {
                var id = S(u, "update_id");
                var installWord = Word(N(u, "install_code"));
                var needsReboot = B(u, "reboot_required");
                reboot |= needsReboot;
                var stillPending = pending.Any(x => Equals(x.GetValueOrDefault("update_id"), id));
                var inHistory = history.FirstOrDefault(x => Equals(x.GetValueOrDefault("update_id"), id));
                string state;
                string? why = null;
                if (!wantInstalled)
                {
                    var dl = Word(N(u, "download_code"));
                    state = dl is "Succeeded" or "SucceededWithErrors" ? "downloaded" : "failed";
                    if (state == "failed") why = $"the download ended {dl}{(Named(N(u, "download_hresult")) is { } dh ? " " + dh : "")}";
                }
                else if (installWord is "Succeeded" or "SucceededWithErrors" && needsReboot)
                {
                    state = "reboot_required";
                    why = "installed; Windows finishes it at the next boot";
                }
                else if (installWord is "Succeeded" or "SucceededWithErrors" && !stillPending && inHistory?.GetValueOrDefault("result") is "Succeeded" or "SucceededWithErrors")
                {
                    state = "installed";
                }
                else if (installWord is "Succeeded" or "SucceededWithErrors")
                {
                    state = "unverified";
                    why = stillPending ? "the installer said Succeeded, but a new search still lists the update as pending"
                                       : "the installer said Succeeded, but the update history has no Succeeded entry for it";
                }
                else
                {
                    state = "failed";
                    var dl = Word(N(u, "download_code"));
                    why = installWord == "not run"
                        ? $"not installed: the download ended {dl}{(Named(N(u, "download_hresult")) is { } dh ? " " + dh : "")}"
                        : $"the installer ended {installWord}{(Named(N(u, "install_hresult")) is { } ih ? " " + ih : "")}";
                }
                results.Add(new Dictionary<string, object?>
                {
                    ["update_id"] = id, ["kb"] = S(u, "kb"), ["title"] = S(u, "title") ?? "",
                    ["download_result"] = Word(N(u, "download_code")), ["install_result"] = installWord,
                    ["hresult"] = Hex(N(u, "install_hresult")) ?? Hex(N(u, "download_hresult")),
                    ["reboot_required"] = needsReboot, ["state"] = state, ["why"] = why,
                    ["verified"] = state is "installed" or "downloaded",
                });
            }
        }
        return new Dictionary<string, object?>
        {
            ["results"] = results,
            ["reboot_required"] = reboot,
            ["installed"] = results.Count(r => (string?)r["state"] == "installed"),
            ["failed"] = results.Count(r => (string?)r["state"] is "failed" or "unverified"),
        };
    }
}
