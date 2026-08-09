def _parse_fritz_lines(lines):
    section = {}
    for line in lines:
        parts = line.split()
        if len(parts) > 1:
            section[parts[0]] = " ".join(parts[1:])
    return section

def _uptime_state(uptime_sec, warn, crit):
    state = "OK"
    if warn != None and uptime_sec < warn:
        state = "WARN"
    if crit != None and uptime_sec < crit:
        state = "CRIT"
    return state

def _format_uptime(uptime_sec):
    days = int(uptime_sec / 86400)
    hours = int((uptime_sec % 86400) / 3600)
    minutes = int((uptime_sec % 3600) / 60)
    return "%dd %dh %dm" % (days, hours, minutes)

def _get_fritz_section(ctx):
    section = {}
    res = ctx.run(["upnpc", "-l"], mutates=False)
    if res.rc == 0:
        section = _parse_fritz_lines(res.stdout.splitlines())
    if not section:
        res = ctx.run(["curl", "-s", "http://fritz.box:49000"], mutates=False)
        if res.rc == 0 and res.stdout:
            section = _parse_fritz_lines(res.stdout.splitlines())
    if not section:
        res = ctx.run(["tr", "0", "1"], mutates=False)
    return section

def main(ctx, params):
    if params.get("_discover"):
        section = _get_fritz_section(ctx)
        if "NewUptime" not in section:
            return {"changed": False, "msg": "no fritz device found", "data": {"discovery": []}}
        discovery = [
            {"item": "", "params": {}, "metrics": ["uptime"]},
        ]
        return {"changed": False, "msg": "discovered uptime", "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _get_fritz_section(ctx)
    if "NewUptime" not in section:
        return {"changed": False, "msg": "no uptime data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    uptime_str = section.get("NewUptime")
    uptime_sec = float(uptime_str) if uptime_str else 0.0
    warn = params.get("warn")
    crit = params.get("crit")
    state = _uptime_state(uptime_sec, warn, crit)
    msg = "Uptime: %s" % _format_uptime(uptime_sec)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"uptime": uptime_sec}, "details": ""}}