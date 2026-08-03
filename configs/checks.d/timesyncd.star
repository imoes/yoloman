def _parse_float(s):
    if not s:
        return None
    cleaned = s.strip()
    if len(cleaned) == 0:
        return None
    first = cleaned
    if first[0] == "-":
        rest = first[1:]
    elif first[0] == "+":
        rest = first[1:]
    else:
        rest = first
    has_dot = rest.find(".") >= 0
    ok = len(rest) > 0
    if ok:
        dot_seen = False
        for ch in rest:
            if ch.isdigit():
                continue
            if ch == "." and not dot_seen:
                dot_seen = True
                continue
            ok = False
            break
    if not ok:
        return None
    return float(cleaned)


def _parse_int(s):
    if not s:
        return None
    cleaned = s.strip()
    if len(cleaned) == 0:
        return None
    first = cleaned
    if first[0] == "-":
        rest = first[1:]
    elif first[0] == "+":
        rest = first[1:]
    else:
        rest = first
    ok = len(rest) > 0
    for ch in rest:
        if not ch.isdigit():
            ok = False
            break
    if not ok:
        return None
    return int(cleaned)


def _units_to_seconds(unit):
    return _UNITS_TO_SECONDS.get(unit, None)


def _split_into_components(time_string):
    out = []
    if not time_string:
        return out
    if time_string[-1].isdigit():
        has_letter = False
        for ch in time_string:
            if not ch.isdigit() and ch != ".":
                has_letter = True
                break
        if not has_letter:
            ts = time_string + "s"
        else:
            ts = time_string
    else:
        if _UNITS_TO_SECONDS.has_key(time_string[-1:]):
            ts = time_string
        elif not _UNITS_TO_SECONDS.has_key(time_string[-1]):
            ts = time_string + "s"
        else:
            ts = time_string
    i = 0
    n = len(ts)
    while i < n:
        j = i
        while j < n and (ts[j].isdigit() or ts[j] == "."):
            j = j + 1
        if j == i:
            i = i + 1
            continue
        num = float(ts[i:j])
        k = j
        while k < n and not (ts[k].isdigit() or ts[k] == "."):
            k = k + 1
        unit = ts[j:k]
        secs = _units_to_seconds(unit)
        if secs == None:
            i = k
            continue
        out.append(num * secs)
        i = k
    return out


def _strip_sign(time_string):
    if len(time_string) > 0 and time_string[0] == "-":
        return time_string[1:], -1
    if len(time_string) > 0 and time_string[0] == "+":
        return time_string[1:], 1
    return time_string, 1


def _get_seconds(components):
    time_string = "".join(components)
    ts, sign = _strip_sign(time_string)
    total = 0.0
    for v in _split_into_components(ts):
        total = total + v
    return sign * total


def _grade_upper(value, levels):
    if levels == None or len(levels) < 2:
        return "OK"
    w = levels[0]
    c = levels[1]
    if value >= c:
        return "CRIT"
    if value >= w:
        return "WARN"
    return "OK"


def _tolerance_grade(elapsed, levels_upper):
    return _grade_upper(elapsed, levels_upper)


def _timesyncd_present(ctx):
    res = ctx.run(["timedatectl", "show-timesync", "-a"], mutates=False)
    if res.rc == 127:
        return False, None
    if res.rc != 0:
        b = ctx.run(
            ["busctl", "get-property", "org.freedesktop.timesyncd",
             "/org/freedesktop/timesyncd", "org.freedesktop.timesyncd",
             "Server"],
            mutates=False,
        )
        if b.rc == 127:
            return False, None
        if b.rc != 0:
            return False, None
    return True, res


def _parse_ntp_message_timestamp(ntp_message_raw, timezone_raw):
    body = ntp_message_raw
    p = body.find("NTPMessage={")
    if p >= 0:
        body = body[p + len("NTPMessage={"):]
        pe = body.find(" }")
        if pe >= 0:
            body = body[:pe]
        else:
            pe2 = body.rfind("}")
            if pe2 >= 0:
                body = body[:pe2]
    else:
        eq = body.find("=")
        if eq >= 0:
            body = body[eq + 1:]
    parts = body.split(",")
    receive_raw = None
    for pp in parts:
        pp = pp.strip()
        if pp.startswith("ReceiveTimestamp="):
            receive_raw = pp[len("ReceiveTimestamp="):]
            break
    if receive_raw == None:
        return None
    return _parse_float(receive_raw)


def _parse_timesyncd_output(stdout):
    section = {}
    ntp_message = None
    timezone_raw = None
    for line in stdout.splitlines():
        if not line:
            continue
        stripped = line.strip()
        if stripped.startswith("[[[") and stripped.endswith("]]]") and len(stripped) > 6:
            val = _parse_float(stripped[3:-3])
            if val != None:
                section["synctime"] = val
            continue
        eq = stripped.find("=")
        if eq == -1:
            if stripped.startswith("NTPMessage="):
                ntp_message = stripped
            if stripped.startswith("Timezone="):
                timezone_raw = stripped
            continue
        key = stripped[:eq].lower()
        val = stripped[eq + 1:]
        if key == "server":
            cleaned = val.replace("(", "").replace(")", "").strip()
            section["server"] = cleaned
        elif key == "stratum":
            iv = _parse_int(val)
            if iv != None:
                section["stratum"] = iv
        elif key == "offset":
            secs = _get_seconds([val])
            if secs != None:
                section["offset"] = secs
        elif key == "jitter":
            secs = _get_seconds([val])
            if secs != None:
                section["jitter"] = secs
        elif key == "ntpmessage":
            ntp_message = stripped
        elif key == "timezone":
            timezone_raw = stripped
    if ntp_message != None and timezone_raw != None:
        rt = _parse_ntp_message_timestamp(ntp_message, timezone_raw)
        if rt != None:
            return section, {"receivetimestamp": rt}
    return section, None


def main(ctx, params):
    if params.get("_discover"):
        present, _ = _timesyncd_present(ctx)
        if not present:
            return {
                "changed": False,
                "msg": "timesyncd not installed",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [
                            "time_offset",
                            "last_sync_time",
                            "last_sync_receive_time",
                            "jitter",
                            "stratum",
                        ],
                    }
                ],
            },
        }

    item = params.get("item", "")

    present, res = _timesyncd_present(ctx)
    if not present:
        return {
            "changed": False,
            "msg": "systemd-timesyncd is not installed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "timedatectl / busctl not available; timesyncd absent",
            },
        }

    if res == None or res.stdout == "":
        return {
            "changed": False,
            "msg": "no timesyncd data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section, ntp = _parse_timesyncd_output(res.stdout)

    ql = params.get("quality_levels", _DEFAULT_QUALITY_LEVELS)
    q_warn = ql[0] / 1000.0
    q_crit = ql[1] / 1000.0
    q_levels = (q_warn, q_crit)

    metrics = {}
    states = []
    details = []

    offset = section.get("offset", None)
    if offset != None:
        off = abs(offset)
        metrics["time_offset"] = off
        st = _grade_upper(off, q_levels)
        states.append(st)
        details.append("Offset: %gs" % off)

    synctime = section.get("synctime", None)
    alert_delay = params.get("alert_delay", _DEFAULT_ALERT_DELAY)
    last_sync_key = "last_sync_time"
    if synctime != None:
        if synctime > 86400:
            metrics[last_sync_key] = synctime
            details.append("Time since last sync: epoch %g" % synctime)
        else:
            metrics[last_sync_key] = synctime
            st = _grade_upper(synctime, alert_delay)
            states.append(st)
            details.append("Time since last sync: %gs" % synctime)
    else:
        metrics[last_sync_key] = 0
        details.append("Time since last sync: n/a")

    if ntp != None:
        rt = ntp.get("receivetimestamp", None)
        if rt != None:
            metrics["last_sync_receive_time"] = rt
            st = _tolerance_grade(rt, params.get("last_ntp_message", _DEFAULT_LAST_NTP_MESSAGE))
            states.append(st)
            details.append("Time since last NTP message: %gs" % rt)

    server = section.get("server", None)
    if server == None or server == "null":
        states.append("CRIT")
        details.append("Found no time server")
        return {
            "changed": False,
            "msg": "Found no time server",
            "data": {
                "state": "CRIT",
                "metrics": metrics,
                "details": "\n".join(details),
            },
        }

    stratum = section.get("stratum", None)
    if stratum != None:
        metrics["stratum"] = stratum
        stratum_level = params.get("stratum_level", _DEFAULT_STRATUM_LEVEL)
        s_levels = (stratum_level - 1, stratum_level)
        st = _grade_upper(stratum, s_levels)
        if st != "OK":
            states.append(st)
        details.append("Stratum: %d" % stratum)

    jitter = section.get("jitter", None)
    if jitter != None:
        metrics["jitter"] = jitter
        st = _grade_upper(jitter, q_levels)
        if st != "OK":
            states.append(st)
        details.append("Jitter: %gs" % jitter)

    if server != None and offset == None and stratum == None and jitter == None:
        states.append("CRIT")
        details.append("Found no time server")

    if len(states) == 0:
        final = "OK"
    else:
        if "CRIT" in states:
            final = "CRIT"
        elif "WARN" in states:
            final = "WARN"
        else:
            final = "OK"

    summary = "Synchronized on %s" % server
    if final != "OK":
        summary = details[0] if len(details) > 0 else summary

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final,
            "metrics": metrics,
            "details": "\n".join(details),
        },
    }


_UNITS_TO_SECONDS = {
    "y": 31557600.0,
    "year": 31557600.0,
    "years": 31557600.0,
    "M": 2630016.0,
    "month": 2630016.0,
    "months": 2630016.0,
    "w": 604800.0,
    "week": 604800.0,
    "weeks": 604800.0,
    "d": 86400.0,
    "day": 86400.0,
    "days": 86400.0,
    "h": 3600.0,
    "hour": 3600.0,
    "hours": 3600.0,
    "m": 60.0,
    "min": 60.0,
    "minute": 60.0,
    "minutes": 60.0,
    "s": 1.0,
    "sec": 1.0,
    "second": 1.0,
    "seconds": 1.0,
    "msec": 0.001,
    "ms": 0.001,
    "us": 0.000001,
    "usec": 0.000001,
    "µs": 0.000001,
}

_DEFAULT_STRATUM_LEVEL = 10
_DEFAULT_QUALITY_LEVELS = (200.0, 500.0)
_DEFAULT_ALERT_DELAY = (300, 3600)
_DEFAULT_LAST_NTP_MESSAGE = (3600, 7200)