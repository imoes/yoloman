# Raritan PX2 Residual Current — Checkmk SNMP check, translated to read-only Starlark
# Monitors residual operating current on Raritan PX2 PDU inlets via SNMP.

PDU_BASE = ".1.3.6.1.4.1.13742.6.3.3.3.1"

INLET_SENSOR_BASE = ".1.3.6.1.4.1.13742.6"

INLET_POLE_COL_BASE = ".5.2.3.1"
PHASE_POLE_COL_BASE = ".5.2.4.1"

TYPE_MAPPING = {
    "1": ("current", "RMS"),
    "2": ("peak", "Peak"),
    "3": ("unbalanced", "Unbalanced"),
    "4": ("voltage", "RMS"),
    "5": ("power", "Active"),
    "6": ("appower", "Apparent"),
    "7": ("power_factor", "Power Factor"),
    "8": ("energy", "Active"),
    "9": ("energy", "Apparent"),
    "10": ("temp", ""),
    "11": ("humidity", ""),
    "12": ("airflow", ""),
    "13": ("pressure_pa", "Air"),
    "14": ("binary", "On/Off"),
    "15": ("binary", "Trip"),
    "16": ("binary", "Vibration"),
    "17": ("binary", "Water Detector"),
    "18": ("binary", "Smoke Detector"),
    "19": ("binary", ""),
    "20": ("binary", "Contact"),
    "21": ("fanspeed", ""),
    "26": ("residual_current", "Residual Current"),
    "30": ("", "Other"),
    "31": ("", "None"),
}

UNIT_MAPPING = {
    "-1": "",
    "0": " Other",
    "1": " V",
    "2": " A",
    "3": " W",
    "4": " VA",
    "5": " Wh",
    "6": " VAh",
    "7": "c",
    "8": " hz",
    "9": "%",
    "10": " m/s",
    "11": " Pa",
    "12": " psi",
    "13": " g",
    "14": "f",
    "15": " ft",
    "16": " inch",
    "17": " cm",
    "18": " m",
    "19": " RPM",
}

RESIDUAL_BITMASK = 0b01000000

THRESH_WARN_BIT = 0b00000100
THRESH_CRIT_BIT = 0b00001000


def _pow(base, exp):
    result = 1
    i = 0
    while i < exp:
        result = result * base
        i = i + 1
    return result


def _hex_to_int(hexstr):
    s = hexstr.strip()
    if s == "" or s == "None":
        return 0
    n = 0
    for ch in s:
        n = n * 16
        if ch >= "0" and ch <= "9":
            n = n + (ord(ch) - ord("0"))
        elif ch >= "a" and ch <= "f":
            n = n + (ord(ch) - ord("a") + 10)
        elif ch >= "A" and ch <= "F":
            n = n + (ord(ch) - ord("A") + 10)
    return n


def _safe_float(s, default_):
    s = s.strip()
    if s == "" or s == "None" or s == "NOSUCHOBJECT" or s == "NOSUCHINSTANCE":
        return default_
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    is_num = True
    has_dot = False
    if s == "":
        is_num = False
    for ch in s:
        if ch == "." and not has_dot:
            has_dot = True
        elif ch < "0" or ch > "9":
            is_num = False
            break
    if not is_num:
        return default_
    v = float(s)
    if neg:
        v = v * -1
    return v


def _safe_int(s, default_):
    s = s.strip()
    if s == "" or s == "None":
        return default_
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    is_num = True
    if s == "":
        is_num = False
    for ch in s:
        if ch < "0" or ch > "9":
            is_num = False
            break
    if not is_num:
        return default_
    v = int(s)
    if neg:
        v = v * -1
    return v


def _snmp_get_oid(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk_oid(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.split("\n"):
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid_part = line[:sp]
        value = line[sp + 1:]
        idx = oid_part[len(oid) + 1:] if oid_part.startswith(oid + ".") else oid_part
        rows[idx] = value
    return rows


def _probe_residual_capable(ctx, community, host):
    dev_hex = _snmp_get_oid(ctx, community, host, PDU_BASE + ".10")
    pole_hex = _snmp_get_oid(ctx, community, host, PDU_BASE + ".11")
    dev = _hex_to_int(dev_hex) if dev_hex != None else 0
    pole = _hex_to_int(pole_hex) if pole_hex != None else 0
    return dev, pole


def _is_pdu_present(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Onqv", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    out = res.stdout.strip()
    if out == "":
        return False
    if ".1.3.6.1.4.1.13742" in out or "13742" in out:
        return True
    return False


def _gather_inlet_sensors(ctx, community, host):
    sensors = {}

    inlet_avail_oid = INLET_SENSOR_BASE + ".5.2.3.1.2.1.1"
    inlet_value_oid = INLET_SENSOR_BASE + ".5.2.3.1.4.1.1"
    inlet_unit_oid = INLET_SENSOR_BASE + ".3.3.4.1.6.1.1"
    inlet_dec_oid = INLET_SENSOR_BASE + ".3.3.4.1.7.1.1"
    inlet_crit_oid = INLET_SENSOR_BASE + ".3.3.4.1.23.1.1"
    inlet_warn_oid = INLET_SENSOR_BASE + ".3.3.4.1.24.1.1"
    inlet_th_oid = INLET_SENSOR_BASE + ".3.3.4.1.25.1.1"

    phase_avail_oid = INLET_SENSOR_BASE + ".5.2.4.1.2.1.1"
    phase_value_oid = INLET_SENSOR_BASE + ".5.2.4.1.4.1.1"
    phase_unit_oid = INLET_SENSOR_BASE + ".3.3.6.1.6.1.1"
    phase_dec_oid = INLET_SENSOR_BASE + ".3.3.6.1.7.1.1"
    phase_crit_oid = INLET_SENSOR_BASE + ".3.3.6.1.23.1.1"
    phase_warn_oid = INLET_SENSOR_BASE + ".3.3.6.1.24.1.1"
    phase_th_oid = INLET_SENSOR_BASE + ".3.3.6.1.25.1.1"

    table_sets = [
        (inlet_avail_oid, inlet_value_oid, inlet_unit_oid, inlet_dec_oid,
         inlet_crit_oid, inlet_warn_oid, inlet_th_oid, "Summary"),
        (phase_avail_oid, phase_value_oid, phase_unit_oid, phase_dec_oid,
         phase_crit_oid, phase_warn_oid, phase_th_oid, "Phase"),
    ]

    for (a_oid, v_oid, u_oid, d_oid, c_oid, w_oid, t_oid, pole_kind) in table_sets:
        avail_map = _snmp_walk_oid(ctx, community, host, a_oid)
        value_map = _snmp_walk_oid(ctx, community, host, v_oid)
        unit_map = _snmp_walk_oid(ctx, community, host, u_oid)
        dec_map = _snmp_walk_oid(ctx, community, host, d_oid)
        crit_map = _snmp_walk_oid(ctx, community, host, c_oid)
        warn_map = _snmp_walk_oid(ctx, community, host, w_oid)
        th_map = _snmp_walk_oid(ctx, community, host, t_oid)

        for sensor_id, avail_v in avail_map.items():
            parts = sensor_id.split(".")
            if len(parts) == 1:
                sensor = sensor_id
                pole = pole_kind
            else:
                sensor = parts[1]
                pole = "Phase " + parts[0]

            if avail_v != "1":
                continue
            if sensor not in TYPE_MAPPING:
                continue

            dec = _safe_int(dec_map.get(sensor_id, "0"), 0)
            val = _safe_float(value_map.get(sensor_id, "0"), 0.0)
            crit = _safe_float(crit_map.get(sensor_id, "0"), 0.0)
            warn = _safe_float(warn_map.get(sensor_id, "0"), 0.0)
            th_hex = th_map.get(sensor_id, "0")

            divisor = _pow(10, dec)
            sensor_value = val / divisor if divisor != 0 else val
            sensor_upper_crit = crit / divisor if divisor != 0 else crit
            sensor_upper_warn = warn / divisor if divisor != 0 else warn

            unit = UNIT_MAPPING.get(str(unit_map.get(sensor_id, "-1")), "")
            unit = unit.strip()

            sensor_type, sensor_type_readable = TYPE_MAPPING.get(sensor, ("", "Other"))

            sensor_obj = {
                "availability": avail_v,
                "sensor_name": sensor_type_readable,
                "sensor_type": sensor_type,
                "sensor_value": sensor_value,
                "sensor_upper_crit": sensor_upper_crit,
                "sensor_upper_warn": sensor_upper_warn,
                "sensor_unit": unit,
                "enabled_thresholds": _hex_to_int(th_hex),
            }
            if pole not in sensors:
                sensors[pole] = {}
            sensors[pole][sensor] = sensor_obj

    return sensors


def _create_levels(params, sensor):
    thresholds = sensor["enabled_thresholds"]
    has_warn = (thresholds & THRESH_WARN_BIT) != 0 and sensor["sensor_upper_warn"] != 0
    has_crit = (thresholds & THRESH_CRIT_BIT) != 0 and sensor["sensor_upper_crit"] != 0

    if has_warn or has_crit:
        levels_warn = sensor["sensor_upper_warn"] if has_warn else None
        levels_crit = sensor["sensor_upper_crit"] if has_crit else None
        return ("fixed", (levels_warn, levels_crit))
    return params.get("residual_levels", ("no_levels", None))


def _grade(value, levels):
    if levels == None:
        return "OK"
    if len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def _check_data(ctx, params, sensors, pole):
    total_current = None
    total_sensor = sensors.get("1")
    if total_sensor != None:
        total_current = total_sensor["sensor_value"]

    sensor_data = sensors.get("26")
    if sensor_data == None:
        return {
            "state": "WARN",
            "msg": "Missing residual operating current data!",
            "metrics": {},
            "details": "",
        }

    residual_current = sensor_data["sensor_value"]
    unit = sensor_data["sensor_unit"]
    if residual_current > 1:
        unit = "mA"

    if unit == "mA":
        render_func = lambda v: "%f mA" % (v * 1000)
    elif unit == "%":
        render_func = lambda v: "%f%%" % v
    else:
        render_func = lambda v: "%f %s" % (v, sensor_data["sensor_unit"])

    levels_upper = _create_levels(params, sensor_data)
    levels_tuple = None
    if type(levels_upper) == "tuple" and len(levels_upper) == 2:
        levels_tuple = levels_upper[1]

    state = _grade(residual_current, levels_tuple)

    metric_name = sensor_data["sensor_type"]
    metrics = {metric_name: residual_current}

    details_lines = ["%s: %s" % (sensor_data["sensor_name"], render_func(residual_current))]

    if total_current != None and total_current != 0:
        pct = residual_current / total_current * 100
        metrics["residual_current_percentage"] = pct
        details_lines.append("Residual Current Percentage: %f%%" % pct)

    if type(levels_upper) == "tuple" and len(levels_upper) == 2:
        if levels_upper[0] == "no_levels":
            if params.get("warn_missing_levels"):
                if state == "OK":
                    state = "WARN"
            details_lines.append("Missing warn/crit levels!")

    msg = "%s %s" % (render_func(residual_current), sensor_data["sensor_name"])
    return {
        "state": state,
        "msg": msg,
        "metrics": metrics,
        "details": "\n".join(details_lines),
    }


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not _is_pdu_present(ctx, community, host):
            return {"changed": False,
                    "msg": "not installed: no Raritan PX2 found",
                    "data": {"discovery": []}}

        dev_cap, pole_cap = _probe_residual_capable(ctx, community, host)
        if dev_cap == 0 and pole_cap == 0:
            return {"changed": False,
                    "msg": "no device/pole capabilities readable",
                    "data": {"discovery": []}}

        has_residual = (dev_cap & RESIDUAL_BITMASK) != 0 or (pole_cap & RESIDUAL_BITMASK) != 0
        if not has_residual:
            return {"changed": False,
                    "msg": "no residual current support on this PDU",
                    "data": {"discovery": []}}

        sensors = _gather_inlet_sensors(ctx, community, host)
        discovery = []
        for pole, sensor_map in sensors.items():
            if "26" in sensor_map:
                discovery.append({
                    "item": pole,
                    "params": {
                        "warn_missing_data": True,
                        "warn_missing_levels": True,
                        "residual_levels": ("no_levels", None),
                    },
                    "metrics": ["residual_current"],
                })
        if len(discovery) == 0:
            discovery.append({
                "item": "Summary",
                "params": {
                    "warn_missing_data": True,
                    "warn_missing_levels": True,
                    "residual_levels": ("no_levels", None),
                },
                "metrics": ["residual_current"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery,
                     "host_labels": {"cmk/raritan_px2": "yes"}},
        }

    item = params.get("item", "")

    if not _is_pdu_present(ctx, community, host):
        return {
            "changed": False,
            "msg": "no Raritan PX2 PDU responding to SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    dev_cap, pole_cap = _probe_residual_capable(ctx, community, host)
    if dev_cap == 0 and pole_cap == 0:
        return {
            "changed": False,
            "msg": "no Raritan PX2 PDU responding to SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _gather_inlet_sensors(ctx, community, host)

    if item == "":
        item = "Summary"

    pole_sensors = sensors.get(item)
    if pole_sensors == None:
        if params.get("warn_missing_data"):
            return {
                "changed": False,
                "msg": "No residual operating current available!",
                "data": {"state": "WARN", "metrics": {}, "details": ""},
            }
        return {
            "changed": False,
            "msg": "No residual operating current available!",
            "data": {"state": "OK", "metrics": {}, "details": "No residual operating current available!"},
        }

    result = _check_data(ctx, params, pole_sensors, item)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }