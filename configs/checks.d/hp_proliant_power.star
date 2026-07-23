def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Walk both required OIDs for hp_proliant_power section
        status_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.6.2.15.2"
        ], mutates=False)
        reading_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.6.2.15.3"
        ], mutates=False)

        # Parse status OID output: ".1.3.6.1.4.1.232.6.2.15.2.0 = INTEGER: 2"
        status_value = None
        for line in status_res.stdout.splitlines():
            if line.strip():
                parts = line.strip().split()
                if len(parts) >= 4 and parts[-2] == "=":
                    status_value = parts[-1].strip()
                    break

        # Parse reading OID output: ".1.3.6.1.4.1.232.6.2.15.3.0 = INTEGER: 450"
        reading_value = None
        for line in reading_res.stdout.splitlines():
            if line.strip():
                parts = line.strip().split()
                if len(parts) >= 4 and parts[-2] == "=":
                    reading_value = parts[-1].strip()
                    break

        # Determine status string
        status_map = {"1": "other", "2": "present", "3": "absent"}
        status = status_map.get(status_value, "other")

        # If status is not "absent", we have a service to discover
        if status != "absent":
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"levels": None},
                            "metrics": ["power"]
                        }
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no service discovered - power meter absent",
                "data": {"discovery": []}
            }

    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn = params.get("levels")
    
    # Fetch both required OIDs
    status_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.6.2.15.2"
    ], mutates=False)
    reading_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.6.2.15.3"
    ], mutates=False)

    # Parse status value
    status_value = None
    for line in status_res.stdout.splitlines():
        if line.strip():
            parts = line.strip().split()
            if len(parts) >= 4 and parts[-2] == "=":
                status_value = parts[-1].strip()
                break

    # Parse reading value
    reading_value = None
    for line in reading_res.stdout.splitlines():
        if line.strip():
            parts = line.strip().split()
            if len(parts) >= 4 and parts[-2] == "=":
                reading_value = parts[-1].strip()
                break

    # Map status code to status string
    status_map = {"1": "other", "2": "present", "3": "absent"}
    status = status_map.get(status_value, "other")

    # Check status first
    if status != "present":
        return {
            "changed": False,
            "msg": "Power Meter state: %s" % status,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

    # Parse reading as integer safely
    reading = int(reading_value) if reading_value and reading_value.isdigit() else None
    if reading == None:
        return {
            "changed": False,
            "msg": "Power Meter state: present, reading not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Apply levels if provided
    state = "OK"
    if warn != None and type(warn) == "list" and len(warn) >= 2:
        upper_warn = warn[0]
        upper_crit = warn[1]
        if reading >= upper_crit:
            state = "CRIT"
        elif reading >= upper_warn:
            state = "WARN"
    
    # Build message
    msg = "Current reading: %d Watts" % reading
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"power": reading},
            "details": ""
        }
    }