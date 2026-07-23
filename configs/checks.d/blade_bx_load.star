# ===== module: checkmk.blade_bx_load.star =====
# Check: blade_bx_load - CPU load (SNMP-based)
# Discovery: yields one service per host; check mode returns current load and thresholds.

def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels1": None,
                            "levels5": None,
                            "levels15": [5.0, 20.0]
                        },
                        "metrics": ["load1", "load5", "load15"]
                    }
                ]
            }
        }

    # === CHECK MODE ===
    # Fetch the SNMP data (single OID: .1.3.6.1.4.1.2021.10.1.6)
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2021.10.1.6"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP error: " + res.stderr
            }
        }

    # Parse: expect exactly one line ".1.3.6.1.4.1.2021.10.1.6.0 = INTEGER: <value>"
    lines = res.stdout.splitlines()
    if len(lines) != 1:
        return {
            "changed": False,
            "msg": "unexpected SNMP output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Expected exactly one SNMP line, got %d" % len(lines)
            }
        }

    # Extract numeric value from "INTEGER: <value>" or "INTEGER: <value>\n"
    line = lines[0].strip()
    idx = line.rfind("=")
    if idx == -1:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No '=' in SNMP line"
            }
        }

    val_part = line[idx + 1:].strip()
    if val_part.startswith("INTEGER: "):
        val_part = val_part[len("INTEGER: "):]
    val_part = val_part.strip()

    # Guard against invalid numeric string before parsing
    # Accept integer, float, negative numbers (e.g. "-1.23")
    if not val_part:
        return {
            "changed": False,
            "msg": "empty load value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP value is empty"
            }
        }

    # Validate numeric string manually (no try/except allowed)
    def is_valid_float(s):
        if not s:
            return False
        # Allow optional leading minus, one dot, digits
        s = s.lstrip('-')
        if not s:
            return False
        parts = s.split('.')
        if len(parts) > 2:
            return False
        for part in parts:
            if not part.isdigit():
                return False
        return True

    if not is_valid_float(val_part):
        return {
            "changed": False,
            "msg": "non-numeric load value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Cannot parse load as number: " + val_part
            }
        }

    # Safe to parse now (string validated as numeric)
    load1 = float(val_part)

    # Use Checkmk defaults: levels15 = [5.0, 20.0]; levels1/5 = None
    levels1 = params.get("levels1")
    levels5 = params.get("levels5")
    levels15 = params.get("levels15", [5.0, 20.0])

    # Check CPU load thresholds — single CPU system (num_cpus=1 implied)
    # levels are absolute load values (not per-CPU)
    def check_levels(value, levels):
        if levels == None:
            return "OK"
        if len(levels) == 2:
            warn, crit = levels[0], levels[1]
            if value >= crit:
                return "CRIT"
            if value >= warn:
                return "WARN"
            return "OK"
        return "OK"

    state = "OK"
    if check_levels(load1, levels1) == "CRIT":
        state = "CRIT"
    elif check_levels(load1, levels1) == "WARN" and state == "OK":
        state = "WARN"

    # Since we only have load1 from the device, report only load1 metrics.
    # (The Checkmk plugin as written only fetches one OID value.)
    msg = "Load 1 min: %f" % load1
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"load1": load1},
            "details": ""
        }
    }
