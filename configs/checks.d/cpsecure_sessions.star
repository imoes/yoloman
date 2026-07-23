# Module-level constants (metrics and defaults)
DEFAULT_WARN = 2500
DEFAULT_CRIT = 5000

def main(ctx, params):
    if params.get("_discover"):
        # SNMP walk base OID for the cpsecure_sessions section
        base_oid = ".1.3.6.1.4.1.26546.3.1.2.1.1.1"
        # Fetch all rows: OIDs 1 (service name), 2 (enabled), 3 (sessions)
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        # Parse snmpwalk output lines like: "<OID>.<index> = STRING: <value>"
        section = []
        lines = res.stdout.splitlines()
        # Build section: list of [service, enabled, sessions]
        rows = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract index from OID: base.OID.index
            suffix = oid_part[len(base_oid):]
            if not suffix.startswith("."):
                continue
            cols = suffix.split(".")
            if len(cols) < 2:
                continue
            # cols[1] is column (1,2,3), cols[2] is row index if present
            col_str = cols[1]
            # Guard: check if it's a valid integer string before conversion
            if not col_str.isdigit():
                continue
            col = int(col_str)
            row_idx = cols[2] if len(cols) > 2 else "1"

            # Extract value
            value = value_part.strip()
            # Trim type prefix if present (STRING:, INTEGER:, etc.)
            if ":" in value:
                value = value.split(":", 1)[1].strip()
                # Remove quotes from STRING values
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]

            # Accumulate row data
            if row_idx not in rows:
                rows[row_idx] = {1: "", 2: "", 3: ""}
            rows[row_idx][col] = value

        # Build section from rows
        for row_idx in sorted(rows.keys()):
            row = rows[row_idx]
            service = row[1]
            enabled = row[2]
            sessions = row[3]
            if not service:
                continue
            # Skip entries with missing data
            if not enabled or not sessions:
                continue
            # Only enable services where enabled == "1"
            if enabled == "1":
                section.append([service, enabled, sessions])

        # Discovery: yield Service for each enabled service
        discovery_items = []
        for service, enabled, sessions in section:
            discovery_items.append({
                "item": service,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["sessions"]
            })

        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # CHECK mode
    item = params.get("item", "")
    # Re-fetch same data to get current session count for this item
    base_oid = ".1.3.6.1.4.1.26546.3.1.2.1.1.1"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse same way as discovery
    section = []
    lines = res.stdout.splitlines()
    rows = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        suffix = oid_part[len(base_oid):]
        if not suffix.startswith("."):
            continue
        cols = suffix.split(".")
        if len(cols) < 2:
            continue
        col_str = cols[1]
        # Guard: check if it's a valid integer string before conversion
        if not col_str.isdigit():
            continue
        col = int(col_str)
        row_idx = cols[2] if len(cols) > 2 else "1"

        value = value_part.strip()
        if ":" in value:
            value = value.split(":", 1)[1].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]

        if row_idx not in rows:
            rows[row_idx] = {1: "", 2: "", 3: ""}
        rows[row_idx][col] = value

    for row_idx in sorted(rows.keys()):
        row = rows[row_idx]
        service = row[1]
        enabled = row[2]
        sessions = row[3]
        if not service:
            continue
        if not enabled or not sessions:
            continue
        section.append([service, enabled, sessions])

    # Find the requested item
    found = False
    for service, enabled, sessions in section:
        if item == service:
            found = True
            warn = params.get("warn", DEFAULT_WARN)
            crit = params.get("crit", DEFAULT_CRIT)
            # Check enabled status
            if enabled != "1":
                # Guard: check if sessions is a valid integer string before conversion
                session_value = int(sessions) if sessions.isdigit() else 0
                return {"changed": False,
                        "msg": "service not enabled",
                        "data": {"state": "WARN", "metrics": {"sessions": session_value}, "details": ""}}

            # Parse session count - guard before conversion
            if not sessions.isdigit():
                return {"changed": False,
                        "msg": "invalid session count",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            session_count = int(sessions)

            # Determine state (fixed levels: warn=2500, crit=5000)
            if session_count >= crit:
                state = "CRIT"
            elif session_count >= warn:
                state = "WARN"
            else:
                state = "OK"
            return {"changed": False,
                    "msg": "Sessions: %d" % session_count,
                    "data": {"state": state, "metrics": {"sessions": session_count}, "details": ""}}

    if not found:
        return {"changed": False,
                "msg": "service not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
