# Top-level constants
MAP_STATES = {
    "0": (3, "unknown"),
    "1": (1, "initial"),
    "2": (0, "active"),
    "3": (0, "standby"),
    "4": (2, "out of service"),
    "5": (2, "unassigned"),
    "6": (1, "active (pending)"),
    "7": (1, "standby (pending)"),
    "8": (1, "out of service (pending)"),
    "9": (1, "recovery"),
}

# Checkmk default thresholds (lower_levels: ("fixed", (75, 50)) -> warn=75, crit=50)
DEFAULT_WARN = 75
DEFAULT_CRIT = 50

def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # Single-service check: always discover one item (no per-item breakdown)
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {"lower_levels": ("fixed", (75, 50))}, "metrics": ["health_state"]}]}
        }

    # Check mode: gather data via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Fetch both OIDs in one walk: base=".1.3.6.1.4.1.9148.3.2.1.1", oids=["3", "4"]
    base_oid = ".1.3.6.1.4.1.9148.3.2.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)

    # Parse SNMP output lines: "<OID> = <TYPE>: <value>"
    score = None
    status = None

    for line in res.stdout.splitlines():
        # Skip empty lines
        if not line.strip():
            continue
        # Split OID and value
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()

        # Extract value (strip type prefix if present, e.g., "Gauge32: 95" -> "95")
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part

        # Match OID suffixes
        if oid.endswith(".3"):
            score = value
        elif oid.endswith(".4"):
            status = value

    # Missing data -> UNKNOWN
    if score == None or status == None:
        return {
            "changed": False,
            "msg": "missing SNMP data for ACME SBC",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map status to state and label
    state_code, state_label = MAP_STATES.get(status, (3, "unknown"))

    # Determine Starlark state string from SNMP code (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_str = state_map.get(state_code, "UNKNOWN")

    # Parse score to int (guard before conversion)
    score_int = 0
    if score.isdigit() or (score.startswith("-") and score[1:].isdigit()):
        score_int = int(score)

    # Apply thresholds: lower_levels means warn/crit are LOWER bounds
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    # Check levels: lower_levels -> CRIT if <= crit, WARN if <= warn, else OK
    # Note: params may contain 'lower_levels' tuple, but our API uses warn/crit keys
    if score_int <= crit:
        state_str = "CRIT"
    elif score_int <= warn:
        state_str = "WARN"

    # Format message
    msg = "Health state: %s, Score: %d%%" % (state_label, score_int)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_str,
            "metrics": {"health_state": score_int},
            "details": ""
        },
    }
