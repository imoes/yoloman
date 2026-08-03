# ===== translated Starlark check module: decru_fans =====
# FAN monitor for Decru (datafort) storage appliances, via SNMP.
# Discovery item = the fan-name column value; metrics = rpm.

def main(ctx, params):
    # --- discovery mode ---
    if params.get("_discover"):
        # Prove the real thing is here: a Decru (datafort) appliance via SNMP sysDescr.
        oid_descr = ".1.3.6.1.2.1.1.1.0"
        sysdesc = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", "-OQv", params.get("host", "localhost"), oid_descr],
            mutates=False)
        if sysdesc.rc != 0 or "datafort" not in (sysdesc.stdout or ""):
            return {"changed": False, "msg": "no Decru datafort appliance found",
                    "data": {"discovery": []}}

        # Read the fan table: column 2 = name (index), column 3 = rpm value.
        # -Oqn => "<OID>.<index> <value>" per row, bare numeric OID, no type tag.
        base = ".1.3.6.1.4.1.12962.1.2.3.1"
        name_col = base + ".2"
        rpm_col = base + ".3"
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-OQv", params.get("host", "localhost"), name_col],
            mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no Decru fans found",
                    "data": {"discovery": []}}

        discovery = []
        for line in res.stdout.split("\n"):
            if not line.strip():
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            line_oid = line[:sp]
            idx = line_oid[len(name_col) + 1:]
            if not idx:
                continue
            name = line[sp + 1:]
            discovery.append({"item": name, "metrics": ["rpm"]})

        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # --- check mode ---
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.12962.1.2.3.1"
    name_col = base + ".2"
    rpm_col = base + ".3"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Find the numeric index for this fan name.
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-OQv", host, name_col],
                  mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no Decru fans found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    index = None
    for line in res.stdout.split("\n"):
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        line_oid = line[:sp]
        name = line[sp + 1:]
        if name == item:
            index = line_oid[len(name_col) + 1:]
            break

    if index == None or index == "":
        return {"changed": False, "msg": "fan not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the rpm for this index (query by numeric index, never by name).
    get = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-OQv", host,
                   rpm_col + "." + index], mutates=False)
    if get.rc != 0 or not get.stdout.strip():
        return {"changed": False, "msg": "could not read rpm for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = get.stdout.strip()
    if not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid rpm value for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rpm = int(raw)
    levels_lower = params.get("levels_lower", (8400, 8000))
    warn = levels_lower[0] if len(levels_lower) > 0 else 8400
    crit = levels_lower[1] if len(levels_lower) > 1 else 8000

    state = "OK"
    if rpm <= crit:
        state = "CRIT"
    elif rpm <= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "FAN %s: %d rpm" % (item, rpm),
            "data": {"state": state, "metrics": {"rpm": rpm}, "details": ""}}