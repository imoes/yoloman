def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # First, detect if Didactum is present via sysDescr
        detect = ctx.run(
            ["snmpget", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if detect.rc != 0 or detect.skipped:
            return {"changed": False, "msg": "Didactum not detected", "data": {"discovery": []}}
        if "didactum" not in detect.stdout.lower():
            return {"changed": False, "msg": "Not a Didactum device", "data": {"discovery": []}}

        # Walk the sensor table
        # OID columns: 4=type, 5=name, 6=status, 7=value
        # But we need to walk by index to correlate columns
        # The base is .1.3.6.1.4.1.46501.5.3.1
        # Column 5 (name) and 6 (status) are the most useful for discovery
        
        # Walk the type column to get indices
        type_res = ctx.run(
            ["snmpwalk", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.46501.5.3.1.4"],
            mutates=False,
        )
        if type_res.rc != 0 or type_res.skipped:
            return {"changed": False, "msg": "Cannot walk Didactum sensor table", "data": {"discovery": []}}

        # Walk the name column (OID .5)
        name_res = ctx.run(
            ["snmpwalk", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.46501.5.3.1.5"],
            mutates=False,
        )

        # Walk the status column (OID .6)
        status_res = ctx.run(
            ["snmpwalk", "-v2c",
             "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.46501.5.3.1.6"],
            mutates=False,
        )

        # Parse indices from type walk
        indices = []
        for line in type_res.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            index = oid[len(".1.3.6.1.4.1.46501.5.3.1.4") + 1:]
            if index == "":
                continue
            indices.append(index)

        if not indices:
            return {"changed": False, "msg": "No Didactum sensors found", "data": {"discovery": []}}

        # Build name lookup
        names = {}
        for line in name_res.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1].strip()
            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            prefix = ".1.3.6.1.4.1.46501.5.3.1.5."
            if oid.startswith(prefix):
                index = oid[len(prefix):]
                names[index] = value

        # Build status lookup
        statuses = {}
        for line in status_res.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1].strip()
            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            prefix = ".1.3.6.1.4.1.46501.5.3.1.6."
            if oid.startswith(prefix):
                index = oid[len(prefix):]
                statuses[index] = value

        discovery = []
        for idx in indices:
            sensor_type = ""
            for tline in type_res.stdout.splitlines():
                parts = tline.strip().split(" ", 1)
                if len(parts) != 2:
                    continue
                oid = parts[0]
                prefix = ".1.3.6.1.4.1.46501.5.3.1.4."
                if oid.startswith(prefix):
                    tindex = oid[len(prefix):]
                    if tindex == idx:
                        sensor_type = parts[1].strip()
                        if sensor_type.startswith('"') and sensor_type.endswith('"'):
                            sensor_type = sensor_type[1:-1]
                        break

            # Only relay sensors
            if sensor_type != "relay":
                continue

            name = names.get(idx, idx)
            status_readable = statuses.get(idx, "")

            # Only discover relays that are not "off" or "not connected"
            if status_readable not in ("off", "not connected"):
                discovery.append({
                    "item": name,
                    "params": {"levels": params.get("levels", [80, 90])},
                    "metrics": [],
                })

        return {"changed": False, "msg": "discovered %d relays" % len(discovery), "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")

    # Detect Didactum
    detect = ctx.run(
        ["snmpget", "-v2c",
         "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if detect.rc != 0 or detect.skipped:
        return {"changed": False, "msg": "Didactum not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "didactum" not in detect.stdout.lower():
        return {"changed": False, "msg": "Not a Didactum device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk the sensor table to find the relay with the matching name
    name_res = ctx.run(
        ["snmpwalk", "-v2c",
         "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"),
         ".1.3.6.1.4.1.46501.5.3.1.5"],
        mutates=False,
    )
    if name_res.rc != 0 or name_res.skipped:
        return {"changed": False, "msg": "Cannot walk Didactum sensor table", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    for line in name_res.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        prefix = ".1.3.6.1.4.1.46501.5.3.1.5."
        if oid.startswith(prefix):
            index = oid[len(prefix):]
            if value == item:
                target_index = index
                break

    if target_index == None:
        return {"changed": False, "msg": "Relay %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get the type for this index to confirm it's a relay
    type_res = ctx.run(
        ["snmpget", "-v2c",
         "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.46501.5.3.1.4." + target_index],
        mutates=False,
    )
    if type_res.rc != 0 or type_res.skipped:
        return {"changed": False, "msg": "Cannot read sensor type for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get the status for this index
    status_res = ctx.run(
        ["snmpget", "-v2c",
         "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.46501.5.3.1.6." + target_index],
        mutates=False,
    )
    if status_res.rc != 0 or status_res.skipped:
        return {"changed": False, "msg": "Cannot read sensor status for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_raw = status_res.stdout.strip()
    if status_raw.startswith('"') and status_raw.endswith('"'):
        status_raw = status_raw[1:-1]

    # Map status to state
    state_map = {
        "alarm": "CRIT",
        "high alarm": "CRIT",
        "low alarm": "CRIT",
        "warning": "WARN",
        "high warning": "WARN",
        "low warning": "WARN",
        "normal": "OK",
        "not connected": "UNKNOWN",
        "on": "OK",
        "off": "UNKNOWN",
    }

    state = state_map.get(status_raw, "UNKNOWN")

    return {
        "changed": False,
        "msg": "Status: %s" % status_raw,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }