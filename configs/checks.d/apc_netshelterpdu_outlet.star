def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.318.1.1.32.5.5.1"

    def walk_column(suffix):
        oid = base + "." + suffix
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
        out = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            loid = line[:sp]
            val = line[sp + 1:]
            if not loid.startswith(oid):
                continue
            idx = loid[len(oid) + 1:]
            out[idx] = val
        return out

    if params.get("_discover"):
        sysname_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysname_res.rc != 0:
            return {"changed": False, "msg": "no APC NetShelter PDU detected", "data": {"discovery": []}}
        sys_oid = sysname_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.318.1.1.32"):
            return {"changed": False, "msg": "no APC NetShelter PDU detected", "data": {"discovery": []}}

        idx_col = walk_column("2")
        status_col = walk_column("4")
        discovery = []
        for idx in idx_col:
            status = status_col.get(idx, "")
            if status == "2":
                discovery.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d outlets" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    name_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3." + item], mutates=False)
    status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4." + item], mutates=False)
    if name_res.rc != 0 or status_res.rc != 0:
        return {"changed": False, "msg": "no such outlet: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name = name_res.stdout.replace("\x00", "").strip()
    status_raw = status_res.stdout.strip()
    status = status_raw

    if status == "2":
        state = "OK"
        readable = "on"
    elif status == "1":
        state = "WARN"
        readable = "off"
    else:
        state = "UNKNOWN"
        readable = "unknown" if not status else "unknown (" + status + ")"

    return {"changed": False, "msg": name + ": " + readable, "data": {"state": state, "metrics": {}, "details": ""}}