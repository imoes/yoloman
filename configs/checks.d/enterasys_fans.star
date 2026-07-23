# ===== Starlark check: enterasys_fans =====

FAN_STATES = {
    "1": "info not available",
    "2": "not installed",
    "3": "installed and operating",
    "4": "installed and not operating",
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk FAN table via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.52.4.3.1.3.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse snmpwalk output: "OID = TYPE: value"
        fans = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Split into OID and value part
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_str = parts[1].strip()
            # Extract numeric fan index from OID end
            # OID ends with .<fan_index>
            fan_num = oid_part.rsplit(".", 1)
            if len(fan_num) != 2:
                continue
            fan_num = fan_num[1]

            # Skip if fan_num is not a digit
            if not fan_num.isdigit():
                continue

            # Extract value type and content
            if ":" in value_str:
                value = value_str.split(":", 1)[1].strip()
            else:
                value = value_str.strip()

            # State == "2" means installed and operating (OK), skip it
            # We discover only FANs that are NOT in state "2"
            if value != "2":
                fans.append({
                    "item": fan_num,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d fans" % len(fans),
            "data": {"discovery": fans}
        }

    # Check mode: single item
    item = params.get("item", "")

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.52.4.3.1.3.1.1." + item
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for FAN " + item + ": " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse snmpget: ".1.3.6.1.4.1.52.4.3.1.3.1.1.1 = INTEGER: 3"
    line = res.stdout.strip()
    if not line or "=" not in line:
        return {
            "changed": False,
            "msg": "malformed snmpget response for FAN " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    value_str = line.split(":", 1)[1].strip()
    state = value_str.split(" ")[-1]  # e.g., "INTEGER: 3" -> "3"

    state = state.strip()
    if state not in FAN_STATES:
        return {
            "changed": False,
            "msg": "unknown FAN state " + state + " for FAN " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    message = "FAN State: " + FAN_STATES[state]
    if state in ["1", "2"]:
        result_state = "UNKNOWN"
    elif state == "4":
        result_state = "CRIT"
    else:
        result_state = "OK"

    return {
        "changed": False,
        "msg": message,
        "data": {
            "state": result_state,
            "metrics": {},
            "details": ""
        }
    }
