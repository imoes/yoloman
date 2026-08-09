def _warn_from_levels(params):
    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        return levels[0]
    return 90.0

def _crit_from_levels(params):
    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        return levels[1]
    return 95.0

def _grade_cpu(cpu_util, warn, crit):
    # upper-level thresholds: WARN at >= warn, CRIT at >= crit
    if cpu_util >= crit:
        return "CRIT"
    if cpu_util >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                           params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0:
            return {"changed": False, "msg": "Arris CMTS not detected (no sysObjectID)",
                    "data": {"discovery": []}}
        sys_oid = sys_oid.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.4998.2.1":
            return {"changed": False, "msg": "Arris CMTS not detected (sysObjectID mismatch)",
                    "data": {"discovery": []}}
        walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                        params.get("host", "localhost"), ".1.3.6.1.4.1.4998.1.1.5.3.1.1.1"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "Arris CMTS CPU table walk failed",
                    "data": {"discovery": []}}
        discovery = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            suffix = oid[len(".1.3.6.1.4.1.4998.1.1.5.3.1.1.1") + 1:]
            # The index is the full OID suffix; cpu_id is the second column value
            rest = line[sp + 1:].strip()
            cols = rest.split(" ", 1)
            cpu_id = cols[0].strip()
            item = cpu_id if cpu_id != "" else suffix
            discovery.append({"item": item, "params": {"levels": (90.0, 95.0)},
                              "metrics": ["cpu_util"]})
        return {"changed": False, "msg": "discovered %d CPU modules" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Re-walk to find the matching row and its idle util
    sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
                       params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_oid.rc != 0:
        return {"changed": False, "msg": "Arris CMTS not detected (no sysObjectID)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = sys_oid.stdout.strip()
    if sys_oid != ".1.3.6.1.4.1.4998.2.1":
        return {"changed": False, "msg": "Arris CMTS not detected (sysObjectID mismatch)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
                    params.get("host", "localhost"), ".1.3.6.1.4.1.4998.1.1.5.3.1.1.1"], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "Arris CMTS CPU table walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found = False
    cpu_util = None
    base = ".1.3.6.1.4.1.4998.1.1.5.3.1.1.1"
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        suffix = oid[len(base) + 1:]
        rest = line[sp + 1:].strip()
        # SNMP tree columns: OIDEnd (index), 1 (cpu_id), 8 (cpu_idle_util)
        # The walk returns rows indexed by the full OID suffix (index)
        # We need cpu_id (col 1) and idle util (col 8) per index.
        # Since -Oqn walk gives base.index.value, the value here is whichever column.
        # We determine the column by the last sub-identifier of the OID before the index.
        # But the base already includes the column OIDs as fixed trailing nodes below it.
        # Actually base=.1.3.6.1.4.1.4998.1.1.5.3.1.1.1, columns are appended: .1 (cpu_id), .8 (idle)
        # So oid = base + "." + index + "." + col. We split out col.
        parts = oid[len(base) + 1:].split(".")
        if len(parts) < 2:
            continue
        col = parts[-1]
        idx = ".".join(parts[:-1])
        cpu_id_val = ""
        idle_val = ""
        if col == "1":
            cpu_id_val = rest
        elif col == "8":
            idle_val = rest
        # We need to pair cols; do a two-pass by re-reading. Simpler: build a dict.
        # Use a local dict to accumulate per index.
        if not hasattr(main, "_rows"):
            main._rows = {}
        main._rows[idx] = main._rows.get(idx, {})
        if col == "1":
            main._rows[idx]["cpu_id"] = rest
        elif col == "8":
            main._rows[idx]["idle"] = rest
    # Actually the above won't work across calls with the loop; redo cleanly:
    rows = {}
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        suffix = oid[len(base) + 1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[-1]
        idx = ".".join(parts[:-1])
        rest = line[sp + 1:].strip()
        d = rows.get(idx, {})
        if col == "1":
            d["cpu_id"] = rest
        elif col == "8":
            d["idle"] = rest
        rows[idx] = d
    for idx in rows:
        d = rows[idx]
        cpu_id = d.get("cpu_id", "")
        citem = cpu_id if cpu_id != "" else idx
        if citem == item:
            idle_str = d.get("idle", "")
            try_idle = idle_str.replace('"', "").strip()
            idle_val = float(try_idle) if try_idle.replace(".", "", 1).isdigit() else 0.0
            cpu_util = 100.0 - idle_val
            found = True
            break
    if not found:
        return {"changed": False, "msg": "CPU module not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    warn = _warn_from_levels(params)
    crit = _crit_from_levels(params)
    state = _grade_cpu(cpu_util, warn, crit)
    return {"changed": False, "msg": "CPU utilization Module %s: %f%% used" % (item, cpu_util),
            "data": {"state": state, "metrics": {"cpu_util": cpu_util}, "details": ""}}