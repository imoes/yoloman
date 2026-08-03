# Translated Checkmk check: cups_queues
# Monitors CUPS print queues: their status, job counts, and age of oldest job.
# Read-only: never mutates the system.

_MON_MAP = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}

_STATE_STR = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

_SEV = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

_DIGITS = {"0":1,"1":1,"2":1,"3":1,"4":1,"5":1,"6":1,"7":1,"8":1,"9":1}

def _is_digit(s):
    if len(s) == 0:
        return False
    for c in s:
        if _DIGITS.get(c, 0) == 0:
            return False
    return True

def _is_time(s):
    parts = s.split(":")
    if len(parts) != 3:
        return False
    for p in parts:
        if not _is_digit(p):
            return False
    return True

def _parse_time(s):
    parts = s.split(":")
    return (int(parts[0]), int(parts[1]), int(parts[2]))

def _to_epoch(year, mon, day, hh, mm, ss):
    days = _days_from_civil(year, mon, day)
    return days * 86400 + hh * 3600 + mm * 60 + ss

def _days_from_civil(y, m, d):
    y2 = y - (1 if m <= 2 else 0)
    era = (y2 if y2 >= 0 else y2 - 399) // 400
    yoe = y2 - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468

def _safe_strptime_job(tstr):
    parts = tstr.split(" ")
    if len(parts) != 5:
        return None
    if _MON_MAP.get(parts[0], 0) != 0 and len(parts[1]) <= 2 and _is_digit(parts[1]) \
       and _is_time(parts[2]) and _is_digit(parts[3]) and len(parts[3]) == 4:
        mon = _MON_MAP[parts[0]]
        day = int(parts[1])
        hh, mm, ss = _parse_time(parts[2])
        year = int(parts[3])
        return _to_epoch(year, mon, day, hh, mm, ss)
    if _is_digit(parts[0]) and len(parts[0]) <= 2 and _MON_MAP.get(parts[1], 0) != 0 \
       and _is_digit(parts[2]) and len(parts[2]) == 4 and _is_time(parts[3]):
        day = int(parts[0])
        mon = _MON_MAP[parts[1]]
        year = int(parts[2])
        hh, mm, ss = _parse_time(parts[3])
        return _to_epoch(year, mon, day, hh, mm, ss)
    return None

def _looks_like_job(line):
    tokens = line.split()
    if len(tokens) < 8:
        return False
    for i in range(len(tokens) - 1, -1, -1):
        t = tokens[i]
        if len(t) == 4 and _is_digit(t):
            return True
    return False

def _assign_jobs(parsed, job_tokens_list):
    for t in job_tokens_list:
        item = t[0].split("-", 1)[0]
        if item not in parsed:
            continue
        year_idx = -1
        for i in range(len(t) - 1, -1, -1):
            tok = t[i]
            if len(tok) == 4 and _is_digit(tok):
                year_idx = i
                break
        if year_idx < 0 or year_idx < 3:
            continue
        time_tokens = t[year_idx - 4: year_idx + 1]
        if len(time_tokens) != 5:
            continue
        jt = _safe_strptime_job(" ".join(time_tokens))
        if jt != None:
            parsed[item]["jobs"].append(jt)

def _parse_agent(output):
    parsed = {}
    lines = output.split("\n")
    n = len(lines)
    idx = 0
    while idx < n:
        line = lines[idx]
        tokens = line.split()
        if len(tokens) == 0:
            idx += 1
            continue
        if tokens[0] == "printer":
            name = tokens[1]
            rest = " ".join(tokens[2:])
            status_part = " ".join(tokens[2:4]).replace(" ", "_").strip(".")
            if name not in parsed:
                parsed[name] = {"status_readable": status_part, "output": rest, "jobs": []}
            else:
                parsed[name]["status_readable"] = status_part
                parsed[name]["output"] = rest
            idx += 1
            j = idx
            while j < n and len(lines[j]) > 0 and not lines[j].startswith("printer") \
                  and lines[j].split()[0] != "---" and not _looks_like_job(lines[j]):
                parsed[name]["output"] += " (%s)" % " ".join(lines[j].split())
                j += 1
            idx = j
        elif tokens[0] == "---":
            idx += 1
            job_tokens_list = []
            k = idx
            while k < n:
                if _looks_like_job(lines[k]):
                    job_tokens_list.append(lines[k].split())
                k += 1
            _assign_jobs(parsed, job_tokens_list)
            idx = n
        else:
            idx += 1
    return parsed

def _grade_upper(value, levels):
    if levels == None:
        return "OK"
    w = levels[0]
    c = levels[1]
    if value >= c:
        return "CRIT"
    if value >= w:
        return "WARN"
    return "OK"

def _render_timespan(seconds):
    s = int(seconds)
    if s < 60:
        return str(s) + "s"
    m = s // 60
    ss = s % 60
    if m < 60:
        return "%dm %ds" % (m, ss)
    h = m // 60
    mi = m % 60
    if h < 24:
        return "%dh %dm %ds" % (h, mi, ss)
    d = h // 24
    hh = h % 24
    return "%dd %d:%d:%d" % (d, hh, mi, ss)

def _epoch_now(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0 and len(res.stdout) > 0:
        v = ""
        for ch in res.stdout:
            if _DIGITS.get(ch, 0) != 0:
                v += ch
            else:
                break
        if len(v) > 0:
            return int(v)
    return 0

def _suggested_params():
    return {
        "is_idle": 0,
        "now_printing": 0,
        "disabled_since": 2,
        "job_count": (5, 10),
        "job_age": (360, 720),
    }

def _state_num_for(status_key, p):
    is_idle = p.get("is_idle", 0)
    now_printing = p.get("now_printing", 0)
    disabled_since = p.get("disabled_since", 2)
    mp = {"is_idle": is_idle, "now_printing": now_printing, "disabled_since": disabled_since}
    return mp.get(status_key, 3)

def _worst_of(a, b):
    sa = _SEV[a]
    sb = _SEV[b]
    if sa >= sb:
        return a
    return b

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lpstat", "-p", "-t"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no CUPS queues found",
                    "data": {"discovery": [], "host_labels": {}}}
        section = _parse_agent(res.stdout)
        out = []
        for item in sorted(section):
            entry = {"item": item, "params": _suggested_params(), "metrics": ["jobs", "job_age"]}
            out.append(entry)
        return {"changed": False, "msg": "discovered %d CUPS queues" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["lpstat", "-p", "-t"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "lpstat not available: no CUPS data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_agent(res.stdout)
    if item not in section:
        return {"changed": False, "msg": "Queue not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section[item]
    status_key = data["status_readable"]
    state_str = _STATE_STR[_state_num_for(status_key, params)]

    metrics = {}
    details = data["output"]

    now = _epoch_now(ctx)
    jobs = data["jobs"]
    jobs_count = len(jobs)
    age = 0
    if jobs_count > 0:
        metrics["jobs"] = jobs_count
        oldest = min(jobs)
        age = now - oldest
        if age < 0:
            age = 0
        metrics["job_age"] = age
        details += "\nOldest job is from %s" % _render_timespan(age)

    final_state = state_str
    if jobs_count > 0:
        jc = _grade_upper(jobs_count, params.get("job_count", (5, 10)))
        ja = _grade_upper(age, params.get("job_age", (360, 720)))
        final_state = _worst_of(final_state, _worst_of(jc, ja))

    summary = data["output"]
    if jobs_count > 0:
        summary += " (%d jobs, oldest %s)" % (jobs_count, _render_timespan(age))

    return {"changed": False, "msg": summary,
            "data": {"state": final_state, "metrics": metrics, "details": details}}