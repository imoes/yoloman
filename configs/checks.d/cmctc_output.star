# ===== check plugin: cmctc_output (translated) =====
# Translated Checkmk SNMP check for Rittal CMCTC output sensors.
# Read-only: never mutates the system.

TYPE_MAP = {}

def _build_type_map():
    entries = [
        ("4",  "Door locking TS8 Ergoform", "", None),
        ("5",  "Universal lock 1 lock with power", "", None),
        ("6",  "Universal lock 2 unlock with power", "", None),
        ("7",  "Fan relay", "", None),
        ("8",  "Fan controlled", "", None),
        ("9",  "Universal relay output", "", None),
        ("10", "Room door lock", "", None),
        ("11", "Power output", "", None),
        ("12", "Door lock with Master key", "", None),
        ("13", "Door lock FR(i)", "", None),
        ("14", "Setpoint", "", None),
        ("15", "Setpoint temperature monitoring", " °C", "temp"),
        ("16", "Hysteresis of setpoint", "", None),
        ("17", "Command for remote control of RCT", "", None),
        ("18", "Relay", "", None),
        ("19", "High setpoint current monitoring", " A", "current"),
        ("20", "Low setpoint current monitoring", " A", "current"),
        ("21", "Retpoint temperature RTT", " °C", "temp"),
        ("22", "Setpoint temperature monitoring RTT", " °C", "temp"),
        ("23", "Power output 20A", " A", "current"),
        ("24", "Door magnet automatic door release", "", None),
        ("30", "Control mode", "", None),
        ("31", "Min fan speed", " RPM", "rpm"),
        ("32", "Min delta T", " °C", "temp"),
        ("33", "Max delta T", " °C", "temp"),
        ("34", "PID controller", "", None),
        ("35", "PID controller", "", None),
        ("36", "PID controller", "", None),
        ("37", "Flowrate flowmeter", " l/min", "flow"),
        ("38", "Cw value of water", "", ""),
        ("39", "deltaT", " °C", "temp"),
        ("40", "Control mode", "", None),
        ("42", "Setpoint high voltage PSM", "V", "voltage"),
        ("43", "Setpoint low voltage PSM", "V", "voltage"),
        ("44", "Setpoint high current PSM", "A", "current"),
        ("45", "Setpoint low current PSM", "A", "current"),
        ("46", "Command PSM", "", None),
    ]
    for k, desc, unit, perfkey in entries:
        TYPE_MAP[k] = (desc, unit, perfkey)

STATUS_MAP = {
    "1": "not available",
    "2": "lost",
    "3": "changed",
    "4": "ok",
    "5": "off",
    "6": "on",
    "7": "set off",
    "8": "set on",
}

COMMAND_MAP = {
    "1": "off",
    "2": "on",
    "3": "lock",
    "4": "unlock",
    "5": "unlock delay",
}

CONFIG_MAP = {
    "1": "disable remote control",
    "2": "enable remote control",
}

TIMEOUT_MAP = {
    "1": "stay",
    "2": "off",
    "3": "on",
}

STATUS_STATE = {
    "ok": "OK",
    "on": "OK",
    "set off": "OK",
    "set on": "OK",
    "changed": "WARN",
    "lost": "CRIT",
    "off": "CRIT",
    "not available": "UNKNOWN",
}

_TABLES = ["3", "4", "5", "6"]
_COLUMNS = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
_SYSOBJ_OID = ".1.3.6.1.2.1.1.2.0"
_CMCTC_PREFIX = ".1.3.6.1.4.1.2606.4"


def _snmpget(ctx, host, community, oid):
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _snmpwalk(ctx, host, community, oid):
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )


def _walk_table(ctx, host, community, base_oid):
    res = _snmpwalk(ctx, host, community, base_oid)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp <= 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip()
        idx = oid[len(base_oid) + 1:]
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        rows.append((idx, val))
    rows.sort()
    return rows


def _read_sensor(ctx, host, community, base_oid, idx):
    sensor_vals = []
    for col in _COLUMNS:
        full_oid = base_oid + "." + col + "." + idx
        g = _snmpget(ctx, host, community, full_oid)
        if g.rc != 0:
            return None
        sensor_vals.append(g.stdout.strip())
    return sensor_vals


def _parse_sensor(table_idx, sensor):
    index = sensor[0]
    sensor_type_id = sensor[1]
    description = sensor[2]
    status = sensor[3]
    value = sensor[4]
    command = sensor[5]
    config = sensor[6]
    delay = sensor[7]
    timeout_action = sensor[8]

    stype, unit, perfkey = TYPE_MAP.get(sensor_type_id, ("Unknown output", "", None))

    parsed_status = STATUS_MAP.get(status)
    if parsed_status == "not available":
        return None

    parsed = {
        "status": parsed_status,
        "value": int(value),
        "unit": unit,
        "perfkey": perfkey,
        "command": COMMAND_MAP.get(command),
        "config": CONFIG_MAP.get(config),
        "delay": int(delay),
        "timeout_action": TIMEOUT_MAP.get(timeout_action),
        "description": description,
    }

    name = "%s %s.%s" % (stype, table_idx, index)
    return name, parsed


def _all_sensors(ctx, host, community):
    sensors = []
    for table_idx in _TABLES:
        base_oid = ".1.3.6.1.4.1.2606.4.2.%s.6.2.1" % table_idx
        rows = _walk_table(ctx, host, community, base_oid)
        indices = []
        for idx, _v in rows:
            if idx not in indices:
                indices.append(idx)
        for idx in indices:
            sensor_vals = _read_sensor(ctx, host, community, base_oid, idx)
            if sensor_vals and len(sensor_vals) == 9:
                result = _parse_sensor(table_idx, sensor_vals)
                if result:
                    sensors.append(result)
    return sensors


def _is_cmctc(ctx, host, community):
    res = _snmpget(ctx, host, community, _SYSOBJ_OID)
    if res.rc == 127 or res.rc == 1 or res.rc != 0:
        return False
    sysid = res.stdout.strip()
    return sysid.startswith(_CMCTC_PREFIX)


_build_type_map()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_cmctc(ctx, host, community):
        return {"changed": False, "msg": "no CMCTC device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        discovery = []
        for name, data in _all_sensors(ctx, host, community):
            metrics = [data["perfkey"]] if data["perfkey"] else []
            discovery.append({
                "item": name,
                "params": {},
                "metrics": metrics,
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    found_data = None
    for name, data in _all_sensors(ctx, host, community):
        if name == item:
            found_data = data
            break

    if not found_data:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = STATUS_STATE.get(found_data["status"], "UNKNOWN")
    infotext = "[%s] %d%s, %s" % (
        found_data["description"],
        found_data["value"],
        found_data["unit"],
        found_data["status"],
    )
    metrics = {}
    if found_data["perfkey"]:
        metrics[found_data["perfkey"]] = found_data["value"]

    detail = "Command: %s, Config: %s, Delay: %d, Timeout action: %s" % (
        found_data["command"],
        found_data["config"],
        found_data["delay"],
        found_data["timeout_action"],
    )

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": metrics, "details": detail}}