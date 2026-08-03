# windows_updates.star — read-only Checkmk check translation
# Monitors Windows System Updates via the Windows Update API.
# On a non-Windows host or one without access to the Windows Update
# COM source, discovery yields nothing and the check reports UNKNOWN.

def _state_for_level(value, levels_upper, levels_lower):
    # levels_upper: (warn, crit) — warn/crit triggered at >=
    # levels_lower: (warn, crit) for forced-reboot time remaining — triggered at <=
    if levels_upper != None:
        warn, crit = levels_upper
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"
    if levels_lower != None:
        warn, crit = levels_lower
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
        return "OK"
    return "OK"


def _reboot_state(reboot_required_show_state):
    # 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN, None=none
    if reboot_required_show_state == None:
        return None
    mapping = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    return mapping.get(reboot_required_show_state, "UNKNOWN")


def main(ctx, params):
    # This check monitors Windows Update state. The real data source is the
    # Windows Update COM API, accessed via a Checkmk Windows agent plugin.
    # On our sandboxed agent there is no equivalent local source on Linux.
    # Probe: is this a Windows host?
    facts = ctx.facts()
    is_windows = facts.get("os_family") == "windows"

    if params.get("_discover"):
        # Discovery: only applicable on Windows hosts that expose the
        # Windows Update data source. Non-Windows hosts get nothing.
        if not is_windows:
            return {"changed": False,
                    "msg": "not a Windows host; windows_updates does not apply",
                    "data": {"discovery": []}}
        # On Windows, the single-service check applies (item "").
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {
                        "levels_important": (1, 1),
                        "levels_optional": (1, 99),
                        "levels_lower_forced_reboot": (604800, 172800),
                        "reboot_required_show_state": 1,
                     }, "metrics": ["important", "optional", "forbidden_reboot"]},
                 ]}}

    # Check mode — single service, item ""
    if not is_windows:
        return {"changed": False,
                "msg": "windows_updates: not a Windows host; no Windows Update source available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # On Windows, attempt to query Windows Update counts via PowerShell.
    # This is the real source: Get-WmiObject/Win32_QuickFixEngineering or the
    # UpdateSession COM API.
    res = ctx.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command",
         "try { $sess = New-Object -ComObject Microsoft.Update.Session; $s = $sess.CreateUpdateSearcher(); $crit = $s.Search('IsInstalled=0 and Type=\"Software\"'); $imp = ($crit.Results.Updates | Where-Object { $_.MsrcSeverity -ne $null }).Count; $opt = ($crit.Results.Updates | Where-Object { $_.MsrcSeverity -eq $null }).Count; Write-Output \"$imp $opt\"; } catch { Write-Error 'no-windows-update-api'; exit 1 }"],
        mutates=False,
    )

    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False,
                "msg": "windows_updates: could not query Windows Update API",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = res.stdout.strip().split()
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return {"changed": False,
                "msg": "windows_updates: unexpected Windows Update output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    important_count = int(parts[0])
    optional_count = int(parts[1])

    levels_important = params.get("levels_important", (1, 1))
    levels_optional = params.get("levels_optional", (1, 99))
    levels_lower_forced_reboot = params.get("levels_lower_forced_reboot", (604800, 172800))
    reboot_required_show_state_raw = params.get("reboot_required_show_state", 1)
    reboot_required_show_state = _reboot_state(reboot_required_show_state_raw)

    metrics = {"important": important_count, "optional": optional_count}
    details = "Important updates: %d, Optional updates: %d" % (important_count, optional_count)
    msgs = []

    state_imp = _state_for_level(important_count, levels_important, None)
    if state_imp != "OK":
        msgs.append("Important updates %s (%d)" % (state_imp, important_count))

    state_opt = _state_for_level(optional_count, levels_optional, None)
    if state_opt != "OK":
        msgs.append("Optional updates %s (%d)" % (state_opt, optional_count))

    # Reboot required check (simplified — real source tracks this in the section)
    # Without access to reboot-required state, we cannot report it.
    # Forced reboot time-remaining is also from the agent plugin, not queryable
    # via standard PowerShell without the Checkmk source.

    if state_imp == "CRIT" or state_opt == "CRIT":
        verdict = "CRIT"
    elif state_imp == "WARN" or state_opt == "WARN":
        verdict = "WARN"
    else:
        verdict = "OK"

    summary = "; ".join(msgs) if msgs else details
    return {"changed": False, "msg": summary,
            "data": {"state": verdict, "metrics": metrics, "details": details}}