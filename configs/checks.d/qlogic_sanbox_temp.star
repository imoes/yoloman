_STATUS_MAP = [
    "undefined",  # 0
    "unknown",    # 1
    "other",      # 2
    "ok",         # 3
    "warning",    # 4
    "failed",     # 5
]

_STATUS_MAP_LEN = len(_STATUS_MAP)


def _status_from_sensor(sensor_status):
    if sensor_status == 3:
        return "OK"
    if sensor_status == 4:
        return "WARN"
    if sensor_status == 5:
        return "CRIT"
    return "UNKNOWN"


def _clean_sensor_id(sensor_id):
    cleaned = sensor_id.replace("16.0.0.192.221.48.", "")
    cleaned = cleaned.replace(".0.0.0.0.0.0.0.0", "")
    return cleaned


def _strip_type_tag(val):
    if val == None:
        return ""
    colon = val.find(":")
    if colon >= 0:
        rest = val[colon + 1:].strip()
        if rest.startswith('"') and rest.endswith('"'):
            rest = rest[1:-1]
        if rest.startswith("'") and rest.endswith("'"):
            rest = rest[1:-1]
        return rest
    return val


def _is_int(s):
    if s == "":
        return False
    return s.lstrip("-").isdigit()


def _to_int(s):
    if _is_int(s):
        return int(s), True
    return 0, False


def _to_float(s):
    if _is_int(s):
        return float(int(s)), True
    # attempt manual float parse
    sign = 1
    body = s
    if body.startswith("-"):
        sign = -1
        body = body[1:]
    elif body.startswith("+"):
        body = body[1:]
    if body == "":
        return 0.0, False
    dots = body.count(".")
    parts = body.split(".")
    ok = True
    for p in parts:
        if p == "" or not _is_int(p):
            ok = False
            break
    if ok and dots <= 1:
        return sign * float(body), True
    return 0.0, False


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return None, "snmpget not installed"
        if res.stdout == "" and res.stderr == "":
            return None, "no response from host"
        return None, "snmpget failed for " + oid + ": " + res.stderr.strip()
    return res.stdout.strip(), None


def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return [], "snmpwalk not installed"
        if res.stdout == "" and res.stderr == "":
            return [], "no response from host"
        return [], "snmpwalk failed for " + oid + ": " + res.stderr.strip()
    rows = []
    for line in res.stdout.splitlines():
        if line == "":
            continue
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        rows.append((parts[0], parts[1]))
    return rows, None


def _fetch_sysoid(ctx, host, community):
    val, err = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if err != None:
        return "", err
    return val, None


def _is_qlogic(ctx, host, community):
    sysoid, err = _fetch_sysoid(ctx, host, community)
    if err != None:
        return False
    if sysoid.startswith(".1.3.6.1.4.1.3873.1.14"):
        return True
    if sysoid.startswith(".1.3.6.1.4.1.3873.1.8"):
        return True
    return False


def _walk_sensor_table(ctx, host, community):
    base = ".1.3.6.1.3.94.1.8.1"
    name_base = base + ".3"
    rows, err = _snmp_walk(ctx, host, community, name_base)
    if err != None:
        return [], err

    records = []
    for (line_oid, name_val) in rows:
        if not line_oid.startswith(name_base + "."):
            continue
        index = line_oid[len(name_base) + 1:]

        status_val, e1 = _snmp_get(ctx, host, community, base + ".4." + index)
        if e1 != None:
            continue
        message_val, e2 = _snmp_get(ctx, host, community, base + ".6." + index)
        if e2 != None:
            continue
        type_val, e3 = _snmp_get(ctx, host, community, base + ".7." + index)
        if e3 != None:
            continue
        char_val, e4 = _snmp_get(ctx, host, community, base + ".8." + index)
        if e4 != None:
            continue
        id_val, e5 = _snmp_get(ctx, host, community, base + ".9." + index)
        if e5 != None:
            continue

        records.append({
            "sensor_name": name_val,
            "sensor_status": status_val,
            "sensor_message": message_val,
            "sensor_type": type_val,
            "sensor_characteristic": char_val,
            "sensor_id": id_val,
        })

    return records, None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_qlogic(ctx, host, community):
            return {"changed": False, "msg": "not a Qlogic SANbox", "data": {"discovery": []}}

        records, err = _walk_sensor_table(ctx, host, community)
        if err != None:
            return {"changed": False, "msg": "discovery failed: " + err, "data": {"discovery": []}}

        out = []
        seen = set()
        for r in records:
            sensor_type = _strip_type_tag(r["sensor_type"])
            sensor_characteristic = _strip_type_tag(r["sensor_characteristic"])
            sensor_name = _strip_type_tag(r["sensor_name"])
            sensor_id = _strip_type_tag(r["sensor_id"])
            if (
                sensor_type == "8"
                and sensor_characteristic == "3"
                and sensor_name != "Temperature Status"
            ):
                item = _clean_sensor_id(sensor_id)
                if item in seen:
                    continue
                seen.add(item)
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": ["temp"],
                })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    if not _is_qlogic(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Qlogic SANbox",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    records, err = _walk_sensor_table(ctx, host, community)
    if err != None:
        return {
            "changed": False,
            "msg": "failed to fetch sensor table: " + err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    for r in records:
        sensor_id_raw = _strip_type_tag(r["sensor_id"])
        cleaned_id = _clean_sensor_id(sensor_id_raw)
        if cleaned_id != item:
            continue

        sensor_status_raw = _strip_type_tag(r["sensor_status"])
        sensor_message = _strip_type_tag(r["sensor_message"])

        status_int, ok = _to_int(sensor_status_raw)
        if not ok:
            return {
                "changed": False,
                "msg": "invalid sensor status for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

        sensor_status = status_int
        if sensor_status < 0 or sensor_status >= _STATUS_MAP_LEN:
            sensor_status_descr = str(sensor_status)
        else:
            sensor_status_descr = _STATUS_MAP[sensor_status]

        state = _status_from_sensor(sensor_status)

        metrics = {}
        if sensor_message.endswith(" degrees C"):
            temp_str = sensor_message.replace(" degrees C", "")
            temp_val, ok2 = _to_float(temp_str)
            if ok2:
                metrics = {"temp": temp_val}

        summary = "Sensor %s is at %s and reports status %s" % (item, sensor_message, sensor_status_descr)

        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""},
        }

    return {
        "changed": False,
        "msg": "No sensor %s found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }