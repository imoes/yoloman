def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check both internal and digital sensors via SNMP
        res_internal = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.20916.1.13.1.1.1"
        ], mutates=False)
        res_digital = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), ".1.3.6.1.4.1.20916.1.13.1.2.1.1"
        ], mutates=False)

        items = []
        if res_internal.rc == 0 and res_internal.stdout.strip():
            items.append({
                "item": "Internal",
                "params": {"levels": (30.0, 35.0)},
                "metrics": ["temperature"]
            })
        if res_digital.rc == 0 and res_digital.stdout.strip():
            items.append({
                "item": "Sensor",
                "params": {"levels": (30.0, 35.0)},
                "metrics": ["temperature"]
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature items" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: gather sensor data and compute temperature verdict
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn, crit = params.get("levels", (30.0, 35.0))

    # Fetch both internal and digital sensor data
    internal_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.20916.1.13.1.1.1"
    ], mutates=False)
    digital_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.20916.1.13.1.2.1.1"
    ], mutates=False)

    # Parse internal temperature (first OID value, in Celsius if available)
    temp_celsius = None
    if internal_res.rc == 0:
        for line in internal_res.stdout.splitlines():
            if line.strip():
                parts = line.strip().split()
                if len(parts) >= 2:
                    value_str = parts[-1].strip()
                    if value_str.isdigit():
                        temp_celsius = float(value_str) / 100.0
                        break

    # Parse digital sensor temperature (first OID value from digital section)
    digital_temp = None
    if digital_res.rc == 0:
        for line in digital_res.stdout.splitlines():
            if line.strip():
                parts = line.strip().split()
                if len(parts) >= 2:
                    value_str = parts[-1].strip()
                    if value_str.isdigit():
                        digital_temp = float(value_str) / 100.0
                        break

    # Determine temperature and state
    if item == "Internal" and temp_celsius != None:
        temperature = temp_celsius
    elif item == "Sensor" and digital_temp != None:
        temperature = digital_temp
    else:
        return {
            "changed": False,
            "msg": "no temperature data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state based on thresholds
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Temperature: %f C" % temperature
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temperature},
            "details": ""
        }
    }