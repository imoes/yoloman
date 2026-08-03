def main(ctx, params):
    base = ".1.3.6.1.4.1.3375.2.1.13.4.2.1"
    name_oid = "1"
    prompt_oid = "17"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_obj = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_obj.rc == 127 or sys_obj.rc != 0:
        return {"changed": False, "msg": "SNMP not available or host not an F5 BIG-IP", "data": {"discovery": []}}
    sys_objid = (sys_obj.stdout or "").strip()
    if not sys_objid or "3.6.1.4.1.3375.2" not in sys_objid:
        return {"changed": False, "msg": "Host is not an F5 BIG-IP device", "data": {"discovery": []}}

    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + name_oid], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no vCMP guests found", "data": {"discovery": []}}
        guests = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            if not oid.startswith(base + "." + name_oid + "."):
                continue
            index = oid[len(base + "." + name_oid) + 1:]
            if not index:
                continue
            val = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + prompt_oid + "." + index], mutates=False)
            status = (val.stdout or "").strip().lower()
            name_val = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + name_oid + "." + index], mutates=False)
            guest_name = (name_val.stdout or "").strip()
            if not guest_name:
                guest_name = index
            guests.append({"item": guest_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d guests" % len(guests), "data": {"discovery": guests}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + name_oid], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no vCMP guests found on " + host, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_guest = None
    found_status = ""
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        if not oid.startswith(base + "." + name_oid + "."):
            continue
        index = oid[len(base + "." + name_oid) + 1:]
        if not index:
            continue
        val = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + name_oid + "." + index], mutates=False)
        guest_name = (val.stdout or "").strip()
        if guest_name == item:
            pval = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + prompt_oid + "." + index], mutates=False)
            found_guest = guest_name
            found_status = (pval.stdout or "").strip().lower()
            break

    if found_guest == None:
        return {"changed": False, "msg": "guest not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "Guest [%s] is %s" % (found_guest, found_status), "data": {"state": "OK", "metrics": {}, "details": ""}}