def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.3699.1.1.2.1.6.1.1"
        ], mutates=False)
        
        # Parse SNMP output: collect lines into a structured list
        lines = res.stdout.splitlines() if res.stdout else []
        data = {}
        for line in lines:
            if not line.strip():
                continue
            # Format: OID.index = TYPE: value
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            value_part = parts[1]
            # Extract index from OID like .1.3.6.1.4.1.3699.1.1.2.1.6.1.1.1.1
            suffix = oid_part.rsplit(".", 1)
            if len(suffix) != 2:
                continue
            index_str = suffix[1]
            index = int(index_str) if index_str.isdigit() else 0
            
            # Determine OID type by base suffix
            # We need to group by index: build a dict of {index: {field: value}}
            if index not in data:
                data[index] = {}
            
            # Map OID sub-index to field names
            # .1.3.6.1.4.1.3699.1.1.2.1.6.1.1.1 = digIntputIndex
            # .1.3.6.1.4.1.3699.1.1.2.1.6.1.1.2 = digIntputDescription
            # .1.3.6.1.4.1.3699.1.1.2.1.6.1.1.5 = digIntputValue
            # .1.3.6.1.4.1.3699.1.1.2.1.6.1.1.6 = digIntputNormalValue
            last_idx = int(suffix[1])
            if last_idx == 1:
                data[index]["index"] = value_part.split(": ", 1)[-1].strip()
            elif last_idx == 2:
                val = value_part.split(": ", 1)[-1].strip()
                data[index]["description"] = val.strip('"')
            elif last_idx == 5:
                # digIntputValue: INTEGER: 0 (closed) or 1 (open)
                val = value_part.split(": ", 1)[-1].strip()
                if val.isdigit():
                    data[index]["value"] = val
                else:
                    data[index]["value"] = "0"  # default
            elif last_idx == 6:
                # digIntputNormalValue: INTEGER: 0 (closed) or 1 (open)
                val = value_part.split(": ", 1)[-1].strip()
                if val.isdigit():
                    data[index]["normal_value"] = val
                else:
                    data[index]["normal_value"] = "1"  # default

        # Build discovery list: item = "description index"
        discovery = []
        for idx in sorted(data.keys()):
            d = data[idx]
            desc = d.get("description", "")
            idx_str = d.get("index", "")
            item = desc + " " + idx_str if desc else idx_str
            if not item:
                continue
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["status"]
            })
        return {
            "changed": False,
            "msg": "discovered %d digital sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch all digital sensor data in one walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.3699.1.1.2.1.6.1.1"
    ], mutates=False)
    
    lines = res.stdout.splitlines() if res.stdout else []
    data = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1]
        suffix = oid_part.rsplit(".", 1)
        if len(suffix) != 2:
            continue
        index_str = suffix[1]
        index = int(index_str) if index_str.isdigit() else 0
        
        if index not in data:
            data[index] = {}
        last_idx = int(suffix[1])
        if last_idx == 1:
            data[index]["index"] = value_part.split(": ", 1)[-1].strip()
        elif last_idx == 2:
            val = value_part.split(": ", 1)[-1].strip()
            data[index]["description"] = val.strip('"')
        elif last_idx == 5:
            val = value_part.split(": ", 1)[-1].strip()
            if val.isdigit():
                data[index]["value"] = val
            else:
                data[index]["value"] = "0"
        elif last_idx == 6:
            val = value_part.split(": ", 1)[-1].strip()
            if val.isdigit():
                data[index]["normal_value"] = val
            else:
                data[index]["normal_value"] = "1"

    # Find matching sensor
    found = False
    for idx in data.keys():
        d = data[idx]
        desc = d.get("description", "")
        idx_str = d.get("index", "")
        sensor_item = desc + " " + idx_str if desc else idx_str
        if sensor_item == item:
            value = d.get("value", "0")
            normal = d.get("normal_value", "1")
            found = True
            if value == "unknown":
                return {
                    "changed": False,
                    "msg": "Sensor value is unknown",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            if value == normal:
                return {
                    "changed": False,
                    "msg": "Sensor Value is normal: %s" % value,
                    "data": {"state": "OK", "metrics": {"status": 1 if value == "1" else 0}, "details": ""}
                }
            return {
                "changed": False,
                "msg": "Sensor Value is not normal: %s . It should be: %s" % (value, normal),
                "data": {"state": "CRIT", "metrics": {"status": 0 if value == "0" else 1}, "details": ""}
            }

    # Not found
    return {
        "changed": False,
        "msg": "Digital sensor not found: %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
