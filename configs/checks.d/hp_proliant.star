# Mapping for status codes
_MAP_STATES = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("OK", "OK"),
    "3": ("WARN", "degraded"),
    "4": ("CRIT", "failed"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: yield a single service for the host
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch data via SNMP (simulated via ctx.run for Checkmk-style agent output)
    # For Checkmk-style checks, we assume ctx.run returns SNMP-style output as per agent section
    res = ctx.run(["snmpget", "-Ovq", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.232.11.1.3.0", ".1.3.6.1.4.1.232.11.2.14.1.1.5.0", ".1.3.6.1.4.1.232.2.2.2.1.0"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "incomplete SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Extract values in order: status, firmware, serial
    status_raw = lines[0].strip() if lines[0].strip() else "1"
    firmware = lines[1].strip() if lines[1].strip() else "unknown"
    serial = lines[2].strip() if lines[2].strip() else "unknown"

    # Map status
    state, state_readable = _MAP_STATES.get(status_raw, ("UNKNOWN", "unhandled[" + status_raw + "]"))

    return {
        "changed": False,
        "msg": "Status: %s, Firmware: %s, S/N: %s" % (state_readable, firmware, serial),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
