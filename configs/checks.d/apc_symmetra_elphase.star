# Library: check_elphase levels mapping (reproducing Checkmk's library behavior)
ELPHASE_DEFAULTS = {
    "current": (10, 15),   # warn, crit for current levels (amps)
}

# Parse a single SNMP value string to float, return None if empty
def _to_float(s):
    return float(s) if s and s.strip() else None

# Extract numeric value from SNMP string (strip spaces and convert)
def _parse_value(s):
    s = s.strip()
    return float(s) if s else None

def main(ctx, params):
    # Discovery mode: enumerate battery phases
    if params.get("_discover"):
        # Fetch elphase data: OID .1.3.6.1.4.1.318.1.1.1.7.2.4.0 (battery current)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.318.1.1.1.7.2.4.0"
        ], mutates=False)
        # We expect exactly one item: "Battery"
        item = "Battery"
        out = [
            {
                "item": item,
                "params": {"current": ELPHASE_DEFAULTS["current"]},
                "metrics": ["current"]
            }
        ]
        return {
            "changed": False,
            "msg": "discovered 1 phase",
            "data": {"discovery": out}
        }

    # Check mode: process the item (always "Battery" for this check)
    item = params.get("item", "Battery")
    if item != "Battery":
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch battery current from SNMP
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.318.1.1.1.7.2.4.0"
    ], mutates=False)

    # Parse SNMP output: "OID = INTEGER: value" or "OID = gauge32: value"
    # We need the numeric value (last field after ':')
    current = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split()
        if len(parts) >= 3:
            # Get value (might be after ':')
            val_str = parts[-1]
            if val_str.startswith(":"):
                val_str = val_str[1:]
            current = _parse_value(val_str)
            break

    # Get thresholds from params (default: current warn=10, crit=15)
    # Note: Checkmk default for current is (10, 15) amps
    levels = params.get("current", ELPHASE_DEFAULTS["current"])
    warn = levels[0] if isinstance(levels, (list, tuple)) and len(levels) >= 1 else 10.0
    crit = levels[1] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 15.0

    # Determine state based on levels (upper levels: WARN if >= warn, CRIT if >= crit)
    if current == None:
        return {
            "changed": False,
            "msg": "battery current data missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"
    if current >= crit:
        state = "CRIT"
    elif current >= warn:
        state = "WARN"

    # Format message: "Current: X.XX A"
    msg = "Current: %f A" % current

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"current": current},
            "details": ""
        }
    }
