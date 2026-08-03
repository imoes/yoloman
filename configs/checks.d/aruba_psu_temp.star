def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

ARUBA_PSU_BASE = ".1.3.6.1.4.1.11.2.14.11.5.1.55.1.1.1"
OID_STATE = "2"
OID_FAILURES = "3"
OID_TEMP = "4"
OID_VOLTAGE = "5"
OID_WATT_CURR = "6"
OID_WATT_MAX = "7"
OID_LAST_CALL = "8"
OID_MODEL = "9"

SYS_DESCRIBEROID = ".1.3.6.1.2.1.1.1.0"

TEMP_WARN_DEFAULT = 50.0
TEMP_CRIT_DEFAULT = 60.0

PSU_STATE_MAP = {
    "1": "OK",
    "2": "OK",
    "3": "OK",
    "4": "CRIT",
    "5": "CRIT",
    "6": "OK",
    "7": "CRIT",
    "8": "CRIT",
    "9": "CRIT",
}

PSU_STATE_NAME = {
    "1": "NotPresent",
    "2": "NotPlugged",
    "3": "Powered",
    "4": "Failed",
    "5": "PermFailure",
    "6": "Max",
    "7": "AuxFailure",
    "8": "NotPowered",
    "9": "AuxNotPowered",
}

def _is_aruba_2930m(ctx):
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-Oqv", ctx.host, SYS_DESCRIBEROID], mutates=False)
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if val.startswith("Aruba") and "2930M" in val:
        return True
    return False

def _check_present(ctx):
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-Oqv", ctx.host, ARUBA_PSU_BASE + ".1"], mutates=False)
    return res.rc == 0

def _snmp_get_str(ctx, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-Oqv", ctx.host, oid], mutates=False)
    if res.rc != 0:
        return ""
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val

def _snmp_get_int(ctx, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-Oqv", ctx.host, oid], mutates=False)
    if res.rc != 0:
        return 0
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
        return int(val)
    return 0

def _snmp_get_float(ctx, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-Oqv", ctx.host, oid], mutates=False)
    if res.rc != 0:
        return 0.0
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    if _is_numeric(val):
        return float(val)
    return 0.0

def _is_numeric(s):
    s2 = s
    if s2.startswith("-") or s2.startswith("+"):
        s2 = s2[1:]
    if s2 == "":
        return False
    has_dot = False
    for ch in s2:
        if ch == ".":
            if has_dot:
                return False
            has_dot = True
        elif not ch.isdigit():
            return False
    return True

def _read_psus(ctx):
    psus = {}
    index_res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-Oqn", ctx.host, ARUBA_PSU_BASE + "." + OID_MODEL], mutates=False)
    if index_res.rc != 0:
        return psus
    entries = index_res.stdout.strip().splitlines()
    for entry in entries:
        parts = entry.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        index_val = oid_full[len(ARUBA_PSU_BASE + "." + OID_MODEL + "."):]
        model = parts[1].strip().strip('"')

        state = _snmp_get_str(ctx, ARUBA_PSU_BASE + "." + OID_STATE + "." + index_val)
        failures = _snmp_get_int(ctx, ARUBA_PSU_BASE + "." + OID_FAILURES + "." + index_val)
        temperature = _snmp_get_float(ctx, ARUBA_PSU_BASE + "." + OID_TEMP + "." + index_val)
        voltage = _snmp_get_str(ctx, ARUBA_PSU_BASE + "." + OID_VOLTAGE + "." + index_val)
        wattage_curr = _snmp_get_int(ctx, ARUBA_PSU_BASE + "." + OID_WATT_CURR + "." + index_val)
        wattage_max = _snmp_get_int(ctx, ARUBA_PSU_BASE + "." + OID_WATT_MAX + "." + index_val)
        last_call = _snmp_get_int(ctx, ARUBA_PSU_BASE + "." + OID_LAST_CALL + "." + index_val)

        item = model + " " + index_val
        psus[item] = {
            "state": state,
            "failures": failures,
            "temperature": temperature,
            "voltage_info": voltage,
            "wattage_curr": wattage_curr,
            "wattage_max": wattage_max,
            "last_call": last_call,
            "model": model,
        }
    return psus

def _temp_levels(temp, warn, crit):
    if temp >= crit:
        return "CRIT"
    if temp >= warn:
        return "WARN"
    return "OK"

def _format_timespan(seconds):
    if seconds <= 0:
        return "0s"
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    mins = (seconds % 3600) // 60
    secs = seconds % 60
    parts = []
    if days > 0:
        parts.append("%dd" % days)
    if hours > 0:
        parts.append("%dh" % hours)
    if mins > 0:
        parts.append("%dm" % mins)
    if secs > 0 or len(parts) == 0:
        parts.append("%ds" % secs)
    return " ".join(parts)

def _discover(ctx, params):
    if not _is_aruba_2930m(ctx):
        return {"changed": False, "msg": "not an Aruba 2930M", "data": {"discovery": []}}
    if not _check_present(ctx):
        return {"changed": False, "msg": "no Aruba PSU data", "data": {"discovery": []}}
    psus = _read_psus(ctx)
    discovery = []
    for item, entry in psus.items():
        if entry["state"] in ("1", "2"):
            continue
        discovery.append({
            "item": item,
            "params": {"levels": (TEMP_WARN_DEFAULT, TEMP_CRIT_DEFAULT)},
            "metrics": ["temperature"],
        })
    return {
        "changed": False,
        "msg": "discovered %d PSUs" % len(discovery),
        "data": {"discovery": discovery},
    }

def _check(ctx, params):
    item = params.get("item", "")
    levels = params.get("levels", (TEMP_WARN_DEFAULT, TEMP_CRIT_DEFAULT))
    warn = levels[0]
    crit = levels[1]
    if not _is_aruba_2930m(ctx):
        return {"changed": False, "msg": "not an Aruba 2930M or not present",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not _check_present(ctx):
        return {"changed": False, "msg": "no Aruba PSU data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    psus = _read_psus(ctx)
    if item not in psus:
        return {"changed": False, "msg": "PSU not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    psu = psus[item]
    if psu["state"] not in PSU_STATE_MAP:
        return {"changed": False, "msg": "Unknown PSU state: %s" % psu["state"],
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state_str = PSU_STATE_MAP[psu["state"]]
    temperature = psu["temperature"]
    temp_state = _temp_levels(temperature, warn, crit)
    state = "OK"
    if temp_state == "CRIT":
        state = "CRIT"
    elif temp_state == "WARN":
        state = "WARN"
    if state_str == "CRIT" and state != "CRIT":
        state = "CRIT"
    msg = "Temperature: %fC" % temperature
    details = "PSU Status: %s, Uptime: %s, Voltage: %s, Wattage: %d/%dW, Failures: %d" % (
        PSU_STATE_NAME.get(psu["state"], psu["state"]),
        _format_timespan(psu["last_call"]),
        psu["voltage_info"],
        psu["wattage_curr"],
        psu["wattage_max"],
        psu["failures"],
    )
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temperature},
            "details": details,
        },
    }