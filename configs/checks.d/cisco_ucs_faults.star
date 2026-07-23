# ===== Starlark translation of checkmk.cisco_ucs_faults =====

# SNMP OID constants for Cisco UCS fault section
_BASE_OID = ".1.3.6.1.4.1.9.9.719.1.1.1.1"
_OID_5 = ".1.3.6.1.4.1.9.9.719.1.1.1.1.5"   # cucsFaultAffectedObjectDn
_OID_6 = ".1.3.6.1.4.1.9.9.719.1.1.1.1.6"   # cucsFaultAck
_OID_9 = ".1.3.6.1.4.1.9.9.719.1.1.1.1.9"   # cucsFaultCode
_OID_11 = ".1.3.6.1.4.1.9.9.719.1.1.1.1.11" # cucsFaultDescription
_OID_20 = ".1.3.6.1.4.1.9.9.719.1.1.1.1.20" # cucsFaultSeverity

# Severity mapping: code -> (state, name)
_SEVERITY_MAP = {
    "0": ("OK", "cleared"),
    "1": ("OK", "info"),
    "3": ("WARN", "warning"),
    "4": ("WARN", "minor"),
    "5": ("CRIT", "major"),
    "6": ("CRIT", "critical"),
}

# Detect OIDs for Cisco UCS devices
_UCS_DETECT_OIDS = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]


def _get_host_oid(ctx, community, host):
    """Get sysObjectID to detect if this is a Cisco UCS device."""
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"],
                  mutates=False)
    if res.rc != 0:
        return ""
    # Output format: OID = STRING: "..."
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return ""
    oid_str = parts[1].strip().strip('"')
    return oid_str


def _discover(ctx, community, host):
    # Check if this is a Cisco UCS device
    host_oid = _get_host_oid(ctx, community, host)
    if host_oid == "":
        return []
    
    for ucs_oid in _UCS_DETECT_OIDS:
        if host_oid.endswith(ucs_oid):
            # This is a Cisco UCS device; discover one service
            return [{"item": "", "params": {}, "metrics": []}]
    return []


def _check_item(ctx, item, community, host):
    # For single-service check, item is ""
    if item != "":
        return {
            "changed": False,
            "msg": "no such item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Walk the fault section via SNMP
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _BASE_OID],
                  mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpwalk output lines: "<oid> = <type>: <value>"
    lines = res.stdout.splitlines()
    # Group values by instance index (4th OID component after base)
    faults = []
    current_fault = {"dn": "", "ack": "0", "code": "", "description": "", "severity": "0"}

    for line in lines:
        if not line.strip():
            continue
        # Parse: .1.3.6.1.4.1.9.9.719.1.1.1.1.5.1 = STRING: "..."
        dot_idx = line.find(".")
        if dot_idx == -1:
            continue
        
        # Extract OID and value
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        oid = line[:eq_idx].strip()
        value_part = line[eq_idx + 3:].strip()
        
        # Extract value (strip quotes for STRING type)
        if value_part.startswith('"') and value_part.endswith('"'):
            value = value_part[1:-1]
        else:
            # Remove type prefix (e.g., "STRING: " or "OBJECT IDENTIFIER: ")
            colon_idx = value_part.find(": ")
            if colon_idx != -1:
                value = value_part[colon_idx + 2:].strip().strip('"')
            else:
                value = value_part.strip().strip('"')
        
        # Determine OID type by checking the full OID path
        if oid.startswith(_OID_5):
            # Save previous fault if exists
            if current_fault["code"] != "":
                faults.append(current_fault.copy())
            # Start new fault record
            current_fault = {"dn": value, "ack": "0", "code": "", "description": "", "severity": "0"}
        elif oid.startswith(_OID_6):
            current_fault["ack"] = value
        elif oid.startswith(_OID_9):
            current_fault["code"] = value
        elif oid.startswith(_OID_11):
            current_fault["description"] = value
        elif oid.startswith(_OID_20):
            current_fault["severity"] = value

    # Save last fault
    if current_fault["code"] != "":
        faults.append(current_fault.copy())

    # Check faults and compute state
    max_state = "OK"
    notices = []

    for fault in faults:
        severity = fault["severity"]
        if severity in _SEVERITY_MAP:
            state, _ = _SEVERITY_MAP[severity]
            if state == "CRIT":
                max_state = "CRIT"
            elif state == "WARN" and max_state != "CRIT":
                max_state = "WARN"
        else:
            state = "OK"

        # Build notice string
        if fault["code"] != "":
            notice = "Fault: %s - %s" % (fault["code"], fault["description"])
            notices.append(notice)

    # Build summary
    if not faults:
        msg = "No faults"
    elif max_state == "OK":
        msg = "No faults"
    else:
        msg = "%d fault(s) found" % len(faults)

    details = ""
    if notices:
        details = "\n".join(notices)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": max_state,
            "metrics": {},
            "details": details,
        },
    }


def main(ctx, params):
    # Get configuration parameters with defaults
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode
    if params.get("_discover"):
        discovered = _discover(ctx, community, host)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode
    item = params.get("item", "")
    return _check_item(ctx, item, community, host)
