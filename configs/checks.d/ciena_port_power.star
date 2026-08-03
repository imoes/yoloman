def _ipow(b, e):
    r = 1.0
    i = 0
    while i < e:
        r = r * b
        i = i + 1
    return r

_LN10 = 2.302585092994046
_LN2 = 0.6931471805599453

def _ln(x):
    if x <= 0:
        return None
    n = 1
    while n < 1000:
        if x > _ipow(2, n - 1) and x <= _ipow(2, n):
            break
        n = n + 1
    x = x / _ipow(2, n - 1)
    x = x * 2 - 1
    y = 0.0
    k = 1
    term = x / k
    while k < 200:
        y = y + term
        k = k + 1
        term = term * (-1) * x / k
    return y - (n - 1) * _LN2

def _log10(x):
    return _ln(x) / _LN10

def _micro_watt_to_dBm(m_w):
    if m_w == 0:
        return None
    return 10 * _log10(m_w / 1000.0)

def _get_columns(model):
    if model == "5142":
        return ["19", "42", "43", "27", "40", "41"]
    return ["6", "15", "16", "35", "13", "14"]

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "no ciena device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "no ciena device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysdesc = res.stdout.strip()
    model = None
    base = None
    if "5142" in sysdesc:
        model = "5142"
        base = ".1.3.6.1.4.1.6141.2.60.4.1.1.1.1"
    elif "5171" in sysdesc:
        model = "5171"
        base = ".1.3.6.1.4.1.1271.2.1.9.1.1.1.1"
    else:
        if params.get("_discover"):
            return {"changed": False, "msg": "no ciena device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "no ciena device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        cols = _get_columns(model)
        col_base = base + "." + cols[1]
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_base], mutates=False)
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "no ciena port power entries", "data": {"discovery": []}}
        items = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            idx = oid[len(col_base) + 1:]
            if idx and idx not in items:
                items.append(idx)
        discovery = []
        for idx in items:
            discovery.append({"item": idx, "params": {}, "metrics": ["input_signal_power_dbm", "output_signal_power_dbm"]})
        return {"changed": False, "msg": "discovered %d ports" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    cols = _get_columns(model)
    vals = []
    ok = True
    for c in cols:
        oid = base + "." + c + "." + item
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if r.rc != 0 or not r.stdout:
            ok = False
            break
        vals.append(r.stdout.strip())

    if not ok:
        return {"changed": False, "msg": "item %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    nums = []
    for v in vals:
        nums.append(int(v))

    rx_pw = _micro_watt_to_dBm(nums[3])
    rx_upper = _micro_watt_to_dBm(nums[1])
    rx_lower = _micro_watt_to_dBm(nums[2])
    tx_pw = _micro_watt_to_dBm(nums[6])
    tx_upper = _micro_watt_to_dBm(nums[4])
    tx_lower = _micro_watt_to_dBm(nums[5])

    warn_rx_upper = params.get("levels_rx_upper_warn", None)
    crit_rx_upper = params.get("levels_rx_upper_crit", None)
    warn_rx_lower = params.get("levels_rx_lower_warn", None)
    crit_rx_lower = params.get("levels_rx_lower_crit", None)
    warn_tx_upper = params.get("levels_tx_upper_warn", None)
    crit_tx_upper = params.get("levels_tx_upper_crit", None)
    warn_tx_lower = params.get("levels_tx_lower_warn", None)
    crit_tx_lower = params.get("levels_tx_lower_crit", None)

    _rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

    def _worst(s1, s2):
        if _rank.get(s1, 3) >= _rank.get(s2, 3):
            return s1
        return s2

    def _grade(value, warn_u, crit_u, warn_l, crit_l):
        s = "OK"
        if value != None:
            if value >= crit_u:
                s = "CRIT"
            elif value >= warn_u:
                s = "WARN"
            elif value <= crit_l:
                s = "CRIT"
            elif value <= warn_l:
                s = "WARN"
        return s

    state = "OK"
    metrics = {}
    details = ""

    if rx_pw != None and rx_upper != None and rx_lower != None:
        metrics["input_signal_power_dbm"] = rx_pw
        s = _grade(rx_pw, warn_rx_upper, crit_rx_upper, warn_rx_lower, crit_rx_lower)
        state = _worst(state, s)
        details = details + "Receive: %f dBm" % rx_pw
    else:
        details = details + " Receive: 0 watt"

    if tx_pw != None and tx_upper != None and tx_lower != None:
        metrics["output_signal_power_dbm"] = tx_pw
        s = _grade(tx_pw, warn_tx_upper, crit_tx_upper, warn_tx_lower, crit_tx_lower)
        state = _worst(state, s)
        details = details + " Transmit: %f dBm" % tx_pw
    else:
        details = details + " Transmit: 0 watt"

    if not details:
        details = "no data"

    return {"changed": False, "msg": details, "data": {"state": state, "metrics": metrics, "details": details}}