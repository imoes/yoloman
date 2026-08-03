def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ACCESS_STATUS_OID], mutates=False)
    if walk_res.rc == 127:
        return {"changed": False, "msg": "not installed", "data": {"discovery": []}}
    if walk_res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed to discover access sensors", "data": {"discovery": []}}

    discovery = []
    for line in walk_res.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        oid_suffix = full_oid[len(ACCESS_STATUS_OID) + 1:]
        if not oid_suffix:
            continue
        desc_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ACCESS_DESCNAME_OID + "." + oid_suffix], mutates=False)
        desc = desc_res.stdout.strip().strip('"') if desc_res.rc == 0 else oid_suffix
        discovery.append({"item": desc, "params": {"warn": 1, "crit": 2}, "metrics": ["access_status"]})

    return {"changed": False, "msg": "discovered %d access sensors" % len(discovery), "data": {"discovery": discovery}}

def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ACCESS_STATUS_OID], mutates=False)
    if walk_res.rc == 127:
        return {"changed": False, "msg": "not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if walk_res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed to retrieve access sensors", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_index = None
    for line in walk_res.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        oid_suffix = full_oid[len(ACCESS_STATUS_OID) + 1:]
        if not oid_suffix:
            continue
        desc_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ACCESS_DESCNAME_OID + "." + oid_suffix], mutates=False)
        desc = desc_res.stdout.strip().strip('"') if desc_res.rc == 0 else oid_suffix
        if desc == item:
            status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ACCESS_STATUS_OID + "." + oid_suffix], mutates=False)
            if status_res.rc != 0:
                return {"changed": False, "msg": "failed to retrieve status for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            status = status_res.stdout.strip()
            delay_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ACCESS_DELAY_OID + "." + oid_suffix], mutates=False)
            delay = delay_res.stdout.strip().strip('"') if delay_res.rc == 0 else "N/A"
            sens_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ACCESS_SENSITIVITY_OID + "." + oid_suffix], mutates=False)
            sensitivity = sens_res.stdout.strip().strip('"') if sens_res.rc == 0 else "N/A"
            sensor_index = oid_suffix
            state, metric_val = _grade(status, params)
            return {
                "changed": False,
                "msg": "%s: %s" % (item, status),
                "data": {
                    "state": state,
                    "metrics": {"access_status": metric_val},
                    "details": "Delay: %s, Sensitivity: %s" % (delay, sensitivity),
                },
            }

    if sensor_index == None:
        return {"changed": False, "msg": "no access sensor found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def _grade(status_readable, params):
    if status_readable == "Closed":
        return ("OK", 0)
    elif status_readable == "Open":
        return ("WARN", 1)
    else:
        return ("CRIT", 2)

ACCESS_BASE_OID = "1.3.6.1.4.1.2606.7.4.2.2.1.3.3"
ACCESS_STATUS_OID = ACCESS_BASE_OID + ".1"
ACCESS_DESCNAME_OID = ACCESS_BASE_OID + ".2"
ACCESS_DELAY_OID = ACCESS_BASE_OID + ".3"
ACCESS_SENSITIVITY_OID = ACCESS_BASE_OID + ".4"