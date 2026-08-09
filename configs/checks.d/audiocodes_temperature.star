def _is_float(s):
    if not s:
        return False
    body = s
    neg = False
    if body.startswith("-") or body.startswith("+"):
        neg = True
        body = body[1:]
    if body == "":
        return False
    has_dot = False
    digit = False
    for ch in body:
        if ch >= "0" and ch <= "9":
            digit = True
        elif ch == "." and not has_dot:
            has_dot = True
        else:
            return False
    return digit


def _detect_audiocodes(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    out = res.stdout.strip().lower()
    return out.find("audiocodes") != -1 or out.find("audio-codes") != -1


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if not _detect_audiocodes(ctx, host, community):
        if params.get("_discover"):
            return {"changed": False, "msg": "no audiocodes device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no audiocodes device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
    names_base = ".1.3.6.1.4.1.5003.9.10.10.4.21"

    names_walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         host, names_base + ".1"],
        mutates=False,
    )
    module_names = {}
    if names_walk.rc == 0:
        for line in names_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(names_base) + 2:]
            module_names[idx] = parts[1].strip().strip('"')

    temp_walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn",
         host, base + ".11"],
        mutates=False,
    )

    temps = {}
    if temp_walk.rc == 0:
        for line in temp_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(base) + 2:]
            val = parts[1].strip().strip('"')
            if _is_float(val):
                temps[idx] = float(val)

    data_by_idx = {}
    for idx in temps:
        if idx in module_names:
            nm = module_names[idx]
            data_by_idx[nm] = temps[idx]

    if params.get("_discover"):
        discovery = []
        for nm, _t in data_by_idx.items():
            discovery.append({
                "item": nm,
                "params": {},
                "metrics": ["temperature"],
            })
        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    found_temp = None
    for idx, nm in module_names.items():
        if nm == item and idx in temps:
            found_temp = temps[idx]
            break

    if found_temp == None:
        return {"changed": False,
                "msg": "no temperature sensor for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 70.0)
    crit = params.get("crit", 80.0)
    reading = found_temp

    if reading == -1:
        return {"changed": False,
                "msg": "Temperature is not available",
                "data": {"state": "OK", "metrics": {"temperature": 0},
                         "details": ""}}

    st = "OK"
    if reading >= crit:
        st = "CRIT"
    elif reading >= warn:
        st = "WARN"

    return {"changed": False,
            "msg": "Temperature %s: %f C" % (item, reading),
            "data": {"state": st, "metrics": {"temperature": reading},
                     "details": ""}}