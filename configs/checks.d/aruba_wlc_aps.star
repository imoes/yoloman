# Map AP model codes to product names (from Checkmk source)
_MAP_AP_PRODUCTS = {
    "1": "a50",
    "2": "a52",
    "3": "a60",
    "4": "a61",
    "5": "a70",
    "6": "walljackAp61",
    "7": "a2E",
    "8": "ap1200",
    "9": "ap80s",
    "10": "ap80m",
    "11": "wg102",
    "12": "ap40",
    "13": "ap41",
    "14": "ap65",
    "15": "NesotMW1700",
    "16": "ortronics Wi Jack Duo",
    "17": "ortronics Duo",
    "18": "ap80MB",
    "19": "ap80SB",
    "20": "ap85",
    "21": "ap124",
    "22": "ap125",
    "23": "ap120",
    "24": "ap121",
    "25": "ap1250",
    "26": "ap120abg",
    "27": "ap121abg",
    "28": "ap124abg",
    "29": "ap125abg",
    "30": "rap5wn",
    "31": "rap5",
    "32": "rap2wg",
    "34": "ap105",
    "35": "ap65wb",
    "36": "ap651",
    "38": "ap60p",
    "40": "ap92",
    "41": "ap93",
    "42": "ap68",
    "43": "ap68p",
    "44": "ap175p",
    "45": "ap175ac",
    "46": "ap175dc",
    "47": "ap134",
    "48": "ap135",
    "50": "ap93h",
    "51": "rap3wn",
    "52": "rap3wnp",
    "53": "ap104",
    "54": "rap155",
    "55": "rap155p",
    "56": "rap108",
    "57": "rap109",
    "58": "ap224",
    "59": "ap225",
    "60": "ap114",
    "61": "ap115",
    "62": "rap109L",
    "63": "ap274",
    "64": "ap275",
    "65": "ap214a",
    "66": "ap215a",
    "67": "ap204",
    "68": "ap205",
    "69": "ap103",
    "70": "ap103H",
    "72": "ap227",
    "73": "ap214",
    "74": "ap215",
    "75": "ap228",
    "76": "ap205H",
    "9999": "undefined",
}

# SNMP base OID for AP table
_BASE_OID = ".1.3.6.1.4.1.14823.2.2.1.5.2.1.4.1"
# OID suffixes for each column
_OID_AP_NAME = "3"
_OID_AP_STATUS = "19"
_OID_AP_UNPROVISIONED = "22"
_OID_AP_IP = "2"
_OID_AP_GROUP = "4"
_OID_AP_MODEL = "5"
_OID_AP_SERIAL = "6"
_OID_AP_SYSLOC = "32"

def _snmp_get_value(res, oid_suffix):
    """Extract value for a given OID suffix from snmpwalk output lines.
    Returns the first matching value or None."""
    prefix = _BASE_OID + "." + oid_suffix + " "
    for line in res.stdout.splitlines():
        if line.startswith(prefix):
            # Format: "OID = TYPE: value" or "OID TYPE: value"
            parts = line.split(":", 1)
            if len(parts) == 2:
                return parts[1].strip()
    return None

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _BASE_OID
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Group lines by AP name (first column)
        ap_entries = {}  # ap_name -> list of (oid_suffix, value)
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: "BASE.oid_suffix = TYPE: value"
            dot_idx = line.find(".")
            if dot_idx == -1:
                continue
            oid_part = line[dot_idx:].strip()
            if " = " not in oid_part:
                continue
            oid_full, value_part = oid_part.split(" = ", 1)
            value = value_part.strip()
            
            # Extract suffix after base
            if not oid_full.startswith(_BASE_OID + "."):
                continue
            suffix = oid_full[len(_BASE_OID) + 1:]
            
            # Determine which column this is
            if suffix == _OID_AP_NAME:
                # This is the key field - start new entry
                current_ap = value
                ap_entries[current_ap] = []
            else:
                # Add to current AP
                if current_ap in ap_entries:
                    ap_entries[current_ap].append((suffix, value))
        
        # Build discovered items
        items = []
        for ap_name, fields in ap_entries.items():
            # Map fields to values by suffix
            status = None
            unprovisioned = None
            for suffix, value in fields:
                if suffix == _OID_AP_STATUS:
                    status = value
                elif suffix == _OID_AP_UNPROVISIONED:
                    unprovisioned = value
            
            # Only include active, provisioned APs
            if status == "1" and (unprovisioned == None or unprovisioned != "1"):
                items.append({
                    "item": ap_name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode for specific item
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _BASE_OID
    ], mutates=False)
    
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    # Find the AP entry and extract all fields
    ap_fields = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        dot_idx = line.find(".")
        if dot_idx == -1:
            continue
        oid_full = line[dot_idx:].strip()
        if " = " not in oid_full:
            continue
        oid_full, value_part = oid_full.split(" = ", 1)
        value = value_part.strip()
        
        # Check if this line belongs to our target AP
        if oid_full.startswith(_BASE_OID + "." + _OID_AP_NAME + " "):
            ap_name = value
            if ap_name == item:
                # Collect all fields for this AP
                ap_fields["name"] = value
            else:
                # Reset collection if we found another AP
                if ap_fields.get("name") == item:
                    break
                ap_fields = {}
        elif ap_fields.get("name") == item:
            # Collect other fields
            if oid_full == _BASE_OID + "." + _OID_AP_STATUS:
                ap_fields["status"] = value
            elif oid_full == _BASE_OID + "." + _OID_AP_UNPROVISIONED:
                ap_fields["unprovisioned"] = value
            elif oid_full == _BASE_OID + "." + _OID_AP_GROUP:
                ap_fields["group"] = value
            elif oid_full == _BASE_OID + "." + _OID_AP_SYSLOC:
                ap_fields["sys_location"] = value
    
    # Verify we found the AP
    if ap_fields.get("name") != item:
        return {
            "changed": False,
            "msg": "AP not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get status and unprovisioned
    status = ap_fields.get("status", "")
    unprovisioned = ap_fields.get("unprovisioned", "0")
    group = ap_fields.get("group", "")
    sys_location = ap_fields.get("sys_location", "")
    
    # Map status to state
    if status == "1":
        state = "OK"
        state_readable = "up"
    elif status == "2":
        state = "CRIT"
        state_readable = "down"
    else:
        state = "UNKNOWN"
        state_readable = "unknown"
    
    # Build info text
    infotext = "Status: " + state_readable
    if group != "":
        infotext += ", Group: " + group
    if sys_location != "":
        infotext += ", System location: " + sys_location
    
    # Handle unprovisioned
    unprovisioned_text = ""
    if unprovisioned == "1":
        unprovisioned_text = ", Unprovisioned: yes"
    
    # Final output
    return {
        "changed": False,
        "msg": infotext + unprovisioned_text,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
