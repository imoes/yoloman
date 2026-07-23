def main(ctx, params):
    if params.get("_discover"):
        # Discovery: check if we have any sensors (total >= 1)
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.12356.101.4.3.2.1.2"
        ], mutates=False)
        if res.rc != 0:
            # SNMP not available or failed; don't discover
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Count entries by counting OIDs returned (each line contains OID)
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        total_sensors = len(lines)
        if total_sensors >= 1:
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode: fetch sensor data via SNMP
    name_res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.12356.101.4.3.2.1.2"
    ], mutates=False)
    value_res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.12356.101.4.3.2.1.3"
    ], mutates=False)
    status_res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.12356.101.4.3.2.1.4"
    ], mutates=False)

    # Handle SNMP failures gracefully
    if name_res.rc != 0 or value_res.rc != 0 or status_res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse OID -> value mapping for each table
    def parse_snmp_output(output):
        result = {}
        for line in output.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            # OID format: .1.3.6.1.4.1.12356.101.4.3.2.1.<index>.<oid-type> = VALUE
            parts = stripped.split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index from OID: last number before .<type>
            oid_components = oid_part.split(".")
            if len(oid_components) < 12:
                continue
            idx = oid_components[-2]
            result[idx] = value_part
        return result

    names = parse_snmp_output(name_res.stdout)
    values = parse_snmp_output(value_res.stdout)
    statuses = parse_snmp_output(status_res.stdout)

    # Compute totals
    total = 0
    critical_sensors = []

    for idx in names:
        value = values.get(idx, "0")
        status = statuses.get(idx, "0")
        # Ignore sensors with value "0" (disconnected)
        if value != "0":
            total += 1
            if status == "1":
                critical_sensors.append(names[idx])

    ok_sensors = total - len(critical_sensors)

    # Determine state and messages
    if len(critical_sensors) == 0:
        state = "OK"
        summary = "%d sensors, %d OK, %d with alarm" % (total, ok_sensors, 0)
    else:
        state = "CRIT"
        summary = "%d sensors, %d OK, %d with alarm" % (total, ok_sensors, len(critical_sensors))

    # Build details section
    details = ""
    for sensor in critical_sensors:
        details = details + sensor + "\n"

    # Return check result
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"total_sensors": total, "critical_sensors": len(critical_sensors)},
            "details": details.strip()
        }
    }
