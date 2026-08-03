def _parse_battery_table(stdout):
    lines = stdout.splitlines()
    section = {}
    i = 0
    for col_idx in [1, 3, 4]:
        if i < len(lines):
            line = lines[i]
            # -Oqv gives bare value per line
            if line and line != "No Such Instance currently exists" and col_idx != 4:
                section[str(col_idx)] = line
            i += 1
    return section

def _fetch_oids(ctx, host, community, version, base, oids):
    result = {}
    for oid in oids:
        res = ctx.run(
            ["snmpget", "-Oqv", "-c", community, "-v", version, host, base + "." + oid],
            mutates=False,
        )
        val = res.stdout.strip()
        result[oid] = val
    return result

def _is_cps(ctx, host, community, version):
    res = ctx.run(
        ["snmpget", "-Oqv", "-c", community, "-v", version, host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    sys_oid = res.stdout.strip()
    if res.rc != 0 or not sys_oid:
        return False
    return sys_oid.startswith(".1.3.6.1.4.1.3808.1.1.1")

def _grade_lower(value, levels):
    if not levels:
        return "OK"
    warn, crit = levels
    if value < crit:
        return "CRIT"
    if value < warn:
        return "WARN"
    return "OK"

def _grade_upper(value, levels):
    if not levels:
        return "OK"
    warn, crit = levels
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _level_state(state):
    m = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return m.get(state, 3)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    base = ".1.3.6.1.4.1.3808.1.1.1.2.2"

    # Probe: verify this is a CPS UPS via sysObjectID before reporting anything
    if not _is_cps(ctx, host, community, version):
        return {
            "changed": False,
            "msg": "not a CPS UPS (sysObjectID mismatch)",
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        caps = _fetch_oids(ctx, host, community, version, base, ["1", "3", "4"])

        discovery = []

        cap_raw = caps.get("1", "")
        has_capacity = cap_raw != "" and cap_raw != "No Such Instance currently exists"
        if has_capacity:
            discovery.append({
                "item": "",
                "params": {"capacity": (95, 90), "battime": (0, 0)},
                "metrics": ["battery_capacity", "battery_seconds_remaining"],
            })

        temp_raw = caps.get("3", "")
        has_temp = temp_raw != "" and temp_raw != "No Such Instance currently exists" \
            and temp_raw != "NULL"
        if has_temp:
            discovery.append({
                "item": "Battery",
                "params": {"levels": (None, None)},
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")

    # Fetch all needed OIDs for whichever check is requested
    oids_needed = ["1", "4"]
    if item == "Battery":
        oids_needed = ["3"]
    else:
        oids_needed = ["1", "4"]
    data = _fetch_oids(ctx, host, community, version, base, oids_needed)

    if item == "Battery":
        # Temperature check
        temp_raw = data.get("3", "")
        if temp_raw == "" or temp_raw == "No Such Instance currently exists" or temp_raw == "NULL":
            return {
                "changed": False,
                "msg": "No temperature data from UPS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        temperature = int(temp_raw)
        levels = params.get("levels", (None, None))
        warn = levels[0] if len(levels) >= 1 else None
        crit = levels[1] if len(levels) >= 2 else None
        tlvs = []
        if crit != None:
            tlvs.append("crit %dC" % crit)
        if warn != None:
            tlvs.append("warn %dC" % warn)
        levelstext = " (%s)" % ", ".join(tlvs) if tlvs else ""
        state = "OK"
        if crit != None and temperature >= crit:
            state = "CRIT"
        elif warn != None and temperature >= warn:
            state = "WARN"
        return {
            "changed": False,
            "msg": "Temperature: %dC%s" % (temperature, levelstext),
            "data": {
                "state": state,
                "metrics": {"temperature": temperature},
                "details": "",
            },
        }

    # Capacity + battime check (item == "")
    cap_raw = data.get("1", "")
    if cap_raw == "" or cap_raw == "No Such Instance currently exists":
        return {
            "changed": False,
            "msg": "No capacity data from UPS",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    capacity = int(cap_raw)
    capacity_levels = params.get("capacity", (95, 90))
    cap_state = _grade_lower(capacity, capacity_levels)
    warn_c, crit_c = capacity_levels
    cap_text = ""
    if cap_state != "OK":
        cap_text = " (warn/crit at %d/%d%%)" % (warn_c, crit_c)

    bt_raw = data.get("4", "")
    battime_value = 0.0
    if bt_raw != "" and bt_raw != "No Such Instance currently exists":
        battime_value = float(bt_raw) / 100.0
    bt_minutes = battime_value / 60.0
    battime_levels = params.get("battime", (0, 0))
    bt_state = _grade_lower(bt_minutes, battime_levels)
    bt_text = ""
    if bt_state != "OK" and battime_levels != None:
        bt_text = " (warn/crit at %d/%d min)" % (battime_levels[0], battime_levels[1])

    # Summary message: pick the most severe
    states = [cap_state, bt_state]
    severity = max([_level_state(s) for s in states])
    sev_map_inv = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    overall = sev_map_inv.get(severity, "UNKNOWN")

    msg = "Capacity at %d%%%s, %f minutes remaining on battery%s" % (
        capacity, cap_text, bt_minutes, bt_text
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": {
                "battery_capacity": capacity,
                "battery_seconds_remaining": battime_value,
            },
            "details": "",
        },
    }