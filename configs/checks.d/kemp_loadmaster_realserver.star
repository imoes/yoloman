def _rs_state(state):
    if state == "1":
        return ("OK", "in service")
    if state == "2":
        return ("CRIT", "out of service")
    if state == "3":
        return ("CRIT", "failed")
    if state == "4":
        return ("CRIT", "disabled")
    return ("UNKNOWN", "unknown[%s]" % state)

def _detect_kemp_loadmaster(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", "-t", "5", "-r", "1", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    return val == ".1.3.6.1.4.1.12196.250.10" or val == ".1.3.6.1.4.1.2021.250.10"

def _walk_table(ctx, params, base, col_map):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    rows = {}
    for col in col_map:
        oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "5", "-r", "1",
             host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return None
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            line_oid = line[:sp]
            value = line[sp + 1:]
            idx = line_oid[len(oid) + 1:]
            if idx not in rows:
                rows[idx] = {}
            rows[idx][col_map[col]] = value
    return rows

def main(ctx, params):
    if params.get("_discover"):
        if not _detect_kemp_loadmaster(ctx, params):
            return {"changed": False, "msg": "Kemp Loadmaster not detected",
                    "data": {"discovery": []}}
        rs_rows = _walk_table(ctx, params, ".1.3.6.1.4.1.12196.13.2.1",
                              {"1": "vsidx", "2": "ip", "8": "state"})
        if rs_rows == None:
            return {"changed": False, "msg": "Kemp Loadmaster not detected",
                    "data": {"discovery": []}}
        by_ip = {}
        for idx in rs_rows:
            ip = rs_rows[idx].get("ip", "")
            if ip not in by_ip:
                by_ip[ip] = []
            by_ip[ip].append(rs_rows[idx])
        discovery = []
        for ip in by_ip:
            all_disabled = True
            for rs in by_ip[ip]:
                if _rs_state(rs.get("state", ""))[1] != "disabled":
                    all_disabled = False
            if not all_disabled:
                discovery.append({
                    "item": ip,
                    "params": {},
                    "metrics": ["state"],
                })
        n = len(discovery)
        return {"changed": False, "msg": "discovered %d items" % n,
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    if not _detect_kemp_loadmaster(ctx, params):
        return {"changed": False, "msg": "Kemp Loadmaster not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rs_rows = _walk_table(ctx, params, ".1.3.6.1.4.1.12196.13.2.1",
                          {"1": "vsidx", "2": "ip", "8": "state"})
    if rs_rows == None:
        return {"changed": False, "msg": "Kemp Loadmaster not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    svc_rows = _walk_table(ctx, params, ".1.3.6.1.4.1.12196.13.1.1",
                           {"1": "oid_end", "2": "name"})
    if svc_rows == None:
        return {"changed": False, "msg": "could not fetch services table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    matching = []
    for idx in rs_rows:
        if rs_rows[idx].get("ip", "") == item:
            matching.append(rs_rows[idx])
    if len(matching) == 0:
        return {"changed": False, "msg": "no real server found for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    msg_parts = []
    any_crit = False
    any_unknown = False
    for rs in matching:
        state_str, state_txt = _rs_state(rs.get("state", ""))
        summary = state_txt.capitalize()
        vsid = rs.get("vsidx", "")
        for sidx in svc_rows:
            if svc_rows[sidx].get("oid_end", "") == vsid:
                summary = svc_rows[sidx].get("name", "") + ": " + summary
        msg_parts.append(summary)
        if state_str == "CRIT":
            any_crit = True
        if state_str == "UNKNOWN":
            any_unknown = True
    
    if any_crit:
        final_state = "CRIT"
    elif any_unknown:
        final_state = "UNKNOWN"
    else:
        final_state = "OK"
    
    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": final_state, "metrics": {}, "details": ""}}