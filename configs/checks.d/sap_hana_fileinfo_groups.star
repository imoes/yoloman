# ===== Starlark check module: sap_hana_fileinfo_groups =====
# Monitor a group of files matching one or more glob patterns: file count,
# total size and the age of the oldest match (staleness). Read-only — it
# stats the files directly on the host, no Checkmk agent output involved.

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

def _patterns(params):
    # Accept a whitespace-separated string ("/var/log/*.log /etc/*.conf") or a
    # list. A string is what the sidecar declares (the agent's schema has no
    # array type), and it maps straight onto the shell for-loop below.
    pats = params.get("patterns")
    if pats == None:
        pats = params.get("pattern")
    if type(pats) == "string":
        return [p for p in pats.split(" ") if p]
    if type(pats) == "list":
        return [p for p in pats if p]
    return []

def main(ctx, params):
    # Configured per pattern — nothing to auto-discover.
    if params.get("_discover"):
        return {"changed": False, "msg": "sap_hana_fileinfo_groups is configured per pattern",
                "data": {"discovery": []}}

    pats = _patterns(params)
    if not pats:
        return {"changed": False, "msg": STATE_UNKNOWN,
                "data": {"state": STATE_UNKNOWN, "metrics": {},
                         "details": "No file patterns configured — set the 'patterns' option, e.g. /var/log/*.log."}}

    # Expand the globs and stat every regular-file match in one host call:
    # each output line is "<size> <age_seconds>".
    script = "now=$(date +%s); for f in " + " ".join(pats) + '; do [ -f "$f" ] || continue; s=$(stat -c %s "$f" 2>/dev/null) || continue; m=$(stat -c %Y "$f" 2>/dev/null) || continue; echo "$s $((now-m))"; done'
    res = ctx.run(["sh", "-c", script], mutates = False)
    if res.rc != 0:
        return {"changed": False, "msg": STATE_UNKNOWN,
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": "failed to enumerate files: %s" % res.stderr}}

    count = 0
    total = 0
    oldest = None
    newest = None
    for line in res.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        cols = line.split(" ")
        if len(cols) < 2:
            continue
        if not cols[0].isdigit() or not cols[1].lstrip("-").isdigit():
            continue
        sz = int(cols[0])
        ag = int(cols[1])
        if ag < 0:
            ag = 0
        count += 1
        total += sz
        if oldest == None or ag > oldest:
            oldest = ag
        if newest == None or ag < newest:
            newest = ag

    state = STATE_OK
    reasons = []

    min_count = params.get("min_count")
    max_count = params.get("max_count")
    if min_count != None and count < min_count:
        state = STATE_CRIT if count == 0 else STATE_WARN
        reasons.append("count %d < %d" % (count, min_count))
    if max_count != None and count > max_count:
        if state != STATE_CRIT:
            state = STATE_WARN
        reasons.append("count %d > %d" % (count, max_count))

    max_age = params.get("max_age")
    max_age_crit = params.get("max_age_crit")
    if oldest != None:
        if max_age_crit != None and oldest > max_age_crit:
            state = STATE_CRIT
            reasons.append("oldest %s > %s" % (_fmt_age(oldest), _fmt_age(max_age_crit)))
        elif max_age != None and oldest > max_age:
            if state != STATE_CRIT:
                state = STATE_WARN
            reasons.append("oldest %s > %s" % (_fmt_age(oldest), _fmt_age(max_age)))

    detail = "%d files, total %s" % (count, _fmt_size(total))
    if count > 0:
        detail += ", oldest %s, newest %s" % (_fmt_age(oldest), _fmt_age(newest))
    if reasons:
        detail += " (%s)" % ", ".join(reasons)
    detail += " [%s]" % ", ".join(pats)

    metrics = {"count": count, "size": total}
    if oldest != None:
        metrics["oldest_age"] = oldest
        metrics["newest_age"] = newest

    return {"changed": False, "msg": state,
            "data": {"state": state, "metrics": metrics, "details": detail}}
