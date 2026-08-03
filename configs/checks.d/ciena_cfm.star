def main(ctx, params):
    # ----- helpers -----
    OID_SYSDESC = ".1.3.6.1.2.1.1.1.0"
    OID_SYSOBJ = ".1.3.6.1.2.1.1.2.0"
    BASE = ".1.3.6.1.4.1.1271.2.1.4.1.2.1.1"

    OPER_STATE = {
        "1": "enabled",
        "2": "disabled",
    }

    def snmp_get(community, host, oid):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return None
        return res.stdout.strip()

    def snmp_walk(host, community, oid):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return {}
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full, value = parts[0], parts[1]
            rows[oid_full] = value
        return rows

    def ciena_present(community, host):
        sysdesc = snmp_get(community, host, OID_SYSDESC)
        sysid = snmp_get(community, host, OID_SYSOBJ)
        if sysid == None or sysdesc == None:
            return False
        valid_sysid = (
            sysid.startswith(".1.3.6.1.4.1.1271.1.2.11")
            or sysid.startswith(".1.3.6.1.4.1.6141.1.96")
        )
        if not valid_sysid:
            return False
        return "5171" in sysdesc

    def fetch_services(community, host):
        name_oid = BASE + ".6"
        state_oid = BASE + ".5"
        names = snmp_walk(host, community, name_oid)
        states = snmp_walk(host, community, state_oid)
        result = {}
        for oid_full, name_val in names.items():
            idx = oid_full[len(name_oid) + 1:]
            state_val = states.get(state_oid + "." + idx)
            if state_val == None or state_val == "" or state_val == "0":
                continue
            result[name_val] = OPER_STATE.get(state_val, "unknown")
        return result

    # ----- body -----
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not ciena_present(community, host):
            return {
                "changed": False,
                "msg": "not a Ciena 5171 device",
                "data": {"discovery": [], "host_labels": {}},
            }
        services = fetch_services(community, host)
        discovery = []
        for item, oper_state in services.items():
            discovery.append({
                "item": item,
                "params": {"discovered_oper_state": oper_state},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d ciena cfm services" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    if not ciena_present(community, host):
        return {
            "changed": False,
            "msg": "not a Ciena 5171 device",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    services = fetch_services(community, host)
    if item == "" or item not in services:
        return {
            "changed": False,
            "msg": "no such ciena cfm service: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    current = services[item]
    expected = params.get("discovered_oper_state", current)
    if current == expected:
        state = "OK"
    else:
        state = "CRIT"
    return {
        "changed": False,
        "msg": "CFM-Service instance is %s" % current,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }