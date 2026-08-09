# checkmk.fjdarye_thermal_sensors
# Fujitsu storage systems supporting FJDARY-E60.MIB / FJDARY-E100.MIB
# Thermal sensor status check via SNMP.

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",
    ".1.3.6.1.4.1.211.1.21.1.150",
    ".1.3.6.1.4.1.211.1.21.1.153",
]

# sysObjectID OID (for detection)
SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

# Thermal sensor table prefix: <device_oid>.2.11.2.1
# Column .1 = Index, Column .3 = Status
STATUS_OID_SUFFIX = ".2.11.2.1.3"

FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}


def _is_fjdarye_device(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        if sysoid == device_oid:
            return True
    return False


def _fetch_sensor_statuses(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    results = {}
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        column_oid = device_oid + STATUS_OID_SUFFIX
        walk_oid = column_oid  # walk gives .1, .3 etc. as index and value
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, walk_oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            full_oid = parts[0]
            value = parts[1].strip()
            # index is the suffix after the column base OID
            if full_oid.startswith(column_oid + "."):
                index = full_oid[len(column_oid) + 1:]
                if index not in results:
                    results[index] = value
    return results


def main(ctx, params):
    if params.get("_discover"):
        if not _is_fjdarye_device(ctx, params):
            return {
                "changed": False,
                "msg": "no Fujitsu device detected",
                "data": {"discovery": []},
            }
        sensors = _fetch_sensor_statuses(ctx, params)
        discovery = []
        for index, status in sensors.items():
            if status != "4":
                discovery.append(
                    {
                        "item": index,
                        "params": {},
                        "metrics": [],
                    }
                )
        return {
            "changed": False,
            "msg": "discovered %d thermal sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")

    if not _is_fjdarye_device(ctx, params):
        return {
            "changed": False,
            "msg": "no Fujitsu device detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _fetch_sensor_statuses(ctx, params)
    status = sensors.get(item)
    if status == None:
        return {
            "changed": False,
            "msg": "no thermal sensor with index " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entry = FJDARYE_ITEM_STATUS.get(status)
    if entry == None:
        return {
            "changed": False,
            "msg": "thermal sensor %s: unknown status %s" % (item, status),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state, summary = entry
    return {
        "changed": False,
        "msg": "Thermal %s: %s" % (item, summary),
        "data": {"state": state, "metrics": {}, "details": summary},
    }