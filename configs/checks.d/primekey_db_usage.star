DETECT_OID = ".1.3.6.1.2.1.1.2.0"
PRIMEKEY_OID = ".1.3.6.1.4.1.8072.3.2.10"
USAGE_BASE_OID = ".1.3.6.1.4.1.22408.1.1.2.1.4.118.100.98.49"
USAGE_OID = USAGE_BASE_OID + ".1"

def main(ctx, params):
    # Discovery mode: yield one service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels": (80.0, 90.0)}, "metrics": ["disk_utilization"]}
                ]
            }
        }

    # Check mode: single service (item "")
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Detect PrimeKey by comparing sysObjectID
    res_detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), DETECT_OID],
                         mutates=False)
    if res_detect.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res_detect.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    # Parse sysObjectID value (format: OID = STRING: "oid.value")
    sys_obj_line = res_detect.stdout.strip()
    # Find the last colon and take what follows, strip whitespace
    idx = sys_obj_line.rfind(":")
    if idx == -1:
        return {
            "changed": False,
            "msg": "could not parse sysObjectID value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    actual_oid = sys_obj_line[idx+1:].strip()
    if actual_oid != PRIMEKEY_OID:
        return {
            "changed": False,
            "msg": "not a PrimeKey device",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Fetch DB usage
    res_usage = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), USAGE_OID],
                        mutates=False)
    if res_usage.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error fetching DB usage: " + res_usage.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse DB usage value (format: OID = STRING: "value")
    usage_line = res_usage.stdout.strip()
    idx = usage_line.rfind(":")
    if idx == -1:
        return {
            "changed": False,
            "msg": "could not parse DB usage value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    usage_str = usage_line[idx+1:].strip()
    # Strip trailing percent sign if present
    if usage_str.endswith("%"):
        usage_str = usage_str[:-1]

    # Convert to float with guard instead of try/except
    db_usage = float(usage_str) if usage_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (usage_str.count(".") == 1 and usage_str.replace(".", "").replace("-", "", 1).isdigit()) else 0.0
    if usage_str == "" or usage_str == "-":
        return {
            "changed": False,
            "msg": "invalid DB usage value: " + usage_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Apply thresholds
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if len(levels) >= 1 else 80.0
    crit = levels[1] if len(levels) >= 2 else 90.0

    state = "OK"
    if db_usage >= crit:
        state = "CRIT"
    elif db_usage >= warn:
        state = "WARN"

    msg = "Disk Utilization: %f%%" % db_usage
    if state == "CRIT":
        msg = msg + " (above critical threshold of %f%%)" % crit
    elif state == "WARN":
        msg = msg + " (above warning threshold of %f%%)" % warn

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"disk_utilization": db_usage},
            "details": ""
        }
    }