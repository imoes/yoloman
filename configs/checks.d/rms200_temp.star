# RMS200 temperature sensor check (SNMP).
# Translates Checkmk plugin cmk/plugins/infratec_plus/agent_based/rms200_temp.py.

# SNMP OIDs for the RMS200 temperature section.
SYS_OID = ".1.3.6.1.2.1.1.2.0"
PROD_OID = ".1.3.6.1.4.1.1909.13"
TABLE_BASE = ".1.3.6.1.4.1.1909.13.1.1.1"
COL_SENSOR = "1"
COL_LABEL = "2"
COL_TEMP = "5"
COL_TEMP_BASE = TABLE_BASE + "." + COL_TEMP
COL_LABEL_BASE = TABLE_BASE + "." + COL_LABEL

# Defaults mirror Checkmk's check_default_parameters.
DEFAULT_WARN = 25.0
DEFAULT_CRIT = 28.0


def state_from_levels(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def parse_levels(params):
    levels = params.get("levels", None)
    if levels != None and len(levels) >= 2:
        return levels[0], levels[1]
    return DEFAULT_WARN, DEFAULT_CRIT


def is_rms200(ctx, host, community):
    det = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OID],
        mutates=False,
    )
    return det.rc == 0 and det.stdout.strip() == PROD_OID


def walk_column(ctx, host, community, col_base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_base],
        mutates=False,
    )
    rows = []
    base_len = len(col_base) + 1
    if res.rc == 0 or res.rc == 182:
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            if len(oid) <= base_len:
                continue
            rows.append((oid[base_len:], value))
    return rows


def get_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 0:
        return res.stdout.strip()
    return None


def discover(ctx, host, community):
    if not is_rms200(ctx, host, community):
        return []

    rows = walk_column(ctx, host, community, COL_LABEL_BASE)
    discovery = []
    for index, label_val in rows:
        temp_raw = get_scalar(
            ctx, host, community, TABLE_BASE + "." + COL_TEMP + "." + index)
        if temp_raw == None:
            continue
        if not temp_raw.lstrip("-").isdigit():
            continue
        temp_val = int(temp_raw)
        if temp_val == -27300:
            continue
        discovery.append({
            "item": label_val,
            "params": {"levels": [DEFAULT_WARN, DEFAULT_CRIT]},
            "metrics": ["temperature"],
        })
    return discovery


def check(ctx, host, community, item, params):
    warn, crit = parse_levels(params)

    rows = walk_column(ctx, host, community, COL_LABEL_BASE)
    if len(rows) == 0:
        return {"state": "UNKNOWN", "metrics": {}, "details": ""}

    sensor_index = None
    for index, label_val in rows:
        if label_val == item:
            sensor_index = index
            break

    if sensor_index == None:
        return {"state": "UNKNOWN", "metrics": {},
                "details": "no such sensor"}

    temp_raw = get_scalar(
        ctx, host, community, TABLE_BASE + "." + COL_TEMP + "." + sensor_index)
    if temp_raw == None:
        return {"state": "UNKNOWN", "metrics": {},
                "details": "no temperature data"}
    if not temp_raw.lstrip("-").isdigit():
        return {"state": "UNKNOWN", "metrics": {},
                "details": "invalid temperature reading"}
    temp_val = int(temp_raw)
    if temp_val == -27300:
        return {"state": "UNKNOWN", "metrics": {},
                "details": "no sensor connected"}

    temp_celsius = float(temp_val) / 100.0
    state = state_from_levels(temp_celsius, warn, crit)
    return {
        "state": state,
        "metrics": {"temperature": temp_celsius},
        "details": "sensor: " + item,
    }


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        discovery = discover(ctx, host, community)
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    verdict = check(ctx, host, community, item, params)
    return {
        "changed": False,
        "msg": "Temperature %f C (%s)" % (verdict["metrics"].get("temperature", 0.0), item),
        "data": verdict,
    }