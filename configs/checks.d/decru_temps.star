# Module-level constants
DETECT_OID = ".1.3.6.1.2.1.1.1.0"
DETECT_VALUE = "datafort"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch sensor data via SNMP and yield discovered items
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.12962.1.2.4.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                       base_oid + ".2", base_oid + ".3"], mutates=False)
        # Parse snmpwalk output: lines like ".1.3.6.1.4.1.12962.1.2.4.1.2.1 = STRING: "Sensor1"
        #                                          ".1.3.6.1.4.1.12962.1.2.4.1.3.1 = INTEGER: 113"
        # We need to pair name (oid .2) and temp (oid .3) per index
        # Group by index (last component of OID)
        index_to_name = {}
        index_to_temp = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index from OID: base.OID.index
            if oid_part.startswith(base_oid + ".2"):
                idx = oid_part[len(base_oid + ".2."):]
                # Value is STRING: "Name"
                if value_part.startswith("STRING: "):
                    name = value_part[len("STRING: "):].strip('"')
                    index_to_name[idx] = name
            elif oid_part.startswith(base_oid + ".3"):
                idx = oid_part[len(base_oid + ".3."):]
                # Value is INTEGER: temp_f
                if value_part.startswith("INTEGER: "):
                    temp_str = value_part[len("INTEGER: "):].strip()
                    if temp_str != "" and (temp_str[0] == '-' or temp_str.isdigit()):
                        rawtemp = int(temp_str)
                        index_to_temp[idx] = rawtemp
        discovery = []
        for idx, name in index_to_name.items():
            if idx in index_to_temp:
                temp_f = index_to_temp[idx]
                # Convert to Celsius: (F - 32) * 5/9
                temp_c = int((temp_f - 32) * 5.0 / 9.0)
                warn = temp_c + 4
                crit = temp_c + 8
                discovery.append({
                    "item": name,
                    "params": {"levels": (warn, crit)},
                    "metrics": ["temp"]
                })
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.12962.1.2.4.1"
    # Fetch both name and temp OIDs to find the item
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                   base_oid + ".2", base_oid + ".3"], mutates=False)

    # Parse into name/temp pairs
    index_to_name = {}
    index_to_temp = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if oid_part.startswith(base_oid + ".2"):
            idx = oid_part[len(base_oid + ".2."):]
            if value_part.startswith("STRING: "):
                name = value_part[len("STRING: "):].strip('"')
                index_to_name[idx] = name
        elif oid_part.startswith(base_oid + ".3"):
            idx = oid_part[len(base_oid + ".3."):]
            if value_part.startswith("INTEGER: "):
                temp_str = value_part[len("INTEGER: "):].strip()
                if temp_str != "" and (temp_str[0] == '-' or temp_str.isdigit()):
                    rawtemp = int(temp_str)
                    index_to_temp[idx] = rawtemp

    temp_c = None
    for idx, name in index_to_name.items():
        if name == item and idx in index_to_temp:
            temp_f = index_to_temp[idx]
            temp_c = (temp_f - 32) * 5.0 / 9.0
            break

    if temp_c == None:
        return {"changed": False,
                "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply threshold logic
    warn, crit = None, None
    levels = params.get("levels", None)
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]

    # Checkmk temperature check rules:
    # upper levels -> WARN if value >= warn, CRIT if value >= crit
    if crit != None and temp_c >= crit:
        state = "CRIT"
    elif warn != None and temp_c >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format message: "25.5 C, critical at 40 C, warning at 36 C"
    msg_parts = []
    msg_parts.append("%f C" % temp_c)
    if warn != None:
        msg_parts.append("warning at %f C" % warn)
    if crit != None:
        msg_parts.append("critical at %f C" % crit)

    return {"changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"temp": temp_c}, "details": ""}}
