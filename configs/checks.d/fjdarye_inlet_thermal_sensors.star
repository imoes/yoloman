# Translated Checkmk check: fjdarye_inlet_thermal_sensors
# Monitors Fujitsu storage (FJDARY-E60/E100 MIB) inlet thermal sensors via SNMP.

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",
    ".1.3.6.1.4.1.211.1.21.1.150",
    ".1.3.6.1.4.1.211.1.21.1.153",
]

SYSOID_BASE = ".1.3.6.1.2.1.1.2.0"

# <device_oid>.2.10.2.1 with column oids "1" (index) and "3" (status)
INLET_TABLE_BASE_SUFFIX = ".2.10.2.1"
INDEX_COLUMN = "1"
STATUS_COLUMN = "3"

FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

def _sysuptime_oid_ok(ctx, host, community, sysoid_oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sysoid_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return False
    val = res.stdout.strip().strip('"')
    return val in FJDARYE_SUPPORTED_DEVICES

def _walk_table(ctx, host, community, column_base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_base],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        rows.append((oid, value))
    return rows

def _get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    val = res.stdout.strip()
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        val = val[1:-1]
    return val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        supported = _sysuptime_oid_ok(ctx, host, community, SYSOID_BASE)
        if not supported:
            return {"changed": False, "msg": "no Fujitsu storage detected",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.211.1.21.1"
        index_rows = []
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            rows = _walk_table(ctx, host, community, device_oid + INLET_TABLE_BASE_SUFFIX + "." + INDEX_COLUMN)
            if rows:
                index_rows = rows
                break
        if not index_rows:
            return {"changed": False, "msg": "no inlet thermal sensors found",
                    "data": {"discovery": []}}
        discovery = []
        for oid, idx_val in index_rows:
            item_index = oid.rsplit(".", 1)[-1] if "." in oid else idx_val
            status = _get(ctx, host, community, oid.rsplit(".", 1)[0] + "." + STATUS_COLUMN + "." + item_index)
            if status == "4":
                continue
            discovery.append({"item": item_index, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d inlet thermal sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item_index = params.get("item", "")
    if not item_index:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = False
    status = None
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        idx_rows = _walk_table(ctx, host, community, device_oid + INLET_TABLE_BASE_SUFFIX + "." + INDEX_COLUMN)
        for oid, idx_val in idx_rows:
            cur_index = oid.rsplit(".", 1)[-1] if "." in oid else idx_val
            if cur_index == item_index:
                found = True
                status = _get(ctx, host, community, oid.rsplit(".", 1)[0] + "." + STATUS_COLUMN + "." + cur_index)
                break
        if found:
            break
    if not found:
        return {"changed": False, "msg": "no inlet thermal sensor: " + item_index,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if status == None:
        return {"changed": False, "msg": "could not read status for " + item_index,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    entry = FJDARYE_ITEM_STATUS.get(status)
    if entry == None:
        return {"changed": False, "msg": "unknown status code: " + str(status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, summary = entry
    label = "Inlet Thermal %s" % item_index
    return {"changed": False, "msg": label + ": " + summary,
            "data": {"state": state, "metrics": {}, "details": summary}}