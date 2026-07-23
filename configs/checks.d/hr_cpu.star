def main(ctx, params):
    # Read params with Checkmk defaults
    util_warn, util_crit = params.get("util", (80.0, 90.0))

    # Gather CPU utilization from HOST-RESOURCES-MIB hrProcessorLoad
    # OID: .1.3.6.1.2.1.25.3.3.1.2 (hrProcessorLoad)
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discover mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.2.1.25.3.3.1.2"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Count discovered cores
        lines = res.stdout.splitlines()
        num_cores = 0
        for line in lines:
            if line.strip().startswith(".1.3.6.1.2.1.25.3.3.1.2"):
                num_cores += 1
        
        if num_cores >= 1:
            return {
                "changed": False,
                "msg": "discovered 1 CPU utilization service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {"util": (util_warn, util_crit)}, "metrics": ["util"]}
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no CPU cores found",
                "data": {"discovery": []}
            }

    # Check mode
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.2.1.25.3.3.1.2"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse CPU utilization values
    util_sum = 0
    num_cpus = 0
    cores = []
    lines = res.stdout.splitlines()
    for line in lines:
        stripped = line.strip()
        # Format: .1.3.6.1.2.1.25.3.3.1.2.X = INTEGER: Y
        if stripped.startswith(".1.3.6.1.2.1.25.3.3.1.2") and stripped.find(" = INTEGER: ") != -1:
            value_part = stripped.split(" = INTEGER: ", 1)[1]
            if value_part.isdigit():
                core_util = int(value_part)
                cores.append(("core%d" % num_cpus, core_util))
                util_sum += core_util
                num_cpus += 1

    if num_cpus == 0:
        return {
            "changed": False,
            "msg": "No CPU data found in SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Calculate average utilization
    util_avg = float(util_sum) / num_cpus

    # Determine state based on thresholds
    if util_avg >= util_crit:
        state = "CRIT"
    elif util_avg >= util_warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message string
    msg = "Total CPU utilization: %f%%" % util_avg

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"util": util_avg},
            "details": ""
        }
    }