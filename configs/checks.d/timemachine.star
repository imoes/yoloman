def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["tmutil", "latestbackup"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "tmutil not installed", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "tmutil failed", "data": {"discovery": []}}
        out = res.stdout.strip()
        if not out or not out.startswith("/Volumes/"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items", "data": {"discovery": [{"item": "", "params": {"age": (86400, 172800)}, "metrics": ["backup_age"]}]}}

    res = ctx.run(["tmutil", "latestbackup"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "tmutil not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "tmutil failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = res.stdout.strip()
    if not section:
        return {"changed": False, "msg": "no backup path found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not section.startswith("/Volumes/"):
        return {"changed": False, "msg": "Backup seems to have failed, message was: " + section, "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    raw_backup_time = section.rsplit("/", maxsplit=1)[-1].removesuffix(".backup")
    parts = raw_backup_time.split("-")
    if len(parts) != 4:
        return {"changed": False, "msg": "cannot parse backup timestamp: " + raw_backup_time, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    time_part = parts[3]
    if len(time_part) != 6:
        return {"changed": False, "msg": "cannot parse backup timestamp: " + raw_backup_time, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    year = int(parts[0]) if parts[0].isdigit() else 0
    month = int(parts[1]) if parts[1].isdigit() else 0
    day = int(parts[2]) if parts[2].isdigit() else 0
    hour = int(time_part[0:2]) if time_part[0:2].isdigit() else 0
    minute = int(time_part[2:4]) if time_part[2:4].isdigit() else 0
    second = int(time_part[4:6]) if time_part[4:6].isdigit() else 0
    if year == 0 or month == 0 or day == 0:
        return {"changed": False, "msg": "cannot parse backup timestamp: " + raw_backup_time, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    backup_epoch = _to_epoch(year, month, day, hour, minute, second)
    if backup_epoch == -1:
        return {"changed": False, "msg": "invalid backup timestamp: " + raw_backup_time, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now_epoch = _now_epoch(ctx)
    backup_age = now_epoch - backup_epoch
    if backup_age < 0:
        return {"changed": False, "msg": "Timestamp of last backup is in the future: " + _fmt_time(year, month, day, hour, minute, second), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    age_levels = params.get("age", (86400, 172800))
    warn = age_levels[0]
    crit = age_levels[1]
    state = _grade(backup_age, warn, crit)
    label_time = _fmt_time(year, month, day, hour, minute, second)
    return {"changed": False, "msg": "Last backup was at " + label_time + " (" + _human_age(backup_age) + " ago)", "data": {"state": state, "metrics": {"backup_age": backup_age}, "details": "age_levels=" + str(warn) + ":" + str(crit)}}


def _grade(backup_age, warn, crit):
    if backup_age >= crit:
        return "CRIT"
    if backup_age >= warn:
        return "WARN"
    return "OK"


def _human_age(secs):
    days = int(secs // 86400)
    hours = int((secs % 86400) // 3600)
    minutes = int((secs % 3600) // 60)
    seconds = int(secs % 60)
    if days > 0:
        return "%dd %dh" % (days, hours)
    if hours > 0:
        return "%dh %dm" % (hours, minutes)
    if minutes > 0:
        return "%dm %ds" % (minutes, seconds)
    return "%ds" % seconds


def _fmt_time(year, month, day, hour, minute, second):
    return "%d-%d-%d %d:%d:%d" % (year, month, day, hour, minute, second)


def _to_epoch(year, month, day, hour, minute, second):
    dom = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0):
        feb = 29
    else:
        feb = 28
    dom[1] = feb
    if month < 1 or month > 12:
        return -1
    if day < 1 or day > dom[month - 1]:
        return -1
    if hour < 0 or hour > 23:
        return -1
    if minute < 0 or minute > 59:
        return -1
    if second < 0 or second > 59:
        return -1
    days = 0
    y = 1970
    while y < year:
        if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
            days += 366
        else:
            days += 365
        y += 1
    m = 1
    while m < month:
        days += dom[m - 1]
        m += 1
    days += day - 1
    return days * 86400 + hour * 3600 + minute * 60 + second


def _now_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return 0
    s = res.stdout.strip()
    if s.isdigit():
        return int(s)
    return 0