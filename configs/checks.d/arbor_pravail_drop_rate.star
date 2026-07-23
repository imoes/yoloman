# Top-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.9694.1.6.2.39.0"
SNMP_COMMUNITY_DEFAULT = "public"
SNMP_HOST_DEFAULT = "localhost"
ITEM_NAME = "Overrun"
METRIC_NAME = "if_in_pkts"

# Helper: parse decimal integer from string, return None if invalid
def _parse_int(s):
    s = s.strip()
    if not s:
        return None
    if not s.lstrip("-").isdigit():
        return None
    return int(s)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", SNMP_COMMUNITY_DEFAULT),
            "-On", params.get("host", SNMP_HOST_DEFAULT),
            SNMP_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        # Parse output: "OID = INTEGER: <value>" or similar
        lines = res.stdout.splitlines()
        value = None
        for line in lines:
            # Look for the integer value at end of line
            idx = line.rfind(": ")
            if idx >= 0:
                s = line[idx + 2:].strip()
                v = _parse_int(s)
                if v != None:
                    value = v
                    break

        # Discovery always yields one item "Overrun" regardless of value
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": ITEM_NAME,
                 "params": {},
                 "metrics": [METRIC_NAME]}
            ]}
        }

    # Check mode
    item = params.get("item", "")
    if item != ITEM_NAME:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", SNMP_COMMUNITY_DEFAULT),
        "-On", params.get("host", SNMP_HOST_DEFAULT),
        SNMP_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse: "OID = INTEGER: <value>"
    line = res.stdout.strip()
    idx = line.rfind(": ")
    if idx < 0:
        return {"changed": False, "msg": "cannot parse SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    s = line[idx + 2:].strip()
    value = _parse_int(s)
    if value == None:
        return {"changed": False, "msg": "invalid integer value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Threshold logic
    warn = params.get("levels")
    crit = params.get("levels_lower")

    state = "OK"
    details = ""
    if warn != None and value >= warn:
        state = "WARN"
        details = "upper level: " + "%f pps" % value
    elif crit != None and value >= crit:
        state = "CRIT"
        details = "upper level: " + "%f pps" % value

    return {
        "changed": False,
        "msg": "%f pps" % value,
        "data": {
            "state": state,
            "metrics": {METRIC_NAME: float(value)},
            "details": details
        }
    }
