# ===== module-level constants =====
OID_BASE = ".1.3.6.1.4.1.12196.13.1.1"
OID_VSNAME = "13"
OID_VSSTATE = "14"
OID_CONNS = "21"

VS_STATE_MAP = {
    "1": ("OK", "in service"),
    "2": ("CRIT", "out of service"),
    "3": ("CRIT", "failed"),
    "4": ("WARN", "disabled"),
    "5": ("WARN", "sorry"),
    "6": ("OK", "redirect"),
    "7": ("CRIT", "error message"),
}

# ===== helper functions =====
def _parse_snmp_line(line):
    # Format: ".1.3.6.1.4.1.12196.13.1.1.13.1 = STRING: "web-vip"
    # or:     ".1.3.6.1.4.1.12196.13.1.1.14.1 = INTEGER: 1"
    # Split on '=' and strip
    if "=" not in line:
        return None, None
    oid_part, value_part = line.split("=", 1)
    oid = oid_part.strip()
    value = value_part.strip()
    # Extract value type prefix and strip
    if value.startswith("STRING: "):
        return oid, value[8:].strip('"')
    elif value.startswith("INTEGER: "):
        val = value[9:].strip()
        return oid, val if val.isdigit() else val
    elif value.startswith("Gauge32: "):
        val = value[9:].strip()
        return oid, val if val.isdigit() else val
    else:
        # Try direct parsing
        return oid, value

def _get_oid_value(lines, oid_base):
    # Return the value for the given base OID suffix (e.g. "13" -> .13 suffix)
    for line in lines:
        oid, value = _parse_snmp_line(line)
        if oid == None or value == None:
            continue
        # Match OID ending: e.g. oid_end = ".13.1" for base "13"
        if oid.endswith("." + oid_base):
            return oid, value
    return None, None

def _walk_snmp_section(ctx, community, host):
    # Fetch all rows for the SNMP tree base
    base_oid = OID_BASE
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    return res.stdout.splitlines()

# ===== main entry =====
def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        lines = _walk_snmp_section(ctx, community, host)
        items = []
        i = 0
        while i < len(lines):
            # Parse 4 consecutive lines for each row: name, state, conns, oid_end
            row = lines[i:i+4]
            if len(row) < 4:
                i += 1
                continue

            name_oid, name = _parse_snmp_line(row[0])
            state_oid, state = _parse_snmp_line(row[1])
            conns_oid, conns = _parse_snmp_line(row[2])
            oid_end_oid, oid_end = _parse_snmp_line(row[3])

            # Validate base OID matches and name non-empty
            if name_oid == None or state_oid == None or conns_oid == None or oid_end_oid == None:
                i += 1
                continue
            if not name_oid.startswith(OID_BASE + "." + OID_VSNAME) or \
               not state_oid.startswith(OID_BASE + "." + OID_VSSTATE) or \
               not conns_oid.startswith(OID_BASE + "." + OID_CONNS):
                i += 1
                continue
            if name == "" or name == None:
                i += 1
                continue

            # Map state
            state_str = str(state) if state != None else ""
            state_code, state_txt = VS_STATE_MAP.get(state_str, ("UNKNOWN", "unknown[" + state_str + "]"))

            # Skip disabled and unknown[] items in discovery
            if state_txt in ["disabled", "unknown[]"]:
                i += 1
                continue

            # Extract conns as int if possible
            connections = int(conns) if (conns != None and conns.isdigit()) else None

            # Build suggested params (none beyond defaults)
            items.append({
                "item": name,
                "params": {},
                "metrics": ["conns"]
            })
            i += 4

        return {
            "changed": False,
            "msg": "discovered %d services" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: one item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = _walk_snmp_section(ctx, community, host)
    # Scan for the specific item
    i = 0
    found = False
    state_str = ""
    conns = ""
    while i < len(lines):
        row = lines[i:i+4]
        if len(row) < 4:
            i += 1
            continue

        name_oid, name = _parse_snmp_line(row[0])
        state_oid, state = _parse_snmp_line(row[1])
        conns_oid, conn_val = _parse_snmp_line(row[2])
        oid_end_oid, _ = _parse_snmp_line(row[3])

        # Validate base OID matches and name non-empty
        if name_oid == None or state_oid == None or conns_oid == None or oid_end_oid == None:
            i += 1
            continue
        if not name_oid.startswith(OID_BASE + "." + OID_VSNAME) or \
           not state_oid.startswith(OID_BASE + "." + OID_VSSTATE) or \
           not conns_oid.startswith(OID_BASE + "." + OID_CONNS):
            i += 1
            continue
        if name == "" or name == None:
            i += 1
            continue

        # Match the requested item
        if name == item:
            found = True
            state_str = str(state) if state != None else ""
            conns = conn_val if conn_val != None else ""
            break

        i += 4

    if not found:
        return {
            "changed": False,
            "msg": "service not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map state
    state_code, state_txt = VS_STATE_MAP.get(state_str, ("UNKNOWN", "unknown[" + state_str + "]"))

    # Parse connections
    connections = int(conns) if (conns != "" and conns.isdigit()) else None

    # Build result
    msg = "Status: " + state_txt
    data = {
        "state": state_code,
        "metrics": {},
        "details": ""
    }
    if connections != None:
        msg += ", Active connections: " + str(connections)
        data["metrics"]["conns"] = connections

    return {
        "changed": False,
        "msg": msg,
        "data": data
    }