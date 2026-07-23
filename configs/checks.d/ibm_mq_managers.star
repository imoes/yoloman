_STATUS_MAP = {
    "STARTING": ("starting", 0),
    "RUNNING": ("running", 0),
    "RUNNING AS STANDBY": ("running_as_standby", 0),
    "RUNNING ELSEWHERE": ("running_elsewhere", 0),
    "QUIESCING": ("quiescing", 0),
    "ENDING IMMEDIATELY": ("ending_immediately", 0),
    "ENDING PREEMPTIVELY": ("ending_pre_emptively", 0),
    "ENDING PRE-EMPTIVELY": ("ending_pre_emptively", 0),
    "ENDED NORMALLY": ("ended_normally", 0),
    "ENDED IMMEDIATELY": ("ended_immediately", 0),
    "ENDED UNEXPECTEDLY": ("ended_unexpectedly", 2),
    "ENDED PREEMPTIVELY": ("ended_pre_emptively", 1),
    "ENDED PRE-EMPTIVELY": ("ended_pre_emptively", 1),
    "NOT AVAILABLE": ("status_not_available", 0),
    "STATUS NOT AVAILABLE": ("status_not_available", 0),
}

_DIGITS = "0123456789"
_VER_CHARS = {"p": 2, "b": 1, "i": 0}

def _is_digit(ch):
    return ch in _DIGITS

def _tokenize_version(v):
    result = []
    num = ""
    for ch in v:
        if _is_digit(ch):
            num = num + ch
        else:
            if num != "":
                result.append(int(num))
                num = ""
            if ch in _VER_CHARS:
                result.append(_VER_CHARS[ch])
    if num != "":
        result.append(int(num))
    return result

def _check_version(instver, params):
    info = "Version: " + instver
    if "version" not in params:
        return 0, info
    version_param = params["version"]
    comp_info = version_param[0]
    ver_state = version_param[1]
    comp_type = comp_info[0]
    expected = comp_info[1]
    actual_toks = _tokenize_version(instver)
    expected_toks = _tokenize_version(expected)
    if comp_type == "at_least" and actual_toks < expected_toks:
        return ver_state, info + " (should be at least %s)" % expected
    if comp_type == "specific" and actual_toks != expected_toks:
        return ver_state, info + " (should be %s)" % expected
    return 0, info

def _parse_kv_line(line):
    data = {}
    parts = line.split("(")
    if len(parts) < 2:
        return data
    key = parts[0].strip()
    for i in range(1, len(parts)):
        sub = parts[i].split(")", 1)
        value = sub[0].strip()
        if key != "":
            data[key] = value
        if len(sub) > 1:
            key = sub[1].strip()
        else:
            key = ""
    return data

def _fetch_managers(ctx, mq_home):
    dspmq = mq_home + "/bin/dspmq"
    if not ctx.file_exists(dspmq):
        return None
    res = ctx.run([dspmq, "-o", "all", "-x"], mutates=False, ok_codes=[0, 1])
    managers = {}
    current = None
    for raw in res.stdout.splitlines():
        line = raw.strip()
        if line == "":
            continue
        data = _parse_kv_line(line)
        if "QMNAME" in data:
            current = data["QMNAME"]
            managers[current] = {"attrs": data, "instances": []}
        elif "INSTANCE" in data and current != None:
            managers[current]["instances"].append(
                [data.get("INSTANCE", ""), data.get("MODE", "")]
            )
    return managers

def _map_status(status, params):
    entry = _STATUS_MAP.get(status)
    if entry == None:
        wato_key = "unknown"
        check_state = 3
    else:
        wato_key = entry[0]
        check_state = entry[1]
    if "mapped_states" in params:
        mapped = dict(params["mapped_states"])
        if wato_key in mapped:
            check_state = mapped[wato_key]
        elif "mapped_states_default" in params:
            check_state = params["mapped_states_default"]
    return check_state

def _worst(a, b):
    return b if b > a else a

def _state_name(s):
    if s == 0:
        return "OK"
    if s == 1:
        return "WARN"
    if s == 2:
        return "CRIT"
    return "UNKNOWN"

def main(ctx, params):
    mq_home = params.get("mq_home", "/usr/mqm")

    if params.get("_discover"):
        managers = _fetch_managers(ctx, mq_home)
        if managers == None:
            return {
                "changed": False,
                "msg": "dspmq not found under " + mq_home,
                "data": {"discovery": []},
            }
        items = [{"item": name, "params": {}, "metrics": []} for name in managers]
        return {
            "changed": False,
            "msg": "discovered %d managers" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    managers = _fetch_managers(ctx, mq_home)
    if managers == None:
        return {
            "changed": False,
            "msg": "dspmq not found under " + mq_home,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mgr = managers.get(item)
    if mgr == None:
        return {
            "changed": False,
            "msg": "Manager not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    attrs = mgr["attrs"]
    instances = mgr["instances"]
    status = attrs.get("STATUS", "")
    default = attrs.get("DEFAULT", "")
    instname = attrs.get("INSTNAME", "")
    instpath = attrs.get("INSTPATH", "")
    instver = attrs.get("INSTVER", "")

    worst = _map_status(status, params)
    parts = ["Status: " + status]

    ver_state, ver_msg = _check_version(instver, params)
    parts.append(ver_msg)
    worst = _worst(worst, ver_state)

    parts.append("Installation: %s (%s), Default: %s" % (instpath, instname, default))

    standby = attrs.get("STANDBY", "")
    ha = attrs.get("HA")

    if ha == "REPLICATED":
        if len(instances) > 0:
            parts.append("High availability: replicated, Instance: " + instances[0][0])
        else:
            parts.append("High availability: replicated")
    elif standby == "PERMITTED":
        if len(instances) == 2:
            parts.append("Multi-Instance: %s=%s and %s=%s" % (
                instances[0][0], instances[0][1], instances[1][0], instances[1][1],
            ))
        elif len(instances) == 1:
            parts.append("Multi-Instance: %s=%s and missing partner" % (
                instances[0][0], instances[0][1],
            ))
            worst = _worst(worst, 2)
        else:
            parts.append("Multi-Instance: unknown instances (%s)" % str(instances))
            worst = _worst(worst, 2)
    elif standby == "NOT PERMITTED":
        if len(instances) == 1:
            parts.append("Single-Instance: %s=%s" % (instances[0][0], instances[0][1]))
        else:
            parts.append("Single-Instance: unknown instances (%s)" % str(instances))
            worst = _worst(worst, 2)
    elif standby == "NOT APPLICABLE":
        if len(instances) != 0:
            parts.append("Unknown instance setup (%s)" % str(instances))
            worst = _worst(worst, 2)
    else:
        parts.append("Unknown STANDBY state (%s)" % standby)
        worst = _worst(worst, 2)

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": _state_name(worst),
            "metrics": {},
            "details": "",
        },
    }