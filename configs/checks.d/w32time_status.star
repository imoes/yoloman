# Translated Checkmk check: checkmk.w32time_status
# Windows time service (w32tm) monitoring, read-only Starlark module.

def _parse_int(s):
    t = s.strip()
    p = t.find("(")
    if p >= 0:
        t = t[:p].strip()
    sp = t.find(" ")
    if sp >= 0:
        t = t[:sp].strip()
    if t == "":
        return 0
    neg = False
    if t.startswith("-"):
        neg = True
        t = t[1:]
    if not t.isdigit():
        return 0
    v = int(t)
    return -v if neg else v

def _parse_float(s):
    t = s.strip()
    p = t.find("(")
    if p >= 0:
        t = t[:p].strip()
    end = 0
    saw_digit = False
    for i in range(len(t)):
        c = t[i]
        if c.isdigit():
            saw_digit = True
            end = i + 1
        elif c == "." or c == "-" or c == "+":
            end = i + 1
        else:
            if saw_digit:
                break
            end = i + 1
    num = t[:end].strip()
    if num == "" or num == "-" or num == "+" or num == ".":
        return 0.0
    neg = False
    if num.startswith("-"):
        neg = True
        num = num[1:]
    elif num.startswith("+"):
        num = num[1:]
    sign = -1 if neg else 1
    if "." in num:
        whole, frac = num.split(".", 1)
    else:
        whole, frac = num, ""
    if whole == "":
        whole = "0"
    if frac == "":
        frac = "0"
    if len(frac) > 9:
        frac = frac[:9]
    w = int(whole) if whole.isdigit() else 0
    f = 0
    base = 1
    for ch in frac:
        if not ch.isdigit():
            break
        base = base * 10
        f = f * 10 + int(ch)
    if base == 1:
        return float(sign * w)
    return sign * (float(w) + f / float(base))

def _parse_hex(s):
    t = s.strip()
    p = t.find("(")
    if p >= 0:
        t = t[:p].strip()
    if t.startswith("0x") or t.startswith("0X"):
        t = t[2:]
    v = 0
    for ch in t:
        d = -1
        if ("0" <= ch) and (ch <= "9"):
            d = int(ch)
        elif ("a" <= ch) and (ch <= "f"):
            d = 10 + (int(ch[0]) - int("a"[0]))
        elif ("A" <= ch) and (ch <= "F"):
            d = 10 + (int(ch[0]) - int("A"[0]))
        if d < 0:
            return 0
        v = v * 16 + d
    return v

def _grade_levels(value, levels_upper, levels_lower):
    state = "OK"
    detail = ""
    if levels_upper != None:
        mode = levels_upper[0]
        if mode == "fixed":
            lvls = levels_upper[1]
            warn = lvls[0]
            crit = lvls[1]
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
            detail = " (warn>=%f crit>=%f)" % (warn, crit)
    if levels_lower != None:
        mode = levels_lower[0]
        if mode == "fixed":
            lvls = levels_lower[1]
            warn = lvls[0]
            crit = lvls[1]
            if value <= crit:
                state = "CRIT"
            elif value <= warn and state != "CRIT":
                state = "WARN"
            detail = detail + " (lower warn<=%f crit<=%f)" % (warn, crit)
    return state, detail

def _grade_int_levels(value, levels_upper):
    state = "OK"
    detail = ""
    if levels_upper != None:
        mode = levels_upper[0]
        if mode == "fixed":
            lvls = levels_upper[1]
            warn = lvls[0]
            crit = lvls[1]
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
            detail = " (warn>=%d crit>=%d)" % (warn, crit)
    return state, detail

def _state_from_int(v):
    if v == 0:
        return "OK"
    if v == 1:
        return "WARN"
    if v == 2:
        return "CRIT"
    if v == 3:
        return "UNKNOWN"
    return "UNKNOWN"

def _sync_result_to_check_result(err, states):
    notices = {
        0: "Sync status: successful",
        1: "Sync status: No data from time provider",
        2: "Sync status: Stale data received from time provider",
        3: "Sync status: Difference in time from provider was too large",
        4: "Sync status: Time service shutting down",
    }
    notice = notices.get(err, "Sync status: Unexpected sync result")
    if err == 0:
        st = "OK"
    elif err == 1:
        st = _state_from_int(states.get("no_data", 1))
    elif err == 2:
        st = _state_from_int(states.get("stale_data", 0))
    elif err == 3:
        st = _state_from_int(states.get("time_diff_too_large", 1))
    elif err == 4:
        st = _state_from_int(states.get("shutting_down", 1))
    else:
        st = "UNKNOWN"
    return st, notice

def _render_timespan(s):
    if s < 0:
        return "%fs" % s
    days = int(s / 86400)
    rem = s - days * 86400
    hours = int(rem / 3600)
    rem = rem - hours * 3600
    mins = int(rem / 60)
    secs = rem - mins * 60
    if days > 0:
        return "%dd %dh %dm" % (days, hours, mins)
    if hours > 0:
        return "%dh %dm %ds" % (hours, mins, int(secs))
    if mins > 0:
        return "%dm %fs" % (mins, secs)
    return "%fs" % s

def _render_time_offset(s):
    return "%fs" % s

def _before_parens(s):
    p = s.find("(")
    if p >= 0:
        return s[:p]
    return s

def _in_parens(s):
    p1 = s.find("(")
    p2 = s.find(")")
    if p1 >= 0 and p2 >= 0 and p2 > p1:
        return s[p1 + 1:p2]
    return s

def _parse_w32tm_output(stdout):
    lines = []
    for raw in stdout.splitlines():
        if ":" not in raw:
            continue
        value = raw.split(":", 1)[1].strip()
        lines.append(value)
    if len(lines) == 1:
        return {"error": lines[0]}
    if len(lines) < 16:
        msg = "incomplete w32tm output: only %d lines" % len(lines)
        return {"error": msg}
    return {
        "leap_indicator": _parse_int(_before_parens(lines[0])),
        "stratum": _parse_int(_before_parens(lines[1])),
        "precision": _parse_int(_before_parens(lines[2])),
        "root_delay": _parse_float(_before_parens(lines[3])),
        "root_dispersion": _parse_float(_before_parens(lines[4])),
        "reference_id": _parse_hex(_before_parens(lines[5])),
        "last_successful_sync_time": lines[6],
        "source": lines[7],
        "poll_interval": _parse_int(_in_parens(lines[8])),
        "phase_offset": _parse_float(lines[9]),
        "clock_rate": _parse_float(lines[10]),
        "state_machine": _parse_int(_before_parens(lines[11])),
        "time_source_flags": _parse_int(_before_parens(lines[12])),
        "server_role": _parse_int(_before_parens(lines[13])),
        "last_sync_error": _parse_int(_before_parens(lines[14])),
        "seconds_since_last_good_sync": _parse_float(lines[15]),
    }

def _worst(a, b):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    ra = rank.get(a, 3)
    rb = rank.get(b, 3)
    return a if ra >= rb else b

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["w32tm", "/version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "w32tm not found", "data": {"discovery": []}}
        if probe.rc != 0 and probe.stdout == "" and probe.stderr == "":
            return {"changed": False, "msg": "w32tm not found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
            {"item": "", "params": {}, "metrics": [
                "time_offset", "root_dispersion", "root_delay",
                "last_successful_sync", "stratum",
            ]},
        ]}}

    res = ctx.run(["w32tm", "/query", "/status"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "w32tm not found on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "w32tm binary not installed"}}

    if res.rc != 0 or res.stdout.strip() == "":
        errmsg = res.stderr.strip() if res.stderr.strip() else ("w32tm /query /status failed (rc=%d)" % res.rc)
        return {"changed": False, "msg": "w32tm error: " + errmsg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = _parse_w32tm_output(res.stdout)
    if "error" in status:
        return {"changed": False, "msg": status["error"],
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    default_states = {
        "never_synced": 1,
        "no_data": 1,
        "stale_data": 0,
        "time_diff_too_large": 1,
        "shutting_down": 1,
    }
    p_states = params.get("states", {})
    states = dict(default_states)
    for k in p_states:
        states[k] = p_states[k]

    if status["state_machine"] == 0 and status["reference_id"] == 0:
        st = _state_from_int(states["never_synced"])
        return {"changed": False, "msg": "Never synchronized (w32tm reported reference ID and state machine both 0)",
                "data": {"state": st, "metrics": {}, "details": ""}}

    offset_levels = params.get("offset", ("fixed", (0.2, 0.5)))
    sync_levels = params.get("time_since_last_successful_sync", ("no_levels", None))
    stratum_levels = params.get("stratum", ("fixed", (5, 5)))

    offset_lower = None
    if offset_levels[0] == "fixed":
        offset_lower = ("fixed", (-offset_levels[1][1], -offset_levels[1][0]))

    off_state, off_detail = _grade_levels(status["phase_offset"], offset_levels, offset_lower)
    off_render = _render_time_offset(status["phase_offset"])

    sync_state, sync_detail = _grade_levels(status["seconds_since_last_good_sync"], sync_levels, None)
    sync_render = "Last successful sync: " + _render_timespan(status["seconds_since_last_good_sync"]) + " ago"

    stratum_state, stratum_detail = _grade_int_levels(status["stratum"], stratum_levels)

    rd_state, rd_detail = _grade_levels(status["root_dispersion"], None, None)
    rdl_state, rdl_detail = _grade_levels(status["root_delay"], None, None)

    sync_err_state, sync_err_notice = _sync_result_to_check_result(status["last_sync_error"], states)

    overall = "OK"
    overall = _worst(overall, off_state)
    overall = _worst(overall, sync_state)
    overall = _worst(overall, sync_err_state)

    source_name = status["source"].split(",")[0]
    msg = "Source: %s, Offset: %s%s" % (source_name, off_render, off_detail)

    metrics = {
        "time_offset": status["phase_offset"],
        "root_dispersion": status["root_dispersion"],
        "root_delay": status["root_delay"],
        "last_successful_sync": status["seconds_since_last_good_sync"],
        "stratum": status["stratum"],
    }

    part1 = "Source: %s\nOffset: %s%s\nRoot delay: %s\nRoot dispersion: %s\n" % (
        source_name, off_render, off_detail,
        _render_timespan(status["root_delay"]),
        _render_timespan(status["root_dispersion"]),
    )
    part2 = "Stratum: %d%s\nLast successful sync: %s\nSync error: %s\nSeconds since last good sync: %s" % (
        status["stratum"], stratum_detail,
        sync_render,
        sync_err_notice,
        _render_timespan(status["seconds_since_last_good_sync"]),
    )
    details = part1 + part2

    return {"changed": False, "msg": msg,
            "data": {"state": overall, "metrics": metrics, "details": details}}