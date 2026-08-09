def main(ctx, params):
    if params.get("_discover"):
        btime = _read_boot_time(ctx)
        if btime == None:
            return {"changed": False, "msg": "uptime not available on this host",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered uptime",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["uptime"]}
                ], "host_labels": {}}}
    item = params.get("item", "")
    warn = params.get("warn", 8760)
    crit = params.get("crit", 0)
    btime = _read_boot_time(ctx)
    if btime == None:
        return {"changed": False, "msg": "no uptime information found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    secs = _now_seconds(ctx) - btime
    if secs < 0:
        return {"changed": False, "msg": "system time before boot time",
                "data": {"state": "UNKNOWN", "metrics": {"uptime": max(secs, 0)}, "details": ""}}
    state = _grade(secs, warn, crit)
    msg = _fmt_uptime(secs)
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {"uptime": secs}, "details": msg}}


def _read_boot_time(ctx):
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    if res.rc == 0 and res.stdout:
        for line in res.stdout.split("\n"):
            if line.startswith("btime "):
                parts = line.split()
                if len(parts) > 1:
                    return int(parts[1])
        return None
    res = ctx.run(["sysctl", "-n", "kern.timecreate.btime"], mutates=False)
    if res.rc == 0 and res.stdout.strip():
        s = res.stdout.strip()
        return int(float(s))
    return None


def _now_seconds(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return 0
    return int(float(res.stdout.strip()))


def _grade(secs, warn, crit):
    if crit > 0 and secs >= crit:
        return "CRIT"
    if warn > 0 and secs >= warn:
        return "WARN"
    return "OK"


def _fmt_uptime(secs):
    days = int(secs // 86400)
    hours = int((secs % 86400) // 3600)
    mins = int((secs % 3600) // 60)
    if days > 0:
        return "up %d day(s), %d:%d" % (days, hours, mins)
    return "up %d:%d" % (hours, mins)