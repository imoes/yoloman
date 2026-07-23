# ===== Starlark check module for checkmk.fjdarye_disks =====
# Reads disk status via SNMP and reports per-disk or summary state

# SNMP status mappings from Checkmk source
FJDARYE_DISKS_STATUS = {
    "1": ("OK", "available"),
    "2": ("CRIT", "broken"),
    "3": ("WARN", "notavailable"),
    "4": ("WARN", "notsupported"),
    "5": ("OK", "present"),
    "6": ("WARN", "readying"),
    "7": ("WARN", "recovering"),
    "64": ("WARN", "partbroken"),
    "65": ("WARN", "spare"),
    "66": ("OK", "formatting"),
    "67": ("OK", "unformated"),
    "68": ("WARN", "notexist"),
    "69": ("WARN", "copying"),
}

# Device OID mappings for different Fujitsu arrays
DEVICE_OIDS = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.12.2.1",  # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.19.2.1",  # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.12.2.1",  # fjdarye101
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.19.2.1",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.19.2.1",  # fjdarye600
}


def _walk_snmp(ctx, base_oid):
    """Walk SNMP subtree and parse output lines"""
    res = ctx.run(["snmpwalk", "-v2c", "-c", ctx.params.get("community", "public"),
                   "-On", ctx.params.get("host", "localhost"), base_oid], mutates=False)
    if res.rc != 0:
        return []
    
    disks = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(" = ")
        if len(parts) < 2:
            continue
        value_part = parts[1].strip()
        # Handle type prefixes (INTEGER:, STRING:, etc.)
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip()
            # Strip quotes from STRING type
            if value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
        else:
            value_str = value_part
        
        # Extract OID leaf (last number after final dot)
        oid_full = parts[0].strip()
        oid_leaf = oid_full.rsplit(".", 1)[-1] if "." in oid_full else oid_full
        disks.append((oid_leaf, value_str))
    
    return disks


def main(ctx, params):
    # Check for discovery mode
    if params.get("_discover"):
        discovered = []
        for device_oid, disk_oid in DEVICE_OIDS.items():
            base = device_oid + disk_oid
            disks = _walk_snmp(ctx, base)
            for disk_index, disk_state in disks:
                # Skip disks with status "3" (notavailable) during discovery
                if disk_state != "3":
                    status_tuple = FJDARYE_DISKS_STATUS.get(disk_state, ("UNKNOWN", "unknown[" + disk_state + "]"))
                    state_desc = status_tuple[1]
                    discovered.append({
                        "item": disk_index,
                        "params": {"expected_state": state_desc},
                        "metrics": []
                    })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Normal check mode: examine one item
    item = params.get("item", "")
    expected_state = params.get("expected_state", "")
    use_device_states = params.get("use_device_states", False)
    
    # Gather all disks via SNMP from all supported device OIDs
    all_disks = []
    for device_oid, disk_oid in DEVICE_OIDS.items():
        base = device_oid + disk_oid
        all_disks.extend(_walk_snmp(ctx, base))
    
    # Look up requested item
    fjdarye_disk = None
    for disk_index, disk_state in all_disks:
        if disk_index == item:
            fjdarye_disk = {
                "disk_index": disk_index,
                "state": disk_state
            }
            break
    
    # Item not found -> UNKNOWN
    if fjdarye_disk == None:
        return {
            "changed": False,
            "msg": "disk " + item + " not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Map disk state to Checkmk status and description
    status_tuple = FJDARYE_DISKS_STATUS.get(fjdarye_disk["state"], ("UNKNOWN", "unknown[" + fjdarye_disk["state"] + "]"))
    state_desc = status_tuple[1]
    
    # Use device states mode?
    if use_device_states:
        check_state = status_tuple[0]
        summary = "Status: " + state_desc + " (using device states)"
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": check_state,
                "metrics": {},
                "details": ""
            }
        }
    
    # Expected state check
    if expected_state != "" and expected_state != state_desc:
        summary = "Status: " + state_desc + " (expected: " + expected_state + ")"
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }
    
    # Default OK
    summary = "Status: " + state_desc
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
