# ===== Starlark check module: sap_hana_fileinfo =====
# Monitor a single file's age and size on the host. Read-only: it stats the
# file directly (no Checkmk agent output involved).

STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def _fmt_size(n):
    # NB: Starlark's % operator has no precision (%.1f is "unknown conversion"),
    # so render one decimal with integer math via "%d.%d".
    if n == None:
        return "unknown"
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        t = n * 10 // 1024
        return "%d.%d KB" % (t // 10, t % 10)
    if n < 1024 * 1024 * 1024:
        t = n * 10 // (1024 * 1024)
        return "%d.%d MB" % (t // 10, t % 10)
    t = n * 10 // (1024 * 1024 * 1024)
    return "%d.%d GB" % (t // 10, t % 10)

def _fmt_age(sec):
    if sec == None:
        return "unknown"
    if sec < 0:
        sec = -sec
    sec = int(sec)
    d = sec // 86400
    h = (sec // 3600) % 24
    m = (sec // 60) % 60
    s = sec % 60
    parts = []
    if d:
        parts.append("%dd" % d)
    if h:
        parts.append("%dh" % h)
    if m:
        parts.append("%dm" % m)
    parts.append("%ds" % s)
    return " ".join(parts)

def _missing_state(params):
    sm = params.get("state_missing", "CRIT")
    if sm == "OK":
        return STATE_OK
    if sm == "WARN":
        return STATE_WARN
    if sm == "UNKNOWN":
        return STATE_UNKNOWN
    return STATE_CRIT

def _file_age(ctx, path):
    # ctx.stat has no mtime, so read it (and "now") from the host.
    rm = ctx.run(["stat", "-c", "%Y", path], mutates = False)
    rn = ctx.run(["date", "+%s"], mutates = False)
    mt = rm.stdout.strip() if rm.rc == 0 else ""
    nw = rn.stdout.strip() if rn.rc == 0 else ""
    if mt.isdigit() and nw.isdigit():
        age = int(nw) - int(mt)
        if age < 0:
            age = 0
        return age
    return None

def main(ctx, params):
    # Configured per file — nothing to auto-discover.
    if params.get("_discover"):
        return {"changed": False, "msg": "sap_hana_fileinfo is configured per file path",
                "data": {"discovery": []}}

    path = params.get("path", "")
    if not path:
        path = params.get("item", "")
    if not path:
        return {"changed": False, "msg": STATE_UNKNOWN,
                "data": {"state": STATE_UNKNOWN, "metrics": {},
                         "details": "No file path configured — set the 'path' option."}}

    st = ctx.stat(path)
    if st == None or not st.get("exists"):
        ms = _missing_state(params)
        return {"changed": False, "msg": ms,
                "data": {"state": ms, "metrics": {}, "details": "File not found: %s" % path}}
    if st.get("is_dir"):
        return {"changed": False, "msg": STATE_WARN,
                "data": {"state": STATE_WARN, "metrics": {}, "details": "%s is a directory, not a file" % path}}

    size = st.get("size")
    age = _file_age(ctx, path)

    state = STATE_OK
    reasons = []

    max_age = params.get("max_age")
    max_age_crit = params.get("max_age_crit")
    if age != None:
        if max_age_crit != None and age > max_age_crit:
            state = STATE_CRIT
            reasons.append("age > %s" % _fmt_age(max_age_crit))
        elif max_age != None and age > max_age:
            state = STATE_WARN
            reasons.append("age > %s" % _fmt_age(max_age))

    min_size = params.get("min_size")
    max_size = params.get("max_size")
    if size != None:
        if min_size != None and size < min_size:
            if state != STATE_CRIT:
                state = STATE_WARN
            reasons.append("size < %s" % _fmt_size(min_size))
        if max_size != None and size > max_size:
            if state != STATE_CRIT:
                state = STATE_WARN
            reasons.append("size > %s" % _fmt_size(max_size))

    detail = "%s — Size: %s, Age: %s" % (path, _fmt_size(size), _fmt_age(age))
    if reasons:
        detail += " (%s)" % ", ".join(reasons)

    metrics = {"size": size if size != None else 0}
    if age != None:
        metrics["age"] = age

    return {"changed": False, "msg": state,
            "data": {"state": state, "metrics": metrics, "details": detail}}
