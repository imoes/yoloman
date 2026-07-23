def main(ctx, params):
    if params.get("_discover"):
        # Single service check: always yield one service if the host is HP-UX
        facts = ctx.facts()
        if facts.get("distribution", "").startswith("HP-UX"):
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["user", "system", "idle", "nice"]}]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Normal check mode (item is always "" for this check)
    # Run snmpget for the four CPU-related OIDs relative to .1.3.6.1.4.1.11.2.3.1.1
    oids = [
        "1.3.6.1.4.1.11.2.3.1.1.13.0",  # sysUserCPU
        "1.3.6.1.4.1.11.2.3.1.1.14.0",  # sysSysCPU
        "1.3.6.1.4.1.11.2.3.1.1.15.0",  # sysIdleCPU
        "1.3.6.1.4.1.11.2.3.1.1.16.0"   # sysNiceCPU
    ]

    # Build a single snmpget command with all OIDs
    cmd = ["snmpget", "-On", "-v2c", "-c", "public", "localhost"] + oids
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed"}
        }

    # Parse snmpget output: each line like ".1.3.6.1.4.1.11.2.3.1.1.13.0 = INTEGER: 52129100"
    lines = res.stdout.splitlines()
    values = {}
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        # Split on " = " to separate OID from value
        if " = " not in line:
            continue
        oid_part, val_part = line.split(" = ", 1)
        oid_num = oid_part.strip()
        # Extract value: INTEGER: 123 or STRING: ...
        if val_part.startswith("INTEGER:"):
            val_str = val_part.replace("INTEGER:", "").strip()
            if val_str.isdigit():
                oid_key = oid_num.rsplit(".", 1)[0]  # strip .0
                values[oid_key] = int(val_str)
        elif val_part.startswith("STRING:"):
            # ignore non-integer fields (shouldn't happen here)
            pass

    # Ensure all needed OIDs were found
    expected_keys = [
        "1.3.6.1.4.1.11.2.3.1.1.13",  # user
        "1.3.6.1.4.1.11.2.3.1.1.14",  # system
        "1.3.6.1.4.1.11.2.3.1.1.15",  # idle
        "1.3.6.1.4.1.11.2.3.1.1.16"   # nice
    ]
    for key in expected_keys:
        if key not in values:
            return {
                "changed": False,
                "msg": "Missing SNMP values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Missing SNMP values"}
            }

    # Get values
    user_val = values["1.3.6.1.4.1.11.2.3.1.1.13"]
    system_val = values["1.3.6.1.4.1.11.2.3.1.1.14"]
    idle_val = values["1.3.6.1.4.1.11.2.3.1.1.15"]
    nice_val = values["1.3.6.1.4.1.11.2.3.1.1.16"]

    total = user_val + system_val + idle_val + nice_val
    if total == 0:
        return {
            "changed": False,
            "msg": "No counter counted. Time has ceased to flow.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "No counter counted"}
        }

    # Compute percentages
    user_pct = float(user_val) / float(total) * 100.0
    system_pct = float(system_val) / float(total) * 100.0
    idle_pct = float(idle_val) / float(total) * 100.0
    nice_pct = float(nice_val) / float(total) * 100.0

    # Build summary
    infos = []
    metrics = {}
    for what, pct in [("user", user_pct), ("system", system_pct), ("idle", idle_pct), ("nice", nice_pct)]:
        metrics[what] = pct
        infos.append("%s: %f%%" % (what, pct))

    return {
        "changed": False,
        "msg": ", ".join(infos),
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }
