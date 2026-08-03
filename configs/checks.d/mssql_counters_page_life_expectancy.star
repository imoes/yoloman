def _render_timespan(seconds):
    s = int(seconds)
    if s <= 0:
        return "0 seconds"
    days = s // 86400
    hours = (s % 86400) // 3600
    minutes = (s % 3600) // 60
    secs = s % 60
    parts = []
    if days > 0:
        parts.append("%d day%s" % (days, "s" if days != 1 else ""))
    if hours > 0:
        parts.append("%d hour%s" % (hours, "s" if hours != 1 else ""))
    if minutes > 0:
        parts.append("%d minute%s" % (minutes, "s" if minutes != 1 else ""))
    parts.append("%d second%s" % (secs, "s" if secs != 1 else ""))
    return ", ".join(parts)

def main(ctx, params):
    if params.get("_discover"):
        cmd = "Get-Counter -Counter '\\MSSQL*:Buffer Manager" + chr(92) + "page life expectancy' -ErrorAction SilentlyContinue | ForEach-Object { $o = $_.CounterSamples; $cn = ($_.Path -split '\\')[-1]; $inst = ($o.Path -split '\\')[-2]; Write-Output ($cn + '|' + $inst + '|' + [int]$o.CookedValue) }"
        res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
        found = []
        if res.rc == 127:
            return {"changed": False, "msg": "powershell not installed",
                    "data": {"discovery": []}}
        if res.rc == 0 and res.stdout:
            for line in res.stdout.splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                bits = stripped.split("|")
                if len(bits) < 3:
                    continue
                found.append({"obj": bits[0], "instance": bits[1], "value": bits[2]})
        if not found:
            return {"changed": False, "msg": "no MSSQL page life expectancy counters",
                    "data": {"discovery": []}}
        discovery = []
        for f in found:
            obj = f["obj"]
            instance = f["instance"]
            if instance == "None":
                item = "%s page_life_expectancy" % obj
            else:
                item = "%s %s page_life_expectancy" % (obj, instance)
            discovery.append({"item": item, "params": {}, "metrics": ["page_life_expectancy"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    sitems = item.split()
    if len(sitems) == 2 and sitems[1] == "page_life_expectancy":
        obj = sitems[0]
        instance = "None"
    elif len(sitems) == 3 and sitems[2] == "page_life_expectancy":
        obj = sitems[0]
        instance = sitems[1]
    else:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    bs = chr(92)
    counter_path = bs + obj + bs + "page life expectancy"
    if instance != "None":
        counter_path = bs + obj + "(" + instance + ")" + bs + "page life expectancy"
    cmd = "Get-Counter -Counter '" + counter_path + "' -ErrorAction SilentlyContinue; if ($_.Exceptions.Count -gt 0) { exit 1 }"
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    value = None
    if res.rc == 0 and res.stdout:
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped and stripped.replace(".", "").isdigit():
                v = int(stripped)
                if v > 0:
                    value = v
                    break
    if value == None:
        return {"changed": False, "msg": "no page_life_expectancy data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("mssql_min_page_life_expectancy", (350, 300))
    warn = levels[0]
    crit = levels[1]
    if value <= crit:
        state = "CRIT"
    elif value <= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": _render_timespan(value),
            "data": {"state": state, "metrics": {"page_life_expectancy": value},
                     "details": "MSSQL %s page life expectancy: %d seconds" % (obj, value)}}