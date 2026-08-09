# Huawei WLC AP Status — read-only Starlark check module

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

_RADIO_STATE_MAP = {
    "1": ("up", "OK"),
    "2": ("down", "CRIT"),
}

_BASE_AP_INFO1 = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
_BASE_AP_INFO2 = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
_WLC_SYSOID_PREFIX = ".1.3.6.1.4.1.2011.2.240.17"


def _to_float(s):
    if s == None:
        return None
    if s == "":
        return None
    stripped = s.strip()
    if stripped == "":
        return None
    neg = stripped.startswith("-") or stripped.startswith("+")
    body = stripped[1:] if neg else stripped
    if body == "":
        return None
    if not body.replace(".", "", 1).isdigit():
        return None
    return float(stripped)


def _to_int(s):
    if s == None:
        return None
    if s == "":
        return None
    stripped = s.strip()
    if stripped == "":
        return None
    neg = stripped.startswith("-") or stripped.startswith("+")
    body = stripped[1:] if neg else stripped
    if not body.isdigit():
        return None
    return int(stripped)


def _snmpget(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    rows = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        rows.append((sp[0], sp[1].strip()))
    return rows


def _is_wlc_host(ctx, host, community):
    sysoid = _snmpget(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sysoid == None:
        return False
    if not sysoid.startswith(_WLC_SYSOID_PREFIX):
        return False
    return True


def _build_section(ctx, community, host):
    aps_info1 = {}
    cols1 = ["6", "40", "41", "43", "44"]
    for col in cols1:
        oid = _BASE_AP_INFO1 + "." + col
        rows = _snmpwalk(ctx, community, host, oid)
        if rows == None:
            return None
        for full_oid, value in rows:
            idx = full_oid[len(oid) + 1:]
            aps_info1.setdefault(idx, {})[col] = value

    aps_info2 = {}
    cols2 = ["3", "6", "25", "40"]
    for col in cols2:
        oid = _BASE_AP_INFO2 + "." + col
        rows = _snmpwalk(ctx, community, host, oid)
        if rows == None:
            return None
        for full_oid, value in rows:
            idx = full_oid[len(oid) + 1:]
            aps_info2.setdefault(idx, {})[col] = value

    parsed = {}
    idxs = sorted(aps_info1.keys())
    for idx in idxs:
        r1 = aps_info1[idx]
        status = r1.get("6")
        if status == None or status not in _AP_STATE_MAP:
            continue
        ap_label, ap_state = _AP_STATE_MAP[status]
        mem_raw = r1.get("40")
        cpu_raw = r1.get("41")
        temp_raw = r1.get("43")
        con_raw = r1.get("44")
        if mem_raw == None or cpu_raw == None or temp_raw == None or con_raw == None:
            continue
        mem = _to_float(mem_raw)
        cpu = _to_float(cpu_raw)
        if mem == None or cpu == None:
            continue
        if temp_raw == "255":
            temp = "invalid"
        else:
            tf = _to_float(temp_raw)
            if tf == None:
                temp = "invalid"
            else:
                temp = tf

        pairs = {}
        order = sorted(aps_info2.keys())
        for k in range(0, len(order) - 1, 2):
            a = order[k]
            b = order[k + 1]
            ra = aps_info2[a]
            rb = aps_info2[b]
            aid_a = ra.get("3")
            if aid_a != None:
                pairs[aid_a] = (ra, rb)
            else:
                pairs["AP-" + idx] = (ra, rb)

        if len(pairs) > 0:
            match = list(pairs.values())[0]
        else:
            pos = idxs.index(idx)
            if 2 * pos + 1 < len(order):
                match = (aps_info2[order[2 * pos]], aps_info2[order[2 * pos + 1]])
            else:
                match = None

        def _radio_block(rinfo):
            if rinfo == None:
                return {
                    "radio_cmk_state": "UNKNOWN",
                    "radio_readable_state": "not available",
                    "ch_usage": 0.0,
                    "users_online": 0,
                }
            rstate = rinfo.get("6")
            rl, rs = _RADIO_STATE_MAP.get(rstate, ("not available", "UNKNOWN"))
            ch_f = _to_float(rinfo.get("25"))
            users_i = _to_int(rinfo.get("40"))
            return {
                "radio_cmk_state": rs,
                "radio_readable_state": rl,
                "ch_usage": ch_f if ch_f != None else 0.0,
                "users_online": users_i if users_i != None else 0,
            }

        if match != None:
            radio2_block = _radio_block(match[0])
            radio5_block = _radio_block(match[1])
        else:
            radio2_block = _radio_block(None)
            radio5_block = _radio_block(None)

        parsed["AP-" + idx] = {
            "cmk_status": ap_state,
            "state_readable": ap_label,
            "mem_used_percent": mem,
            "cpu_percent": cpu,
            "temp": temp,
            "con_users": con_raw,
            "24ghz": radio2_block,
            "5ghz": radio5_block,
        }

    return parsed


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_wlc_host(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Huawei WLC (no AP syOID)",
            "data": {"discovery": [], "host_labels": {}},
        }

    if params.get("_discover"):
        section = _build_section(ctx, community, host)
        if section == None:
            return {
                "changed": False,
                "msg": "could not build huawei_wlc_aps section",
                "data": {"discovery": [], "host_labels": {}},
            }
        discovery = []
        for name in section:
            discovery.append({
                "item": name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": [
                    "24ghz_clients",
                    "5ghz_clients",
                    "channel_utilization_24ghz",
                    "channel_utilization_5ghz",
                ],
            })
        return {
            "changed": False,
            "msg": "discovered %d APs" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "linux"}},
        }

    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0

    section = _build_section(ctx, community, host)
    if section == None or not section:
        return {
            "changed": False,
            "msg": "no Huawei WLC AP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "AP not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = data["cmk_status"]
    details_parts = [data["state_readable"]]

    metrics = {}
    for radio, band in (("24ghz", "2,4GHz"), ("5ghz", "5GHz")):
        rinfo = data[radio]
        ch = rinfo["ch_usage"]
        clients = rinfo["users_online"]
        band_key = "24ghz" if band == "2,4GHz" else "5ghz"
        metrics[band_key + "_clients"] = clients
        metrics["channel_utilization_" + band_key] = ch

        if ch >= crit:
            if state == "OK":
                state = "CRIT"
            elif state == "WARN":
                state = "CRIT"
        elif ch >= warn:
            if state == "OK":
                state = "WARN"

        details_parts.append(
            "Channel usage [%s]: %s%%, Users online [%s]: %d (radio: %s)" % (
                band, str(ch), band, clients, rinfo["radio_readable_state"],
            )
        )

    for radio, band in (("24ghz", "2,4GHz"), ("5ghz", "5GHz")):
        rstate = data[radio]["radio_cmk_state"]
        if rstate == "CRIT" and state != "CRIT":
            state = "CRIT"
        elif rstate == "WARN" and state == "OK":
            state = "WARN"
        elif rstate == "UNKNOWN" and state == "OK":
            state = "UNKNOWN"

    cpu = data["cpu_percent"]
    mem = data["mem_used_percent"]
    metrics["cpu_percent"] = cpu
    metrics["mem_used_percent"] = mem
    if cpu >= crit:
        if state == "OK":
            state = "CRIT"
        elif state == "WARN":
            state = "CRIT"
    elif cpu >= warn:
        if state == "OK":
            state = "WARN"
    if mem >= crit:
        if state == "OK":
            state = "CRIT"
        elif state == "WARN":
            state = "CRIT"
    elif mem >= warn:
        if state == "OK":
            state = "WARN"

    details_parts.append("Connected users: %s" % data["con_users"])
    details_parts.append("CPU: %s%%, Memory: %s%%" % (str(cpu), str(mem)))

    return {
        "changed": False,
        "msg": "AP %s Status: %s" % (item, data["state_readable"]),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "; ".join(details_parts),
        },
    }