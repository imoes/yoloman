# Top-level constant: board names in order of the SNMP OIDs
BOARDS = (
    "CPMA",
    "CFMA",
    "CPMB",
    "CFMB",
    "CFMC",
    "CFMD",
    "FTA",
    "FTB",
    "NI1",
    "NI2",
    "NI3",
    "NI4",
    "NI5",
    "NI6",
    "NI7",
    "NI8",
)

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch SNMP data and enumerate boards
        base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1"
        board_oids = ["8", "9", "10", "11", "12", "13", "14", "15",
                      "16", "17", "18", "19", "20", "21", "22", "23"]
        # Build full OID list for snmpwalk
        oids_list = [base_oid + "." + oid for oid in board_oids]
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost")] + oids_list,
                      mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse output: map board index to temperature value
        temperature_map = {}
        lines = res.stdout.splitlines()
        for i, line in enumerate(lines):
            if i >= len(BOARDS):
                continue
            # Format: ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1.N = INTEGER: value"
            parts = line.split()
            if len(parts) < 4:
                continue
            value_str = parts[-1].strip()
            if not value_str.isdigit():
                continue
            temperature = int(value_str)
            # Skip board_not_connected_value (0)
            if temperature != 0:
                temperature_map[BOARDS[i]] = temperature

        # Build discovery list
        discovery_list = []
        for item in temperature_map:
            discovery_list.append({
                "item": item,
                "params": {"levels": (45.0, 50.0)},
                "metrics": ["temperature"]
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature boards" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    # Check mode: examine one board
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Gather data via SNMP for this single OID
    base_oid = ".1.3.6.1.4.1.6486.801.1.1.1.3.1.1.3.1"
    if item not in BOARDS:
        return {
            "changed": False,
            "msg": "unknown board: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    board_index = BOARDS.index(item)
    oid = base_oid + "." + str(board_index + 8)  # OIDs start at 8 for CPMA

    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), oid],
                  mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for " + item + ": " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: "OID = INTEGER: value"
    line = res.stdout.strip()
    parts = line.split()
    if len(parts) < 4:
        return {
            "changed": False,
            "msg": "unexpected SNMP output for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = parts[-1].strip()
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid temperature value for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temperature = int(value_str)
    # Skip board_not_connected_value (0)
    if temperature == 0:
        return {
            "changed": False,
            "msg": "board " + item + " not connected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds
    warn = 45.0
    crit = 50.0
    levels = params.get("levels", (45.0, 50.0))
    if isinstance(levels, list):
        if len(levels) == 2:
            warn = float(levels[0])
            crit = float(levels[1])
    elif isinstance(levels, dict):
        upper_levels = levels.get("upper_levels", (45.0, 50.0))
        if isinstance(upper_levels, list) and len(upper_levels) == 2:
            warn = float(upper_levels[0])
            crit = float(upper_levels[1])
        elif isinstance(upper_levels, (float, int)):
            warn = float(upper_levels)
            crit = float(upper_levels)
    # Use defaults if parsing failed (already set above)

    # Determine state
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature Board %s: %f C" % (item, float(temperature)),
        "data": {
            "state": state,
            "metrics": {"temperature": float(temperature)},
            "details": ""
        }
    }
