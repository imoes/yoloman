# wagner_titanus_topsense_info.star
# Translated from Checkmk check plugins:
#   wagner_titanus_topsense_info, _overall_status, _alarm, _smoke,
#   _chamber_deviation, _airflow_deviation, _temp
# Source device: Wagner Titanus topsense (environmental monitoring), via SNMP.
# This is a READ-ONLY monitor: discovery enumerates items; check mode grades them.

_OID_SYS = ".1.3.6.1.2.1.1"
_OID_SYS_OIDS = ["1", "3", "4", "5", "6"]

_OID_MAIN_BASE = ".1.3.6.1.4.1.34187"
_OID_21501_BASE = _OID_MAIN_BASE + ".21501.1.1"
_OID_21501_EXTRA = _OID_MAIN_BASE + ".21501.2.1"
_OID_74195_BASE = _OID_MAIN_BASE + ".74195.1.1"
_OID_74195_EXTRA = _OID_MAIN_BASE + ".74195.2.1"

_OID_21501_OIDS = ["1", "2", "3", "1000", "1001", "1002", "1003", "1004", "1005", "1006"]
_OID_21501_EXTRA_OIDS = [
    "245810000", "245820000", "245950000", "246090000",
    "245960000", "246100000", "245970000", "246110000", "24584008",
]
_OID_74195_OIDS = ["1", "2", "3", "1000", "1001", "1002", "1003", "1004", "1005", "1006"]
_OID_74195_EXTRA_OIDS = [
    "245790000", "245800000", "245940000", "246060000",
    "245950000", "246070000", "245960000", "246080000",
]

_OID_SYSMIB_SYSOID = ".1.3.6.1.2.1.1.2.0"

_TEMP_DEFAULT = {"levels": (30.0, 35.0)}
_AIRFLOW_DEFAULT = {"levels_upper": (20.0, 20.0), "levels_lower": (-20.0, -20.0)}
_SMOKE_WARN = 3.0
_SMOKE_CRIT = 5.0

_IS_21501 = (_OID_21501_BASE, _OID_21501_OIDS, _OID_21501_EXTRA, _OID_21501_EXTRA_OIDS)
_IS_74195 = (_OID_74195_BASE, _OID_74195_OIDS, _OID_74195_EXTRA, _OID_74195_EXTRA_OIDS)


def _snmpget_all(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmpwalk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0 or not res.stdout:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        left = line[:sp]
        right = line[sp + 1:].strip()
        rows.append((left, right))
    return rows


def _fetch_tree(ctx, params, base, oids):
    out = {}
    for oid in oids:
        full = base + "." + oid if not oid.startswith(".") else oid
        out[oid] = _snmpget_all(ctx, params, full)
    return out


def _fetch_system(ctx, params):
    row = _fetch_tree(ctx, params, _OID_SYS, _OID_SYS_OIDS)
    vals = [row.get(o, "") for o in _OID_SYS_OIDS]
    return [vals]


def _fetch_model(ctx, params, base, oids):
    row = _fetch_tree(ctx, params, base, oids)
    vals = [row.get(o, "") for o in oids]
    return [vals]


def _fetch_extra(ctx, params, base, oids):
    return _fetch_model(ctx, params, base, oids)


def _detect_model(ctx, params):
    sysOID = _snmpget_all(ctx, params, _OID_SYSMIB_SYSOID)
    if not sysOID:
        return None
    if sysOID == ".1.3.6.1.4.1.34187.21501":
        return _IS_21501
    if sysOID == ".1.3.6.1.4.1.34187.74195":
        return _IS_74195
    return None


def _gather_section(ctx, params):
    model = _detect_model(ctx, params)
    if model == None:
        return None
    m_base, m_oids, e_base, e_oids = model
    sys_grp = _fetch_system(ctx, params)
    m_row = _fetch_model(ctx, params, m_base, m_oids)
    e_row = _fetch_extra(ctx, params, e_base, e_oids)
    if model == _IS_21501:
        s3 = [["" for _ in _OID_74195_OIDS]]
        s4 = [["" for _ in _OID_74195_EXTRA_OIDS]]
    else:
        s3 = _fetch_model(ctx, params, _OID_74195_BASE, _OID_74195_OIDS)
        s4 = _fetch_extra(ctx, params, _OID_74195_EXTRA, _OID_74195_EXTRA_OIDS)
    return [sys_grp, m_row, e_row, s3, s4]


def _get_model_data(section):
    sec1 = section[1]
    sec3 = section[3]

    def nonempty(tbl):
        if not tbl:
            return False
        row0 = tbl[0]
        for v in row0:
            if v != "":
                return True
        return False

    model = sec1 if nonempty(sec1) else sec3
    sec2 = section[2]
    sec4 = section[4]
    extra = sec2 if nonempty(sec2) else sec4
    return [section[0], model, extra]


def _fmt_timespan(hundredths):
    secs = 0
    if hundredths != "":
        # accept plain int or numeric string; no try/except
        if hundredths.lstrip("-").isdigit():
            secs = int(hundredths) // 100
        else:
            # float form "123.45"
            dot = hundredths.find(".")
            if dot >= 0:
                intpart = hundredths[:dot]
                if intpart.lstrip("-").isdigit():
                    secs = int(intpart) // 100
    days = secs // 86400
    hh = (secs % 86400) // 3600
    mm = (secs % 3600) // 60
    ss = secs % 60
    return "%dd %d:%d:%d" % (days, hh, mm, ss)


def _to_float(val):
    """Return float(val) or 0.0 when not parseable (no try/except)."""
    if val == None or val == "":
        return 0.0
    s = str(val)
    neg = False
    body = s
    if s.startswith("-"):
        neg = True
        body = s[1:]
    if s.startswith("+"):
        body = s[1:]
    if body == "":
        return 0.0
    if body.isdigit():
        f = float(int(body))
        return -f if neg else f
    dot = body.find(".")
    if dot >= 0:
        left = body[:dot]
        right = body[dot + 1:]
        ok = (left.isdigit() or left == "") and (right.isdigit() or right == "")
        if ok:
            f = float(body)
            return -f if neg else f
    return 0.0


def _temp_state(value, params):
    levels = _TEMP_DEFAULT["levels"]
    if type(params) == "dict":
        lv = params.get("levels", _TEMP_DEFAULT["levels"])
        levels = lv if type(lv) == "tuple" else _TEMP_DEFAULT["levels"]
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _upper_state(value, params):
    lu = (20.0, 20.0)
    if type(params) == "dict":
        v = params.get("levels_upper", (20.0, 20.0))
        lu = v if type(v) == "tuple" else (20.0, 20.0)
    warn = lu[0]
    crit = lu[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _lower_state(value, params):
    ll = (-20.0, -20.0)
    if type(params) == "dict":
        v = params.get("levels_lower", (-20.0, -20.0))
        ll = v if type(v) == "tuple" else (-20.0, -20.0)
    warn = ll[0]
    crit = ll[1]
    if value <= crit:
        return "CRIT"
    if value <= warn:
        return "WARN"
    return "OK"


def _row_val(row, idx):
    if row == None or idx < 0 or idx >= len(row):
        return ""
    return row[idx]


def main(ctx, params):
    name = params.get("check_name", "wagner_titanus_topsense_info")
    item = params.get("item", "")
    want_disc = params.get("_discover", False)

    if want_disc:
        model = _detect_model(ctx, params)
        if model == None:
            return {"changed": False, "msg": "no wagner_titanus_topsense device found",
                    "data": {"discovery": []}}
        if name == "wagner_titanus_topsense_info":
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": []}]}}
        if name == "wagner_titanus_topsense_overall_status":
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": []}]}}
        if name == "wagner_titanus_topsense_alarm":
            return {"changed": False, "msg": "discovered 2 services",
                    "data": {"discovery": [
                        {"item": "1", "params": {}, "metrics": []},
                        {"item": "2", "params": {}, "metrics": []}]}}
        if name == "wagner_titanus_topsense_smoke":
            return {"changed": False, "msg": "discovered 2 services",
                    "data": {"discovery": [
                        {"item": "1", "params": {}, "metrics": ["smoke_perc"]},
                        {"item": "2", "params": {}, "metrics": ["smoke_perc"]}]}}
        if name == "wagner_titanus_topsense_chamber_deviation":
            return {"changed": False, "msg": "discovered 2 services",
                    "data": {"discovery": [
                        {"item": "1", "params": {}, "metrics": ["chamber_deviation"]},
                        {"item": "2", "params": {}, "metrics": ["chamber_deviation"]}]}}
        if name == "wagner_titanus_topsense_airflow_deviation":
            lp = {"levels_upper": (20.0, 20.0), "levels_lower": (-20.0, -20.0)}
            return {"changed": False, "msg": "discovered 2 services",
                    "data": {"discovery": [
                        {"item": "1", "params": lp, "metrics": ["airflow_deviation"]},
                        {"item": "2", "params": lp, "metrics": ["airflow_deviation"]}]}}
        if name == "wagner_titanus_topsense_temp":
            lp = {"levels": (30.0, 35.0)}
            return {"changed": False, "msg": "discovered 2 services",
                    "data": {"discovery": [
                        {"item": "Ambient 1", "params": lp, "metrics": []},
                        {"item": "Ambient 2", "params": lp, "metrics": []}]}}
        return {"changed": False, "msg": "unknown check name", "data": {"discovery": []}}

    section = _gather_section(ctx, params)
    if section == None:
        return {"changed": False,
                "msg": "no wagner_titanus_topsense device found (sysOID not present)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _get_model_data(section)

    if name == "wagner_titanus_topsense_info":
        sysrow = parsed[0][0]
        mrow = parsed[1][0]
        msg = "System: %s" % _row_val(sysrow, 0)
        msg += ", Uptime: %s" % _fmt_timespan(_row_val(sysrow, 1))
        msg += ", System Name: %s" % _row_val(sysrow, 3)
        msg += ", System Contact: %s" % _row_val(sysrow, 2)
        msg += ", System Location: %s" % _row_val(sysrow, 4)
        msg += ", Company: %s" % _row_val(mrow, 0)
        msg += ", Model: %s" % _row_val(mrow, 1)
        msg += ", Revision: %s" % _row_val(mrow, 2)
        if len(section) > 8:
            erow = parsed[2][0]
            lsn = _row_val(erow, 8) if len(erow) > 8 else ""
            if lsn == "0":
                lsn = "offline"
            elif lsn == "1":
                lsn = "online"
            else:
                lsn = "unknown"
            msg += ", LSNi bus: %s" % lsn
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if name == "wagner_titanus_topsense_overall_status":
        mrow = parsed[1][0]
        psw = _row_val(mrow, 9)
        if psw == "0":
            return {"changed": False, "msg": "Overall Status reports OK",
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "Overall Status reports a problem",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    if name == "wagner_titanus_topsense_alarm":
        mrow = parsed[1][0]
        if item == "1":
            main_a = _row_val(mrow, 3)
            pre_a = _row_val(mrow, 4)
            info_a = _row_val(mrow, 5)
        elif item == "2":
            main_a = _row_val(mrow, 6)
            pre_a = _row_val(mrow, 7)
            info_a = _row_val(mrow, 8)
        else:
            return {"changed": False,
                    "msg": "Alarm Detector %s not found in SNMP" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state = "OK"
        msg = "No Alarm"
        if info_a != "0":
            msg = "Info Alarm"
            state = "WARN"
        if pre_a != "0":
            msg = "Pre Alarm"
            state = "WARN"
        if main_a != "0":
            msg = "Main Alarm: Fire"
            state = "CRIT"
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {}, "details": ""}}

    if name == "wagner_titanus_topsense_smoke":
        erow = parsed[2][0]
        if item == "1":
            val = _row_val(erow, 0)
        elif item == "2":
            val = _row_val(erow, 1)
        else:
            return {"changed": False,
                    "msg": "Smoke Detector %s not found in SNMP" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        smoke = _to_float(val)
        if smoke > _SMOKE_CRIT:
            state = "CRIT"
        elif smoke > _SMOKE_WARN:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False,
                "msg": "%f%% smoke detected" % smoke,
                "data": {"state": state, "metrics": {"smoke_perc": smoke}, "details": ""}}

    if name == "wagner_titanus_topsense_chamber_deviation":
        erow = parsed[2][0]
        if item == "1":
            val = _row_val(erow, 2)
        elif item == "2":
            val = _row_val(erow, 3)
        else:
            return {"changed": False,
                    "msg": "Chamber Deviation Detector %s not found in SNMP" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        dev = _to_float(val)
        return {"changed": False,
                "msg": "%f%% Chamber Deviation" % dev,
                "data": {"state": "OK", "metrics": {"chamber_deviation": dev}, "details": ""}}

    if name == "wagner_titanus_topsense_airflow_deviation":
        erow = parsed[2][0]
        if item == "1":
            val = _row_val(erow, 4)
        elif item == "2":
            val = _row_val(erow, 5)
        else:
            return {"changed": False,
                    "msg": "Airflow Deviation Detector %s not found in SNMP" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        af = _to_float(val)
        up = params.get("levels_upper", (20.0, 20.0))
        lo = params.get("levels_lower", (-20.0, -20.0))
        st = _upper_state(af, {"levels_upper": up})
        if st == "OK":
            st = _lower_state(af, {"levels_lower": lo})
        msg = "%f%% Airflow deviation" % (af,)
        return {"changed": False, "msg": msg,
                "data": {"state": st, "metrics": {"airflow_deviation": af}, "details": ""}}

    if name == "wagner_titanus_topsense_temp":
        erow = parsed[2][0]
        if not item.startswith("Ambient"):
            item = "Ambient %s" % item
        if item == "Ambient 1":
            val = _row_val(erow, 6)
        elif item == "Ambient 2":
            val = _row_val(erow, 7)
        else:
            return {"changed": False,
                    "msg": "Temperature %s: unknown item" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        temp = _to_float(val)
        tparams = params
        st = _temp_state(temp, tparams)
        return {"changed": False,
                "msg": "%f C" % temp,
                "data": {"state": st, "metrics": {}, "details": ""}}

    return {"changed": False,
            "msg": "unknown check name: %s" % name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}