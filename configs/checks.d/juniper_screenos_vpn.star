def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysid.rc != 0:
            return {"changed": False, "msg": "SNMP sysObjectID not reachable", "data": {"discovery": []}}
        if not sysid.stdout.startswith(".1.3.6.1.4.1.3224.1"):
            return {"changed": False, "msg": "host is not a Juniper ScreenOS device", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.3224.4.1.1.1.4"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            idx = oid[len(".1.3.6.1.4.1.3224.4.1.1.1.4") + 1:]
            if not idx:
                continue
            out.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d VPNs" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    col_oid = ".1.3.6.1.4.1.3224.4.1.1.1.4"
    status_oid = ".1.3.6.1.4.1.3224.4.1.1.1.23"
    status_get = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, status_oid + "." + item], mutates=False)
    if status_get.rc != 0:
        return {"changed": False, "msg": "VPN %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = status_get.stdout.strip().strip('"')
    if status == "1":
        state = "OK"
        summary = "VPN Status %s is active" % item
    elif status == "0":
        state = "CRIT"
        summary = "VPN Status %s inactive" % item
    else:
        state = "WARN"
        summary = "Unknown vpn status %s" % status
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}