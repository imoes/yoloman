# Module: kentix_amp_sensors (temperature only, per item)
# Discovery yields one service per sensor; check reads temp via SNMP

SENSOR_OID_BASE = ".1.3.6.1.4.1.37954.1.2.7"

def _snmp_walk(ctx, base_oid, community, host):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    lines = res.stdout.splitlines()
    parsed = {}
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        oid = parts[0].strip()
        value = parts[1].strip()
        # Extract numeric OID suffix (e.g., ".1.3.6.1.4.1.37954.1.2.7.1.0" -> "1.0")
        suffix = oid.rsplit(".", 1)[-1] if "." in oid else "0"
        # Store as (suffix -> value)
        parsed[suffix] = value
    return parsed

def _parse_sensors(sensor_data, names, temps, hums, smokes):
    parsed = {}
    # Map numeric suffix to sensor index
    # suffix pattern: "<index>.<field>", where field: 1=name, 2=temp, 3=humidity, 4=dew, 5=CO, 6=motion, 7=di1, 8=di2, 9=do, 10=comErr
    sensor_index = {}
    for s, v in sensor_data.items():
        if "." not in s:
            continue
        parts = s.split(".")
        if len(parts) < 2:
            continue
        idx_part = parts[-2]  # the index part (e.g., "1" from "1.0")
        field_part = parts[-1]  # the field part (e.g., "0" from "1.0")
        if not idx_part.isdigit():
            continue
        idx = int(idx_part)
        field = int(field_part)
        if idx not in sensor_index:
            sensor_index[idx] = {}
        sensor_index[idx][field] = v.strip() if v.strip() != "" else None

    for idx, fields in sensor_index.items():
        name = fields.get(1)
        if name == None or name == "":
            continue
        temp_raw = fields.get(2)
        hum_raw = fields.get(3)
        smoke_raw = fields.get(5)
        leakage_raw = fields.get(7)

        temp = float(temp_raw) / 10.0 if (temp_raw != None and temp_raw.strip() != "") else None
        humidity = float(hum_raw) / 10.0 if (hum_raw != None and hum_raw.strip() != "") else None
        smoke = int(smoke_raw) if (smoke_raw != None and smoke_raw.strip() != "") else 0
        leakage = int(leakage_raw) if (leakage_raw != None and leakage_raw.strip() != "") else 0

        sensor = {}
        if temp != None:
            sensor["temp"] = temp
        if humidity != None:
            sensor["humidity"] = humidity
        sensor["smoke"] = smoke
        if leakage != 0:
            sensor["leakage"] = leakage
        parsed[name] = sensor

    return parsed

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sensor_data = _snmp_walk(ctx, SENSOR_OID_BASE, community, host)
        parsed = _parse_sensors(sensor_data, {}, {}, {}, {})

        items = []
        for item_name in parsed:
            items.append({
                "item": item_name,
                "params": {},
                "metrics": ["temp"]
            })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    if item == None:
        item = ""
    sensor_data = _snmp_walk(ctx, SENSOR_OID_BASE, community, host)
    parsed = _parse_sensors(sensor_data, {}, {}, {}, {})

    sensor = parsed.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp = sensor.get("temp")
    if temp == None:
        return {
            "changed": False,
            "msg": "no temperature data for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Thresholds (defaults per Checkmk temperature check)
    levels = params.get("levels", None)
    if levels != None:
        warn, crit = levels
    else:
        warn = (25.0, 30.0)
        crit = (30.0, 35.0)

    # Determine state
    state = "OK"
    summary_parts = []

    # Check upper levels (warn/crit as (warn, crit) or just upper bound)
    if isinstance(warn, (int, float)):
        upper_warn = warn
        upper_crit = crit if isinstance(crit, (int, float)) else warn
    else:
        upper_warn = warn[1] if isinstance(warn, (list, tuple)) and len(warn) > 1 else warn
        upper_crit = crit[1] if isinstance(crit, (list, tuple)) and len(crit) > 1 else crit

    if temp >= upper_crit:
        state = "CRIT"
    elif temp >= upper_warn:
        state = "WARN"

    summary_parts.append("Temperature: %f C" % temp)

    return {
        "changed": False,
        "msg": "; ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }