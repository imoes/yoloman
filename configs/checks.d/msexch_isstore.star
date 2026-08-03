# Checkmk check: msexch_isstore -> read-only Starlark check module
# Monitors Exchange Information Store (IS) Store RPC Average Latency via WMI.

def main(ctx, params):
    if params.get("_discover"):
        # DISCOVERY: enumerate Exchange IS Store instances from the WMI perf table.
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_MSExchangeIS_HelperTable", "get", "Name", "/value"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "wmic not available / no data",
                    "data": {"discovery": []}}
        # wmic /value emits blocks like:
        # Name="Information Store - Mailbox"
        # Name="Information Store - Public"
        names = []
        for line in res.stdout.splitlines():
            s = line.strip()
            if s.startswith("Name="):
                raw = s[len("Name="):]
                name = raw.strip().strip('"')
                if name != "" and name not in names:
                    names.append(name)
        if len(names) == 0:
            return {"changed": False, "msg": "no Exchange IS Store instances found",
                    "data": {"discovery": []}}
        out = []
        for n in names:
            out.append({"item": n, "params": {"store_latency_s": [0.04, 0.05]},
                        "metrics": ["average_latency_s"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE: read one item's RPCAverageLatency raw counter.
    item = params.get("item", "")
    warn_crit = params.get("store_latency_s", [0.04, 0.05])
    warn = warn_crit[0] if len(warn_crit) > 0 else 0.04
    crit = warn_crit[1] if len(warn_crit) > 1 else 0.05

    # Probe first: is wmic present at all?
    probe = ctx.run(["wmic", "path", "Win32_PerfRawData_MSExchangeIS_HelperTable", "get", "Name", "/value"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "wmic not installed; Exchange IS Store not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        return {"changed": False, "msg": "wmic probe failed (rc=%s)" % probe.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Query the specific instance's RPCAverageLatency raw counter.
    res = ctx.run(["wmic", "path", "Win32_PerfRawData_MSExchangeIS_HelperTable",
                   "where", "Name='%s'" % item, "get", "RPCAverageLatency", "/value"],
                  mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no data for item",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = None
    for line in res.stdout.splitlines():
        s = line.strip()
        if s.startswith("RPCAverageLatency="):
            raw = s[len("RPCAverageLatency="):].strip()
            if raw.isdigit():
                value = int(raw)
            break

    if value == None:
        return {"changed": False, "msg": "RPCAverageLatency not parseable for item",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # RPCAverageLatency is a raw counter; with no prior sample we cannot compute
    # a true per-second rate. We report the raw value as the latency metric
    # (consistent with a point-in-time reading) and grade against thresholds.
    latency_s = float(value) * 0.001
    state = "CRIT" if latency_s >= crit else ("WARN" if latency_s >= warn else "OK")
    return {"changed": False,
            "msg": "Average latency: %s s" % str(latency_s),
            "data": {"state": state, "metrics": {"average_latency_s": latency_s}, "details": ""}}