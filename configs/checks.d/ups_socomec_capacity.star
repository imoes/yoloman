# Translated Checkmk check: ups_socomec_capacity (Battery capacity)
# Reads Socomec UPS SNMP data directly via net-snmp; read-only, never mutates.

def _detect_socomec(ctx, host, community):
    # Verify the device at sysObjectID matches Socomec (.1.3.6.1.4.1.4555.1.1.1)
    res = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return False
    oid = res.stdout.strip()
    return oid == ".1.3.6.1.2.1.1.2.0 = .1.3.6.1.4.1.4555.1.1.1" or oid.endswith(".1.3.6.1.4.1.4555.1.1.1")

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.4555.1.1.1.1.2"

    if params.get("_discover"):
        if not _detect_socomec(ctx, host, community):
            return {"changed": False, "msg": "Socomec UPS not detected", "data": {"discovery": []}}

        # Walk the three OIDs the SNMPTree fetches: .2 (.uptime), .3 (minutes_left), .4 (percent_fuel)
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Ovqn", host, base + ".2"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no Socomec UPS capacity data", "data": {"discovery": []}}

        # Single-service check (no per-item breakdown)
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"battime": (0, 0), "capacity": (95, 90)}, "metrics": ["capacity", "percent"]},
            ]},
        }

    item = params.get("item", "")

    if not _detect_socomec(ctx, host, community):
        return {"changed": False, "msg": "Socomec UPS not detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch the three scalars: upsSecondsOnBattery(.2), upsEstimatedMinutesRemaining(.3), upsEstimatedChargeRemaining(.4)
    time_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".2"], mutates=False)
    min_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3"], mutates=False)
    cap_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4"], mutates=False)

    if time_res.rc != 0 or min_res.rc != 0 or cap_res.rc != 0:
        return {"changed": False, "msg": "failed to read Socomec UPS capacity OIDs", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_time = time_res.stdout.strip()
    raw_min = min_res.stdout.strip()
    raw_cap = cap_res.stdout.strip()
    if raw_time == "" or raw_min == "" or raw_cap == "":
        return {"changed": False, "msg": "empty value from Socomec UPS", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    time_on_bat = int(raw_time)
    minutes_left = int(raw_min)
    percent_fuel = int(raw_cap)

    # Threshold params (Checkmk defaults: battime=(0,0), capacity=(95,90))
    battime = params.get("battime", (0, 0))
    warn, crit = battime[0], battime[1]
    capacity = params.get("capacity", (95, 90))
    cap_warn, cap_crit = capacity[0], capacity[1]

    details_parts = []

    # Battery time left check
    minutes_state = "OK"
    levelsinfo = ""
    if minutes_left != -1:
        if minutes_left <= crit:
            minutes_state = "CRIT"
            levelsinfo = " (crit at %d min)" % cap_crit
        elif minutes_left < warn:
            minutes_state = "WARN"
            levelsinfo = " (warn at %d min)" % cap_warn
        else:
            minutes_state = "OK"
        details_parts.append("%d min left on battery%s" % (minutes_left, levelsinfo))

    # Capacity percentage check
    cap_state = "OK"
    cap_levelsinfo = ""
    if percent_fuel <= cap_crit:
        cap_state = "CRIT"
        cap_levelsinfo = " (crit at %d%%)" % cap_crit
    elif percent_fuel < cap_warn:
        cap_state = "WARN"
        cap_levelsinfo = " (warn at %d%%)" % cap_warn
    else:
        cap_state = "OK"
    details_parts.append("capacity: %d%%%s" % (percent_fuel, cap_levelsinfo))

    # Time on battery informational output
    if time_on_bat > 0:
        details_parts.append("On battery for %d min" % time_on_bat)

    # Overall state: worst of the two graded checks
    state_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    final_state = "OK"
    for s in [minutes_state, cap_state]:
        if state_order.get(s, 0) > state_order.get(final_state, 0):
            final_state = s

    metrics = {}
    if minutes_left != -1:
        metrics["capacity"] = float(minutes_left)
    metrics["percent"] = float(percent_fuel)
    if time_on_bat > 0:
        metrics["time_on_battery"] = float(time_on_bat)

    msg = "; ".join(details_parts)
    return {"changed": False, "msg": msg, "data": {"state": final_state, "metrics": metrics, "details": msg}}