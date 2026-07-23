BASE_OID = ".1.3.6.1.4.1.232.6.2.6.7.1"

FANS_LOCALE = {
    1: "other",
    2: "unknown",
    3: "system",
    4: "systemBoard",
    5: "ioBoard",
    6: "cpu",
    7: "memory",
    8: "storage",
    9: "removableMedia",
    10: "powerSupply",
    11: "ambient",
    12: "chassis",
    13: "bridgeCard",
}

FANS_STATUS_MAP = {1: "other", 2: "ok", 3: "degraded", 4: "failed"}
SPEED_MAP = {1: "other", 2: "normal", 3: "high"}
STATUS_TO_STATE = {"other": "UNKNOWN", "ok": "OK", "degraded": "CRIT", "failed": "CRIT"}


def _snmp_parse_line(line):
    eq_idx = line.find(" = ")
    if eq_idx < 0:
        return [], ""
    oid_str = line[:eq_idx].lstrip(".")
    parts = oid_str.split(".")
    rest = line[eq_idx + 3:]
    colon_idx = rest.find(": ")
    val = rest[colon_idx + 2:].strip() if colon_idx >= 0 else rest.strip()
    return parts, val


def _collect_rows(stdout):
    rows = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line or " = " not in line:
            continue
        parts, val = _snmp_parse_line(line)
        # base OID has 12 numeric components, then column, then row index
        if len(parts) < 14:
            continue
        col = parts[12]
        row = parts[13]
        if row not in rows:
            rows[row] = {}
        rows[row][col] = val
    return rows


def _make_item(index, locale_num):
    label = FANS_LOCALE.get(locale_num, "other")
    return ("%d (%s)" % (index, label)).replace("\x00", "\\x00")


def _build_fans(rows):
    fans = {}
    for row_id in rows:
        r = rows[row_id]
        idx_str = r.get("2", "")
        locale_str = r.get("3", "")
        present_str = r.get("4", "")
        speed_str = r.get("6", "")
        status_str = r.get("9", "")
        rpm_str = r.get("12", "")

        if not idx_str.isdigit():
            continue

        index = int(idx_str)
        locale_num = int(locale_str) if locale_str.isdigit() else 1
        speed = int(speed_str) if speed_str.isdigit() else 1
        status = int(status_str) if status_str.isdigit() else 1
        # treat 0 as absent — matches Checkmk "if fan.speed_rpm:" guard
        speed_rpm = int(rpm_str) if (rpm_str.isdigit() and int(rpm_str) > 0) else None

        item = _make_item(index, locale_num)
        fans[item] = {
            "is_present": present_str == "3",
            "speed": speed,
            "status": status,
            "speed_rpm": speed_rpm,
        }
    return fans


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
    )

    if params.get("_discover"):
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no SNMP data", "data": {"discovery": []}}
        rows = _collect_rows(res.stdout)
        fans = _build_fans(rows)
        discovered = []
        for item in sorted(fans.keys()):
            fan = fans[item]
            if fan["is_present"]:
                metrics = ["status"]
                if fan["speed_rpm"] != None:
                    metrics.append("rpm")
                discovered.append({"item": item, "params": {}, "metrics": metrics})
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovered),
            "data": {"discovery": discovered},
        }

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP walk failed for " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _collect_rows(res.stdout)
    fans = _build_fans(rows)
    item = params.get("item", "")
    fan = fans.get(item)

    if fan == None:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    snmp_status = FANS_STATUS_MAP.get(fan["status"], "other")
    state = STATUS_TO_STATE.get(snmp_status, "UNKNOWN")

    speed_val = fan["speed"]
    speed_label = SPEED_MAP.get(speed_val, None)
    if speed_label != None:
        speed_str = "Speed: " + speed_label
    else:
        speed_str = "Speed: %d%%" % speed_val

    metrics = {"status": fan["status"]}
    parts_msg = ["Status: " + snmp_status, speed_str]

    if fan["speed_rpm"] != None:
        metrics["rpm"] = fan["speed_rpm"]
        parts_msg.append("RPM: %d" % fan["speed_rpm"])

    return {
        "changed": False,
        "msg": ", ".join(parts_msg),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }