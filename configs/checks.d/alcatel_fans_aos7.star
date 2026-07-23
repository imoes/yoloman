# Constants defined at module top level
FAN_BASE_AOS7 = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.11.1"
FAN_OID = "2"

FAN_STATE_NAMES = {
    0: "has no status",
    1: "not running",
    2: "running",
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            FAN_BASE_AOS7 + "." + FAN_OID
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"discovery": []}
            }

        items = []
        for line in res.stdout.splitlines():
            # Format: OID = INTEGER: value
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1]
            if value_part.startswith("INTEGER: "):
                fan_state_str = value_part[9:]
                if fan_state_str.isdigit():
                    items.append({
                        "item": str(len(items) + 1),
                        "params": {},
                        "metrics": []
                    })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "fan item is empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard before conversion - item must be numeric digits only
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid fan index: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    fan_index = int(item)

    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        FAN_BASE_AOS7 + "." + FAN_OID + "." + str(fan_index)
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    output = res.stdout.strip()
    # Format: OID = INTEGER: value
    parts = output.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unexpected SNMP output for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_part = parts[1]
    if not value_part.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "unexpected SNMP output for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    fan_state_str = value_part[9:]
    if not fan_state_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid fan state for fan " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    fan_state = int(fan_state_str)
    state = "OK" if fan_state == 2 else "CRIT"
    summary = "Fan " + FAN_STATE_NAMES.get(fan_state, "unknown (%s)" % fan_state)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
