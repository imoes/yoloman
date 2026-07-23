# Module-level constants
METRICS_MAP = {"util": "cpu_util"}
DEFAULT_WARN = 90.0
DEFAULT_CRIT = 95.0

def main(ctx, params):
    # Discovery mode: emit exactly one service (single-service check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 CPU item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"util": (90.0, 95.0)}, "metrics": ["cpu_util"]}
                ]
            },
        }

    # Check mode: fetch CPU utilization via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # OID base from Checkmk source: .1.3.6.1.4.1.6527.3.1.2.1.1.1
    oid = ".1.3.6.1.4.1.6527.3.1.2.1.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    
    # Parse snmpwalk output: lines like "OID = INTEGER: value" or "OID = Gauge32: value"
    cpu_val = None
    for line in res.stdout.splitlines():
        line = line.strip()
        # Find the OID match and extract value
        if line.startswith(oid + " = "):
            parts = line[len(oid) + 3:].split(": ")
            if len(parts) >= 2:
                val_str = parts[-1].strip()
                # Handle types like "INTEGER: 45" or "Gauge32: 45"
                if val_str.isdigit():
                    cpu_val = float(val_str)
                    break

    # If data unavailable, report UNKNOWN state
    if cpu_val == None:
        return {
            "changed": False,
            "msg": "no CPU utilization data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Extract thresholds (checkmk default: {"util": (90.0, 95.0)})
    util_params = params.get("util", (DEFAULT_WARN, DEFAULT_CRIT))
    warn = util_params[0]
    crit = util_params[1]

    # Compute state: upper levels (CRIT if >= crit, WARN if >= warn)
    state = "CRIT" if cpu_val >= crit else ("WARN" if cpu_val >= warn else "OK")

    # Build message: Checkmk style, e.g. "CPU total: 45.00 %"
    msg = "CPU total: %f %%" % cpu_val

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu_val},
            "details": ""
        }
    }
