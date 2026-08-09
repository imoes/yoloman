def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _discover(ctx, params):
    zonefiles = _list_thermal_zones(ctx)
    if len(zonefiles) == 0:
        return {"changed": False, "msg": "no thermal zones found",
                "data": {"discovery": []}}
    out = []
    for zf in zonefiles:
        thermal = _read_zone(ctx, zf)
        if thermal == None:
            continue
        if not thermal["enabled"]:
            continue
        out.append({"item": "Zone " + _zone_num(zf),
                    "params": {"levels": (70.0, 80.0)},
                    "metrics": ["temperature"]})
    return {"changed": False, "msg": "discovered %d zones" % len(out),
            "data": {"discovery": out}}

def _check(ctx, params):
    item = params.get("item", "")
    zonefiles = _list_thermal_zones(ctx)
    if len(zonefiles) == 0:
        return {"changed": False, "msg": "no thermal zones found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    target = _zone_num_to_file(item)
    thermal = _read_zone(ctx, target)
    if thermal == None or not thermal["enabled"]:
        return {"changed": False, "msg": "no such thermal zone: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = thermal["temperature"]
    warn = params.get("warn", 70.0)
    crit = params.get("crit", 80.0)
    levels = params.get("levels", (70.0, 80.0))
    if type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    dev_crit = thermal["critical"]
    dev_hot = thermal["hot"]
    dev_warn = thermal["passive"]
    eff_crit = _min_nonzero(dev_crit, dev_hot)
    if eff_crit != None and crit != None:
        crit = min(crit, eff_crit)
    elif eff_crit != None:
        crit = eff_crit
    if dev_warn != None and warn != None:
        warn = min(warn, dev_warn)
    elif dev_warn != None:
        warn = dev_warn
    if crit != None and temp >= crit:
        state = "CRIT"
    elif warn != None and temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    details = "Temperature: %f C" % temp
    if dev_warn != None:
        details = details + ", Passive: %f C" % dev_warn
    if dev_crit != None:
        details = details + ", Critical: %f C" % dev_crit
    if dev_hot != None:
        details = details + ", Hot: %f C" % dev_hot
    return {"changed": False, "msg": "%s %f C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": details}}

def _list_thermal_zones(ctx):
    res = ctx.run(["ls", "/sys/class/thermal/"], mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        s = line.strip()
        if s.startswith("thermal_zone"):
            out.append(s)
    return out

def _zone_num(zonename):
    return zonename[len("thermal_zone"):]

def _zone_num_to_file(item):
    if item.startswith("Zone "):
        return "thermal_zone" + item[len("Zone "):]
    return item

def _min_nonzero(a, b):
    vals = []
    if a != None and a > 0:
        vals.append(a)
    if b != None and b > 0:
        vals.append(b)
    if len(vals) == 0:
        return None
    return min(vals)

def _read_zone(ctx, zonename):
    base = "/sys/class/thermal/" + zonename + "/"
    enabled = _read_int(ctx, base, "temp")
    if enabled < 0:
        return None
    enabled_bool = True
    raw_temp = _read_int(ctx, base, "temp")
    temp = _to_celsius(ctx, raw_temp)
    passive = _read_trip(ctx, base, "trip_point0_temp", "trip_point0_type", "passive")
    critical = _read_trip(ctx, base, "trip_point0_temp", "trip_point0_type", "critical")
    hot = _read_trip(ctx, base, "trip_point0_temp", "trip_point0_type", "hot")
    return {"enabled": enabled_bool, "temperature": temp,
            "passive": passive, "critical": critical, "hot": hot}

def _to_celsius(ctx, raw):
    if raw >= 100000:
        return float(raw) / 1000.0
    return float(raw)

def _read_trip(ctx, base, temp_file, type_file, want_type):
    for i in range(20):
        tfile = "trip_point" + str(i) + "_temp"
        tyfile = "trip_point" + str(i) + "_type"
        tval = _safe_read_int(ctx, base + tfile)
        if tval == None or tval <= 0:
            continue
        ttype = _safe_read_str(ctx, base + tyfile)
        if ttype == None:
            continue
        if ttype.strip() == want_type:
            return float(tval) / 1000.0
        if want_type == "critical" and ttype.strip() == "critical":
            return float(tval) / 1000.0
        if want_type == "hot" and ttype.strip() == "hot":
            return float(tval) / 1000.0
        if want_type == "passive" and ttype.strip() == "passive":
            return float(tval) / 1000.0
    return None

def _read_int(ctx, base, fname):
    res = ctx.run(["cat", base + fname], mutates=False)
    if res.rc != 0:
        return -1
    s = res.stdout.strip()
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    return -1

def _safe_read_int(ctx, path):
    res = ctx.run(["cat", path], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return None
    s = res.stdout.strip()
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    return None

def _safe_read_str(ctx, path):
    res = ctx.run(["cat", path], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()