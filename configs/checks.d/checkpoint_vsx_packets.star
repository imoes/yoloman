def _opt_int(raw):
    if raw == None or raw == "":
        return None
    neg = ""
    s = raw
    if s.startswith("-"):
        neg = "-"
        s = s[1:]
    out = ""
    for ch in s:
        if ch >= "0" and ch <= "9":
            out = out + ch
        else:
            break
    if out == "":
        return None
    n = 0
    for ch in out:
        n = n * 10 + (ord(ch) - 48)
    if neg == "-":
        n = -n
    return n

def _rate(prev):
    cur_val = prev["val"]
    cur_time = prev["time"]
    return cur_val, cur_time

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-Oqv", params.get("host", "localhost"),
                       ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no checkpoint device found",
                    "data": {"discovery": [], "host_labels": {}}}
        sysoid = res.stdout.strip()
        if not (sysoid.startswith(".1.3.6.1.4.1.2620") or sysoid == ""):
            fw = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqv", params.get("host", "localhost"),
                         ".1.3.6.1.4.1.2620.1.1.21.0"], mutates=False)
            if fw.rc != 0:
                fw_val = ""
            else:
                fw_val = fw.stdout.strip()
            if fw_val != "firewall":
                gaia = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                               "-Oqv", params.get("host", "localhost"),
                               ".1.3.6.1.4.1.2620.1.6.5.1.0"], mutates=False)
                if gaia.rc != 0 or gaia.stdout.strip() != "Gaia":
                    return {"changed": False, "msg": "no checkpoint device found",
                            "data": {"discovery": [], "host_labels": {}}}
        status_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                              "-Oqn", params.get("host", "localhost"),
                              ".1.3.6.1.4.1.2620.1.16.22.1.1.1"], mutates=False)
        counter_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                               "-Oqn", params.get("host", "localhost"),
                               ".1.3.6.1.4.1.2620.1.16.23.1.1.2"], mutates=False)
        if status_res.rc != 0 or counter_res.rc != 0:
            return {"changed": False, "msg": "no checkpoint vsx found",
                    "data": {"discovery": [], "host_labels": {}}}
        by_index = {}
        for line in status_res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            idx = oid[len(".1.3.6.1.4.1.2620.1.16.22.1.1.1."):]
            col = oid[len(".1.3.6.1.4.1.2620.1.16.22.1.1.1.")]
            if not by_index.has(idx):
                by_index[idx] = {}
            by_index[idx]["col"] = col
            by_index[idx]["oid"] = oid
            by_index[idx]["status_val"] = val
        status_map = {}
        for line in status_res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp+1:]
            if not oid.startswith(".1.3.6.1.4.1.2620.1.16.22.1.1.1."):
                continue
            suffix = oid[len(".1.3.6.1.4.1.2620.1.16.22.1.1.1."):]
            parts = suffix.rsplit(".", 1)
            if len(parts) != 2:
                continue
            col = parts[0]
            idx = parts[1]
            if not status_map.has(idx):
                status_map[idx] = {}
            status_map[idx][col] = val
        instances = {}
        for idx, cols in status_map.items():
            vs_name = cols.get("3", "")
            vs_type = cols.get("4", "")
            vs_ip = cols.get("5", "")
            vs_policy = cols.get("6", "")
            vs_policy_type = cols.get("7", "")
            vs_sic_status = cols.get("8", "")
            vs_ha_status = cols.get("9", "")
            packets = _opt_int(cols.get("10"))
            if packets == None:
                continue
            instances[idx] = {
                "vs_name": vs_name, "vs_type": vs_type, "vs_sic_status": vs_sic_status,
                "vs_ha_status": vs_ha_status, "vs_ip": vs_ip, "vs_policy": vs_policy,
                "vs_policy_type": vs_policy_type, "packets": packets,
            }
        discovery = []
        for idx, data in instances.items():
            item_name = data["vs_name"] + " " + idx
            discovery.append({"item": item_name, "params": {},
                              "metrics": ["packets", "packets_accepted",
                                          "packets_dropped", "packets_rejected",
                                          "packets_logged"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    idx = item
    sp = item.rfind(" ")
    if sp != -1:
        idx = item[sp+1:]
        vs_name = item[:sp]
    else:
        idx = item
        vs_name = ""
    status_base = ".1.3.6.1.4.1.2620.1.16.22.1.1"
    counter_base = ".1.3.6.1.4.1.2620.1.16.23.1.1"
    cols_status = ["1", "3", "4", "5", "6", "7", "8", "9", "10"]
    status_vals = {}
    for c in cols_status:
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                     host, status_base + "." + c + "." + idx], mutates=False)
        if r.rc != 0:
            return {"changed": False,
                    "msg": "unknown: no vsx instance '%s'" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        status_vals[c] = r.stdout.strip()
    packets = _opt_int(status_vals.get("10"))
    if packets == None:
        return {"changed": False,
                "msg": "unknown: no packet data for '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    now_time = ctx.run(["date", "+%s"], mutates=False)
    if now_time.rc != 0 or not now_time.stdout.strip().isdigit():
        this_time = 0
    else:
        this_time = int(now_time.stdout.strip())
    rate_key = "pkts_rate_" + idx
    prev = {}
    if not ctx.file_exists("/tmp/.cmk_vsx_pkts_" + idx):
        prev = {"val": packets, "time": this_time - 1}
    else:
        prev_content = ctx.file_read("/tmp/.cmk_vsx_pkts_" + idx)
        lines = prev_content.split("\n")
        prev = {"val": _opt_int(lines[0]) if len(lines) > 0 else packets,
                "time": int(lines[1]) if len(lines) > 1 and lines[1].isdigit() else this_time - 1}
    elapsed = this_time - prev["time"]
    if elapsed > 0 and prev["val"] != None:
        rate = (packets - prev["val"]) / elapsed
        if rate < 0:
            rate = 0.0
    else:
        rate = 0.0
    if not ctx.check_mode:
        ctx.run(["sh", "-c", "echo '" + str(packets) + "\n" + str(this_time) + "' > /tmp/.cmk_vsx_pkts_" + idx + "'"], mutates=False)
    metrics = {"packets": rate}
    warn = params.get("warn")
    crit = params.get("crit")
    levels = params.get("packets")
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        lw = levels[0]
        lc = levels[1]
    else:
        lw = None
        lc = None
    state = "OK"
    if lc != None and rate >= lc:
        state = "CRIT"
    elif lw != None and rate >= lw:
        state = "WARN"
    msg = "%s packets/s" % str(rate)
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}