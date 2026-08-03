AKCP_BASE_OID = ".1.3.6.1.4.1.3854"
AKCP_EXP_BASE = ".1.3.6.1.4.1.3854.2"
SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

HUMIDITY_OID_BASE = ".1.3.6.1.4.1.3854.2.3.3.1"
COL_DESCRIPTION = "2"
COL_PERCENT = "4"
COL_STATUS = "6"
COL_ONLINE = "8"

AKCP_LEVEL_STATES = {
    "1": (2, "no status"),
    "2": (0, "normal"),
    "3": (1, "high warning"),
    "4": (2, "high critical"),
    "5": (1, "low warning"),
    "6": (2, "low critical"),
    "7": (2, "sensor error"),
}

STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
STATE_MAP = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}


def _strip_type_tag(value):
    idx = value.find(": ")
    if idx != -1:
        return value[idx + 2:]
    return value


def _strip_quotes(value):
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def _snmp_get_scalar(ctx, params, oid):
    res = ctx.run(["snmpget", "-v2c", "-c",
                   params.get("community", "public"),
                   "-Oqv",
                   params.get("host", "localhost"),
                   oid], mutates=False)
    if res.rc == 127:
        return None, True
    if res.rc != 0:
        return None, False
    raw = res.stdout.strip()
    raw = _strip_quotes(raw)
    raw = _strip_type_tag(raw)
    return raw, False


def _snmp_walk(ctx, params, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c",
                   params.get("community", "public"),
                   "-Oqn",
                   params.get("host", "localhost"),
                   oid], mutates=False)
    if res.rc == 127:
        return None, True
    if res.rc != 0:
        return None, False
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp].strip()
        rest = line[sp + 1:].strip()
        rest = _strip_quotes(rest)
        rest = _strip_type_tag(rest)
        index = full_oid[len(oid):]
        if index.startswith("."):
            index = index[1:]
        rows.append((index, rest))
    return rows, False


def _check_humidity_value(value, params):
    levels = params.get("levels", (60.0, 65.0))
    lower_levels = params.get("levels_lower", (30.0, 35.0))
    warn_hi = levels[0]
    crit_hi = levels[1]
    warn_lo = lower_levels[0]
    crit_lo = lower_levels[1]

    if value >= crit_hi:
        return "CRIT", "above crit"
    if value >= warn_hi:
        return "WARN", "above warn"
    if value <= crit_lo:
        return "CRIT", "below crit"
    if value <= warn_lo:
        return "WARN", "below warn"
    return "OK", ""


def _is_akcp_exp(ctx, params):
    sysval, not_installed = _snmp_get_scalar(ctx, params, SYSOID_OID)
    if not_installed:
        return False
    if sysval == None or not sysval.startswith(AKCP_BASE_OID + ".1"):
        return False
    res = ctx.run(["snmpwalk", "-v2c", "-c",
                   params.get("community", "public"),
                   "-Oqn",
                   params.get("host", "localhost"),
                   AKCP_EXP_BASE], mutates=False)
    if res.rc == 127:
        return False
    if res.rc == 0:
        return True
    return False


def _to_int_safe(s):
    if s == None or s == "":
        return 0
    if s.isdigit():
        return int(s)
    # strip any non-digit prefix/suffix that might remain
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits = digits + ch
        elif ch == "-":
            digits = digits + ch
    if digits == "" or digits == "-":
        return 0
    return int(digits)


def main(ctx, params):
    if not _is_akcp_exp(ctx, params):
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "host is not an AKCP EXP device or not reachable",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no AKCP EXP device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        rows_desc, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_DESCRIPTION)
        if rows_desc == None:
            return {"changed": False,
                    "msg": "could not retrieve AKCP EXP humidity table",
                    "data": {"discovery": []}}

        rows_on, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_ONLINE)

        indices = []
        for idx, desc in rows_desc:
            if idx not in indices:
                indices.append(idx)

        discovery = []
        for idx in indices:
            desc = ""
            on = ""
            for o_idx, o_val in rows_desc:
                if o_idx == idx:
                    desc = o_val
                    break
            if rows_on != None:
                for o_idx, o_val in rows_on:
                    if o_idx == idx:
                        on = o_val
                        break
            if on == "1":
                discovery.append({"item": desc,
                                  "params": {"levels": (60.0, 65.0),
                                             "levels_lower": (30.0, 35.0)},
                                  "metrics": ["humidity"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    rows_desc, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_DESCRIPTION)
    if rows_desc == None:
        return {"changed": False,
                "msg": "could not retrieve AKCP EXP humidity table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows_pct, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_PERCENT)
    rows_stat, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_STATUS)
    rows_on, _ = _snmp_walk(ctx, params, HUMIDITY_OID_BASE + "." + COL_ONLINE)

    found = False
    pct_val = ""
    stat_val = ""
    on_val = ""

    for idx, d_val in rows_desc:
        if d_val == item:
            if rows_pct != None:
                for o_idx, o_val in rows_pct:
                    if o_idx == idx:
                        pct_val = o_val
                        break
            if rows_stat != None:
                for o_idx, o_val in rows_stat:
                    if o_idx == idx:
                        stat_val = o_val
                        break
            if rows_on != None:
                for o_idx, o_val in rows_on:
                    if o_idx == idx:
                        on_val = o_val
                        break
            found = True
            break

    if not found:
        return {"changed": False,
                "msg": "no such humidity sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summaries = []
    worst_state = 0

    if on_val != "1":
        summaries.append("sensor is offline")
        worst_state = max(worst_state, 2)

    if stat_val in ["1", "7"] and stat_val in AKCP_LEVEL_STATES:
        st, name = AKCP_LEVEL_STATES[stat_val]
        summaries.append("State: " + name)
        worst_state = max(worst_state, st)

    metrics = {}
    if pct_val != "" and pct_val != None:
        pct_num = _to_int_safe(pct_val)
        hum_state, hum_detail = _check_humidity_value(pct_num, params)
        summaries.append("Humidity: %d%%" % pct_num)
        worst_state = max(worst_state, STATE_MAP[hum_state])
        metrics["humidity"] = pct_num

    final_state = STATE_NAMES[worst_state]

    return {"changed": False,
            "msg": ", ".join(summaries) if summaries else "Humidity sensor OK",
            "data": {"state": final_state,
                     "metrics": metrics,
                     "details": ", ".join(summaries)}}