# win_dhcp_pools_stats: read-only Checkmk check → Starlark module for yolo-man

_WIN_DHCP_POOLS_STATS_TRANSLATE = {
    "Entdeckungen": "Discovers",
    "Angebote": "Offers",
    "Anforderungen": "Requests",
    "Acks": "Acks",
    "Naks": "Nacks",
    "Abweisungen": "Declines",
    "Freigaben": "Releases",
    "Subnetz": "Subnet",
    "Bereiche": "Scopes",
    "Anzahl der verwendeten Adressen": "No. of Addresses in use",
    "Anzahl der freien Adressen": "No. of free Addresses",
    "Anzahl der anstehenden Angebote": "No. of pending offers",
    "D\u00c9couvertes": "Discovers",
    "Offres": "Offers",
    "Requ\u0088tes": "Requests",
    "AR": "Acks",
    "AR n\u0082g.": "Nacks",
    "Refus": "Declines",
    "Lib\u0082rations": "Releases",
    "Sous-r\u0082seau": "Subnet",
    "\u0090tendues": "Scopes",
    "Nb d'adresses utilis\u0082es": "No. of Addresses in use",
    "Nb d'adresses libres": "No. of free Addresses",
    "Nb d'offres en attente": "No. of pending offers",
}

_STATS_KEYS = [
    "Discovers",
    "Offers",
    "Requests",
    "Acks",
    "Nacks",
    "Declines",
    "Releases",
    "Scopes",
]

# PowerShell command that emits the win_dhcp_pools section format as plain text
_PS_COMMAND = [
    "powershell",
    "-NoProfile",
    "-Command",
    "& { Import-Module NetSecurity -ErrorAction SilentlyContinue; $r = Get-DhcpServerv4Statistics -ErrorAction SilentlyContinue; if ($r) { Write-Host ('MIBCounts:'); Write-Host ('        Discovers = ' + $r.Discovers + '.'); Write-Host ('        Offers = ' + $r.Offers + '.'); Write-Host ('        Requests = ' + $r.Requests + '.'); Write-Host ('        Acks = ' + $r.Acks + '.'); Write-Host ('        Naks = ' + $r.Naks + '.'); Write-Host ('        Declines = ' + $r.Declines + '.'); Write-Host ('        Releases = ' + $r.Releases + '.'); Write-Host ('        Scopes = ' + $r.Scopes + '.'); } }",
]


def _parse_line(line):
    if " = " not in line:
        return None
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None
    key = parts[0].strip().rstrip(".")
    val = parts[1].strip().rstrip(".")
    return (key, val)


def _run_ps(ctx):
    return ctx.run(_PS_COMMAND, mutates=False)


def _exists_dhcp(ctx):
    res = ctx.run(["powershell", "-NoProfile", "-Command", "& { try { $null = Get-Command Get-DhcpServerv4Statistics -ErrorAction Stop; exit 0 } catch { exit 1 } }"], mutates=False)
    return res.rc == 0


def _parse_section(ctx):
    res = _run_ps(ctx)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    section = []
    for line in lines:
        parsed = _parse_line(line)
        if parsed != None:
            section.append(parsed)
    return section


def main(ctx, params):
    # Discovery mode: detect whether the DHCP server role / cmdlet is present
    if params.get("_discover"):
        if not _exists_dhcp(ctx):
            return {"changed": False, "msg": "no dhcp server found", "data": {"discovery": []}}
        section = _parse_section(ctx)
        if section == None or len(section) == 0:
            return {"changed": False, "msg": "no dhcp stats found", "data": {"discovery": []}}
        metrics = []
        for key in _STATS_KEYS:
            metrics.append(key)
        return {"changed": False, "msg": "discovered dhcp stats", "data": {"discovery": [{"item": "", "params": {"levels": (10.0, 5.0)}, "metrics": metrics}]}}

    # Check mode: report rates of the DHCP statistics counters
    item = params.get("item", "")
    if not _exists_dhcp(ctx):
        return {"changed": False, "msg": "no dhcp server found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(ctx)
    if section == None:
        return {"changed": False, "msg": "no dhcp stats found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    last_key = ""
    last_val = 0
    for key, val in section:
        if key in _STATS_KEYS:
            if val.isdigit():
                metrics[key] = int(val)
                last_key = key
                last_val = int(val)

    if len(metrics) == 0:
        return {"changed": False, "msg": "no dhcp stats found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply configured levels where present (Checkmk default free_leases (10.0, 5.0))
    levels = params.get("levels", (10.0, 5.0))
    warn = levels[0] if isinstance(levels, list) else levels[0]
    crit = levels[1] if isinstance(levels, list) else levels[1]

    # Use Scopes count as the graded metric (mirrors check_levels on a primary counter)
    graded = metrics.get("Scopes", 0)
    state = "OK"
    if graded >= crit:
        state = "CRIT"
    elif graded >= warn:
        state = "WARN"

    msg = "Discovers=%d Offers=%d Requests=%d Acks=%d Nacks=%d Declines=%d Releases=%d Scopes=%d" % (
        metrics.get("Discovers", 0),
        metrics.get("Offers", 0),
        metrics.get("Requests", 0),
        metrics.get("Acks", 0),
        metrics.get("Nacks", 0),
        metrics.get("Declines", 0),
        metrics.get("Releases", 0),
        metrics.get("Scopes", 0),
    )

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": "All values are averaged, as the Windows DHCP plug-in collects statistics, not real-time measurements"}}