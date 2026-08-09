def main(ctx, params):
    if params.get("_discover"):
        info_text = _read_av_update_date(ctx)
        if info_text == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (259200, 345600)},
                     "metrics": ["age"]}]}}

    item = params.get("item", "")
    info_text = _read_av_update_date(ctx)
    if info_text == None:
        return {"changed": False, "msg": "no Symantec AV update information found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    last_text = _extract_date(info_text)
    if last_text == None:
        return {"changed": False,
                "msg": "could not parse last update date from: %s" % info_text,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    last_timestamp = _parse_date(last_text)
    if last_timestamp == None:
        return {"changed": False,
                "msg": "could not parse date format: %s" % last_text,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    age = _current_time() - last_timestamp
    if age < 0:
        age = 0

    levels = params.get("levels", (259200, 345600))
    lvl = levels if type(levels) == "list" or type(levels) == "tuple" else [259200, 345600]
    warn = lvl[0]
    crit = lvl[1]

    state = "OK"
    if age >= crit:
        state = "CRIT"
    elif age >= warn:
        state = "WARN"

    age_str = _format_duration(age)
    return {"changed": False,
            "msg": "Time since last update: %s" % age_str,
            "data": {"state": state, "metrics": {"age": age},
                     "details": "Last update: %s" % last_text}}


def _read_av_update_date(ctx):
    paths = [
        "/opt/Symantec/Definitions/DefUtil/defdiag.txt",
        "/etc/symantec/defs/definition_date",
        "/opt/symantec/sep/definition_date",
    ]
    for p in paths:
        if ctx.file_exists(p):
            content = ctx.file_read(p)
            t = content.strip()
            if t:
                return t.splitlines()[0]
    res = ctx.run(["/usr/sbin/sav", "info", "-d", "--def-date"], mutates=False)
    if res.rc == 0 and res.stdout.strip():
        return res.stdout.strip().splitlines()[0]
    res2 = ctx.run(["/opt/Symantec/sep/bin/sav", "info", "--def-date"], mutates=False)
    if res2.rc == 0 and res2.stdout.strip():
        return res2.stdout.strip().splitlines()[0]
    return None


def _extract_date(text):
    t = text.strip()
    for sep in ["/", "."]:
        parts = t.split(sep)
        if len(parts) >= 3:
            first = parts[0]
            second = parts[1]
            third = parts[2]
            if _is_digit(first) and _is_digit(second) and _is_digit(third):
                date_len = len(first) + 1 + len(second) + 1 + len(third)
                return t[:date_len]
    return None


def _parse_date(text):
    text = text.strip()
    if "/" in text:
        parts = text.split("/")
        if len(parts) != 3:
            return None
        m = int(parts[0])
        d = int(parts[1])
        y = int(parts[2])
        if len(parts[2]) == 2:
            if y < 50:
                y = y + 2000
            else:
                y = y + 1900
        return _mktime(y, m, d, 0, 0, 0)
    elif "." in text:
        parts = text.split(".")
        if len(parts) != 3:
            return None
        d = int(parts[0])
        m = int(parts[1])
        y = int(parts[2])
        return _mktime(y, m, d, 0, 0, 0)
    return None


def _mktime(year, month, day, hour, minute, second):
    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    total_days = 0
    y = 1970
    while y < year:
        if _is_leap(y):
            total_days = total_days + 366
        else:
            total_days = total_days + 365
        y = y + 1
    mo = 1
    while mo < month:
        dm = days_in_month[mo - 1]
        if mo == 2 and _is_leap(year):
            dm = 29
        total_days = total_days + dm
        mo = mo + 1
    total_days = total_days + (day - 1)
    return total_days * 86400 + hour * 3600 + minute * 60 + second


def _is_leap(year):
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)


def _is_digit(s):
    if len(s) == 0:
        return False
    for c in s:
        if c < "0" or c > "9":
            return False
    return True


def _current_time(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0:
        ts = res.stdout.strip()
        if _is_digit(ts):
            return int(ts)
    return 0


def _format_duration(seconds):
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    if days > 0:
        return "%dd %dh" % (days, hours)
    elif hours > 0:
        return "%dh %dm" % (hours, minutes)
    else:
        return "%dm" % minutes