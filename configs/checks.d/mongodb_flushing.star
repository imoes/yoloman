# MongoDB Flushing — read-only Starlark check module (fixed, no try/except)

def _to_float(s):
    """Best-effort float conversion without exceptions. Returns None on failure."""
    if s == None or s == "":
        return None
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    # integer form
    if s.isdigit():
        v = 0.0
        for ch in s:
            v = v * 10.0 + (ord(ch) - 48)
        return -v if neg else v
    # decimal form d.dd
    if "." in s:
        int_part, frac_part = s.split(".", 1)
        int_ok = (int_part == "") or int_part.isdigit()
        frac_ok = (frac_part == "") or frac_part.isdigit()
        if int_ok and frac_ok:
            whole = 0.0
            for ch in int_part:
                whole = whole * 10.0 + (ord(ch) - 48)
            frac = 0.0
            for ch in frac_part:
                frac = frac * 10.0 + (ord(ch) - 48)
            scale = 1.0
            for _ in range(len(frac_part)):
                scale = scale * 10.0
            val = whole + (frac / scale)
            return -val if neg else val
    return None

def _to_int(s):
    """Best-effort int conversion without exceptions. Returns None on failure."""
    if s == None or s == "":
        return None
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    if s.isdigit():
        v = 0
        for ch in s:
            v = v * 10 + (ord(ch) - 48)
        return -v if neg else v
    return None

def _grade_upper(value, warn, crit):
    if value == None or warn == None or crit == None:
        return "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _fmt_seconds(seconds):
    if seconds == None:
        return ""
    total = int(seconds)
    days = total / 86400
    hours = (total % 86400) / 3600
    minutes = (total % 3600) / 60
    secs = total % 60
    parts = []
    if days > 0:
        parts.append("%dd" % days)
    parts.append("%dh" % hours)
    parts.append("%dm" % minutes)
    parts.append("%ds" % secs)
    return " ".join(parts)

def _get_section(ctx, name):
    """Return the named Checkmk agent section text, or '' if unavailable."""
    if hasattr(ctx, "section"):
        # Call without try/except — guard the availability separately.
        fn = getattr(ctx, "section")
        if fn != None:
            res = fn(name)
            if res != None:
                return res
    return ""

def main(ctx, params):
    # Discovery mode: single-service check yields one Service (item "").
    if params.get("_discover"):
        # The <<<mongodb_flushing>>> section is emitted by the Checkmk MongoDB
        # agent plugin. Without Checkmk installed on this host, the source is
        # unavailable — report no item rather than substituting local data.
        section_text = _get_section(ctx, "mongodb_flushing")
        if section_text == None or section_text == "":
            return {
                "changed": False,
                "msg": "discovered 0 items: no mongodb_flushing agent section available",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["flush_time", "avg_flush_time", "flushed"]}]},
        }

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "item not supported: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section_text = _get_section(ctx, "mongodb_flushing")
    if section_text == None or section_text == "":
        return {
            "changed": False,
            "msg": "no mongodb_flushing agent section available (Checkmk MongoDB agent plugin not installed)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse section: lines of "key value".
    info_dict = {}
    for line in section_text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            info_dict[parts[0]] = parts[1]

    required = ["last_ms", "average_ms", "flushed"]
    missing = []
    for k in required:
        if k not in info_dict:
            missing.append(k)
    if missing:
        return {
            "changed": False,
            "msg": "missing data: " + " and ".join(sorted(missing)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    last_ms = _to_float(info_dict["last_ms"])
    avg_ms = _to_float(info_dict["average_ms"])
    flushed = _to_int(info_dict["flushed"])

    if last_ms == None or avg_ms == None or flushed == None:
        return {
            "changed": False,
            "msg": "Invalid data: last_ms: %s, average_ms: %s, flushed: %s" % (
                info_dict["last_ms"], info_dict["average_ms"], info_dict["flushed"]),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    avg_flush_time = avg_ms / 1000.0
    last_flush_s = last_ms / 1000.0

    last_levels = params.get("last_time")  # (warn, crit) or absent
    avg_levels = params.get("average_time")  # (warn, crit, interval) or absent

    state = "OK"
    metrics = {
        "flush_time": last_flush_s,
        "flushed": flushed,
        "avg_flush_time": avg_flush_time,
    }

    if last_levels != None:
        warn_l = last_levels[0]
        crit_l = last_levels[1]
        g = _grade_upper(last_flush_s, warn_l, crit_l)
        if g == "CRIT":
            state = "CRIT"
        elif g == "WARN" and state != "CRIT":
            state = "WARN"

    details = "Average flush time: %s\nLast flush time: %s s\nFlushes since restart: %d" % (
        _fmt_seconds(avg_flush_time), "%f" % last_flush_s, flushed)
    summary = "Average flush time %s, last %s s, %d flushes" % (
        _fmt_seconds(avg_flush_time), "%f" % last_flush_s, flushed)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": details},
    }