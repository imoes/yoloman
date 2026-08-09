# Translation of Checkmk check ups_modulys_alarms -> read-only Starlark check module.
# SNMP-based check for Modulys UPS alarms at .1.3.6.1.4.1.2254.2.4.

OIDDEF = {
    "1": ("CRIT", "Disconnect"),
    "2": ("CRIT", "Input power failure"),
    "3": ("CRIT", "Low batteries"),
    "4": ("WARN", "High load"),
    "5": ("CRIT", "Severley high load"),
    "6": ("CRIT", "On bypass"),
    "7": ("CRIT", "General failure"),
    "8": ("CRIT", "Battery ground fault"),
    "9": ("OK", "UPS test in progress"),
    "10": ("CRIT", "UPS test failure"),
    "11": ("CRIT", "Fuse failure"),
    "12": ("CRIT", "Output overload"),
    "13": ("CRIT", "Output overcurrent"),
    "14": ("CRIT", "Inverter abnormal"),
    "15": ("CRIT", "Rectifier abnormal"),
    "16": ("CRIT", "Reserve abnormal"),
    "17": ("WARN", "On reserve"),
    "18": ("CRIT", "Overheating"),
    "19": ("CRIT", "Output abnormal"),
    "20": ("CRIT", "Bypass bad"),
    "21": ("OK", "In standby mode"),
    "22": ("CRIT", "Charger failure"),
    "23": ("CRIT", "Fan failure"),
    "24": ("OK", "In economic mode"),
    "25": ("WARN", "Output turned off"),
    "26": ("WARN", "Smart shutdown in progress"),
    "27": ("CRIT", "Emergency power off"),
    "28": ("WARN", "Shutdown"),
    "29": ("CRIT", "Output breaker open"),
}

BASE_OID = ".1.3.6.1.4.1.2254.2.4"
ALARM_COL_OID = BASE_OID + ".9"
MODULYS_SYSOID = ".1.3.6.1.4.1.2254.2.4"


def _split_first(s, sep):
    idx = s.find(sep)
    if idx < 0:
        return None, None
    return s[:idx], s[idx + len(sep):]


def _is_modulys_up(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False, res
    val = res.stdout.strip()
    if not val:
        return False, res
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:-1]
    return val == MODULYS_SYSOID, res


def _probe_alarms(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    res = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, ALARM_COL_OID],
        mutates=False,
    )
    rows = []
    if res.rc == 0 and res.stdout:
        lines = res.stdout.splitlines()
        for idx in range(len(lines)):
            line = lines[idx]
            stripped = line.strip()
            if not stripped:
                continue
            oid, rest = _split_first(stripped, " ")
            if oid == None:
                continue
            suffix = oid[len(ALARM_COL_OID) + 1:]
            value = rest.strip()
            rows.append((suffix, value))
    return rows, res


def _worst_state(alarms):
    state_rank = {"OK": 0, "WARN": 1, "CRIT": 2}
    worst = "OK"
    for entry in alarms:
        s = entry[0]
        if state_rank.get(s, 2) > state_rank.get(worst, 0):
            worst = s
    return worst


def _join_summaries(alarms):
    parts = []
    for entry in alarms:
        parts.append(entry[1])
    return ", ".join(parts)


def main(ctx, params):
    # ---- DISCOVERY ----
    if params.get("_discover"):
        is_modulys, _det = _is_modulys_up(ctx, params)
        if not is_modulys:
            return {
                "changed": False,
                "msg": "not a Modulys UPS (sysObjectID match failed or unreachable)",
                "data": {"discovery": []},
            }
        _rows, _walk = _probe_alarms(ctx, params)
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    # ---- CHECK (single service, item "") ----
    is_modulys, _det = _is_modulys_up(ctx, params)
    if not is_modulys:
        return {
            "changed": False,
            "msg": "no Modulys UPS found (sysObjectID mismatch or unreachable)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows, _walk = _probe_alarms(ctx, params)
    alarms = []
    for entry in rows:
        suffix = entry[0]
        flag = entry[1]
        if flag and flag != "NULL" and flag.isdigit() and int(flag):
            desc = OIDDEF.get(suffix)
            if desc != None:
                alarms.append(desc)
            else:
                alarms.append(("CRIT", "Unknown alarm (" + suffix + ")"))

    if not alarms:
        return {
            "changed": False,
            "msg": "No alarms",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    worst = _worst_state(alarms)
    summaries = _join_summaries(alarms)
    return {
        "changed": False,
        "msg": summaries,
        "data": {"state": worst, "metrics": {}, "details": summaries},
    }