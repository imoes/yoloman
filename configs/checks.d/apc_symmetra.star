BASE = ".1.3.6.1.4.1.318.1.1.1"
CART_OID = BASE + ".2.3.10.2.1.10"

BATTERY_OIDS = [
    BASE + ".8.1.0",    # 0: ups_comm_status
    BASE + ".2.1.1.0",  # 1: battery_status
    BASE + ".4.1.1.0",  # 2: output_status
    BASE + ".2.2.1.0",  # 3: battery_capacity (%)
    BASE + ".2.2.4.0",  # 4: battery_replace
    BASE + ".2.2.6.0",  # 5: battery_num_packs
    BASE + ".2.2.3.0",  # 6: time_remain (1/100 s)
    BASE + ".7.2.6.0",  # 7: calib_result
    BASE + ".7.2.4.0",  # 8: last_diag_date (unused)
    BASE + ".2.2.2.0",  # 9: battery_temp (temp sub-check)
    BASE + ".2.2.9.0",  # 10: battery_current (elphase sub-check)
    BASE + ".11.1.1.0", # 11: state_output_state bitmask
]

OUTPUT_TEXTS = {
    "1": "unknown", "2": "on line", "3": "on battery", "4": "on smart boost",
    "5": "timed sleeping", "6": "software bypass", "7": "off", "8": "rebooting",
    "9": "switched bypass", "10": "hardware failure bypass",
    "11": "sleeping until power return", "12": "on smart trim",
    "13": "eco mode", "14": "hot standby", "15": "on battery test",
    "16": "emergency static bypass", "17": "static bypass standby",
    "18": "power saving mode", "19": "spot mode", "20": "e conversion",
}

CART_FAULTS = {
    0: "Disconnected", 1: "Overvoltage", 2: "Needs Replacement",
    3: "Overtemperature Critical", 4: "Charger", 5: "Temperature Sensor",
    6: "Bus Soft Start", 7: "Overtemperature Warning", 8: "General Error",
    9: "Communication", 10: "Disconnected Frame", 11: "Firmware Mismatch",
}

STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

def _merge(cur, new_s):
    if STATE_RANK.get(new_s, 0) > STATE_RANK.get(cur, 0):
        return new_s
    return cur

def _state_name(n):
    return STATE_NAMES.get(n, "UNKNOWN")

def _clean(s):
    return s.strip().strip('"')

def _to_bits(raw):
    raw = _clean(raw).replace(":", "").replace(" ", "")
    if not raw:
        return ""
    only_bin = True
    for c in raw:
        if c != "0" and c != "1":
            only_bin = False
    if only_bin:
        return raw
    result = ""
    for i in range(0, len(raw), 2):
        chunk = raw[i:i+2]
        if len(chunk) < 2:
            continue
        valid = True
        for c in chunk:
            if not (c.isdigit() or c.lower() in "abcdef"):
                valid = False
        if valid:
            b = int(chunk, 16)
            for bit_pos in range(7, -1, -1):
                result = result + ("1" if (b & (1 << bit_pos)) else "0")
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    ver = params.get("snmp_version", "2c")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v" + ver, "-c", community, "-Ovq", host, BASE + ".2.1.1.0"],
            mutates=False, ok_codes=[0, 1, 2],
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no APC Symmetra found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{
            "item": "",
            "params": {
                "capacity_warn": 95.0, "capacity_crit": 80.0,
                "calibration_state": 0, "battery_replace_state": 1,
                "battime_warn": 0.0, "battime_crit": 0.0,
            },
            "metrics": ["capacity", "runtime"],
        }]}}

    res = ctx.run(
        ["snmpget", "-v" + ver, "-c", community, "-Ovqt", host] + BATTERY_OIDS,
        mutates=False, ok_codes=[0, 1, 2],
    )
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "SNMP unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = [_clean(l) for l in res.stdout.splitlines() if l.strip()]
    if len(lines) < 12:
        return {"changed": False, "msg": "incomplete SNMP response (%d fields)" % len(lines),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ups_comm    = lines[0]
    battery_s   = lines[1]
    output_s    = lines[2]
    cap_s       = lines[3]
    repl_s      = lines[4]
    packs_s     = lines[5]
    time_s      = lines[6]
    calib       = lines[7]
    state_raw   = lines[11]

    bits_str = _to_bits(state_raw)
    self_test = len(bits_str) > 28 and bits_str[28] == "1"

    overall = "OK"
    parts = []
    metrics = {}

    if ups_comm == "2":
        overall = _merge(overall, "UNKNOWN")
        parts.append("UPS communication lost")

    batt_map = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "normal"),
        "3": ("CRIT", "low"),
        "4": ("CRIT", "in fault condition"),
    }
    if battery_s in batt_map:
        bs, br = batt_map[battery_s]
    else:
        bs, br = "UNKNOWN", "unexpected(%s)" % battery_s
    parts.append("Battery status: " + br)
    overall = _merge(overall, bs)

    if repl_s:
        num_packs = int(packs_s) if packs_s.isdigit() else 0
        if num_packs > 1:
            parts.append("%d batteries need replacing" % num_packs)
            overall = _merge(overall, "CRIT")
        elif repl_s == "1":
            parts.append("No battery needs replacing")
        elif repl_s == "2":
            repl_sev = _state_name(params.get("battery_replace_state", 1))
            parts.append("Battery needs replacing")
            overall = _merge(overall, repl_sev)
        else:
            parts.append("Battery needs replacing: unknown")
            overall = _merge(overall, "UNKNOWN")

    if output_s:
        os_txt = OUTPUT_TEXTS.get(output_s, "unexpected(%s)" % output_s)
        if output_s not in OUTPUT_TEXTS:
            os_state = "UNKNOWN"
        elif output_s not in ["2", "4", "12"] and calib != "3" and not self_test:
            os_state = "CRIT"
        elif output_s in ["2", "4", "12"] and calib == "2" and not self_test:
            os_state = _state_name(params.get("calibration_state", 0))
        else:
            os_state = "OK"
        calib_txts = {"1": "", "2": " (calibration invalid)", "3": " (calibration in progress)"}
        calib_txt = calib_txts.get(calib, " (calibration unexpected(%s))" % calib)
        st_txt = " (self-test running)" if self_test else ""
        parts.append("Output status: " + os_txt + calib_txt + st_txt)
        overall = _merge(overall, os_state)

    if cap_s.isdigit():
        cap = float(cap_s)
        metrics["capacity"] = cap
        cap_warn = params.get("capacity_warn", 95.0)
        cap_crit = params.get("capacity_crit", 80.0)
        if cap <= cap_crit:
            overall = _merge(overall, "CRIT")
            parts.append("Capacity: %f%% (crit<=%f%%)" % (cap, cap_crit))
        elif cap <= cap_warn:
            overall = _merge(overall, "WARN")
            parts.append("Capacity: %f%% (warn<=%f%%)" % (cap, cap_warn))
        else:
            parts.append("Capacity: %f%%" % cap)

    if time_s.isdigit():
        secs = float(time_s) / 100.0
        metrics["runtime"] = secs
        tw = params.get("battime_warn", 0.0)
        tc = params.get("battime_crit", 0.0)
        mins = int(secs / 60)
        sec_part = int(secs % 60)
        ts = "%d m %d s" % (mins, sec_part)
        if tc > 0.0 and secs <= tc:
            overall = _merge(overall, "CRIT")
            parts.append("Time remaining: %s (!!)" % ts)
        elif tw > 0.0 and secs <= tw:
            overall = _merge(overall, "WARN")
            parts.append("Time remaining: %s (!)" % ts)
        else:
            parts.append("Time remaining: " + ts)

    cart_res = ctx.run(
        ["snmpwalk", "-v" + ver, "-c", community, "-Ovq", host, CART_OID],
        mutates=False, ok_codes=[0, 1, 2],
    )
    if cart_res.rc == 0 and cart_res.stdout.strip():
        for cart_idx, cline in enumerate(cart_res.stdout.splitlines()):
            bm = _to_bits(_clean(cline))
            if not bm:
                continue
            faults = []
            for bit_i in range(len(bm)):
                if bm[bit_i] == "1" and bit_i in CART_FAULTS:
                    faults.append(CART_FAULTS[bit_i])
            if faults:
                parts.append("Battery pack cartridge %d: %s" % (cart_idx, ", ".join(faults)))
                overall = _merge(overall, "WARN")
            else:
                parts.append("Battery pack cartridge %d: OK" % cart_idx)

    msg = ", ".join(parts) if parts else "APC Symmetra OK"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": overall, "metrics": metrics, "details": ""},
    }