def main(ctx, params):
    _STATUS_NAME = {1: "CRIT", 2: "OK", 3: "WARN", 4: "CRIT"}
    _STATUS_READABLE = {1: "Other", 2: "Ok", 3: "Degraded", 4: "Failed"}
    _ROLE_MAP = {1: "standby", 2: "active"}

    if params.get("_discover"):
        # Probe: is this an HPE blade system? Use sysDescr to confirm the
        # CPQRack (232) enterprise MIB is present.
        descr = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if descr.rc != 0:
            return {"changed": False, "msg": "no SNMP response / not HP blade system",
                    "data": {"discovery": []}}
        sys_oid = str(descr.stdout).strip()
        if not (sys_oid.startswith(".1.3.6.1.4.1.232.") and "5.7.1.2" in sys_oid):
            return {"changed": False,
                    "msg": "sysObjectID does not match HP blade enclosure",
                    "data": {"discovery": []}}

        index_col = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.232.22.2.3.1.6.1.3"],
            mutates=False)
        if index_col.rc != 0 or not index_col.stdout.strip():
            return {"changed": False,
                    "msg": "no enclosure manager index found",
                    "data": {"discovery": []}}

        role_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.232.22.2.3.1.6.1.10"],
            mutates=False)
        role_vals = _parse_walk(role_res.stdout) if role_res.rc == 0 else {}

        out = []
        for line in index_col.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            idx = oid_full[len(".1.3.6.1.4.1.232.22.2.3.1.6.1.3") + 1:]
            if not idx:
                continue
            role = role_vals.get(idx, "")
            out.append({"item": idx,
                        "params": {"role": str(role)},
                        "metrics": ["enclosure_manager_condition"]})

        return {"changed": False,
                "msg": "discovered %d enclosure managers" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE
    item = params.get("item", "")
    idx = item

    def _get(oid_suffix):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.232.22.2.3.1.6.1." + oid_suffix + "." + idx],
            mutates=False)
        if res.rc != 0:
            return ""
        return str(res.stdout).strip()

    role_raw = _get("10")
    cond_raw = _get("12")
    serial = _get("8")

    if role_raw == "" and cond_raw == "":
        return {"changed": False,
                "msg": "no data for enclosure manager item %s" % item,
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "SNMP get failed for manager indices"}}

    raw_state = 2 if cond_raw == "0" else (int(cond_raw) if cond_raw.isdigit() else 2)
    st_name = _STATUS_NAME.get(raw_state, "UNKNOWN")
    readable = _STATUS_READABLE.get(raw_state, "Unknown")

    expected_role = params.get("role", role_raw)
    role_int = int(role_raw) if role_raw.isdigit() else 0
    exp_int = int(expected_role) if str(expected_role).isdigit() else 0
    role_name = _ROLE_MAP.get(role_int, "unknown")
    exp_role_name = _ROLE_MAP.get(exp_int, "unknown")

    if role_raw != "" and expected_role != "" and role_raw != expected_role:
        return {"changed": False,
                "msg": "Unexpected role: %s (Expected: %s)" % (role_name, exp_role_name),
                "data": {"state": "CRIT",
                         "metrics": {},
                         "details": ""}}

    return {"changed": False,
            "msg": "Enclosure Manager condition is %s (Role: %s, S/N: %s)" % (readable, role_name, serial),
            "data": {"state": st_name,
                     "metrics": {"enclosure_manager_condition": raw_state},
                     "details": ""}}


def _parse_walk(stdout):
    result = {}
    base = ".1.3.6.1.4.1.232.22.2.3.1.6.1.10"
    for line in stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid = sp[0]
        val = sp[1]
        dot = oid.rfind(".")
        if dot <= 0:
            continue
        idx = oid[dot + 1:]
        result[idx] = val
    return result