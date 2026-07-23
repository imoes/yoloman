# Top-level constants
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_KENTIX_PREFIX = ".1.3.6.1.4.1.332.11.6"
BASE_OID = ".1.3.6.1.4.1.37954.1"
SMOKE_OID = BASE_OID + ".2.7.5"

def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), SMOKE_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            # Expected format: OID = INTEGER: value
            if line == None or line.strip() == "":
                continue
            parts = line.strip().rsplit(" = ", 1)
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER: "):
                # Extract sensor name by walking the name OID
                # OID pattern: .1.3.6.1.4.1.37954.1.2.7.1.<idx>
                # We need to derive the index from the smoke OID: .1.3.6.1.4.1.37954.1.2.7.5.<idx>
                if not oid_part.endswith(".5"):
                    continue
                # Extract index from .5 to get ".1" equivalent for sensor name OID
                # e.g., .1.3.6.1.4.1.37954.1.2.7.5.1 -> .1.3.6.1.4.1.37954.1.2.7.1.1
                idx = oid_part.rsplit(".", 1)[1]
                name_oid = BASE_OID + ".2.7.1." + idx
                res_name = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                                    params.get("host", "localhost"), name_oid], mutates=False)
                if res_name.rc == 0:
                    # Expected: OID = STRING: "sensor-name"
                    name_line = res_name.stdout.strip()
                    if name_line:
                        name_parts = name_line.rsplit(" = STRING: ", 1)
                        if len(name_parts) == 2:
                            sensor_name = name_parts[1].strip().strip('"')
                            items.append({"item": sensor_name, "params": {"levels": [1.0, 5.0]},
                                          "metrics": ["smoke_perc"]})
        
        return {"changed": False, "msg": "discovered %d smoke detectors" % len(items),
                "data": {"discovery": items}}
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    if item == None:
        item = ""
    
    # Walk all smoke sensors to find matching item
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), SMOKE_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Build mapping from sensor name to smoke value
    # We need the sensor name OID (.1.3.6.1.4.1.37954.1.2.7.1.<idx>) to correlate
    smoke_values = {}
    name_oid_base = BASE_OID + ".2.7.1."
    
    for line in res.stdout.splitlines():
        if line == None or line.strip() == "":
            continue
        parts = line.strip().rsplit(" = ", 1)
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER: "):
            idx = oid_part.rsplit(".", 1)[1]
            # Get sensor name
            name_oid = name_oid_base + idx
            res_name = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                                params.get("host", "localhost"), name_oid], mutates=False)
            if res_name.rc == 0:
                name_line = res_name.stdout.strip()
                if name_line:
                    name_parts = name_line.rsplit(" = STRING: ", 1)
                    if len(name_parts) == 2:
                        sensor_name = name_parts[1].strip().strip('"')
                        # Get smoke value (percent)
                        smoke_val = float(value_part.split("INTEGER: ")[1].strip())
                        smoke_values[sensor_name] = smoke_val
    
    # Find our item
    if not item in smoke_values:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    smoke = smoke_values[item]
    levels = params.get("levels", [1.0, 5.0])
    warn = levels[0] if len(levels) >= 1 else 1.0
    crit = levels[1] if len(levels) >= 2 else 5.0
    
    # Upper levels: WARN if >= warn, CRIT if >= crit
    if smoke >= crit:
        state = "CRIT"
    elif smoke >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False, "msg": "Smoke: %f%%" % smoke,
            "data": {"state": state, "metrics": {"smoke_perc": smoke}, "details": ""}}