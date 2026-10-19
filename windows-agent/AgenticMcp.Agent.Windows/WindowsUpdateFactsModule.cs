using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_update_facts</c> — what Windows Update says about this host: pending updates (KB, title, categories,
/// MsrcSeverity, CVE ids where Windows gives them, reboot behaviour, downloaded or not), the update history with
/// Windows' own result codes, the last successful search and install, the update server (Windows Update or a WSUS
/// the policy names) and whether a reboot is pending. READ-ONLY (plan B13): a search changes nothing on the host.
///
/// <para>Through the Windows Update Agent COM API (Microsoft.Update.Session), asked from the agent's service
/// process, which runs as SYSTEM. The interpretation lives in <see cref="WindowsUpdateFacts"/> (tested on Linux).</para>
/// </summary>
public sealed class WindowsUpdateFactsModule : IModule
{
    public string Name => "windows_update_facts";

    public string Description =>
        "What Windows Update reports for this host — read-only. Pending updates (kb, title, categories, msrc_severity in "
        + "Windows' own words, cve_ids where Windows supplies them, reboot_behavior, downloaded, size), the last 50 history "
        + "entries (operation, result NotStarted/InProgress/Succeeded/SucceededWithErrors/Failed/Aborted, hresult), "
        + "last successful search/installation, the update server (windows_update, or the WSUS a policy assigns) and a "
        + "pending reboot. Updates without CVE ids are counted in cve_gap with the reason. Takes no parameters.\n\n"
        + "Cross-tool equivalents:\n- Ansible: ansible.windows.win_updates with state=searched.\n"
        + "- PowerShell: PSWindowsUpdate Get-WindowsUpdate (a gallery module; this uses the built-in COM API).";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>(),
    };

    public bool Writes => false;

    // One collection script; dates as ISO-8601 UTC so nothing depends on the host's locale.
    internal const string Setup =
        "$s = New-Object -ComObject Microsoft.Update.Session; "
        + "$searcher = $s.CreateUpdateSearcher(); "
        + "$res = $searcher.Search('IsInstalled=0 and IsHidden=0'); "
        + "$pending = @(foreach ($u in $res.Updates) { [pscustomobject]@{ update_id = $u.Identity.UpdateID; revision = $u.Identity.RevisionNumber; "
        + "  title = $u.Title; kb = @($u.KBArticleIDs | ForEach-Object { [string]$_ }); cve = @($u.CveIDs | ForEach-Object { [string]$_ }); "
        + "  severity = [string]$u.MsrcSeverity; categories = @($u.Categories | ForEach-Object { $_.Name }); "
        + "  reboot_behavior = [int]$u.InstallationBehavior.RebootBehavior; downloaded = [bool]$u.IsDownloaded; "
        + "  max_size = [long]$u.MaxDownloadSize; can_uninstall = [bool]$u.IsUninstallable; "
        + "  published = $u.LastDeploymentChangeTime.ToUniversalTime().ToString('o') } }); "
        + "$n = $searcher.GetTotalHistoryCount(); $hist = @(); "
        + "if ($n -gt 0) { $hist = @(foreach ($h in $searcher.QueryHistory(0, [Math]::Min($n, 50))) { [pscustomobject]@{ "
        + "  date = $h.Date.ToUniversalTime().ToString('o'); operation = [int]$h.Operation; result_code = [int]$h.ResultCode; "
        + "  hresult = [long]$h.HResult; title = $h.Title; update_id = $h.UpdateIdentity.UpdateID } }) }; "
        + "$last = $null; $lastInstall = $null; "
        + "try { $au = New-Object -ComObject Microsoft.Update.AutoUpdate; "
        + "  $last = ([datetime]$au.Results.LastSearchSuccessDate).ToUniversalTime().ToString('o'); "
        + "  $lastInstall = ([datetime]$au.Results.LastInstallationSuccessDate).ToUniversalTime().ToString('o') } catch { }; "
        + "$pol = Get-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' -ErrorAction SilentlyContinue; "
        + "$au2 = Get-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -ErrorAction SilentlyContinue; "
        + "$cbs = Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending'; "
        + "$wu = Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\WindowsUpdate\\Auto Update\\RebootRequired'";

    internal const string Expression =
        "[pscustomobject]@{ search_result = [int]$res.ResultCode; pending = $pending; history = $hist; last_search = $last; "
        + "last_install = $lastInstall; wsus_server = [string]$pol.WUServer; use_wsus = [int]$au2.UseWUServer; "
        + "reboot_cbs = [bool]$cbs; reboot_wu = [bool]$wu }";

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun, CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("windows_update_facts asks the Windows Update Agent; on Linux the package manager's own facts module answers.");
        // A search against Microsoft Update takes seconds when the catalogue is cached and minutes when it is not.
        var answer = await WindowsPowerShellBridge.RunJson(Setup, Expression, TimeSpan.FromMinutes(10), ct);
        var data = WindowsUpdateFacts.Interpret(answer.Items.FirstOrDefault());
        var count = (int)data["pending_count"]!;
        var msg = data["complete"] is true ? (count == 0 ? "no update is pending" : $"{count} update(s) pending")
            : $"{count} update(s) found, but the list may be incomplete: the search ended {data["search_result"]}";
        if (data["reboot_required"] is true) msg += "; a reboot is pending";
        return new ModuleResult(false, msg, data);
    }
}
