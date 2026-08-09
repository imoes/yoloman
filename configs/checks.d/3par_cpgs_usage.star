_STATES = {
    1: ("OK", "Normal"),
    2: ("WARN", "Degraded"),
    3: ("CRIT", "Failed"),
}

_DEFAULT_PARAMS = {
    "warn": 80.0,
    "crit": 90.0,
}

def _b64(s):
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    pad = "="
    out = []
    val = 0
    bits = 0
    for c in s:
        val = (val << 8) | _ord(c)
        bits += 8
        while bits >= 6:
            bits -= 6
            idx = (val >> bits) & 63
            out.append(chars[idx])
    if bits > 0:
        idx = (val << (6 - bits)) & 63
        out.append(chars[idx])
    while len(out) % 4 != 0:
        out.append(pad)
    return "".join(out)

def _ord(c):
    for i in range(256):
        if chr(i) == c:
            return i
    return 0

def _fetch_cpgs(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    token = params.get("token")
    username = params.get("username")
    password = params.get("password")
    path = params.get("path", "/api/v1/cpgs")
    base = "https://%s:%d%s" % (host, int(port), path)
    argv = ["curl", "-sk", "-H", "Accept: application/json"]
    if token != None:
        argv = argv + ["-H", "x-hp3par-wsapi-sessionkey: " + token]
    if username != None and password != None:
        argv = argv + ["-H", "authorization: Basic " + _b64(username + ":" + password)]
    argv = argv + ["-X", "GET", base]
    res = ctx.run(argv, mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0 or not res.stdout:
        return None
    return json.decode(res.stdout)

def _extract_cpgs(raw):
    if raw == None:
        return {}
    members = None
    if type(raw) == "dict":
        members = raw.get("members")
    if members == None:
        return {}
    out = {}
    if type(members) == "list":
        for entry in members:
            if type(entry) == "dict":
                name = entry.get("name")
                if name != None:
                    out[name] = entry
    return out

def _space_usage(data, field):
    su = data.get(field) if type(data) == "dict" else None
    if su == None:
        return (0.0, 0.0)
    total = su.get("totalMiB")
    used = su.get("usedMiB")
    total = float(total) if total != None else 0.0
    used = float(used) if used != None else 0.0
    return (total, used)

def _count_vvs(cpg):
    fpvvs = cpg.get("numFPVVs")
    tdvvs = cpg.get("numTDVVs")
    tpvvs = cpg.get("numTPVVs")
    fpvvs = int(fpvvs) if fpvvs != None else 0
    tdvvs = int(tdvvs) if tdvvs != None else 0
    tpvvs = int(tpvvs) if tpvvs != None else 0
    return fpvvs + tdvvs + tpvvs

def _grade_usage(total, used, free, warn, crit):
    if total <= 0:
        return ("OK", 0.0)
    used_pct = (used / total) * 100.0
    free_pct = (free / total) * 100.0
    state = "OK"
    if used_pct >= crit:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"
    return (state, free_pct)

def main(ctx, params):
    if params.get("_discover"):
        raw = _fetch_cpgs(ctx, params)
        section = _extract_cpgs(raw)
        if len(section) == 0:
            return {"changed": False, "msg": "no HPE 3PAR array reachable",
                    "data": {"discovery": []}}
        items = []
        for cpg in section.values():
            if _count_vvs(cpg) > 0:
                for fs in ["SAUsage", "SDUsage", "UsrUsage"]:
                    item_name = "%s %s" % (cpg.get("name"), fs)
                    items.append({"item": item_name,
                                  "params": dict(_DEFAULT_PARAMS),
                                  "metrics": ["used_percent", "free_percent"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    raw = _fetch_cpgs(ctx, params)
    if raw == None:
        return {"changed": False,
                "msg": "HPE 3PAR array not reachable (no data source)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _extract_cpgs(raw)
    if len(section) == 0:
        return {"changed": False,
                "msg": "no CPG data in response from array",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpg = None
    fs = None
    for key in section:
        c = section[key]
        name = c.get("name")
        if name != None:
            if item == "%s SAUsage" % name:
                cpg = c
                fs = "SAUsage"
                break
            if item == "%s SDUsage" % name:
                cpg = c
                fs = "SDUsage"
                break
            if item == "%s UsrUsage" % name:
                cpg = c
                fs = "UsrUsage"
                break
    if cpg == None:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total, used = _space_usage(cpg, fs)
    free = total - used
    warn = params.get("warn", _DEFAULT_PARAMS["warn"])
    crit = params.get("crit", _DEFAULT_PARAMS["crit"])
    state, free_pct = _grade_usage(total, used, free, warn, crit)
    used_pct = (used / total) * 100.0 if total > 0 else 0.0

    cpg_state = cpg.get("state")
    state_label = "Unknown"
    if cpg_state != None and cpg_state in _STATES:
        st, label = _STATES[cpg_state]
        if st == "CRIT" and state != "CRIT":
            state = "CRIT"
        state_label = label

    msg = "%s, %s VVs, %f%% used, %f%% free" % (state_label,
                                                     str(_count_vvs(cpg)),
                                                     used_pct, free_pct)
    return {"changed": False,
            "msg": msg,
            "data": {"state": state,
                     "metrics": {"used_percent": used_pct, "free_percent": free_pct},
                     "details": "total=%f MiB, used=%f MiB, free=%f MiB" % (total, used, free)}}