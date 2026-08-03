# cmk/plugins/akcp/agent_based/akcp_sensor_humidity.py -> Starlark (read-only)
# Humidity sensor check for AKCP devices via SNMP.

def _snmpget_oid(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmpwalk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 1:
            continue
        out.append((line[:sp], line[sp + 1:]))
    return out

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # SPAGENT-MIB ent (sysObjectID) must start with the AKCP enterprise prefix.
    sys_oid = _snmpget_oid(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None:
        # Device not present / unreachable -> absent answer.
        return {
            "changed": False,
            "msg": "no akcp device reachable",
            "data": {"discovery": []},
        }
    if not sys_oid.startswith(".1.3.6.1.4.1.3854"):
        return {
            "changed": False,
            "msg": "no akcp device reachable",
            "data": {"discovery": []},
        }

    base_sp = ".1.3.6.1.4.1.3854.1.2.2.1.17.1"
    base_sp2 = ".1.3.6.1.4.1.3854.3.5.3.1"

    # Column OIDs (suffix appended to base).
    c_desc_sp = "1"
    c_pct_sp = "3"
    c_stat_sp = "4"
    c_online_sp = "5"
    c_desc_sp2 = "2"
    c_pct_sp2 = "4"
    c_stat_sp2 = "6"
    c_online_sp2 = "8"

    # Detect SP2+ variant: requires .3854.3.* and must NOT have .3854.2.*.
    sp2plus_only = sys_oid.startswith(".1.3.6.1.4.1.3854.") and not sys_oid.startswith(".1.3.6.1.4.1.3854.1")

    is_sp2plus = False
    has_child2 = _snmpget_oid(ctx, host, community, ".1.3.6.1.4.1.3854.2") != None
    has_child3 = _snmpget_oid(ctx, host, community, ".1.3.6.1.4.1.3854.3") != None
    if sp2plus_only and has_child3 and not has_child2:
        is_sp2plus = True

    if params.get("_discover"):
        discovery = []
        if is_sp2plus:
            walk = _snmpwalk(ctx, host, community, base_sp2 + "." + c_desc_sp2)
            for oid, desc in walk:
                idx = oid[len(base_sp2) + len(c_desc_sp2) + 1:]
                online = _snmpget_oid(ctx, host, community, base_sp2 + "." + c_online_sp2 + "." + idx)
                if online == None:
                    continue
                if online == "1":
                    discovery.append({
                        "item": desc,
                        "params": {
                            "levels": (60.0, 65.0),
                            "levels_lower": (30.0, 35.0),
                        },
                        "metrics": ["humidity"],
                    })
        else:
            walk = _snmpwalk(ctx, host, community, base_sp + "." + c_desc_sp)
            for oid, desc in walk:
                idx = oid[len(base_sp) + len(c_desc_sp) + 1:]
                online = _snmpget_oid(ctx, host, community, base_sp + "." + c_online_sp + "." + idx)
                if online == None:
                    continue
                if online == "1":
                    discovery.append({
                        "item": desc,
                        "params": {
                            "levels": (60.0, 65.0),
                            "levels_lower": (30.0, 35.0),
                        },
                        "metrics": ["humidity"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    levels = params.get("levels", (60.0, 65.0))
    levels_lower = params.get("levels_lower", (30.0, 35.0))
    warn_hi = levels[0]
    crit_hi = levels[1]
    warn_lo = levels_lower[0]
    crit_lo = levels_lower[1]

    sensor_level_states = {
        "1": (2, "no status"),
        "2": (0, "normal"),
        "3": (1, "high warning"),
        "4": (2, "high critical"),
        "5": (1, "low warning"),
        "6": (2, "low critical"),
        "7": (2, "sensor error"),
    }

    if is_sp2plus:
        base = base_sp2
        c_desc = c_desc_sp2
        c_pct = c_pct_sp2
        c_stat = c_stat_sp2
        c_online = c_online_sp2
    else:
        base = base_sp
        c_desc = c_desc_sp
        c_pct = c_pct_sp
        c_stat = c_stat_sp
        c_online = c_online_sp

    walk = _snmpwalk(ctx, host, community, base + "." + c_desc)
    idx = None
    for oid, desc in walk:
        if desc == item:
            idx = oid[len(base + "." + c_desc) + 1:]
            break

    if idx == None:
        return {
            "changed": False,
            "msg": "no such humidity sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    online = _snmpget_oid(ctx, host, community, base + "." + c_online + "." + idx)
    percent = _snmpget_oid(ctx, host, community, base + "." + c_pct + "." + idx)
    status = _snmpget_oid(ctx, host, community, base + "." + c_stat + "." + idx)

    details_lines = []
    overall = 0

    if online == None or online != "1":
        overall = 2
        details_lines.append("sensor is offline")
    if online == None:
        details_lines.append("online state not readable")

    if status != None and status in ["1", "7"]:
        s, state_name = sensor_level_states[status]
        if s > overall:
            overall = s
        details_lines.append("State: " + state_name)

    if percent == None or percent == "":
        if overall == 0:
            overall = 3
            details_lines.append("humidity value not readable")
        state_name = "OK"
        if overall == 1:
            state_name = "WARN"
        elif overall == 2:
            state_name = "CRIT"
        elif overall == 3:
            state_name = "UNKNOWN"
        msg = "%s %s" % (item, "; ".join(details_lines))
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state_name, "metrics": {}, "details": "\n".join(details_lines)},
        }

    pct_val = None
    if percent.isdigit():
        pct_val = int(percent)
    else:
        pct_val = None

    if pct_val != None:
        if pct_val >= crit_hi:
            overall = 2 if overall < 2 else overall
        elif pct_val >= warn_hi:
            if overall < 1:
                overall = 1
        if pct_val <= crit_lo:
            overall = 2 if overall < 2 else overall
        elif pct_val <= warn_lo:
            if overall < 1:
                overall = 1

    # Build summary string.
    pct_str = "%d" % pct_val if pct_val != None else "n/a"
    msg = "%s: %s%%" % (item, pct_str)

    state_name = "OK"
    if overall == 1:
        state_name = "WARN"
    elif overall == 2:
        state_name = "CRIT"
    elif overall == 3:
        state_name = "UNKNOWN"

    metrics = {}
    if pct_val != None:
        metrics["humidity"] = pct_val

    details = "\n".join(details_lines) if details_lines else ""

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state_name, "metrics": metrics, "details": details},
    }