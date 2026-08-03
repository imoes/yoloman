PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}

STATUS_MAP = {1: ("CRIT", "Other"), 2: ("OK", "Ok"), 3: ("WARN", "Degraded"), 4: ("CRIT", "Failed")}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.232.22.2.3.1.3.1"

    sys_oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_oid_res.rc != 0:
        return {"changed": False, "msg": "not installed", "data": {"discovery": [], "host_labels": {}}}

    sys_oid = sys_oid_res.stdout.strip()
    if sys_oid.find(".11.5.7.1.2") == -1:
        return {"changed": False, "msg": "not installed", "data": {"discovery": [], "host_labels": {}}}

    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".3"], mutates=False)
    fan_indices = []
    if walk_res.rc == 0:
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            if oid_full.find(base + ".3.") != 0:
                continue
            value = parts[1]
            fan_indices.append(value)

    if params.get("_discover"):
        discovery = []
        for idx in fan_indices:
            discovery.append({"item": idx, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery, "host_labels": {}}}

    item = params.get("item", "")
    present_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".8." + item], mutates=False)
    cond_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".11." + item], mutates=False)

    if present_res.rc != 0 or cond_res.rc != 0:
        return {"changed": False, "msg": "fan %s not available" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    present_val = present_res.stdout.strip()
    cond_val = cond_res.stdout.strip()

    present_int = int(present_val) if present_val.isdigit() else 0
    present_state = PRESENT_MAP.get(present_int, "unknown")
    if present_state != "present":
        return {"changed": False, "msg": "FAN was present but is not available anymore (Present state: %s)" % present_state, "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    cond_int = int(cond_val) if cond_val.isdigit() else 0
    state_name, state_readable = STATUS_MAP.get(cond_int, ("UNKNOWN", "Unknown"))
    return {"changed": False, "msg": "FAN condition is %s" % state_readable, "data": {"state": state_name, "metrics": {}, "details": ""}}