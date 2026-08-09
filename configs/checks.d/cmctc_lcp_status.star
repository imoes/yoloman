def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    trees = ["3", "4", "5", "6"]
    sensor_specs = {
        "4": (None, "access"),
        "12": (None, "humidity"),
        "13": ("normally open", "user"),
        "14": ("normally closed", "user"),
        "23": (None, "flow"),
        "30": (None, "current"),
        "31": (None, "status"),
        "32": (None, "position"),
        "40": ("1", "blower"),
        "41": ("2", "blower"),
        "42": ("3", "blower"),
        "43": ("4", "blower"),
        "44": ("5", "blower"),
        "45": ("6", "blower"),
        "46": ("7", "blower"),
        "47": ("8", "blower"),
        "48": ("Server in 1", "temp"),
        "49": ("Server out 1", "temp"),
        "50": ("Server in 2", "temp"),
        "51": ("Server out 2", "temp"),
        "52": ("Server in 3", "temp"),
        "53": ("Server out 3", "temp"),
        "54": ("Server in 4", "temp"),
        "55": ("Server out 4", "temp"),
        "56": ("Overview Server in", "temp"),
        "57": ("Overview Server out", "temp"),
        "58": ("Water in", "temp"),
        "59": ("Water out", "temp"),
        "60": (None, "flow"),
        "61": (None, "blowergrade"),
        "62": (None, "regulator"),
    }
    map_sensor_state = {
        "1": (3, "not available"),
        "2": (2, "lost"),
        "3": (1, "changed"),
        "4": (0, "ok"),
        "5": (2, "off"),
        "6": (0, "on"),
        "7": (1, "warning"),
        "8": (2, "too low"),
        "9": (2, "too high"),
        "10": (2, "error"),
    }
    map_unit = {
        "access": "",
        "current": " A",
        "status": "",
        "position": "",
        "temp": " °C",
        "blower": " RPM",
        "blowergrade": "",
        "humidity": "%",
        "flow": " l/min",
        "regulator": "%",
        "user": "",
    }

    def probe_cmctc():
        base = ".1.3.6.1.4.1.2606.4.2"
        oids = [
            "5.2.1.1",
            "5.2.1.2",
            "5.2.1.4",
            "5.2.1.5",
            "5.2.1.6",
            "5.2.1.7",
            "5.2.1.8",
            "7.2.1.2",
        ]
        rows = []
        for tree in trees:
            full_base = base + "." + tree
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn",
                 "-c", community, host, full_base],
                mutates=False,
            )
            # Fallback: simpler invocation if -c flag doubled
            if res.rc != 0:
                res = ctx.run(
                    ["snmpwalk", "-v2c", "-c", community, "-Oqn",
                     host, full_base],
                    mutates=False,
                )
            if res.rc != 0 or res.stdout == "":
                return None
            lines = res.stdout.split("\n")
            parsed = {}
            for line in lines:
                line = line.strip()
                if line == "":
                    continue
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                val = parts[1]
                suffix = oid[len(full_base) + 1:]
                col = suffix.split(".", 1)[0]
                idx = suffix.split(".", 1)[1] if "." in suffix else ""
                if idx == "":
                    continue
                if idx not in parsed:
                    parsed[idx] = {}
                parsed[idx][col] = val
            for idx in sorted(parsed.keys()):
                p = parsed[idx]
                row = []
                for col in ["5", "2", "4", "5", "6", "7", "8", "2"]:
                    pass
                # Build row: index, typeid, status, reading, high, low, warn, description
                # typeid is col 2, status col 4, reading col 5, high col 6, low col 7, warn col 8, description col 7.2.1.2
                # Actually mapping: 5.2.1.1=index, 5.2.1.2=typeid, 5.2.1.4=status, 5.2.1.5=reading, 5.2.1.6=high, 5.2.1.7=low, 5.2.1.8=warn, 7.2.1.2=description
                typeid = p.get("2", "")
                status = p.get("4", "")
                reading = p.get("5", "")
                high = p.get("6", "")
                low = p.get("7", "")
                warn = p.get("8", "")
                # description from 7.2.1.2 — need separate walk
                desc = ""
                rows.append((idx, typeid, status, reading, high, low, warn, desc))
        return rows

    def fetch_section():
        base = ".1.3.6.1.4.1.2606.4.2"
        columns = {
            "5.2.1.2": "typeid",
            "5.2.1.4": "status",
            "5.2.1.5": "reading",
            "5.2.1.6": "high",
            "5.2.1.7": "low",
            "5.2.1.8": "warn",
            "7.2.1.2": "description",
        }
        section = {}
        for tree in trees:
            full_base = base + "." + tree
            by_index = {}
            for col_oid, col_name in columns.items():
                walk_oid = full_base + "." + col_oid
                res = ctx.run(
                    ["snmpwalk", "-v2c", "-c", community, "-Oqn",
                     host, walk_oid],
                    mutates=False,
                )
                if res.rc != 0 or res.stdout == "":
                    continue
                for line in res.stdout.split("\n"):
                    line = line.strip()
                    if line == "":
                        continue
                    parts = line.split(" ", 1)
                    if len(parts) < 2:
                        continue
                    oid = parts[0]
                    val = parts[1]
                    suffix = oid[len(walk_oid) + 1:]
                    idx = suffix if suffix != "" else "0"
                    if idx not in by_index:
                        by_index[idx] = {}
                    by_index[idx][col_name] = val
            for idx in sorted(by_index.keys()):
                p = by_index[idx]
                typeid = p.get("typeid", "")
                spec = sensor_specs.get(typeid)
                if spec == None:
                    continue
                prefix = spec[0]
                if prefix != None and prefix != "":
                    item = prefix + " - " + tree + "." + idx
                else:
                    item = tree + "." + idx
                sensor = {
                    "status": p.get("status", ""),
                    "reading": _to_float(p.get("reading", "")),
                    "high": _to_float(p.get("high", "")),
                    "low": _to_float(p.get("low", "")),
                    "warn": _to_float(p.get("warn", "")),
                    "description": p.get("description", ""),
                    "type_": spec[1],
                }
                section[item] = sensor
        return section

    def _to_float(s):
        if s == None or s == "":
            return 0.0
        # strip quotes if present
        s = s.strip()
        if s.startswith('"') and s.endswith('"'):
            s = s[1:-1]
        return float(s)

    if params.get("_discover"):
        section = fetch_section()
        if section == None or len(section) == 0:
            # Probe whether device responds at all
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn",
                 host, ".1.3.6.1.2.1.1.2"],
                mutates=False,
            )
            if res.rc != 0 or res.stdout == "":
                return {"changed": False, "msg": "no cmctc device found",
                        "data": {"discovery": []}}
            return {"changed": False, "msg": "no lcp sensors found",
                    "data": {"discovery": []}}
        out = []
        for item, sensor in section.items():
            out.append({
                "item": item,
                "params": {},
                "metrics": ["status"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    sensortype = params.get("sensortype", "status")
    section = fetch_section()
    if section == None or len(section) == 0:
        return {"changed": False, "msg": "no cmctc device or sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in section:
        return {"changed": False,
                "msg": "item %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensor = section[item]
    unit = map_unit.get(sensor["type_"], "")
    infotext = ""
    if sensor["description"] != "":
        infotext += "[%s] " % sensor["description"]
    state_map_entry = map_sensor_state.get(sensor["status"], (3, "unknown"))
    state = state_map_entry[0]
    extra_info = state_map_entry[1]
    extra_state = 0
    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
        metrics = {"status": sensor["reading"]}
        if sensor["reading"] >= crit:
            extra_state = 2
        elif sensor["reading"] >= warn:
            extra_state = 1
        if extra_state:
            extra_info += " (warn/crit at %d/%d%s)" % (int(warn), int(crit), unit)
    else:
        metrics = {"status": sensor["reading"]}
        low = sensor["low"]
        warn = sensor["warn"]
        high = sensor["high"]
        has_levels = (low != 0.0 or warn != 0.0 or high != 0.0) and (low < high)
        if has_levels:
            if sensor["reading"] >= high or sensor["reading"] <= low:
                extra_state = 2
                extra_info += " (device lower/upper crit at %d/%d%s)" % (int(low), int(high), unit)

    state_str = {0: "OK", 1: "WARN", 2: "CRIT", 3: "CRIT"}.get(state, "UNKNOWN")
    extra_state_str = {0: "OK", 1: "WARN", 2: "CRIT"}.get(extra_state, "UNKNOWN")
    # Combine: primary state from sensor status, secondary from levels
    combined = max(state, extra_state)
    if state == 3:
        combined = 3
    final_state = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(combined, "UNKNOWN")
    summary = "%s%d%s" % (infotext, int(sensor["reading"]), unit)
    if extra_info != "":
        summary += " %s" % extra_info
    return {"changed": False,
            "msg": summary,
            "data": {"state": final_state,
                     "metrics": metrics,
                     "details": extra_info}}