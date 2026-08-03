# ibm_mq_channels — read-only Starlark check module for the yolo-man agent.
# Reproduces checkmk.ibm_mq_channels: discovers IBM MQ channels and reports
# their status. Data source is the on-host IBM MQ queue manager via runmqsc.
#
# Default status mapping: lowercase label -> check state int
_STATUS_MAP = {
    "inactive": 0,
    "initializing": 0,
    "binding": 0,
    "starting": 0,
    "running": 0,
    "retrying": 1,
    "stopping": 0,
    "stopped": 2,
}

_STATE_FROM_INT = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

# Keys we extract from channel status output
_KEY_NAMES = ["CHANNEL", "CHLTYPE", "CONNAME", "CURRENT", "RQMNAME", "STATUS",
              "SUBSTATE", "XMITQ"]


def _has_mq(ctx):
    """Probe for IBM MQ presence: runmqsc availability is the real thing."""
    res = ctx.run(["runmqsc", "-v"], mutates=False)
    # rc 2 = usage/help (installed); rc 127 = not installed
    return res.rc != 127 and res.rc != 126


def _safe_qmgr(name):
    """Sanitize queue manager name for runmqsc command (no shell metachars)."""
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
    out = []
    for ch in str(name):
        if ch in allowed:
            out.append(ch)
        else:
            out.append("_")
    return "".join(out)


def _find_field(line, key):
    """Find KEY(...) value; return inner content or None."""
    start = line.find(key + "(")
    if start < 0:
        start = line.find(key + " ")
        if start < 0:
            return None
        return ""
    inner_start = start + len(key) + 1
    depth = 1
    i = inner_start
    out = ""
    while i < len(line):
        c = line[i]
        if c == "(":
            depth = depth + 1
            out = out + c
        elif c == ")":
            depth = depth - 1
            if depth == 0:
                i = i + 1
                break
            out = out + c
        else:
            out = out + c
        i = i + 1
    return out


def _extract_fields(line):
    """Extract all KEY(value) pairs from a line into a dict."""
    out = {}
    i = 0
    n = len(line)
    while i < n:
        while i < n and (line[i] == " " or line[i] == "\t"):
            i = i + 1
        if i >= n:
            break
        kstart = i
        while i < n and (line[i].isalnum() or line[i] == "_"):
            i = i + 1
        key = line[kstart:i]
        if key == "":
            i = i + 1
            continue
        while i < n and (line[i] == " " or line[i] == "\t"):
            i = i + 1
        if i < n and line[i] == "(":
            i = i + 1
            depth = 1
            vbuf = ""
            while i < n and depth > 0:
                c = line[i]
                if c == "(":
                    depth = depth + 1
                    vbuf = vbuf + c
                elif c == ")":
                    depth = depth - 1
                    if depth == 0:
                        break
                    vbuf = vbuf + c
                else:
                    vbuf = vbuf + c
                i = i + 1
            out[key] = vbuf.strip()
            if i < n and line[i] == ")":
                i = i + 1
        else:
            out[key] = ""
    return out


def _parse_runmqsc(stdout):
    """Parse runmqsc 'display chstatus(*)' output into {item: {FIELD: value}}.
    Returns dict keyed by 'QMGR:CHANNEL'.
    """
    qmgr = None
    channels = {}
    cur_chan = None
    for raw in stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("AMQ") and "details" in line:
            cur_chan = None
            continue
        if line.startswith("AMQ") and "One valid" in line:
            continue
        if line.startswith("AMQ") and "No commands" in line:
            continue
        if line.startswith("Starting MQSC"):
            if "queue manager" in line:
                rest = line.split("queue manager", 1)[1].strip()
                qmgr = rest.split(".")[0].strip()
            continue
        if line.startswith("QMNAME"):
            m = _find_field(line, "QMNAME")
            if m != None:
                qmgr = m
            continue
        matched_key = None
        for k in _KEY_NAMES:
            if line.startswith(k + "(") or line.startswith(k + " "):
                matched_key = k
                break
        if matched_key == None:
            continue
        parts = _extract_fields(line)
        if matched_key == "CHANNEL":
            ch = parts.get("CHANNEL")
            if ch != None and qmgr != None:
                cur_chan = qmgr + ":" + ch
                channels[cur_chan] = {"STATUS": "INACTIVE"}
        if cur_chan != None:
            for k, v in parts.items():
                channels[cur_chan][k] = v
    return channels


def _list_qmgrs(ctx):
    """Get list of queue manager names via 'dspmq' (standard IBM MQ command)."""
    res = ctx.run(["dspmq"], mutates=False)
    if res.rc != 0:
        return []
    out = []
    for raw in res.stdout.splitlines():
        line = raw.strip()
        if line.startswith("QMGR") and "(" in line:
            name = line.replace("QMGR", "", 1).strip().split("(")[0].strip()
            if name:
                out.append(name)
    return out


def main(ctx, params):
    if params.get("_discover"):
        if not _has_mq(ctx):
            return {"changed": False, "msg": "IBM MQ not installed",
                    "data": {"discovery": []}}
        qmgrs = _list_qmgrs(ctx)
        if len(qmgrs) == 0:
            return {"changed": False, "msg": "no queue managers found",
                    "data": {"discovery": []}}
        discovery = []
        for qmgr in qmgrs:
            safe = _safe_qmgr(qmgr)
            res = ctx.run(
                ["bash", "-c",
                 "printf '%s\\n' 'display chstatus(*)' | runmqsc " + safe],
                mutates=False, ok_codes=[0, 1])
            if res.rc == 127:
                continue
            parsed = _parse_runmqsc(res.stdout)
            for item in parsed:
                if ":" not in item:
                    continue
                if item not in discovery:
                    discovery.append({
                        "item": item,
                        "params": {},
                        "metrics": [],
                    })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    if not _has_mq(ctx):
        return {"changed": False,
                "msg": "IBM MQ not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    if ":" not in item:
        return {"changed": False,
                "msg": "no queue manager in item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    qmgr_name = item.split(":", 1)[0]
    safe = _safe_qmgr(qmgr_name)
    res = ctx.run(
        ["bash", "-c",
         "printf '%s\\n' 'display chstatus(*)' | runmqsc " + safe],
        mutates=False, ok_codes=[0, 1])
    if res.rc == 127:
        return {"changed": False,
                "msg": "runmqsc not available for " + str(qmgr_name),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_runmqsc(res.stdout)
    if item not in parsed:
        qmgr_key = qmgr_name
        if qmgr_key in parsed:
            qmgr_status = parsed[qmgr_key].get("STATUS", "")
            if qmgr_status == "RUNNING":
                return {"changed": False,
                        "msg": "channel vanished (service STALE)",
                        "data": {"state": "UNKNOWN", "metrics": {},
                                 "details": "channel " + str(item) +
                                 " not in output; qmgr " + str(qmgr_name) +
                                 " is RUNNING"}}
        return {"changed": False,
                "msg": "channel not found: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = parsed[item]
    status = data.get("STATUS", "INACTIVE")
    lower = status.lower()
    check_state = _STATUS_MAP.get(lower, 3)
    chltype = data.get("CHLTYPE")
    infotext = "Status: " + str(status) + ", Type: " + str(chltype)
    if "XMITQ" in data and data.get("XMITQ") != "":
        infotext = infotext + ", Xmitq: " + str(data.get("XMITQ"))
    return {"changed": False,
            "msg": infotext,
            "data": {"state": _STATE_FROM_INT.get(check_state, "UNKNOWN"),
                     "metrics": {}, "details": ""}}