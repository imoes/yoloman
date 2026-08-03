def _days_in_month(y, m):
    if m == 2:
        if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0:
            return 29
        return 28
    if m in (4, 6, 9, 11):
        return 30
    return 31

def _days_since_epoch(y, m, d):
    days = 0
    for yr in range(1970, y):
        days += 366 if ((yr % 4 == 0 and yr % 100 != 0) or yr % 400 == 0) else 365
    for mo in range(1, m):
        days += _days_in_month(y, mo)
    days += d - 1
    return days

def _parse_date_str(s):
    parts = s.split("/")
    if len(parts) != 3:
        return None
    if not (parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit()):
        return None
    y = int(parts[0])
    m = int(parts[1])
    d = int(parts[2])
    if m < 1 or m > 12 or d < 1 or d > 31:
        return None
    return _days_since_epoch(y, m, d) * 86400

def _find_date_pattern(s):
    for line in s.splitlines():
        parts = line.split("/")
        if len(parts) != 3:
            continue
        # Try to find YYYY/MM/DD pattern in the line
        for i in range(len(parts)):
            p = parts[i]
            if len(p) >= 4 and p[-4:].isdigit():
                year_str = p[-4:]
                year = int(year_str)
                if year < 1900 or year > 2100:
                    continue
                rest = line[line.find(p):]
                sub_parts = rest.split("/")
                if len(sub_parts) >= 3 and sub_parts[0][-4:] == year_str and sub_parts[1].isdigit() and sub_parts[2][:2].isdigit():
                    month = int(sub_parts[1])
                    day_str = sub_parts[2][:2]
                    day = int(day_str)
                    if (1 <= month) and (month <= 12) and (1 <= day) and (day <= 31):
                        return "%d/%d/%d" % (year, month, day)
    return None

def _extract_date(ctx):
    res = ctx.run(["uvscan", "--version"], mutates=False)
    if res.rc == 0:
        date_str = _find_date_pattern(res.stdout)
        if date_str != None:
            return date_str
    candidates = [
        "/opt/NAE/SigUpdt.log",
        "/opt/MFE/SigUpdt.log",
        "/opt/NAE/logs/SigUpdt.log",
        "/var/log/mcafee/SigUpdt.log",
    ]
    for p in candidates:
        if ctx.file_exists(p):
            content = ctx.file_read(p)
            date_str = _find_date_pattern(content)
            if date_str != None:
                return date_str
    return None

def _get_now_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0:
        val = res.stdout.strip()
        if val.isdigit():
            return int(val)
    res2 = ctx.run(["date", "+%Y/%m/%d"], mutates=False)
    if res2.rc == 0:
        return _parse_date_str(res2.stdout.strip())
    return None

def _render_timespan(seconds):
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        m = seconds / 60
        s = seconds % 60
        return "%dm%ds" % (m, s)
    if seconds < 86400:
        h = seconds / 3600
        m = (seconds % 3600) / 60
        return "%dh%dm" % (h, m)
    d = seconds / 86400
    h = (seconds % 86400) / 3600
    return "%dd%dh" % (d, h)

def main(ctx, params):
    if params.get("_discover"):
        mcafee_present = False
        res = ctx.run(["uvscan", "--version"], mutates=False)
        if res.rc == 0:
            mcafee_present = True
        if not mcafee_present:
            for p in ["/opt/NAE", "/opt/MFE"]:
                st = ctx.stat(p)
                if st != None and st.get("exists", False):
                    mcafee_present = True
                    break
        if mcafee_present:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"signature_age": (86400, 604800)},
                            "metrics": ["sig_age"],
                        },
                    ],
                },
            }
        return {
            "changed": False,
            "msg": "no McAfee AV found",
            "data": {"discovery": []},
        }

    item = params.get("item", "")

    mcafee_present = False
    res = ctx.run(["uvscan", "--version"], mutates=False)
    if res.rc == 0:
        mcafee_present = True
    if not mcafee_present:
        for p in ["/opt/NAE", "/opt/MFE"]:
            st = ctx.stat(p)
            if st != None and st.get("exists", False):
                mcafee_present = True
                break

    if not mcafee_present:
        return {
            "changed": False,
            "msg": "McAfee AV not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "McAfee AV client is not present on this host"},
        }

    date_str = _extract_date(ctx)
    if date_str == None:
        return {
            "changed": False,
            "msg": "could not determine signature update date",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Unable to find McAfee signature update timestamp"},
        }

    sig_epoch = _parse_date_str(date_str)
    if sig_epoch == None:
        return {
            "changed": False,
            "msg": "could not parse signature update date: " + date_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Failed to parse McAfee signature date"},
        }

    now_epoch = _get_now_epoch(ctx)
    if now_epoch == None:
        return {
            "changed": False,
            "msg": "could not determine current time",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Unable to get current system time"},
        }

    age = now_epoch - sig_epoch
    if age < 0:
        age = 0

    levels = params.get("signature_age", (86400, 604800))
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if age >= crit:
        state = "CRIT"
    elif age >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Time since last update of signatures: " + _render_timespan(age),
        "data": {
            "state": state,
            "metrics": {"sig_age": age},
            "details": "Signature date: " + date_str + " (age " + _render_timespan(age) + ")",
        },
    }