def main(ctx, params):
    # Constants
    SNMP_BASE = ".1.3.6.1.4.1.1991.1.1.2.13.1.1"
    OID_DESCR = "3"
    OID_VALUE = "4"
    DEFAULT_LEVELS = (105.0, 110.0)

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            SNMP_BASE + "." + OID_DESCR,
            SNMP_BASE + "." + OID_VALUE
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        descr_map = {}
        value_map = {}

        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip('"')
                if oid_full.endswith("." + OID_DESCR):
                    idx = oid_full.split(".")[-1]
                    descr_map[idx] = value
            elif value_part.startswith("INTEGER: ") or value_part.startswith(" Gauge32: "):
                if oid_full.endswith("." + OID_VALUE):
                    idx = oid_full.split(".")[-1]
                    raw_val = value_part.split(": ")[1] if ": " in value_part else ""
                    if raw_val.isdigit():
                        value_map[idx] = int(raw_val)

        # Combine into sections and build discovery list
        discovered = []
        for idx, temp_descr in descr_map.items():
            if idx in value_map:
                temp_value = value_map[idx]
                if temp_value != 0:
                    item = (
                        temp_descr.replace("temperature", "")
                        .replace("module", "Module")
                        .replace("sensor", "Sensor")
                        .replace(",", "")
                        .strip()
                    )
                    discovered.append({
                        "item": item,
                        "params": {"levels": DEFAULT_LEVELS},
                        "metrics": ["temp"]
                    })

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn, crit = params.get("levels", DEFAULT_LEVELS)

    # Get both OID values via snmpget
    res_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        SNMP_BASE + "." + OID_DESCR + ".1"
    ], mutates=False)
    res_value = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        SNMP_BASE + "." + OID_VALUE + ".1"
    ], mutates=False)

    if res_descr.rc != 0 or res_value.rc != 0:
        return {"changed": False, "msg": "SNMP get failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse description
    temp_descr = ""
    lines = res_descr.stdout.splitlines()
    for line in lines:
        if " = STRING: " in line:
            temp_descr = line.split(" = STRING: ")[1].strip('"')
            break

    # Parse value
    temp_value_raw = None
    lines = res_value.stdout.splitlines()
    for line in lines:
        if " = INTEGER: " in line:
            raw_val = line.split(" = INTEGER: ")[1] if ": " in line else ""
            if raw_val.isdigit():
                temp_value_raw = int(raw_val)
        elif " = Gauge32: " in line:
            raw_val = line.split(" = Gauge32: ")[1] if ": " in line else ""
            if raw_val.isdigit():
                temp_value_raw = int(raw_val)

    # Apply transformation and check
    if temp_value_raw == None or temp_value_raw == 0:
        return {"changed": False, "msg": "no valid temperature data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_celsius = float(temp_value_raw) * 0.5
    state = "CRIT" if temp_celsius >= crit else ("WARN" if temp_celsius >= warn else "OK")
    msg = "Temperature: %f C" % temp_celsius

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp_celsius}, "details": ""}}