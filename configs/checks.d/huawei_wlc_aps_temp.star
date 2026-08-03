# Huawei WLC APs Temperature check — read-only Starlark translation
# Source check: checkmk.huawei_wlc_aps_temp
# Data source: SNMP (Huawei WLAN Controller AP table)

_AP_STATE_MAP = {
    "1": ("Idle", "CRIT"),
    "2": ("Auto find", "WARN"),
    "3": ("Type not match", "CRIT"),
    "4": ("Fault", "CRIT"),
    "5": ("Config", "CRIT"),
    "6": ("Config failed", "CRIT"),
    "7": ("Download", "WARN"),
    "8": ("Normal", "OK"),
    "9": ("Committing", "CRIT"),
    "10": ("Commit failed", "CRIT"),
    "11": ("Standy", "WARN"),
    "12": ("Version mismatch", "CRIT"),
    "13": ("Name conflicted", "CRIT"),
    "14": ("Invalid", "CRIT"),
    "15": ("Country code mismatch", "CRIT"),
}

def _to_float(s):
    if s == None or s == "":
        return None
    cleaned = s.strip()
    if cleaned == "":
        return None
    neg = False
    start = 0
    if cleaned.startswith("-"):
        neg = True
        start = 1
    body = cleaned[start:]
    valid = True
    has_dot = False
    for ch in body:
        if ch == ".":
            if has_dot:
                valid = False
                break
            has_dot = True
        elif ch < "0" or ch > "9":
            valid = False
            break
    if not valid:
        return None
    return float(cleaned)

def _grade_temp(value, levels):
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _get_ap_table(ctx, host, community):
    base1 = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
    cols1 = ["6", "40", "41", "43", "44"]
    col_data = {}
    for col in cols1:
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base1 + "." + col],
            mutates=False,
        )
        if res.rc != 0:
            return None
        lines = res.stdout.strip().splitlines()
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            full_oid = parts[0]
            val = parts[1].strip()
            prefix = base1 + "." + col
            if full_oid.startswith(prefix + "."):
                idx = full_oid[len(prefix) + 1:]
            else:
                idx = ""
            row = col_data.get(idx)
            if row == None:
                row = {}
                col_data[idx] = row
            row[col] = val

    base2 = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
    res2 = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base2 + ".3"],
        mutates=False,
    )
    ap_id_map = {}
    if res2.rc == 0:
        for line in res2.stdout.strip().splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            full_oid = parts[0]
            val = parts[1].strip()
            if full_oid.startswith(base2 + ".3."):
                idx = full_oid[len(base2 + ".3") + 1:]
            else:
                idx = ""
            ap_id_map[idx] = val

    table = {}
    for idx, cols in col_data.items():
        ap_id = ap_id_map.get(idx, idx)
        table[ap_id] = {
            "status": cols.get("6", ""),
            "mem": cols.get("40", ""),
            "cpu": cols.get("41", ""),
            "temp": cols.get("43", ""),
            "con_users": cols.get("44", ""),
        }
    return table

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed", "data": {"discovery": []}}
        sysoid = res.stdout.strip()
        if sysoid.find("2011.2.240.17") == -1 and sysoid.find("2011.6.139.13") == -1:
            return {"changed": False, "msg": "not a Huawei WLC", "data": {"discovery": []}}

        table = _get_ap_table(ctx, host, community)
        if table == None:
            return {"changed": False, "msg": "could not fetch AP table", "data": {"discovery": []}}

        discovery = []
        for ap_id in sorted(table.keys()):
            discovery.append({
                "item": ap_id,
                "params": {"levels": [70.0, 75.0]},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "huawei_wlc"}},
        }

    levels = params.get("levels", [70.0, 75.0])
    table = _get_ap_table(ctx, host, community)
    if table == None:
        return {"changed": False, "msg": "not a Huawei WLC or no data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = table.get(item)
    if data == None:
        return {"changed": False, "msg": "AP %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_raw = data["temp"]
    if temp_raw == "255":
        return {"changed": False, "msg": "AP " + item + " Temperature: not available", "data": {"state": "OK", "metrics": {}, "details": "temperature sensor reports invalid (255)"}}

    temp = _to_float(temp_raw)
    if temp == None:
        return {"changed": False, "msg": "AP " + item + " Temperature: " + str(temp_raw), "data": {"state": "OK", "metrics": {}, "details": str(temp_raw)}}

    state = _grade_temp(temp, levels)
    return {
        "changed": False,
        "msg": "AP " + item + " Temperature: %f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "AP %s temperature: %f C" % (item, temp),
        },
    }