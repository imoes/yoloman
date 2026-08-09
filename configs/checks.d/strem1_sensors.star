def main(ctx, params):
    # Constants
    DEFAULT_WARN = 28.0
    DEFAULT_CRIT = 32.0
    SENSOR_TYPE_HUMIDITY_WETNESS = ["Humidity", "Wetness"]

    # Discovery mode: enumerate all valid sensors
    if params.get("_discover") != None:
        # Fetch SNMP data: two sections: [0] = unit of measure, [1] = sensor data
        res0 = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.16174.1.1.3.2.3.1"], mutates=False)
        res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.16174.1.1.3.3"], mutates=False)

        if res0.rc != 0 or res1.rc != 0:
            fail("SNMP query failed")
        
        # Parse unit of measure (first section)
        uoms = res0.stdout.strip().split()
        uom = ""
        if len(uoms) >= 2:
            # Extract value part after '='
            eq_idx = res0.stdout.find("=")
            if eq_idx != -1:
                uom = res0.stdout[eq_idx+1:].strip()

        # Parse sensor data (second section): group by OID base
        lines = [l.strip() for l in res1.stdout.splitlines() if l.strip()]
        sensors = []
        i = 0
        while i < len(lines):
            # Expect 4 consecutive lines per sensor: index, type, value, intval
            if i + 3 >= len(lines):
                break
            # Extract values from lines like: .1.3.6.1.4.1.16174.1.1.3.3.1.1 = INTEGER: 1
            def extract_value(line):
                eq = line.find("=")
                if eq == -1:
                    return ""
                return line[eq+1:].strip().split(":")[-1].strip()
            
            idx = extract_value(lines[i])
            typ = extract_value(lines[i+1])
            val = extract_value(lines[i+2])
            intval = extract_value(lines[i+3])
            
            # Skip invalid sensors (val == "-999.9")
            if val != "-999.9":
                sensors.append({
                    "item": idx,
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": [typ.lower()]
                })
            i += 4
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(sensors),
            "data": {"discovery": sensors}
        }

    # Check mode: verify one sensor
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch both SNMP sections
    res0 = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.16174.1.1.3.2.3.1"], mutates=False)
    res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.16174.1.1.3.3"], mutates=False)

    if res0.rc != 0 or res1.rc != 0:
        fail("SNMP query failed")

    # Parse unit of measure
    uom = ""
    eq_idx = res0.stdout.find("=")
    if eq_idx != -1:
        uom = res0.stdout[eq_idx+1:].strip()

    # Parse sensor data
    lines = [l.strip() for l in res1.stdout.splitlines() if l.strip()]
    i = 0
    found = False
    while i < len(lines):
        if i + 3 >= len(lines):
            break
        def extract_value(line):
            eq = line.find("=")
            if eq == -1:
                return ""
            return line[eq+1:].strip().split(":")[-1].strip()
        
        idx = extract_value(lines[i])
        typ = extract_value(lines[i+1])
        val = extract_value(lines[i+2])
        intval = extract_value(lines[i+3])
        
        if idx == item:
            found = True
            
            # Determine measurement unit
            unit = uom if typ == "Temperature" else "%"
            
            # Convert value to float
            val_f = float(val) if val.isdigit() or (val.find(".") != -1 and val.replace(".", "").replace("-", "").isdigit()) else 0.0
            
            # Set thresholds based on type
            warn = None
            crit = None
            type_found = False
            for t in SENSOR_TYPE_HUMIDITY_WETNESS:
                if t == typ:
                    type_found = True
                    break
            if type_found == False:
                warn = params.get("warn", DEFAULT_WARN)
                crit = params.get("crit", DEFAULT_CRIT)
            
            # Build info text
            infotext = "%f%s" % (val_f, unit)
            thrtext = []
            if warn != None:
                thrtext.append("warn at %f%s" % (warn, unit))
            if crit != None:
                thrtext.append("crit at %f%s" % (crit, unit))
            if len(thrtext) > 0:
                infotext += " (%s)" % ", ".join(thrtext)
            
            # Determine state
            if crit != None and val_f >= crit:
                state = "CRIT"
            elif warn != None and val_f >= warn:
                state = "WARN"
            else:
                state = "OK"
            
            # Build metrics
            metrics = {typ.lower(): val_f}
            
            return {
                "changed": False,
                "msg": "%s is: %s" % (typ, infotext),
                "data": {
                    "state": state,
                    "metrics": metrics,
                    "details": ""
                }
            }
        i += 4

    # Sensor not found
    return {
        "changed": False,
        "msg": "Sensor not found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
