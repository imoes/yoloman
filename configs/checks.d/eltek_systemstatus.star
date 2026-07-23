def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: probe SNMP value for systemOperationalStatus (OID .1.3.6.1.4.1.12148.9.2.2.0)
    res = ctx.run([
        "snmpget",
        "-O", "q",
        "-v", "2c",
        "-c", "public",
        ctx.facts().get("hostname", "localhost"),
        ".1.3.6.1.4.1.12148.9.2.2.0"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.strip().splitlines()
    if len(lines) < 1 or not lines[0]:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value = lines[0].strip()
    map_state = {
        "0": ("CRIT", "float, voltage regulated"),
        "1": ("OK", "float, temperature comp. regulated"),
        "2": ("CRIT", "battery boost"),
        "3": ("CRIT", "battery test"),
    }

    state_readable = map_state.get(value, ("UNKNOWN", "unknown status"))
    state = state_readable[0]

    return {
        "changed": False,
        "msg": "Operational status: " + state_readable[1],
        "data": {"state": state, "metrics": {}, "details": ""}
    }
