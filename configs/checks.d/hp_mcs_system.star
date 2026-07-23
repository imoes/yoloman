# Top-level constants
_STATUS_MAP = {
    0: ("CRIT", "Not available"),
    1: ("UNKNOWN", "Other"),
    2: ("OK", "OK"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

def _parse_status(status_int):
    """Return (state, readable) for status_int; fallback to UNKNOWN if not found."""
    return _STATUS_MAP.get(status_int, ("UNKNOWN", "Unknown status %d" % status_int))

def main(ctx, params):
    # Detect mode
    if params.get("_discover"):
        # SNMP discovery: fetch base OID .1.3.6.1.4.1.232 and decode system name
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.2.2.4.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        name = ""
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split(None, 1)
            if len(parts) < 2:
                continue
            # parts[1] looks like "STRING: \"name\""
            val_part = parts[1].strip()
            if val_part.startswith("STRING:"):
                # Extract quoted string
                rest = val_part[7:].strip()
                if rest.startswith('"') and rest.endswith('"'):
                    name = rest[1:-1]
                elif rest.startswith('"'):
                    name = rest[1:]
                else:
                    name = rest
                break
        if name == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": name, "params": {}, "metrics": []}
            ]}
        }

    # Check mode: fetch required OIDs for this item
    # OIDs: .1.3.6.1.4.1.232.2.2.4.2 (name), .1.3.6.1.4.1.232.11.2.10.1 (status bytes), .1.3.6.1.4.1.232.11.2.10.3 (serial)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    # Fetch name OID first to verify item matches
    res_name = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.2.2.4.2"
    ], mutates=False)
    if res_name.rc != 0 or res_name.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "SNMP get failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract name from snmpget output
    name_from_snmp = ""
    for line in res_name.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(None, 1)
        if len(parts) < 2:
            continue
        val_part = parts[1].strip()
        if val_part.startswith("STRING:"):
            rest = val_part[7:].strip()
            if rest.startswith('"') and rest.endswith('"'):
                name_from_snmp = rest[1:-1]
            else:
                name_from_snmp = rest
        break

    # Verify item matches (item is the system name)
    if name_from_snmp != item:
        return {
            "changed": False,
            "msg": "item '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Now fetch status and serial OIDs in one go
    # snmpget can fetch multiple OIDs
    oids = [
        ".1.3.6.1.4.1.232.11.2.10.1",  # systemStatus
        ".1.3.6.1.4.1.232.11.2.10.3"   # serialNumber
    ]
    res_status_serial = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host
    ] + oids, mutates=False)

    if res_status_serial.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for status/serial",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse outputs: one line per OID in order
    lines = [l.strip() for l in res_status_serial.stdout.splitlines() if l.strip() != ""]
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "SNMP output incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse status (second OID)
    status_val = None
    status_line = lines[0]
    if "INTEGER:" in status_line:
        # snmpget output: OID = INTEGER: 2
        parts = status_line.split("INTEGER:", 1)
        if len(parts) == 2:
            s = parts[1].strip()
            if s.isdigit():
                status_val = int(s)
            else:
                # try to remove trailing spaces/quotes
                s_clean = s.strip().rstrip('"')
                if s_clean.isdigit():
                    status_val = int(s_clean)
    if status_val == None:
        return {
            "changed": False,
            "msg": "unable to parse status value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse serial (third OID)
    serial_val = ""
    serial_line = lines[1]
    if "STRING:" in serial_line:
        parts = serial_line.split("STRING:", 1)
        if len(parts) == 2:
            rest = parts[1].strip()
            if rest.startswith('"') and rest.endswith('"'):
                serial_val = rest[1:-1]
            else:
                serial_val = rest
    if serial_val == "":
        serial_val = "Unknown"

    # Compute state
    state, state_readable = _parse_status(status_val)
    if state == "OK":
        summary = "Serial: " + serial_val
    else:
        summary = "Status: " + state_readable + ", Serial: " + serial_val

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        }
    }