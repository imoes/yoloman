using System.Text.Json;
using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_update</c> — search, download and install Windows updates (plan B13 step 3). WRITES, so it is behind
/// the write gate; <c>dry_run</c> returns the list that would be taken and loads nothing.
///
/// <para>Steps: (1) a search, read the same way as windows_update_facts; (2) the selection, with the parameters of
/// ansible.windows.win_updates (<see cref="WindowsUpdateSelection"/>); (3) download and — for state=installed —
/// install through the Windows Update Agent, as SYSTEM (the agent's service account; the installer refuses
/// non-local callers); (4) a NEW read: an update counts as installed only when the history shows it Succeeded and a
/// search no longer lists it (<see cref="WindowsUpdateRun"/>). A needed reboot is the outcome reboot_required; with
/// reboot=never (the default) the host is not restarted.</para>
/// </summary>
public sealed class WindowsUpdateModule : IModule
{
    public string Name => "windows_update";

    public string Description =>
        "Search, download and install Windows updates through the Windows Update Agent (the same selection as "
        + "ansible.windows.win_updates). Parameters: state searched|downloaded|installed (default installed), "
        + "category_names (default CriticalUpdates, SecurityUpdates, UpdateRollups; \"*\" for all; e.g. DefinitionUpdates), "
        + "accept_list / reject_list (KB ids or title patterns; accept_list applies within the categories), "
        + "reboot never|if_required (default never — a needed reboot is reported as reboot_required, the host is not "
        + "restarted), dry_run (the list that would be taken; nothing is downloaded). Each update's result is Windows' "
        + "own (Succeeded, SucceededWithErrors, Failed, Aborted + HRESULT), and an update is `installed` only when a new "
        + "read confirms it (history Succeeded, no longer pending); otherwise `unverified` with the reason.\n\n"
        + "Cross-tool equivalents:\n- Ansible: ansible.windows.win_updates.\n- Rollback: state=removed — DISM /Remove-Package by the KB's package (wusa /quiet is deprecated on Server 2016+).";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["state"] = new Dictionary<string, object> { ["type"] = "string", ["enum"] = new[] { "searched", "downloaded", "installed", "removed" }, ["default"] = "installed",
                ["description"] = "removed = uninstall the KBs named in accept_list with DISM (the rollback)." },
            ["category_names"] = new Dictionary<string, object> { ["type"] = "array", ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Default CriticalUpdates, SecurityUpdates, UpdateRollups; \"*\" for all." },
            ["accept_list"] = new Dictionary<string, object> { ["type"] = "array", ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Only these (KB ids or title patterns), within category_names." },
            ["reject_list"] = new Dictionary<string, object> { ["type"] = "array", ["items"] = new Dictionary<string, object> { ["type"] = "string" },
                ["description"] = "Never these (KB ids or title patterns)." },
            ["reboot"] = new Dictionary<string, object> { ["type"] = "string", ["enum"] = new[] { "never", "if_required" }, ["default"] = "never" },
            ["dry_run"] = new Dictionary<string, object> { ["type"] = "boolean", ["default"] = false },
        },
    };

    public bool Writes => true;

    internal const string InstallSetup =
        "$ids = @($env:YOLO_WU_IDS -split ',' | Where-Object { $_ }); "
        + "$s = New-Object -ComObject Microsoft.Update.Session; $s.ClientApplicationID = 'yoloman-agent windows_update'; "
        + "$res = $s.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0'); "
        + "$coll = New-Object -ComObject Microsoft.Update.UpdateColl; "
        + "foreach ($u in $res.Updates) { if ($ids -contains $u.Identity.UpdateID) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) } }; "
        + "$dl = $null; $inst = $null; $dlById = @{}; $instById = @{}; "
        + "if ($coll.Count -gt 0) { $d = $s.CreateUpdateDownloader(); $d.Updates = $coll; $dl = $d.Download(); "
        + "  for ($k = 0; $k -lt $coll.Count; $k++) { $dlById[$coll.Item($k).Identity.UpdateID] = $dl.GetUpdateResult($k) }; "
        + "  if ($env:YOLO_WU_STATE -eq 'installed') { $todo = New-Object -ComObject Microsoft.Update.UpdateColl; "
        + "    foreach ($u in $coll) { if ($u.IsDownloaded) { [void]$todo.Add($u) } }; "
        + "    if ($todo.Count -gt 0) { $i = $s.CreateUpdateInstaller(); $i.Updates = $todo; $inst = $i.Install(); "
        + "      for ($k = 0; $k -lt $todo.Count; $k++) { $instById[$todo.Item($k).Identity.UpdateID] = $inst.GetUpdateResult($k) } } } }; "
        + "$out = @(foreach ($u in $coll) { $id = $u.Identity.UpdateID; $dr = $dlById[$id]; $ir = $instById[$id]; "
        + "  [pscustomobject]@{ update_id = $id; title = $u.Title; kb = ('KB' + (@($u.KBArticleIDs) | Select-Object -First 1)); "
        + "    download_code = $(if ($dr) { [int]$dr.ResultCode } else { $null }); download_hresult = $(if ($dr) { [long]$dr.HResult } else { $null }); "
        + "    install_code = $(if ($ir) { [int]$ir.ResultCode } else { $null }); install_hresult = $(if ($ir) { [long]$ir.HResult } else { $null }); "
        + "    reboot_required = $(if ($ir) { [bool]$ir.RebootRequired } else { $false }) } })";

    internal const string InstallExpression = "[pscustomobject]@{ found = $coll.Count; updates = $out }";

    // dism.exe with /english: the table and the package info are parsed, and a German host would answer in German.
    // A KB maps to Package_for_KB<n>, or to a Package_for_RollupFix / DotNetRollup whose info reads "Fix for KB<n>"
    // (measured on bossman-wintest: "Description : Fix for KB5126655").
    internal const string RemoveSetup =
        "$kbs = @($env:YOLO_WU_KBS -split ',' | Where-Object { $_ }); "
        + "function Pkgs { $t = dism.exe /online /english /get-packages /format:table; "
        + "  @($t | Where-Object { $_ -match '^Package_' } | ForEach-Object { $c = $_ -split '\\|'; [pscustomobject]@{ name = $c[0].Trim(); state = $c[1].Trim() } }) }; "
        + "function Info($n) { (dism.exe /online /english /get-packageinfo /packagename:$n | Select-String '^Description : ' | Select-Object -First 1).Line }; "
        + "$all = Pkgs; "
        + "$rollups = @($all | Where-Object { $_.name -match 'RollupFix|DotNetRollup' -and $_.state -in 'Installed','Superseded' } | "
        + "  ForEach-Object { [pscustomobject]@{ name = $_.name; state = $_.state; desc = (Info $_.name) } }); "
        // An umbrella update (the .NET rollup KB5128928) is installed as per-product packages with their OWN KB
        // ("Fix for KB5127687", measured): Windows Update's BundledUpdates names those, so they are searched too.
        + "$wua = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=1').Updates; "
        + "function Find($n) { @($all | Where-Object { $_.name -match ('Package_for_KB' + $n + '~') }) + @($rollups | Where-Object { $_.desc -match ('KB' + $n + '\\b') }) | Select-Object -First 1 }; "
        + "$out = @(foreach ($kb in $kbs) { $num = $kb -replace '^KB',''; $via = $null; "
        + "  $u = $wua | Where-Object { @($_.KBArticleIDs) -contains $num } | Select-Object -First 1; "
        + "  $p = Find $num; "
        + "  if (-not $p -and $u) { foreach ($b in @($u.BundledUpdates | ForEach-Object { @($_.KBArticleIDs) })) { $p = Find $b; if ($p) { $via = 'KB' + $b; break } } }; "
        + "  $code = $null; $after = $null; "
        + "  if ($p -and $p.state -eq 'Installed' -and $env:YOLO_WU_DRY -ne '1') { "
        + "    dism.exe /online /english /remove-package /packagename:$($p.name) /quiet /norestart | Out-Null; $code = $LASTEXITCODE; "
        + "    $after = (Pkgs | Where-Object { $_.name -eq $p.name } | Select-Object -First 1).state } "
        + "  [pscustomobject]@{ kb = $kb; package = $(if ($p) { $p.name } else { $null }); state_before = $(if ($p) { $p.state } else { $null }); "
        + "    hotfix = [bool](Get-HotFix -Id $kb -ErrorAction SilentlyContinue); wua_installed = [bool]$u; via = $via; exit_code = $code; state_after = $after; "
        + "    dry_run = ($env:YOLO_WU_DRY -eq '1') } })";

    private async Task<ModuleResult> Remove(List<string> kbs, bool dryRun, CancellationToken ct)
    {
        // Only what is named: a rollback that removed "whatever matches" could take a security fix nobody meant.
        var named = kbs.Select(k => k.Trim().ToUpperInvariant()).Select(k => k.StartsWith("KB") ? k : "KB" + k)
            .Where(k => System.Text.RegularExpressions.Regex.IsMatch(k, @"^KB\d{6,8}$")).Distinct().ToList();
        if (named.Count == 0)
            throw new ArgumentException("windows_update: state=removed needs the KB ids to remove in accept_list (e.g. [\"KB5128928\"])");
        var answer = await WindowsPowerShellBridge.RunJson(RemoveSetup, "[pscustomobject]@{ kbs = $out }", TimeSpan.FromMinutes(90), ct,
            new Dictionary<string, string> { ["YOLO_WU_KBS"] = string.Join(",", named), ["YOLO_WU_DRY"] = dryRun ? "1" : "0" });
        var data = WindowsUpdateRemoval.Interpret(answer.Items.FirstOrDefault());
        data["state"] = "removed";
        data["reboot"] = data["reboot_required"] is true ? "reboot_required — not restarted" : "not needed";
        var results = (List<Dictionary<string, object?>>)data["results"]!;
        var msg = string.Join("; ", results.Select(r => $"{r["kb"]}: {r["state"]}"));
        return new ModuleResult(results.Any(r => (string?)r["state"] is "removed" or "reboot_required"), msg, data);
    }

    private static List<string> Strings(IReadOnlyDictionary<string, object?> p, string name)
    {
        if (!p.TryGetValue(name, out var v) || v is null) return [];
        return v switch
        {
            string s => s.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList(),
            JsonElement { ValueKind: JsonValueKind.Array } a => a.EnumerateArray().Select(x => x.ToString().Trim()).Where(x => x.Length > 0).ToList(),
            JsonElement { ValueKind: JsonValueKind.String } js => (js.GetString() ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList(),
            IEnumerable<object> e => e.Select(x => Convert.ToString(x)?.Trim() ?? "").Where(x => x.Length > 0).ToList(),
            _ => [Convert.ToString(v) ?? ""],
        };
    }

    private static string Str(IReadOnlyDictionary<string, object?> p, string name, string fallback) =>
        p.TryGetValue(name, out var v) && v is not null && Convert.ToString(v) is { Length: > 0 } s
            ? (v is JsonElement je && je.ValueKind == JsonValueKind.String ? je.GetString() ?? fallback : s) : fallback;

    private static async Task<Dictionary<string, object?>> Facts(CancellationToken ct)
    {
        var answer = await WindowsPowerShellBridge.RunJson(WindowsUpdateFactsModule.Setup, WindowsUpdateFactsModule.Expression, TimeSpan.FromMinutes(10), ct);
        return WindowsUpdateFacts.Interpret(answer.Items.FirstOrDefault());
    }

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("windows_update drives the Windows Update Agent; on Linux the apt/dnf modules install updates.");
        var state = Str(parameters, "state", "installed");
        if (state is not ("searched" or "downloaded" or "installed" or "removed"))
            throw new ArgumentException($"windows_update: state '{state}' is none of searched, downloaded, installed, removed");
        if (state == "removed")
            return await Remove(Strings(parameters, "accept_list"), dryRun, ct);
        var reboot = Str(parameters, "reboot", "never");
        if (reboot is not ("never" or "if_required"))
            throw new ArgumentException($"windows_update: reboot '{reboot}' is none of never, if_required");

        var before = await Facts(ct);
        var pending = ((List<Dictionary<string, object?>>)before["pending"]!).Cast<IReadOnlyDictionary<string, object?>>();
        var (selected, skipped) = WindowsUpdateSelection.Select(pending, Strings(parameters, "category_names"),
            Strings(parameters, "accept_list"), Strings(parameters, "reject_list"));
        var data = new Dictionary<string, object?>
        {
            ["state"] = state, ["server"] = before["server"], ["wsus_server"] = before["wsus_server"],
            ["selected"] = selected.Select(c => new Dictionary<string, object?> { ["kb"] = c.Kb, ["title"] = c.Title, ["update_id"] = c.UpdateId }).ToList(),
            ["skipped"] = skipped.Select(c => new Dictionary<string, object?> { ["kb"] = c.Kb, ["title"] = c.Title, ["reason"] = c.Reason }).ToList(),
        };
        if (selected.Count == 0)
            return new ModuleResult(false, $"nothing to do: none of the {skipped.Count} pending update(s) is selected", data);
        if (dryRun || state == "searched")
        {
            var verb = state == "searched" ? "selected" : $"would be {state}";
            return new ModuleResult(false, $"{selected.Count} update(s) {verb}: {string.Join(", ", selected.Select(c => c.Kb ?? c.Title))}", data);
        }

        var install = await WindowsPowerShellBridge.RunJson(InstallSetup, InstallExpression, TimeSpan.FromMinutes(90), ct,
            new Dictionary<string, string>
            {
                ["YOLO_WU_IDS"] = string.Join(",", selected.Select(c => c.UpdateId).Where(i => i is not null)),
                ["YOLO_WU_STATE"] = state,
            });
        var after = await Facts(ct);
        var run = WindowsUpdateRun.Interpret(install.Items.FirstOrDefault(), after, wantInstalled: state == "installed");
        foreach (var kv in run) data[kv.Key] = kv.Value;
        data["reboot_pending_now"] = after["reboot_required"];

        var needReboot = run["reboot_required"] is true;
        if (needReboot && reboot == "if_required")
        {
            await WindowsPowerShellBridge.Run("shutdown.exe /r /t 60 /c \"yoloman windows_update: updates need a reboot\"", TimeSpan.FromMinutes(1), ct);
            data["reboot"] = "scheduled in 60 s (reboot=if_required)";
        }
        else
        {
            data["reboot"] = needReboot ? "reboot_required — not restarted (reboot=never)" : "not needed";
        }
        var results = (List<Dictionary<string, object?>>)run["results"]!;
        var msg = string.Join("; ", results.GroupBy(r => (string?)r["state"]).Select(g => $"{g.Count()} {g.Key}"));
        return new ModuleResult(results.Any(r => (string?)r["state"] is "installed" or "downloaded" or "reboot_required"), msg, data);
    }
}
