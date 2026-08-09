# ibm_tl_changer_devices
# Checkmk check: IBM tape library changer device status via SNMP
# Source: cmk/plugins/ibm_tl/agent_based/ibm_tl_changer_devices.py
# Translation: read-only Starlark check module for yolo-man agent

# SNMP OIDs for IBM tape library changer devices
# .1.3.6.1.4.1.14851.3.1.11.2.1 - base
#   .4 = changerDevice-ElementName (device name, e.g. "Logical_Library: LTO6")
#   .8 = changerDevice-Availability
#   .9 = changerDevice-OperationalStatus

# IBM Tape Library Availability codes (SNIA-CIM standard)
# 1=Other, 2=Unknown, 3=OK, 4=Degraded, 5=Stressed, 6=Power, 7=Predictive Failure
# 8=On/Off, 9=Off, 10=Not Installed, 11=Install Error, 12=Backup/Restore
# For tape libraries, Availability 3=OK, 4=Degraded (WARN), 7=Predictive Failure (WARN/CRIT)

# IBM Tape Library Operational Status codes (SNIA-CIM standard)
# 0=Unknown, 1=Other, 2=OK, 3=Degraded, 4=Stressed, 5=Power,
# 6=Predictive Failure, 7=On/Off, 8=Off, 9=Test, 10=Offline, 11=Deferring
# 12=MMServices, 13=MMServices, 14=InTest, 15=Transitioning, 16=Restore

def _device_state(avail, status):
    """Map availability and operational status to state and message.
    Reproduces ibm_tape_library_get_device_state from the IBM TL check lib.
    """
    # Availability: 3=OK, others vary
    # Operational Status: 0=Unknown, 2=OK, others indicate issues
    
    # Default: OK
    state = "OK"
    msg_parts = []
    
    avail_str = str(avail)
    status_str = str(status)
    
    # Map availability
    avail_map = {
        "3":  ("OK", "OK"),
        "4":  ("WARN", "Degraded"),
        "5":  ("WARN", "Stressed"),
        "6":  ("WARN", "Power"),
        "7":  ("CRIT", "Predictive Failure"),
        "8":  ("WARN", "On/Off"),
        "9":  ("WARN", "Off"),
        "10": ("WARN", "Not Installed"),
        "11": ("WARN", "Install Error"),
    }
    
    avail_state = "UNKNOWN"
    avail_name = "Unknown"
    if avail_str in avail_map:
        avail_state, avail_name = avail_map[avail_str]
    
    # Map operational status
    status_map = {
        "0":  ("UNKNOWN", "Unknown"),
        "2":  ("OK", "OK"),
        "3":  ("WARN", "Degraded"),
        "4":  ("WARN", "Stressed"),
        "5":  ("WARN", "Power"),
        "6":  ("WARN", "Predictive Failure"),
        "7":  ("WARN", "On/Off"),
        "8":  ("WARN", "Off"),
        "9":  ("WARN", "Test"),
        "10": ("WARN", "Offline"),
        "14": ("WARN", "In Test"),
        "15": ("WARN", "Transitioning"),
    }
    
    status_state = "UNKNOWN"
    status_name = "Unknown"
    if status_str in status_map:
        status_state, status_name = status_map[status_str]
    
    # Combine: use the more severe of the two
    state_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    
    combined = avail_state
    if state_order.get(status_state, 3) > state_order.get(combined, 0):
        combined = status_state
    if state_order.get(avail_state, 3) > state_order.get(combined, 0):
        combined = avail_state
    
    if combined == "OK" and avail_state == "OK" and status_state == "OK":
        combined = "OK"
    
    # Build message
    msg = "Availability: %s, Operational Status: %s" % (avail_name, status_name)
    if avail_state != "OK":
        msg = msg + " (avail=%s)" % avail_state
    if status_state != "OK":
        msg = msg + " (status=%s)" % status_state
    
    return combined, msg


def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.14851.3.1.11.2.1"
    name_col = "4"
    avail_col = "8"
    status_col = "9"
    
    host = params.get("host", params.get("snmp_host", "localhost"))
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")
    
    if params.get("_discover"):
        # Discovery: walk the SNMP table to find all changer devices
        # First, probe for the device - check if the library is present
        # via sysObjectID detection (as in the original detect)
        sys_oid_res = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False
        )
        
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "SNMP not available",
                    "data": {"discovery": []}}
        
        # Walk the name column to enumerate devices
        walk_res = ctx.run(
            ["snmpwalk", "-" + version, "-c", community, "-Oqn",
             host, base_oid + "." + name_col],
            mutates=False
        )
        
        if walk_res.rc != 0 or not walk_res.stdout.strip():
            return {"changed": False, "msg": "No changer devices found",
                    "data": {"discovery": []}}
        
        discovery = []
        for line in walk_res.stdout.splitlines():
            # Format: ".1.3.6.1.4.1.14851.3.1.11.2.1.4.<index> <value>"
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1].strip().strip('"')
            
            # Extract index (suffix after column base)
            col_base = base_oid + "." + name_col + "."
            if not oid.startswith(col_base):
                continue
            index = oid[len(col_base):]
            
            # Make item name from the value
            item = value.replace("Logical_Library:", "").strip()
            if not item:
                item = value
            
            discovery.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        
        return {"changed": False,
                "msg": "discovered %d changer devices" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode: check one specific item
    item = params.get("item", "")
    
    # First, find the device index by walking the name column
    walk_res = ctx.run(
        ["snmpwalk", "-" + version, "-c", community, "-Oqn",
         host, base_oid + "." + name_col],
        mutates=False
    )
    
    if walk_res.rc != 0 or not walk_res.stdout.strip():
        return {"changed": False,
                "msg": "No changer devices found via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Find the index for this item
    target_index = None
    col_base = base_oid + "." + name_col + "."
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        
        if not oid.startswith(col_base):
            continue
        index = oid[len(col_base):]
        
        dev_name = value.replace("Logical_Library:", "").strip()
        if not dev_name:
            dev_name = value
        
        if dev_name == item:
            target_index = index
            break
    
    if target_index == None:
        return {"changed": False,
                "msg": "Device not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch availability and operational status by index
    avail_oid = base_oid + "." + avail_col + "." + target_index
    status_oid = base_oid + "." + status_col + "." + target_index
    
    avail_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host, avail_oid],
        mutates=False
    )
    status_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host, status_oid],
        mutates=False
    )
    
    if avail_res.rc != 0 or status_res.rc != 0:
        return {"changed": False,
                "msg": "Failed to fetch device state for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    avail = avail_res.stdout.strip()
    status = status_res.stdout.strip()
    
    state, msg = _device_state(avail, status)
    
    return {"changed": False,
            "msg": "%s - %s" % (item, msg),
            "data": {"state": state, "metrics": {}, "details": ""}}