# ===== check plugin: orion_batterytest =====
# Starlark translation of Checkmk check cmk.plugins.orion.orion_batterytest

def main(ctx, params):
    # Discovery mode: yield a single service (no per-item breakdown)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 battery test service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: fetch SNMP data for orion_batterytest
    # base OID: .1.3.6.1.4.1.20246.2.3.1.1.1.2.5.2.2
    # OIDs: 1 (last_test_date), 2 (test_result)
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.20246.2.3.1.1.1.2.5.2.2.1",
        ".1.3.6.1.4.1.20246.2.3.1.1.1.2.5.2.2.2"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: each line has OID = value
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "SNMP response missing values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract values (strip leading/trailing spaces and quotes)
    def extract_value(line):
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            return ""
        val = parts[1].strip()
        # Remove quotes if present
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        return val

    last_test_date = extract_value(lines[0])
    test_result = extract_value(lines[1])

    # Map test_result to state
    map_states = {
        "1": ("OK", "none"),
        "2": ("CRIT", "failed"),
        "3": ("WARN", "aborted"),
        "4": ("CRIT", "load failure"),
        "5": ("OK", "OK"),
        "6": ("WARN", "aborted manual"),
        "7": ("WARN", "aborted ev ctrl charge"),
        "8": ("WARN", "aborted inhibit ev")
    }

    # test_result "1" means "no test result available"
    if test_result != "1":
        state_str, state_readable = map_states.get(test_result, ("UNKNOWN", "unknown[" + test_result + "]"))
        summary = "Last performed: " + last_test_date + ", Result: " + state_readable
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state_str, "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "No test result available",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
