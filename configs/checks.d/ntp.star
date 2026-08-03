NTP_STATE_CODES = {
    "x": "falsetick",
    ".": "excess",
    "-": "outlyer",
    "+": "candidat",
    "#": "selected",
    "*": "sys.peer",
    "o": "pps.peer",
    "%": "discarded",
}

def _ntp_fmt_time(raw):
    if raw == "-":
        return 0
    suffix = raw[-1]
    body = raw[:-1]
    if suffix == "m":
        return int(body) * 60
    if suffix == "h":
        return int(body) * 3600
    if suffix == "d":
        return int(body) * 86400
    if suffix == "y":
        return int(body) * 31536000
    return int(raw)

def _parse_ntp_line(fields):
    return {
        "statecode": fields[0],
        "name": fields[1],
        "refid": fields[2],
        "stratum": int(fields[3]),
        "when": _ntp_fmt_time(fields[5]),
        "reach": fields[7],
        "offset": float(fields[9]),
        "jitter": float(fields[10]),
    }

def _parse_ntp(stdout):
    section = {}
    for line in stdout.splitlines():
        fields = line.split()
        if len(fields) != 11:
            continue
        if fields[0] == "%" or fields[0] == "remote":
            continue
        peer = _parse_ntp_line(fields)
        section[peer["name"]] = peer
        if None not in section and peer["statecode"] in ("*", "o"):
            section[None] = peer
    return section

def _grade_offset(offset, warn, crit):
    lower_warn = -warn
    lower_crit = -crit
    if (offset >= crit) or (offset <= lower_crit):
        return "CRIT"
    if (offset >= warn) or (offset <= lower_warn):
        return "WARN"
    return "OK"

def _grade_stratum(stratum, crit_stratum, warn_stratum):
    if stratum >= crit_stratum:
        return "CRIT"
    if stratum >= warn_stratum:
        return "WARN"
    return "OK"

def _format_timespan(seconds):
    if seconds == 0:
        return "0s"
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%ds" % (seconds // 60, seconds % 60)
    if seconds < 86400:
        return "%dh%dm" % (seconds // 3600, (seconds % 3600) // 60)
    if seconds < 31536000:
        return "%dd%dh" % (seconds // 86400, (seconds % 86400) // 3600)
    return "%dy%dd" % (seconds // 31536000, (seconds % 31536000) // 86400)

def main(ctx, params):
    if params.get("_discover"):
        return _discovery(ctx, params)
    return _check(ctx, params)

def _discovery(ctx, params):
    version = ctx.run(["ntpq", "-V"], mutates=False)
    if version.rc == 127:
        return {
            "changed": False,
            "msg": "ntpq not installed",
            "data": {"discovery": []},
        }
    res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "ntpq query failed",
            "data": {"discovery": []},
        }
    section = _parse_ntp(res.stdout)
    mode = params.get("mode", "summary")
    discovery = []
    if mode in ("single", "both"):
        for peer in section.values():
            if peer["reach"] != "0" and peer["refid"] != ".LOCL.":
                discovery.append({
                    "item": peer["name"],
                    "params": {"ntp_levels": (10, 200.0, 500.0), "alert_delay": (300, 3600)},
                    "metrics": ["offset", "jitter", "stratum"],
                })
    if mode in ("summary", "both") and section:
        discovery.append({
            "item": "",
            "params": {"ntp_levels": (10, 200.0, 500.0), "alert_delay": (300, 3600)},
            "metrics": ["offset", "jitter", "stratum"],
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }

def _check(ctx, params):
    version = ctx.run(["ntpq", "-V"], mutates=False)
    if version.rc == 127:
        return {
            "changed": False,
            "msg": "ntpq not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    res = ctx.run(["ntpq", "-p", "-n"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "ntpq query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _parse_ntp(res.stdout)
    ntp_levels = params.get("ntp_levels", (10, 200.0, 500.0))
    warn_stratum = ntp_levels[0]
    warn_offset = ntp_levels[1]
    crit_offset = ntp_levels[2]
    crit_stratum = warn_stratum
    mode = params.get("mode", "summary")
    item = params.get("item", "")

    if mode in ("summary", "both") and item == "":
        peer = section.get(None)
        if peer == None:
            if section:
                msg = "Found %d peers, but none is suitable" % len(section)
            else:
                msg = "no NTP peer found"
            return {
                "changed": False,
                "msg": msg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return _grade_peer(peer, warn_stratum, crit_stratum, warn_offset, crit_offset)

    if mode in ("single", "both"):
        peer = section.get(item)
        if peer == None:
            return {
                "changed": False,
                "msg": "peer %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        return _grade_peer(peer, warn_stratum, crit_stratum, warn_offset, crit_offset)

    return {
        "changed": False,
        "msg": "unknown mode: %s" % mode,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }

def _grade_peer(peer, warn_stratum, crit_stratum, warn_offset, crit_offset):
    if peer["reach"] == "0":
        return {
            "changed": False,
            "msg": "Peer %s is unreachable" % peer["name"],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    offset = peer["offset"]
    stratum = peer["stratum"]
    jitter = peer["jitter"]
    state_offset = _grade_offset(offset, warn_offset, crit_offset)
    state_stratum = _grade_stratum(stratum, crit_stratum, warn_stratum)
    state_codes = {"CRIT": 3, "WARN": 2, "OK": 0}
    worst = max(state_codes.get(state_offset, 0), state_codes.get(state_stratum, 0))
    if state_offset == "CRIT" or state_stratum == "CRIT":
        state = "CRIT"
    elif state_offset == "WARN" or state_stratum == "WARN":
        state = "WARN"
    else:
        state = "OK"
    metrics = {"offset": offset, "jitter": jitter, "stratum": stratum}
    parts = []
    parts.append("Offset: %f ms" % offset)
    parts.append("Stratum: %d" % stratum)
    parts.append("Jitter: %f ms" % jitter)
    if peer["when"] > 0:
        parts.append("Time since last sync: %s" % _format_timespan(peer["when"]))
    state_name = NTP_STATE_CODES.get(peer["statecode"], "unknown")
    if state_name == "falsetick":
        state = "CRIT"
    msg = ", ".join(parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }