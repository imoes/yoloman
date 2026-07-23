def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.10876.2"
        ], mutates=False)
        lines = res.stdout.splitlines()
        found = False
        for line in lines:
            if line.strip().startswith(".1.3.6.1.4.1.10876.2."):
                found = True
                break
        if found:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []}
        }

    # Check mode: single-service health check
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.10876.2.1.1.1.1.12.1"
    ], mutates=False)
    status_line = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.10876.2.1.1.1.1.12.1 ="):
            status_line = line
            break

    res2 = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.10876.2.2"
    ], mutates=False)
    desc_line = None
    for line in res2.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.10876.2.2 ="):
            desc_line = line
            break

    if status_line == None or desc_line == None:
        return {
            "changed": False,
            "msg": "Unable to retrieve Supermicro health data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    status_parts = status_line.split(" = ")
    if len(status_parts) < 2:
        return {
            "changed": False,
            "msg": "Unable to parse status value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    status_value_str = status_parts[1].strip()
    if status_value_str.startswith("INTEGER:"):
        status_value_str = status_value_str[8:].strip()
    elif status_value_str.startswith("Integer32:"):
        status_value_str = status_value_str[10:].strip()
    if not status_value_str.isdigit():
        return {
            "changed": False,
            "msg": "Unable to parse status value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    status_value = int(status_value_str)

    desc_parts = desc_line.split(" = ")
    if len(desc_parts) < 2:
        return {
            "changed": False,
            "msg": "Unable to parse description value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    desc_value = desc_parts[1].strip()
    if desc_value.startswith("STRING:"):
        desc_value = desc_value[7:].strip().strip('"')
    description = desc_value if desc_value else "Overall Hardware Health"

    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(status_value, "UNKNOWN")

    return {
        "changed": False,
        "msg": description,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }