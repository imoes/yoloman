def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _to_int(s):
    if s == "" or s == "-":
        return 0
    stripped = s.strip()
    if stripped.lstrip("-").isdigit():
        return int(stripped)
    return 0


def _to_float(s):
    if s == "" or s == "-":
        return 0.0
    stripped = s.strip()
    if _is_numeric(stripped):
        return float(stripped)
    return 0.0


def _is_numeric(s):
    if s == "" or s == "-" or s == "+" or s == ".":
        return False
    digits = "0123456789"
    parts = s
    if parts == "":
        return False
    if parts[0] == "-":
        parts = parts[1:]
    elif parts[0] == "+":
        parts = parts[1:]
    if parts == "":
        return False
    has_dot = False
    seen_digit = False
    for ch in parts:
        if ch == ".":
            if has_dot:
                return False
            has_dot = True
        elif ch in digits:
            seen_digit = True
        else:
            return False
    return seen_digit


def _fmt_time(raw):
    if raw == "-" or raw == "":
        return 0
    suffix = raw[-1]
    mult = {"m": 60, "h": 3600, "d": 86400, "y": 31536000}
    if suffix in mult and _is_numeric(raw[:-1]):
        return int(raw[:-1]) * mult[suffix]
    if _is_numeric(raw):
        return int(raw)
    return 0


_NTP_STATE_CODES = {
    "x": "falsetick",
    ".": "excess",
    "-": "outlyer",
    "+": "candidat",
    "#": "selected",
    "*": "sys.peer",
    "o": "pps.peer",
    "%": "discarded",
}


def _get_section(ctx):
    res = ctx.run(["chronyc", "sources", "-c"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {}
    section = {}
    for line in res.stdout.splitlines():
        f = line.split(",")
        if len(f) != 11:
            continue
        statecode = f[0]
        name = f[1]
        refid = f[2]
        stratum = _to_int(f[3])
        when = _fmt_time(f[5])
        reach = f[7]
        offset = _to_float(f[9])
        jitter = _to_float(f[10])
        peer = {
            "statecode": statecode,
            "name": name,
            "refid": refid,
            "stratum": stratum,
            "when": when,
            "reach": reach,
            "offset": offset,
            "jitter": jitter,
        }
        section[peer["name"]] = peer
        if None not in section and statecode in "*o":
            section[None] = peer
    return section


def _discover(ctx, params):
    res = ctx.run(["chronyc", "sources", "-c"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no ntp time data", "data": {"discovery": []}}
    section = _get_section(ctx)
    mode = params.get("mode", "summary")
    items = []
    if mode in ("single", "both"):
        for peer in section.values():
            if peer["reach"] != "0" and peer["refid"] != ".LOCL.":
                items.append({"item": peer["name"], "params": {}, "metrics": ["offset", "jitter"]})
    if mode in ("summary", "both") and section:
        items.append({"item": "", "params": {}, "metrics": ["offset"]})
    msg = "discovered %d items" % len(items)
    return {"changed": False, "msg": msg, "data": {"discovery": items}}


def _check(ctx, params):
    section = _get_section(ctx)
    ntp_levels = params.get("ntp_levels", (10, 200.0, 500.0))
    crit_stratum = ntp_levels[0]
    warn = ntp_levels[1]
    crit = ntp_levels[2]
    peer = section.get(None)
    if peer == None:
        if section:
            msg = "Found %d peers, but none is suitable" % len(section)
            return {"changed": False, "msg": msg, "data": {"state": "OK", "metrics": {}, "details": ""}}
        msg = "no synchronization source found"
        return {"changed": False, "msg": msg, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    offset = peer["offset"]
    if offset >= crit or offset <= -crit:
        offset_state = "CRIT"
    elif offset >= warn or offset <= -warn:
        offset_state = "WARN"
    else:
        offset_state = "OK"

    stratum = peer["stratum"]
    if stratum >= crit_stratum:
        stratum_state = "CRIT"
    else:
        stratum_state = "OK"

    jitter = peer["jitter"]

    state = "OK"
    if offset_state != "OK":
        state = offset_state
    if stratum_state == "CRIT" and state != "CRIT":
        state = stratum_state

    if peer["statecode"] in _NTP_STATE_CODES:
        state_code = _NTP_STATE_CODES[peer["statecode"]]
    else:
        state_code = "unknown"
    if state_code == "falsetick":
        state = "CRIT"

    if peer["reach"] == "0":
        msg = "Peer %s is unreachable" % peer["name"]
        state = "UNKNOWN"
    else:
        msg = "Offset: %f ms, Jitter: %f ms, Stratum: %d, State: %s" % (offset, jitter, stratum, state_code)

    metrics = {"offset": offset, "jitter": jitter}
    details = "Synchronized on %s" % peer["name"]
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}