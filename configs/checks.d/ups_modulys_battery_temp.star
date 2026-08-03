def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = ".1.3.6.1.4.1.2254.2.4.7"
    oids = ["1", "4", "5", "8", "9"]
    targets = [base_oid + "." + o for o in oids]

    if params.get("_discover"):
        # Probe for the device first - check the sysObjectID
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.rc == 127 or sysoid_res.rc != 0 or not sysoid_res.stdout.strip():
            return {"changed": False, "msg": "Modulys UPS not detected on host",
                    "data": {"discovery": []}}

        sysoid = sysoid_res.stdout.strip()
        if sysoid != ".1.3.6.1.4.1.2254.2.4":
            return {"changed": False, "msg": "Modulys UPS not detected on host",
                    "data": {"discovery": []}}

        # Fetch the battery table row
        walk_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host] + targets,
            mutates=False,
        )
        if walk_res.rc != 0 or not walk_res.stdout.strip():
            return {"changed": False, "msg": "Modulys battery data not available",
                    "data": {"discovery": []}}

        values = walk_res.stdout.splitlines()
        if len(values) < 5:
            return {"changed": False, "msg": "Modulys battery data incomplete",
                    "data": {"discovery": []}}

        # Check if the temperature value is parseable
        temp_str = values[4].strip()
        if not _is_float(temp_str):
            return {"changed": False, "msg": "Modulys battery temperature not reported",
                    "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered 1 Temperature service",
                "data": {"discovery": [
                    {"item": "Battery",
                     "params": {},
                     "metrics": ["temperature"]},
                ]}}

    # Check mode
    item = params.get("item", "Battery")

    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc == 127 or sysoid_res.rc != 0 or not sysoid_res.stdout.strip():
        return {"changed": False, "msg": "Modulys UPS not detected on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP unreachable or device not a Modulys UPS"}}

    sysoid = sysoid_res.stdout.strip()
    if sysoid != ".1.3.6.1.4.1.2254.2.4":
        return {"changed": False, "msg": "Device is not a Modulys UPS",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "sysObjectID mismatch"}}

    walk_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host] + targets,
        mutates=False,
    )
    if walk_res.rc != 0 or not walk_res.stdout.strip():
        return {"changed": False, "msg": "Could not read Modulys battery OIDs",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = walk_res.stdout.splitlines()
    if len(values) < 5:
        return {"changed": False, "msg": "Modulys battery data incomplete",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_str = values[4].strip()
    if not _is_float(temp_str):
        return {"changed": False, "msg": "Temperature not reported by device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = float(temp_str)

    warn = params.get("warn", 55)
    crit = params.get("crit", 60)

    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "Temperature: %f C" % temperature,
            "data": {"state": state, "metrics": {"temperature": temperature},
                     "details": "%f C" % temperature}}


def _is_float(s):
    if not s:
        return False
    parts = s.split(".")
    if len(parts) > 2:
        return False
    for p in parts:
        if p == "":
            continue
        if not p.lstrip("-").isdigit():
            return False
    return True