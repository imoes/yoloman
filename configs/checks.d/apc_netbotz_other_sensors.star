def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_v2 = ".1.3.6.1.4.1.5528.100.4.2.10.1"
    base_50 = ".1.3.6.1.4.1.52674.500.4.2.10.1"

    # Probe for the real thing: check sysObjectID to identify APC NetBotz devices.
    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no APC NetBotz device found (snmp unreachable)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no APC NetBotz device found (snmp unreachable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysoid = sysoid_res.stdout.strip()
    is_v2 = sysoid.startswith(".1.3.6.1.4.1.5528.100.20.10")
    is_50 = sysoid.startswith(".1.3.6.1.4.1.52674.500")
    if not (is_v2 or is_50):
        if params.get("_discover"):
            return {"changed": False, "msg": "no APC NetBotz device found (sysoid mismatch)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no APC NetBotz device found (sysoid mismatch)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = base_v2 if is_v2 else base_50

    label_oid = base + ".4"
    error_oid = base + ".3"
    state_oid = base + ".7"

    labels_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, label_oid],
        mutates=False,
    )
    errors_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, error_oid],
        mutates=False,
    )
    states_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, state_oid],
        mutates=False,
    )

    sensors = []
    for line in labels_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, label = parts
        idx = oid[len(label_oid) + 1:]
        sensors.append({"label": label, "error_state": "", "state_readable": "", "idx": idx})

    for line in errors_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        idx = oid[len(error_oid) + 1:]
        for s in sensors:
            if s["idx"] == idx:
                s["error_state"] = value
                break

    for line in states_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        idx = oid[len(state_oid) + 1:]
        for s in sensors:
            if s["idx"] == idx:
                s["state_readable"] = value
                break

    if params.get("_discover"):
        discovery = []
        for s in sensors:
            if s["state_readable"] != "":
                discovery.append({"item": s["label"], "params": {},
                                  "metrics": ["sensors_ok"]})
        return {"changed": False, "msg": "discovered %d sensor(s)" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    target = None
    for s in sensors:
        if s["label"] == item:
            target = s
            break

    if target == None:
        return {"changed": False, "msg": "no sensor with label: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    count_ok = 0
    details = ""
    for s in sensors:
        if s["state_readable"] != "":
            if s["error_state"] == "0":
                count_ok += 1
            else:
                state_readable = s["state_readable"].lower()
                details = details + s["label"] + ": " + state_readable + "\n"

    if count_ok > 0:
        details = str(count_ok) + " sensors are OK\n" + details
        return {"changed": False, "msg": details.strip(),
                "data": {"state": "OK", "metrics": {"sensors_ok": count_ok}, "details": details}}

    return {"changed": False, "msg": "no sensors OK",
            "data": {"state": "CRIT", "metrics": {"sensors_ok": 0}, "details": details}}