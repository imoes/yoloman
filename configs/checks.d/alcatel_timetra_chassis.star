# Translated Checkmk check plugin: checkmk.alcatel_timetra_chassis
# SNMP table of Alcatel-Lucent TiMOS chassis devices.
# Source OIDs (from the Checkmk SNMPTree):
#   base = .1.3.6.1.4.1.6527.3.1.2.2.1.8.1
#   columns: 8 = name, 15 = adminState, 16 = operState, 24 = alarmState
# Detection: sysDescr (.1.3.6.1.2.1.1.1.0) contains "TiMOS".

def main(ctx, params):
    # ---- discovery: walk the SNMP table via snmpwalk -Oqn ----
    base_oid = "1.3.6.1.4.1.6527.3.1.2.2.1.8.1"
    name_col = base_oid + ".8"
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Verify the device is actually a TiMOS system first.
        sysdesc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysdesc.rc != 0 or "TiMOS" not in sysdesc.stdout:
            return {"changed": False, "msg": "no TiMOS device found",
                    "data": {"discovery": []}}
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no chassis devices found",
                    "data": {"discovery": []}}
        rows = {}
        prefix_len = len(name_col) + 1  # +1 for the trailing dot
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp <= prefix_len:
                continue
            full_oid = line[:sp]
            index = full_oid[prefix_len:]
            rows[index] = line[sp + 1:]
        discovery = []
        for index in sorted(rows.keys()):
            name = rows[index]
            oper_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 base_oid + ".16." + index],
                mutates=False,
            )
            if oper_res.rc != 0:
                continue
            operstate = oper_res.stdout.strip()
            if operstate in ["2", "8"]:
                discovery.append({"item": name, "params": {},
                                  "metrics": []})
        return {"changed": False, "msg": "discovered %d devices" % len(discovery),
                "data": {"discovery": discovery}}

    # ---- check mode: evaluate a single device ----
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    admin_states = {
        1: ("OK", "noop"),
        2: ("OK", "in service"),
        3: ("WARN", "out of service"),
        4: ("CRIT", "diagnose"),
        5: ("CRIT", "operate switch"),
    }
    oper_states = {
        1: ("UNKNOWN", "unknown"),
        2: ("OK", "in service"),
        3: ("CRIT", "out of service"),
        4: ("WARN", "diagnosing"),
        5: ("CRIT", "failed"),
        6: ("WARN", "booting"),
        7: ("UNKNOWN", "empty"),
        8: ("OK", "provisioned"),
        9: ("UNKNOWN", "unprovisioned"),
        10: ("WARN", "upgrade"),
        11: ("WARN", "downgrade"),
        12: ("WARN", "in service upgrade"),
        13: ("WARN", "in service downgrade"),
        14: ("WARN", "reset pending"),
    }
    alarm_states = {
        0: ("OK", "unknown"),
        1: ("CRIT", "alarm active"),
        2: ("OK", "alarm cleared"),
    }

    # Find the device index whose name column matches the requested item.
    sysdesc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdesc.rc != 0 or "TiMOS" not in sysdesc.stdout:
        return {"changed": False, "msg": "no TiMOS device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no chassis devices found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    target_index = None
    prefix_len = len(name_col) + 1
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp <= prefix_len:
            continue
        full_oid = line[:sp]
        index = full_oid[prefix_len:]
        if line[sp + 1:] == item:
            target_index = index
            break
    if target_index == None:
        return {"changed": False, "msg": "no such device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _get_int(col_oid):
        r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             base_oid + "." + str(col_oid) + "." + target_index],
            mutates=False,
        )
        return int(r.stdout.strip()) if r.rc == 0 and r.stdout.strip().isdigit() else None

    adminstate = _get_int(15)
    operstate = _get_int(16)
    alarmstate = _get_int(24)
    if adminstate == None or operstate == None or alarmstate == None:
        return {"changed": False,
                "msg": "could not read state for device %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    details = []
    state = "OK"
    if operstate != adminstate:
        a = admin_states.get(adminstate, ("UNKNOWN", "unknown"))
        details.append("Admin state: %s" % a[1])
        if a[0] == "CRIT":
            state = "CRIT"
        elif a[0] == "WARN" and state != "CRIT":
            state = "WARN"
    o = oper_states.get(operstate, ("UNKNOWN", "unknown"))
    details.append("Operational state: %s" % o[1])
    if o[0] == "CRIT":
        state = "CRIT"
    elif o[0] == "WARN" and state != "CRIT":
        state = "WARN"
    elif o[0] == "UNKNOWN" and state == "OK":
        state = "UNKNOWN"
    al = alarm_states.get(alarmstate, ("OK", "unknown"))
    details.append("Alarm state: %s" % al[1])
    if al[0] == "CRIT":
        state = "CRIT"

    summary = "Operational state: %s" % o[1]
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": "; ".join(details)}}