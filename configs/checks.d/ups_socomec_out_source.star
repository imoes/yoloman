# Map from SNMP integer state to (Checkmk State string, description)
_SOURCE_STATES = {
    1: ("UNKNOWN", "Unknown"),
    2: ("CRIT", "On inverter"),
    3: ("OK", "On mains"),
    4: ("OK", "Eco mode"),
    5: ("WARN", "On bypass"),
    6: ("OK", "Standby"),
    7: ("WARN", "On maintenance bypass"),
    8: ("CRIT", "UPS off"),
    9: ("OK", "Normal mode"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Single-service check: always discover one service if the SNMP section is present
        # Probe presence by querying the OID (read-only)
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.4555.1.1.1.1.4.1"], mutates=False)
        if res.rc == 0:
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 0 services",
                "data": {"discovery": []}}

    # Normal check mode (item is always "" for this single-service check)
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.4555.1.1.1.1.4.1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpget output: typical form is ".1.3.6.1.4.1.4555.1.1.1.1.4.1 = INTEGER: 3"
    stdout = res.stdout.strip()
    parts = stdout.split("=", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_part = parts[1].strip()
    # Extract integer value after "INTEGER:"
    if not value_part.startswith("INTEGER:"):
        return {"changed": False, "msg": "expected INTEGER type",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    num_str = value_part[8:].strip()
    if not num_str.isdigit():
        return {"changed": False, "msg": "invalid integer value: %s" % num_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_num = int(num_str)
    state_str, text = _SOURCE_STATES.get(state_num, ("UNKNOWN", "Unknown"))

    return {"changed": False, "msg": text,
            "data": {"state": state_str, "metrics": {}, "details": ""}}
