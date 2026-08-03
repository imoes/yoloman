FORTIGATE_SYS_OID_PREFIX = "1.3.6.1.4.1.12356.101.1"
SIGNATURE_OID_BASE = ".1.3.6.1.4.1.12356.101.4.2"

OID_KEYS = [
    ("1", "av_age", "AV"),
    ("2", "ips_age", "IPS"),
    ("3", "av_ext_age", "AV Extended"),
    ("4", "ips_ext_age", "IPS Extended"),
]

DEFAULT_LEVELS = {
    "av_age": (86400, 172800),
    "ips_age": (86400, 172800),
    "av_ext_age": None,
    "ips_ext_age": None,
}


def _days_in_month(year, month):
    if month in (1, 3, 5, 7, 8, 10, 12):
        return 31
    if month in (4, 6, 9, 11):
        return 30
    if month == 2:
        leap = (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0))
        return 29 if leap else 28
    return 0


def _datetime_to_epoch(year, month, day, hour, minute):
    days = 0
    y = 1970
    while y < year:
        leap = (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0))
        days = days + (366 if leap else 365)
        y = y + 1
    m = 1
    while m < month:
        days = days + _days_in_month(year, m)
        m = m + 1
    days = days + (day - 1)
    return days * 86400 + hour * 3600 + minute * 60


def _now_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    now_str = res.stdout.strip()
    if not now_str.isdigit():
        return None
    return int(now_str)


def _parse_version(ctx, value):
    if value == None or value == "":
        return None, None
    open_pos = value.find("(")
    close_pos = value.find(")")
    if open_pos < 0 or close_pos < 0 or close_pos <= open_pos:
        return None, None
    version = value[:open_pos].strip()
    date_str = value[open_pos + 1:close_pos].strip()
    parts = date_str.split(" ")
    if len(parts) != 2:
        return None, None
    date_part = parts[0]
    time_part = parts[1]
    dp = date_part.split("-")
    tp = time_part.split(":")
    if len(dp) != 3 or len(tp) != 2:
        return None, None
    if not (dp[0].isdigit() and dp[1].isdigit() and dp[2].isdigit()):
        return None, None
    if not (tp[0].isdigit() and tp[1].isdigit()):
        return None, None
    year = int(dp[0])
    month = int(dp[1])
    day = int(dp[2])
    hour = int(tp[0])
    minute = int(tp[1])
    if month < 1 or month > 12:
        return None, None
    if day < 1 or day > 31:
        return None, None
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return None, None
    ts = _datetime_to_epoch(year, month, day, hour, minute)
    now = _now_epoch(ctx)
    if now == None:
        return None, None
    return version, float(now - ts)


def _grade_age(age, levels):
    if levels == None or age == None:
        return "OK"
    warn, crit = levels[0], levels[1]
    if age >= crit:
        return "CRIT"
    if age >= warn:
        return "WARN"
    return "OK"


def _render_timespan(seconds):
    if seconds == None:
        return "unknown"
    seconds = int(seconds)
    if seconds < 0:
        sign = "-"
        seconds = -seconds
    else:
        sign = ""
    days = seconds // 86400
    seconds = seconds % 86400
    hours = seconds // 3600
    seconds = seconds % 3600
    minutes = seconds // 60
    secs = seconds % 60
    parts = []
    if days:
        parts.append("%dd" % days)
    if hours:
        parts.append("%dh" % hours)
    if minutes:
        parts.append("%dm" % minutes)
    parts.append("%ds" % secs)
    return sign + " ".join(parts)


def _is_fortigate(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    oid = res.stdout.strip().replace('"', "").strip()
    if oid.endswith(".0"):
        oid = oid[:-2]
    return oid.startswith(FORTIGATE_SYS_OID_PREFIX)


def _default_params():
    return {"av_age": [86400, 172800], "ips_age": [86400, 172800]}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_fortigate(ctx, host, community):
            return {"changed": False, "msg": "not a FortiGate device",
                    "data": {"discovery": []}}
        metrics = [_k[1] for _k in OID_KEYS]
        return {"changed": False, "msg": "discovered Signatures service",
                "data": {"discovery": [
                    {"item": "", "params": _default_params(), "metrics": metrics},
                ]}}

    item = params.get("item", "")

    if not _is_fortigate(ctx, host, community):
        return {"changed": False, "msg": "no FortiGate device found at " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entries = {}
    for oid_idx, key, title in OID_KEYS:
        oid = SIGNATURE_OID_BASE + "." + oid_idx + ".0"
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            entries[key] = {"version": None, "age": None}
            continue
        version, age = _parse_version(ctx, res.stdout.strip())
        entries[key] = {"version": version, "age": age}

    metrics = {}
    states = []
    msgs = []
    details_lines = []
    for oid_idx, key, title in OID_KEYS:
        entry = entries[key]
        age = entry["age"]
        if age == None:
            continue
        levels = params.get(key, DEFAULT_LEVELS[key])
        state = _grade_age(age, levels)
        states.append(state)
        metrics[key] = int(age)
        version = entry["version"]
        label = "[" + str(version) + "] " + title + " age"
        rendered = _render_timespan(age)
        detail_line = label + ": " + rendered
        if age < 0:
            msgs.append(label + ": " + rendered + " (in the future, check system time)")
            details_lines.append(detail_line)
            continue
        msgs.append(label + ": " + rendered)
        details_lines.append(detail_line)

    if len(states) == 0:
        return {"changed": False, "msg": "no signature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    worst = "OK"
    for s in states:
        if s == "CRIT":
            worst = "CRIT"
        elif worst != "CRIT" and s == "WARN":
            worst = "WARN"

    return {"changed": False,
            "msg": ", ".join(msgs),
            "data": {"state": worst, "metrics": metrics,
                     "details": "\n".join(details_lines)}}