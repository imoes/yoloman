# Constants (defined at module top level)
CPU_TEMP_OID_BASE = ".1.3.6.1.4.1.9.9.719.1.41.2.1"
CPU_TEMP_OID_NAME = CPU_TEMP_OID_BASE + ".2"
CPU_TEMP_OID_TEMP = CPU_TEMP_OID_BASE + ".10"

DISCOVER_DEFAULT = {"warn": 75.0, "crit": 85.0}


def main(ctx, params):
    if params.get("_discover"):
        # SNMP walk for CPU temperature data
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), CPU_TEMP_OID_NAME
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed for CPU temperature: " + res.stderr)

        # Extract CPU names and temperatures (two walks: names then temps)
        cpu_names = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # OID ends with .<index>; extract last component as index
            index = oid_part.rsplit(".", 1)[-1]
            # Value is STRING: "cpu<N>"
            name = val_part.strip('"')
            cpu_names[index] = name

        # Walk temperature OIDs
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), CPU_TEMP_OID_TEMP
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed for CPU temperature values: " + res.stderr)

        temp_map = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            index = oid_part.rsplit(".", 1)[-1]
            # Temperature is INTEGER: value in Celsius
            if val_part.isdigit():
                temp_map[index] = int(val_part)

        # Build discovery list: item = CPU name, params with defaults
        items = []
        for index, name in cpu_names.items():
            if index in temp_map:
                items.append({
                    "item": name,
                    "params": DISCOVER_DEFAULT,
                    "metrics": ["temp"]
                })

        return {
            "changed": False,
            "msg": "discovered %d CPUs" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode
    item = params.get("item", "")
    warn = params.get("warn", 75.0)
    crit = params.get("crit", 85.0)

    # Get temperature for this CPU by walking OID
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), CPU_TEMP_OID_NAME
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    cpu_oid = ""
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val_part = parts[1].strip()
        name = val_part.strip('"')
        if name == item:
            # Extract index from OID
            oid_part = parts[0].strip()
            cpu_oid = CPU_TEMP_OID_TEMP + "." + oid_part.rsplit(".", 1)[-1]
            break

    if cpu_oid == "":
        return {
            "changed": False,
            "msg": "CPU not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get temperature value
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), cpu_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for CPU temperature: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP GET response: "<oid> = INTEGER: <value>"
    temp = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val_part = parts[1].strip()
        # Handle both "INTEGER: <value>" and raw digit formats
        if val_part.startswith("INTEGER:"):
            val_str = val_part.split(":", 1)[1].strip()
            if val_str.isdigit():
                temp = int(val_str)
        elif val_part.isdigit():
            temp = int(val_part)

    if temp == None:
        return {
            "changed": False,
            "msg": "Could not parse temperature for CPU: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state
    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")

    # Checkmk-style message
    msg = "CPU %s: %d C" % (item, temp)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": float(temp)},
            "details": ""
        }
    }
