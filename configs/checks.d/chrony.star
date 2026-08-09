# Checkmk check: chrony (NTP Time) — read-only Starlark translation

def main(ctx, params):
    if params.get("_discover"):
        version = ctx.run(["chronyc", "-v"], mutates=False)
        if version.rc == 127:
            return {"changed": False, "msg": "chronyc not installed",
                    "data": {"discovery": []}}
        tracking = ctx.run(["chronyc", "tracking"], mutates=False)
        if tracking.rc != 0:
            txt = tracking.stdout.strip()
            if tracking.rc == 127 or len(txt) == 0:
                return {"changed": False, "msg": "chrony not running",
                        "data": {"discovery": []}}
            return {"changed": False, "msg": "chrony daemon not reachable",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered NTP Time service",
                "data": {"discovery": [
                    {"item": "", "params": {"ntp_levels": (10, 200.0, 500.0),
                                            "alert_delay": (1025, 3600)},
                     "metrics": ["offset", "stratum", "last_sync"]}
                ]}}

    tracking = ctx.run(["chronyc", "tracking"], mutates=False)
    if tracking.rc != 0 or len(tracking.stdout.strip()) == 0:
        return {"changed": False,
                "msg": "chrony daemon not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    info = {}
    for line in tracking.stdout.splitlines():
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip()
        value = line[idx + 1:].strip()
        info[key] = value

    ref_id = info.get("Reference ID", "")
    address = None
    if ref_id:
        parts = ref_id.split(" ")
        if len(parts) > 1:
            address = parts[1].replace("(", "").replace(")", "")
        else:
            address = ref_id

    stratum = None
    sraw = info.get("Stratum")
    if sraw != None and sraw.isdigit():
        stratum = int(sraw)

    sys_time = None
    st = info.get("System time")
    if st != None:
        first = st.split(" ")[0]
        fnum = _to_float(first, ctx)
        if fnum != None:
            sys_time = fnum * 1000.0

    last_sync = None
    rt = info.get("Ref time (UTC)")
    if rt != None:
        last_sync = _epoch_from_chrono(rt, ctx)

    crit_stratum = 10
    ntp_warn = 200.0
    ntp_crit = 500.0
    lvls = params.get("ntp_levels", (10, 200.0, 500.0))
    if type(lvls) == "list" or type(lvls) == "tuple":
        ntp_warn = lvls[1]
        ntp_crit = lvls[2]

    alert_delay = params.get("alert_delay", (1025, 3600))
    sd_warn = 1025
    sd_crit = 3600
    if type(alert_delay) == "list" or type(alert_delay) == "tuple":
        sd_warn = alert_delay[0]
        sd_crit = alert_delay[1]

    states = []
    msgs = []

    if address:
        states.append("OK")
        msgs.append("NTP servers: %s" % address)
    else:
        states.append("WARN")
        msgs.append("NTP servers: unreachable")
    if ref_id:
        msgs.append("Reference ID: %s" % ref_id)

    if sys_time != None:
        metrics["offset"] = sys_time
        st2 = _upper_state(sys_time, ntp_warn, ntp_crit)
        states.append(st2)
        msgs.append("Offset: %f ms" % sys_time)

    if address and stratum != None:
        metrics["stratum"] = stratum
        ss = _upper_state(stratum, crit_stratum, crit_stratum)
        states.append(ss)
        msgs.append("Stratum: %d" % stratum)

    if address and last_sync != None:
        metrics["last_sync"] = last_sync
        if last_sync >= 0:
            sst = _upper_state(last_sync, sd_warn, sd_crit)
            states.append(sst)
            msgs.append("Time since last sync: %s" % _render_timespan(last_sync))
        else:
            states.append("OK")
            msgs.append("Last synchronization appears to be %s in the future (check your system time)" %
                        _render_timespan(-last_sync))

    final = "OK"
    if "CRIT" in states:
        final = "CRIT"
    elif "WARN" in states:
        final = "WARN"

    return {"changed": False,
            "msg": "\n".join(msgs),
            "data": {"state": final,
                     "metrics": metrics,
                     "details": "\n".join(msgs)}}


def _to_float(s, ctx):
    neg = s.startswith("-") or s.startswith("+")
    candidate = s[1:] if neg else s
    if "." in candidate:
        ip, _, fp = candidate.partition(".")
        if not ip.isdigit() or not fp.isdigit():
            return None
        return float(s)
    if candidate.isdigit():
        return float(s)
    return None

def _upper_state(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _render_timespan(seconds):
    if seconds < 0:
        return "%ds" % int(seconds)
    days = int(seconds / 86400)
    hours = int((seconds % 86400) / 3600)
    mins = int((seconds % 3600) / 60)
    secs = int(seconds % 60)
    if days > 0:
        return "%dd %d:%d:%d" % (days, hours, mins, secs)
    if hours > 0:
        return "%d:%d:%d" % (hours, mins, secs)
    if mins > 0:
        return "%dm %ds" % (mins, secs)
    return "%ds" % secs

def _epoch_from_chrono(value, ctx):
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    parts = value.split(" ")
    if len(parts) < 5:
        return None
    month_name = parts[1]
    if month_name not in months:
        return None
    month = months.index(month_name) + 1
    day_s = parts[2]
    if not day_s.isdigit():
        return None
    day = int(day_s)
    year_s = parts[4]
    if not year_s.isdigit():
        return None
    year = int(year_s)
    time_s = parts[3]
    tparts = time_s.split(":")
    if len(tparts) != 3:
        return None
    if not (tparts[0].isdigit() and tparts[1].isdigit() and tparts[2].isdigit()):
        return None
    hour = int(tparts[0])
    minute = int(tparts[1])
    sec = int(tparts[2])
    days = _days_from_civil(year, month, day)
    now_e = _now_epoch(ctx)
    if now_e == None:
        return None
    return float(days * 86400 + hour * 3600 + minute * 60 + sec) - now_e

def _days_from_civil(y, m, d):
    y2 = y - (1 if m <= 2 else 0)
    era = y2 // 400 if y2 >= 0 else (y2 - 399) // 400
    yoe = y2 - era * 400
    doy = (153 * (m - 3 if m > 2 else m + 9) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468

def _now_epoch(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    s = res.stdout.strip()
    if s.isdigit():
        return float(s)
    return None