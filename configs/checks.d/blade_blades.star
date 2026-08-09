# Module for checkmk.blade_blades - read-only SNMP check for IBM Blade chassis blades
# Maps: exists, power, health status per blade item

MAP_EXISTS = {
    "0": ("CRIT", "false"),
    "1": ("OK", "true"),
}

MAP_POWER = {
    "0": ("CRIT", "off"),
    "1": ("OK", "on"),
    "3": ("WARN", "standby"),
    "4": ("WARN", "hibernate"),
    "255": ("UNKNOWN", "unknown"),
}

MAP_HEALTH = {
    "0": ("UNKNOWN", "unknown"),
    "1": ("OK", "good"),
    "2": ("WARN", "warning"),
    "3": ("CRIT", "critical"),
    "4": ("WARN", "kernel mode"),
    "5": ("OK", "discovering"),
    "6": ("CRIT", "communications error"),
    "7": ("CRIT", "no power"),
    "8": ("WARN", "flashing"),
    "9": ("CRIT", "initialization Failure"),
    "10": ("CRIT", "insuffiecient power"),
    "11": ("CRIT", "power denied"),
    "12": ("WARN", "maintenance mode"),
    "13": ("WARN", "firehose dump"),
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2.3.51.2.22.1.5.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse snmpwalk output into blade entries
        # Expected format: OID = STRING: value or OID = INTEGER: value
        # OIDs: .1.3.6.1.4.1.2.3.51.2.22.1.5.1.1.2.x (exists)
        #       .1.3.6.1.4.1.2.3.51.2.22.1.5.1.1.3.x (power)
        #       .1.3.6.1.4.1.2.3.51.2.22.1.5.1.1.4.x (health)
        #       .1.3.6.1.4.1.2.3.51.2.22.1.5.1.1.5.x (blade index - skip)
        #       .1.3.6.1.4.1.2.3.51.2.22.1.5.1.1.6.x (name)
        # Group by index (last number in OID)
        blades = {}  # index -> {"exists": "", "power": "", "health": "", "name": ""}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            # Extract last component as index
            oid_parts = oid.split(".")
            if len(oid_parts) < 1:
                continue
            idx_str = oid_parts[-1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)

            # Determine type by OID suffix
            if oid.endswith(".2." + str(idx)):
                blades.setdefault(idx, {})["exists"] = value
            elif oid.endswith(".3." + str(idx)):
                blades.setdefault(idx, {})["power"] = value
            elif oid.endswith(".4." + str(idx)):
                blades.setdefault(idx, {})["health"] = value
            elif oid.endswith(".6." + str(idx)):
                blades.setdefault(idx, {})["name"] = value

        # Filter to blades with power == "1" (on) and emit services
        out = []
        for idx, data in blades.items():
            if data.get("power") == "1":
                item = str(idx)
                out.append({"item": item, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d blades" % len(out),
            "data": {"discovery": out}
        }

    # Check mode
    item = params.get("item", "")
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    idx = int(item)

    # Fetch all blade data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2.3.51.2.22.1.5.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    blades = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        oid_parts = oid.split(".")
        if len(oid_parts) < 1:
            continue
        idx_str = oid_parts[-1]
        if not idx_str.isdigit():
            continue
        i = int(idx_str)
        if i == idx:
            if oid.endswith(".2." + str(idx)):
                blades["exists"] = value
            elif oid.endswith(".3." + str(idx)):
                blades["power"] = value
            elif oid.endswith(".4." + str(idx)):
                blades["health"] = value
            elif oid.endswith(".6." + str(idx)):
                blades["name"] = value

    if not blades:
        return {
            "changed": False,
            "msg": "blade %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine states
    state = "OK"
    summaries = []

    # Name
    name = blades.get("name", "")
    summaries.append(name)

    # Exists
    exists_str = blades.get("exists", "0")
    exists_state, exists_text = MAP_EXISTS.get(exists_str, ("UNKNOWN", "unknown"))
    if exists_state == "CRIT":
        state = "CRIT"
    elif exists_state == "WARN" and state != "CRIT":
        state = "WARN"
    summaries.append("Exists: %s" % exists_text)

    # Power
    power_str = blades.get("power", "0")
    power_state, power_text = MAP_POWER.get(power_str, ("UNKNOWN", "unknown"))
    if power_state == "CRIT":
        state = "CRIT"
    elif power_state == "WARN" and state != "CRIT":
        state = "WARN"
    summaries.append("Power: %s" % power_text)

    # Health
    health_str = blades.get("health", "0")
    health_state, health_text = MAP_HEALTH.get(health_str, ("UNKNOWN", "unknown"))
    if health_state == "CRIT":
        state = "CRIT"
    elif health_state == "WARN" and state != "CRIT":
        state = "WARN"
    summaries.append("Health: %s" % health_text)

    msg = ", ".join(summaries)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
