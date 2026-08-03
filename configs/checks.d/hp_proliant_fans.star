# Translated from Checkmk check: hp_proliant_fans
# HW FAN%s
#
# Reads the HPE Insight Management-MIB / CPQHLTH-MIB fan table directly via SNMP
# (same OIDs the Checkmk SimpleSNMPSection fetches from base
# .1.3.6.1.4.1.232.6.2.6.7.1, columns 2..12) and reports one service per
# present fan.

FANS_BASE_OID = ".1.3.6.1.4.1.232.6.2.6.7.1"

COL_PRESENT = "4"
COL_SPEED = "6"
COL_STATUS = "9"
COL_RPM = "12"

FAN_STATUS_MAP = {
    "1": "other",
    "2": "ok",
    "3": "degraded",
    "4": "failed",
}
FAN_SPEED_MAP = {
    "1": "other",
    "2": "normal",
    "3": "high",
}
FAN_LOCALE = {
    "1": "other",
    "2": "unknown",
    "3": "system",
    "4": "systemBoard",
    "5": "ioBoard",
    "6": "cpu",
    "7": "memory",
    "8": "storage",
    "9": "removableMedia",
    "10": "powerSupply",
    "11": "ambient",
    "12": "chassis",
    "13": "bridgeCard",
}
STATE_MAP = {
    "unknown": "UNKNOWN",
    "other": "UNKNOWN",
    "ok": "OK",
    "degraded": "CRIT",
    "failed": "CRIT",
    "disabled": "WARN",
}

DISCLAIMER = "HPE started to report the speed in percent without updating the MIB.\nThis means that for a reported speed of 'other', 'normal' or 'high', there is the chance that the speed is actually 1, 2 or 3 percent respectively.\nThis has no influence on the service state."


def _sanitize_item(item):
    return item.replace("\x00", "\\x00")


def _get_community(params):
    return params.get("community", "public")


def _snmp_get(ctx, params, oid):
    community = _get_community(params)
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", oid],
        mutates=False,
    )


def _snmp_walk(ctx, params, oid):
    community = _get_community(params)
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", oid],
        mutates=False,
    )


def _get_product_name(ctx, params):
    res = _snmp_get(ctx, params, "1.3.6.1.4.1.232.2.2.4.2.0")
    if res.rc != 0 or not res.stdout:
        return None
    return res.stdout.strip()


def _is_proliant(ctx, params):
    name = _get_product_name(ctx, params)
    if name == None:
        return False
    n = name.lower()
    return "proliant" in n or "storeeasy" in n or "synergy" in n


def _parse_fan_line(index, present, speed, status, rpm):
    locale = FAN_LOCALE.get(index, "other")
    return {
        "index": index,
        "locale": locale,
        "is_present": present == "3",
        "speed": int(speed) if speed else 0,
        "status": int(status) if status else 1,
        "speed_rpm": int(rpm) if rpm else None,
    }


def _fetch_fans(ctx, params):
    present_col = FANS_BASE_OID + "." + COL_PRESENT
    speed_col = FANS_BASE_OID + "." + COL_SPEED
    status_col = FANS_BASE_OID + "." + COL_STATUS
    rpm_col = FANS_BASE_OID + "." + COL_RPM

    res = _snmp_walk(ctx, params, present_col)
    if res.rc != 0 or not res.stdout:
        return {}

    fans = {}
    for line in res.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        row_oid = parts[0]
        row_val = parts[1]

        oid_parts = row_oid.split(".")
        col_id_pos = None
        for ci, cp in enumerate(oid_parts):
            if cp == COL_PRESENT:
                col_id_pos = ci
                break
        if col_id_pos == None:
            continue
        index = ".".join(oid_parts[(col_id_pos + 1):])

        present = row_val

        speed_v = _snmp_get(ctx, params, speed_col + "." + index)
        speed = speed_v.stdout.strip() if speed_v.rc == 0 else ""

        status_v = _snmp_get(ctx, params, status_col + "." + index)
        status = status_v.stdout.strip() if status_v.rc == 0 else ""

        rpm_v = _snmp_get(ctx, params, rpm_col + "." + index)
        rpm = rpm_v.stdout.strip() if rpm_v.rc == 0 else ""

        fan = _parse_fan_line(index, present, speed, status, rpm)
        item = _sanitize_item(index + " (" + fan["locale"] + ")")
        fans[item] = fan
    return fans


def main(ctx, params):
    if not _is_proliant(ctx, params):
        return {
            "changed": False,
            "msg": "not an HPE ProLiant / StoreEasy / Synergy system",
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        fans = _fetch_fans(ctx, params)
        discovery = []
        for item, fan in fans.items():
            if fan["is_present"]:
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["rpm"],
                })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {
                    "cmk/os_family": ctx.facts().get("os_family", "unknown"),
                },
            },
        }

    item = params.get("item", "")

    if item == "":
        return {
            "changed": False,
            "msg": "no fan item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fans = _fetch_fans(ctx, params)
    fan = fans.get(item)
    if fan == None:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not fan["is_present"]:
        return {
            "changed": False,
            "msg": "fan not present: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    snmp_status = FAN_STATUS_MAP.get(str(fan["status"]), "unknown")
    state = STATE_MAP.get(snmp_status, "UNKNOWN")

    speed_key = str(fan["speed"])
    speed_label = "Speed: " + (FAN_SPEED_MAP.get(speed_key, speed_key + "%"))

    metrics = {}
    if fan["speed_rpm"]:
        metrics["rpm"] = fan["speed_rpm"]

    details = speed_label + "\n" + DISCLAIMER

    return {
        "changed": False,
        "msg": "Status: " + snmp_status + ", " + speed_label,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }