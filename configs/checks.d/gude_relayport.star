# gude_relayport.star — read-only Starlark check module
# Monitors GUDE relay ports / smart plugs via SNMP.

BASE_OID = "1.3.6.1.4.1.28507.38.1"
COL_PORTNAME = BASE_OID + ".3.1.2.1.2"
COL_STATE = BASE_OID + ".3.1.2.1.3"
COL_POWER_ACTIVE = BASE_OID + ".5.5.2.1.4"
COL_CURRENT = BASE_OID + ".5.5.2.1.5"
COL_VOLTAGE = BASE_OID + ".5.5.2.1.6"
COL_FREQUENCY = BASE_OID + ".5.5.2.1.7"
COL_POWER_APPARENT = BASE_OID + ".5.5.2.1.10"

DEFAULT_VOLTAGE = (220, 210)
DEFAULT_CURRENT = (15, 16)


def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, oid, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        out.append((line[:sp], line[sp + 1:].strip()))
    return out


def _parse_float(text):
    if text == None or text == "":
        return None
    s = text.strip().strip('"')
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    num = 0
    has_digit = False
    for ch in s:
        if ch >= "0" and ch <= "9":
            num = num * 10 + (ord(ch) - ord("0"))
            has_digit = True
        elif ch == ".":
            break
        else:
            break
    if not has_digit:
        return None
    v = float(num)
    if neg:
        v = v * -1
    return v


def _state_for_value(value, warn, crit, direction):
    if value == None:
        return "UNKNOWN"
    if direction == "upper":
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
        return "OK"


def _port_data(ctx, community, host, index):
    portname = _snmp_get(ctx, COL_PORTNAME + "." + index, community, host)
    state_raw = _snmp_get(ctx, COL_STATE + "." + index, community, host)
    power_active = _snmp_get(ctx, COL_POWER_ACTIVE + "." + index, community, host)
    current = _snmp_get(ctx, COL_CURRENT + "." + index, community, host)
    voltage = _snmp_get(ctx, COL_VOLTAGE + "." + index, community, host)
    freq = _snmp_get(ctx, COL_FREQUENCY + "." + index, community, host)
    appower = _snmp_get(ctx, COL_POWER_APPARENT + "." + index, community, host)

    if portname == None:
        return None

    if state_raw == "1":
        port_state = "OK"
        port_label = "on"
    else:
        port_state = "CRIT"
        port_label = "off"

    power_val = _parse_float(power_active) if (power_active != None and power_active != "") else None
    current_val = _parse_float(current) if (current != None and current != "") else None
    voltage_val = _parse_float(voltage) if (voltage != None and voltage != "") else None
    freq_val = _parse_float(freq) if (freq != None and freq != "") else None
    appower_val = _parse_float(appower) if (appower != None and appower != "") else None

    result = {
        "portname": portname,
        "port_state": port_state,
        "port_label": port_label,
        "power": power_val,
        "voltage": voltage_val,
        "appower": appower_val,
    }
    if current_val == None:
        result["current"] = None
    else:
        result["current"] = current_val * 0.001
    if freq_val == None:
        result["frequency"] = None
    else:
        result["frequency"] = freq_val * 0.01
    return result


def _grade_all(data, params):
    states = []
    metrics = {}

    if data["port_state"] == "CRIT":
        states.append("CRIT")
    elif data["port_state"] == "OK":
        states.append("OK")

    if data["power"] != None:
        metrics["power"] = data["power"]

    if data["current"] != None:
        metrics["current"] = data["current"]
        cur_levels = params.get("current", list(DEFAULT_CURRENT))
        cw = cur_levels[0] if len(cur_levels) >= 1 else None
        cc = cur_levels[1] if len(cur_levels) >= 2 else None
        if cw != None and cc != None:
            states.append(_state_for_value(data["current"], cw, cc, "upper"))

    if data["voltage"] != None:
        metrics["voltage"] = data["voltage"]
        vol_levels = params.get("voltage", list(DEFAULT_VOLTAGE))
        vw = vol_levels[0] if len(vol_levels) >= 1 else None
        vc = vol_levels[1] if len(vol_levels) >= 2 else None
        if vw != None and vc != None:
            states.append(_state_for_value(data["voltage"], vw, vc, "upper"))

    if data["frequency"] != None:
        metrics["frequency"] = data["frequency"]

    if data["appower"] != None:
        metrics["appower"] = data["appower"]

    overall = "OK"
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    elif len(states) == 0:
        overall = "UNKNOWN"
    elif "UNKNOWN" in states:
        overall = "UNKNOWN"

    return overall, metrics


def _is_gude(ctx, community, host):
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_res.rc != 0:
        return False
    sysobj = sys_res.stdout.strip()
    return sysobj.startswith("1.3.6.1.4.1.28507.38")


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        names = _snmp_walk(ctx, COL_PORTNAME, community, host)
        if len(names) == 0:
            if not _is_gude(ctx, community, host):
                return {"changed": False, "msg": "device not reachable", "data": {"discovery": []}}
            return {"changed": False, "msg": "discovered 0 relay ports", "data": {"discovery": []}}

        discovery = []
        for entry in names:
            oid = entry[0]
            name = entry[1]
            index = oid[len(COL_PORTNAME) + 1:]
            portname = name.strip('"')
            discovery.append({
                "item": portname,
                "params": {
                    "voltage": [DEFAULT_VOLTAGE[0], DEFAULT_VOLTAGE[1]],
                    "current": [DEFAULT_CURRENT[0], DEFAULT_CURRENT[1]],
                },
                "metrics": ["power", "current", "voltage", "frequency", "appower"],
            })
        return {
            "changed": False,
            "msg": "discovered %d relay ports" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    names = _snmp_walk(ctx, COL_PORTNAME, community, host)
    if len(names) == 0:
        if not _is_gude(ctx, community, host):
            return {
                "changed": False,
                "msg": "no GUDE relay ports found on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return {
            "changed": False,
            "msg": "no relay ports found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_index = None
    for entry in names:
        oid = entry[0]
        name = entry[1]
        portname = name.strip('"')
        if portname == item:
            target_index = oid[len(COL_PORTNAME) + 1:]
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "no such relay port: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = _port_data(ctx, community, host, target_index)
    if data == None:
        return {
            "changed": False,
            "msg": "failed to read relay port data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state, metrics = _grade_all(data, params)
    parts = []
    if data["power"] != None:
        parts.append("Power: %f W" % data["power"])
    if data["current"] != None:
        parts.append("Current: %f A" % data["current"])
    if data["voltage"] != None:
        parts.append("Voltage: %f V" % data["voltage"])
    if data["frequency"] != None:
        parts.append("Freq: %f Hz" % data["frequency"])
    if data["appower"] != None:
        parts.append("AppPower: %f VA" % data["appower"])
    parts.append("State: " + data["port_label"])
    summary = ", ".join(parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "Port named '" + data["portname"] + "' on " + host,
        },
    }