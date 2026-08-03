def _opt_int(raw):
    if raw == None:
        return None
    s = raw.strip()
    if s == "":
        return None
    if s[0] == "-":
        rest = s[1:]
    else:
        rest = s
    if rest == "" or not rest.isdigit():
        return None
    return int(s)


def _snmpwalk(ctx, host, community, oid, ok_codes):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc == 127:
        return None, "not_installed"
    if res.rc != 0 and res.rc not in ok_codes:
        return None, "error"
    rows = []
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx <= 0:
            continue
        rows.append((line[:idx], line[idx + 1:]))
    return rows, "ok"


def _get_instances(ctx, host, community):
    sbase = ".1.3.6.1.4.1.2620.1.16.22.1.1"
    cbase = ".1.3.6.1.4.1.2620.1.16.23.1.1"
    ok_codes = [0, 2]

    srows, st = _snmpwalk(ctx, host, community, sbase, ok_codes)
    if srows == None or st != "ok":
        return None, st

    crows, ct = _snmpwalk(ctx, host, community, cbase, ok_codes)
    if crows == None or ct != "ok":
        return None, ct

    sby = {}
    for oid, val in srows:
        idx = oid[len(sbase) + 1:]
        sby.setdefault(idx, {})["s"] = val

    cby = {}
    for oid, val in crows:
        idx = oid[len(cbase) + 1:]
        cby.setdefault(idx, {})["c"] = val

    all_idx = list(sby.keys()) + [i for i in cby.keys() if i not in sby.keys()]
    instances = {}
    for idx in all_idx:
        se = sby.get(idx, {})
        ce = cby.get(idx, {})
        sv = se.get("s")
        cv = ce.get("c")
        if sv == None or cv == None:
            continue
        sfields = [f.strip().strip('"') for f in sv.split(",")]
        cfields = [f.strip().strip('"') for f in cv.split(",")]
        if len(sfields) < 9 or len(cfields) < 13:
            continue
        vs_id = sfields[0]
        vs_name = sfields[2]
        vs_ip = sfields[3]
        vs_policy = sfields[4]
        vs_policy_type = sfields[5]
        vs_sic_status = sfields[6]
        vs_ha_status = sfields[7]
        conn_num = _opt_int(sfields[8])

        conn_table_size = _opt_int(cfields[1]) if len(cfields) > 1 else None
        packets = _opt_int(cfields[2]) if len(cfields) > 2 else None
        packets_dropped = _opt_int(cfields[3]) if len(cfields) > 3 else None
        packets_accepted = _opt_int(cfields[4]) if len(cfields) > 4 else None
        packets_rejected = _opt_int(cfields[5]) if len(cfields) > 5 else None
        bytes_accepted = _opt_int(cfields[7]) if len(cfields) > 7 else None
        bytes_dropped = _opt_int(cfields[8]) if len(cfields) > 8 else None
        bytes_rejected = _opt_int(cfields[9]) if len(cfields) > 9 else None
        packets_logged = _opt_int(cfields[6]) if len(cfields) > 6 else None

        instances["%s %s" % (vs_name, vs_id)] = {
            "vs_name": vs_name,
            "vs_ip": vs_ip,
            "vs_policy": vs_policy,
            "vs_policy_type": vs_policy_type,
            "vs_sic_status": vs_sic_status,
            "vs_ha_status": vs_ha_status,
            "conn_num": conn_num,
            "conn_table_size": conn_table_size,
            "packets": packets,
            "packets_dropped": packets_dropped,
            "packets_accepted": packets_accepted,
            "packets_rejected": packets_rejected,
            "bytes_accepted": bytes_accepted,
            "bytes_dropped": bytes_dropped,
            "bytes_rejected": bytes_rejected,
            "packets_logged": packets_logged,
        }
    return instances, "ok"


def _grade_upper(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _check_vs_status(data):
    ha_state = data["vs_ha_status"]
    sic_state = data["vs_sic_status"]
    policy_type = data["vs_policy_type"]

    state = "OK"
    if ha_state.lower() not in ["active", "standby"]:
        state = "CRIT"
    if sic_state.lower() != "trust established":
        state = "CRIT"
    if policy_type.lower() not in ["active", "initial policy"]:
        state = "CRIT"

    parts = ["HA Status: %s" % ha_state, "SIC Status: %s" % sic_state, "Policy name: %s" % data["vs_policy"], "Policy type: %s" % policy_type]
    if policy_type.lower() not in ["active", "initial policy"]:
        parts = parts[:3] + ["Policy type: %s (no policy installed)" % policy_type]

    return {"state": state, "metrics": {}, "details": "; ".join(parts)}


def _check_vs_info(data):
    details = "Type: %s; Main IP: %s" % (data["vs_name"], data["vs_ip"])
    return {"state": "OK", "metrics": {}, "details": details}


def _check_vs_connections(data, warn, crit):
    conn_total = data["conn_num"]
    if conn_total == None:
        return None

    metrics = {"connections": conn_total}
    details = "Used: %d" % conn_total
    conn_limit = data["conn_table_size"]

    if conn_limit != None and conn_limit > 0:
        perc = 100.0 * conn_total / conn_limit
        metrics["connections_perc"] = perc
        details += ", limit: %d (%f%%)" % (conn_limit, perc)
        state = _grade_upper(perc, warn, crit)
    else:
        state = _grade_upper(conn_total, warn, crit)

    return {"state": state, "metrics": metrics, "details": details}


def _check_vs_packets(ctx, data, params, rate_cache):
    metrics = {}
    details_parts = []
    rate_state = "OK"
    now_ts = 0
    up = ctx.file_read("/proc/uptime") if ctx.file_exists("/proc/uptime") else ""
    if up != "":
        up_fields = up.split()
        if len(up_fields) > 0:
            now_ts = int(float(up_fields[0]))

    for key, label, value in [
        ("packets", "Total number of packets processed", data["packets"]),
        ("packets_accepted", "Total number of accepted packets", data["packets_accepted"]),
        ("packets_dropped", "Total number of dropped packets", data["packets_dropped"]),
        ("packets_rejected", "Total number of rejected packets", data["packets_rejected"]),
        ("packets_logged", "Total number of logs sent", data["packets_logged"]),
    ]:
        if value == None:
            continue
        rate_key = "%s_rate" % key
        rk = rate_cache.get(rate_key)
        if rk != None and rk.get("time") != None and now_ts != 0:
            dt = now_ts - rk["time"]
            if dt > 0:
                rate = (value - rk["value"]) / dt
            else:
                rate = 0.0
        else:
            rate = 0.0
        rate_cache[rate_key] = {"time": now_ts, "value": value}
        metrics[key] = value
        details_parts.append("%s: %d (%d/s)" % (label, value, int(rate)))
        lv = params.get(key, None)
        if lv != None and rate > 0:
            if type(lv) == "list" and len(lv) >= 2:
                warn_v = lv[0]
                crit_v = lv[1]
                s = _grade_upper(rate, warn_v, crit_v)
                if s == "CRIT":
                    rate_state = "CRIT"
                elif s == "WARN" and rate_state != "CRIT":
                    rate_state = "WARN"

    return {"state": rate_state, "metrics": metrics, "details": "; ".join(details_parts)}


def _check_vs_traffic(data, params):
    metrics = {}
    details_parts = []
    rate_state = "OK"

    for key, value in [
        ("bytes_accepted", data["bytes_accepted"]),
        ("bytes_dropped", data["bytes_dropped"]),
        ("bytes_rejected", data["bytes_rejected"]),
    ]:
        if value == None:
            continue
        metrics[key] = value
        details_parts.append("Total number of %s: %d" % (key.replace("_", " "), value))
        lv = params.get(key, None)
        if lv != None and value > 0:
            if type(lv) == "list" and len(lv) >= 2:
                warn_v = lv[0]
                crit_v = lv[1]
                s = _grade_upper(value, warn_v, crit_v)
                if s == "CRIT":
                    rate_state = "CRIT"
                elif s == "WARN" and rate_state != "CRIT":
                    rate_state = "WARN"

    return {"state": rate_state, "metrics": metrics, "details": "; ".join(details_parts)}


def _discover(ctx, host, community):
    test_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if test_res.rc == 127:
        return {"discovery": [], "host_labels": {"cmk/os_family": "unknown"}}

    instances, st = _get_instances(ctx, host, community)
    if instances == None:
        return {"discovery": [], "host_labels": {"cmk/os_family": "unknown"}}

    discovery = []
    for item in instances:
        d = instances[item]
        metrics = []
        if d.get("conn_num") != None:
            metrics.append("connections")
        if d.get("packets") != None:
            metrics.extend(["packets", "packets_accepted", "packets_dropped", "packets_rejected", "packets_logged"])
        if d.get("bytes_accepted") != None:
            metrics.extend(["bytes_accepted", "bytes_dropped", "bytes_rejected"])
        discovery.append({
            "item": item,
            "params": {"warn": 80, "crit": 90},
            "metrics": metrics,
            "service_labels": {"vsx_ha_status": d.get("vs_ha_status", ""), "vsx_sic_status": d.get("vs_sic_status", ""), "vsx_policy_type": d.get("vs_policy_type", "")},
        })
    return {"discovery": discovery, "host_labels": {"cmk/os_family": "unknown"}}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        result = _discover(ctx, host, community)
        return {"changed": False, "msg": "discovered %d VSX instances" % len(result["discovery"]), "data": result}

    item = params.get("item", "")
    subcheck = params.get("subcheck", "vsx_status")
    instances, st = _get_instances(ctx, host, community)
    if instances == None:
        return {"changed": False, "msg": "no checkpoint_vsx data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item not in instances:
        return {"changed": False, "msg": "VS %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = instances[item]

    if subcheck == "vsx_info":
        r = _check_vs_info(data)
        return {"changed": False, "msg": "VS %s Info: Type: %s, Main IP: %s" % (item, data["vs_name"], data["vs_ip"]), "data": {"state": r["state"], "metrics": r["metrics"], "details": r["details"]}}

    if subcheck == "vsx_connections":
        warn = params.get("warn", 80.0)
        crit = params.get("crit", 90.0)
        if type(warn) == "list":
            warn = warn[0] if len(warn) > 0 else 80.0
        if type(crit) == "list":
            crit = crit[0] if len(crit) > 0 else 90.0
        if type(warn) != "float" and type(warn) != "int":
            warn = 80.0
        if type(crit) != "float" and type(crit) != "int":
            crit = 90.0
        r = _check_vs_connections(data, warn, crit)
        if r == None:
            return {"changed": False, "msg": "VS %s Connections: no connection data" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "VS %s Connections: %s" % (item, r["details"]), "data": {"state": r["state"], "metrics": r["metrics"], "details": r["details"]}}

    if subcheck == "vsx_packets":
        rate_cache = {}
        r = _check_vs_packets(ctx, data, params, rate_cache)
        return {"changed": False, "msg": "VS %s Packets: %s" % (item, r["details"]), "data": {"state": r["state"], "metrics": r["metrics"], "details": r["details"]}}

    if subcheck == "vsx_traffic":
        r = _check_vs_traffic(data, params)
        return {"changed": False, "msg": "VS %s Traffic: %s" % (item, r["details"]), "data": {"state": r["state"], "metrics": r["metrics"], "details": r["details"]}}

    r = _check_vs_status(data)
    return {"changed": False, "msg": "VS %s Status: %s" % (item, r["details"]), "data": {"state": r["state"], "metrics": r["metrics"], "details": r["details"]}}