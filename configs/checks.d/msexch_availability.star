# Copyright (C) 2024 Checkmk GmbH - License: GNU General Public License v2
# Translated Checkmk check: msexch_availability
# Monitors Exchange Availability Service requests/sec via WMI.

def main(ctx, params):
    if params.get("_discover"):
        return discovery(ctx, params)
    return check(ctx, params)


def _wmi_get_perf(ctx, host, community, wmi_class, col_indices):
    """Run wbemcli-style perf-class read; returns list of rows (per-instance).
    Each row is a dict: {"instance": str_or_None, "..." : val}.
    We probe the real thing first: rc==127 means wbemcli not installed."""
    cmd = _wmi_command(host, community)
    res = ctx.run(cmd + ["--no-header", "--output-count=1",
                         "root\\CIMV2:" + wmi_class],
                    mutates=False)
    if res.rc == 127:
        return None  # wbemctl missing -> check not applicable
    if res.rc != 0:
        return None
    rows = []
    for line in res.stdout.splitlines():
        f = line.split(";")
        if not f:
            continue
        row = {}
        for i, v in enumerate(f):
            col = col_indices[i]
            v = v.strip()
            if col == "_Total":
                v = None
            row[col] = v
        rows.append(row)
    return rows


def check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    rows = _wmi_get_perf(ctx, host, community,
                         "Win32_PerfRawData_MSExchange_Availability",
                         ["Name", "RequestsPersec"])
    if rows == None:
        # wbemcli missing -> not installed
        return {"changed": False, "msg": "wbemcli not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "wbemcli is not installed or unreachable"}}

    # Find the _Total (instance None) row.
    total_row = None
    for r in rows:
        if r.get("Name") == None:
            total_row = r
            break

    if total_row == None:
        return {"changed": False, "msg": "no Availability instance",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No _Total entry in " + "Win32_PerfRawData_MSExchange_Availability"}}

    raw = total_row.get("RequestsPersec")
    if raw == None or not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "no data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "RequestsPersec value missing/invalid"}}

    value = int(raw)
    warn = params.get("warn", 20)
    crit = params.get("crit", 40)
    levels = params.get("levels")
    if levels != None:
        if len(levels) > 0:
            warn = levels[0]
        if len(levels) > 1:
            crit = levels[1]

    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Availability Requests/sec: %d" % value,
            "data": {"state": state,
                     "metrics": {"requests_per_sec": value},
                     "details": ""}}


def discovery(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    rows = _wmi_get_perf(ctx, host, community,
                         "Win32_PerfRawData_MSExchange_Availability",
                         ["Name", "RequestsPersec"])
    if rows == None:
        return {"changed": False, "msg": "wbemcli not available",
                "data": {"discovery": []}}

    # Per Checkmk: only the total ("_Total") instance yields a service.
    has_total = False
    for r in rows:
        if r.get("Name") == None:
            has_total = True
            break

    if not has_total:
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    return {"changed": False, "msg": "discovered Exchange Availability Service",
            "data": {"discovery": [{"item": "",
                                    "params": {"warn": 20, "crit": 40},
                                    "metrics": ["requests_per_sec"]}]}}


def _wmi_command(host, community):
    return ["wbemcli", "ei", "-n", "root\\CIMV2",
            "-c", community, host]