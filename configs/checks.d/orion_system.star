# Translated from Checkmk check mk.orion_system (SNMP: Orion/Phasor energy
# system). Read-only: discovers one Temperature / Charge / Direct Current
# service per entity and reports its state against operator-supplied levels.

def _snmpget(ctx, host, community, oid):
    return ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, oid
    ], mutates=False)

def _snmpwalk(ctx, host, community, oid):
    return ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid
    ], mutates=False)

# SNMP base OID for the Orion system table.
BASE_OID = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
# Column OIDs (relative to BASE_OID) per the source plugin's oids list.
COL = {
    "system_voltage":        "1",
    "load_current":          "2",
    "battery_current":       "3",
    "battery_temp":          "4",
    "charge_state":          "5",
    "battery_current_limit": "6",
    "rectifier_current":     "7",
    "system_power":          "8",
}
# Sentinel meaning "no value" in the firmware.
NO_VALUE = "2147483647"

CHARGE_STATES = {
    "1": (0, "float charging"),
    "2": (0, "discharge"),
    "3": (0, "equalize"),
    "4": (0, "boost"),
    "5": (0, "battery test"),
    "6": (0, "recharge"),
    "7": (0, "separate charge"),
    "8": (0, "event control charge"),
}

def _to_float(raw):
    if raw == None:
        return None
    s = raw.strip()
    if s == NO_VALUE or s == "":
        return None
    if not s.replace("-", "").replace("+", "").isdigit() and not s.endswith(".0") and not (s.startswith("-") and s[1:].replace("-", "").isdigit()):
        return None
    n = float(s)
    return n

def main(ctx, params):
    discover = params.get("_discover", False)
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    plugin = params.get("_plugin", "orion_system_temp")

    # Probe: is this an Orion device? The source checks the sysObjectID prefix.
    sysid = _snmpget(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysid.rc != 0 or sysid.stdout == None or \
       not sysid.stdout.strip().startswith(".1.3.6.1.4.1.20246"):
        if discover:
            return {"changed": False, "msg": "no Orion system found",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "no Orion system (" + plugin + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk the whole table once; rows identified by index suffix.
    rows = {}
    for col in COL:
        res = _snmpwalk(ctx, host, community, BASE_OID + "." + COL[col])
        if res.rc != 0 or res.stdout == None or res.stdout.strip() == "":
            continue
        for line in res.stdout.strip().splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid_full = line[:sp]
            val = line[sp + 1:]
            idx = oid_full[len(BASE_OID + "." + COL[col]) + 1:]
            if idx not in rows:
                rows[idx] = {}
            rows[idx][col] = val

    # No rows -> nothing to report.
    if not rows:
        if discover:
            return {"changed": False, "msg": "no Orion system rows",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no Orion system (" + plugin + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse each row into the section structure used by the source plugin.
    parsed = {}
    for idx, row in rows.items():
        sv = _to_float(row.get("system_voltage", NO_VALUE))
        lc = _to_float(row.get("load_current", NO_VALUE))
        bc = _to_float(row.get("battery_current", NO_VALUE))
        bt = _to_float(row.get("battery_temp", NO_VALUE))
        cs = row.get("charge_state", "")
        sp_v = _to_float(row.get("system_power", NO_VALUE))
        rc = _to_float(row.get("rectifier_current", NO_VALUE))

        temperature = {}
        if bt != None:
            temperature["Battery"] = bt * 0.1

        electrical = {}
        for what, value, factor in [
            ("voltage", sv, 0.01),
            ("current", lc, 0.1),
            ("power", sp_v, 1),
        ]:
            if value != None:
                sd = electrical.setdefault("System", {})
                sd[what] = value * factor

        for name, value in [("Battery", bc), ("Rectifier", rc)]:
            if value != None:
                idata = electrical.setdefault(name, {})
                idata["current"] = value * 0.1

        charging = {"Battery": CHARGE_STATES.get(cs, (3, "unknown[%s]" % cs))}

        parsed[idx] = {
            "temperature": temperature,
            "electrical": electrical,
            "charging": charging,
        }

    # ---- DISCOVERY ----
    if discover:
        if plugin == "orion_system_charging":
            out = []
            for idx, sec in parsed.items():
                for entity in sec["charging"]:
                    out.append({"item": entity, "params": {}, "metrics": []})
            return {"changed": False,
                    "msg": "discovered %d items" % len(out),
                    "data": {"discovery": out}}

        if plugin == "orion_system_dc":
            out = []
            for idx, sec in parsed.items():
                for entity in sec["electrical"]:
                    out.append({"item": entity, "params": {},
                                "metrics": ["power", "current", "voltage"]})
            return {"changed": False,
                    "msg": "discovered %d items" % len(out),
                    "data": {"discovery": out}}

        # default: temperature
        out = []
        for idx, sec in parsed.items():
            for entity in sec["temperature"]:
                warn = params.get("warn", 35)
                crit = params.get("crit", 40)
                out.append({"item": entity,
                            "params": {"warn": warn, "crit": crit},
                            "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # ---- CHECK ----
    match_idx = None
    for idx, sec in parsed.items():
        if plugin == "orion_system_charging":
            if item in sec["charging"]:
                match_idx = idx
                break
        elif plugin == "orion_system_dc":
            if item in sec["electrical"]:
                match_idx = idx
                break
        else:
            if item in sec["temperature"]:
                match_idx = idx
                break

    if match_idx == None:
        return {"changed": False,
                "msg": "no such item: " + str(item) + " (" + plugin + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sec = parsed[match_idx]

    if plugin == "orion_system_temp":
        if item in sec["temperature"]:
            value = sec["temperature"][item]
            warn = params.get("warn", 35)
            crit = params.get("crit", 40)
            state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
            return {"changed": False,
                    "msg": "Temperature %s: %f C" % (item, value),
                    "data": {"state": state,
                             "metrics": {"temperature": value},
                             "details": ""}}
        return {"changed": False, "msg": "no temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if plugin == "orion_system_charging":
        if item in sec["charging"]:
            state_int, state_readable = sec["charging"][item]
            st = ["OK", "WARN", "CRIT", "UNKNOWN"][state_int] \
                 if 0 <= state_int and state_int <= 3 else "UNKNOWN"
            return {"changed": False,
                    "msg": "Charge %s: %s" % (item, state_readable),
                    "data": {"state": st, "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no charging state for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # orion_system_dc
    if item in sec["electrical"]:
        e = sec["electrical"][item]
        power = e.get("power", 0.0)
        current = e.get("current", 0.0)
        voltage = e.get("voltage", 0.0)
        warn = params.get("warn", 0)
        crit = params.get("crit", 0)
        state = "OK"
        if power != None:
            if crit != 0 and power >= crit:
                state = "CRIT"
            elif warn != 0 and power >= warn:
                state = "WARN"
        return {"changed": False,
                "msg": "Direct Current %s: %f W" % (item, power),
                "data": {"state": state,
                         "metrics": {"power": power,
                                     "current": current,
                                     "voltage": voltage},
                         "details": ""}}
    return {"changed": False, "msg": "no electrical data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}