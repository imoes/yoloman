# Checkmk check: ibm_mq_managers
# Translated to a read-only Starlark check module for the yolo-man agent.

def _tokenize(version):
    _map_chars = {"p": 2, "b": 1, "i": 0}
    allowed = "0123456789.pbi"
    for ch in version:
        if not ch in allowed:
            return None
    tokens = []
    current = ""
    for ch in version:
        if ch == ".":
            if current != "":
                tokens.append(current)
                current = ""
            continue
        current += ch
    if current != "":
        tokens.append(current)
    parts = []
    for g in tokens:
        if g in _map_chars:
            parts.append(_map_chars[g])
        else:
            if not g.isdigit():
                return None
            parts.append(int(g))
    return parts


def _ibm_mq_check_version(actual_version, params, label):
    info = "%s: %s" % (label, actual_version)
    if actual_version == None:
        return 3, info + " (no agent info)"
    if not "version" in params:
        return 0, info
    version_param = params["version"]
    comp_type = version_param[0]
    expected_version = version_param[1]
    state = version_param[2]
    parts_actual = _tokenize(actual_version)
    parts_expected = _tokenize(expected_version)
    if parts_actual == None or parts_expected == None:
        return 3, ("Cannot compare %s and %s. Only numbers separated by characters 'b', 'i', 'p', or '.' are allowed for a version." % (actual_version, expected_version))
    if comp_type == "at_least" and parts_actual < parts_expected:
        return state, info + " (should be at least %s)" % expected_version
    if comp_type == "specific" and parts_actual != parts_expected:
        return state, info + " (should be %s)" % expected_version
    return 0, info


_DEFAULT_STATUS_MAP = {
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


def _map_status(status, params):
    wato_key, check_state = _DEFAULT_STATUS_MAP.get(status, ("unknown", 3))
    if "mapped_states" in params:
        mapped_states = dict(params["mapped_states"])
        if wato_key in mapped_states:
            check_state = mapped_states[wato_key]
        elif "mapped_states_default" in params:
            check_state = params["mapped_states_default"]
    return check_state


def _parse_line(line):
    data = {}
    idx = 0
    rest = line
    while True:
        pos = rest.find("(", idx)
        if pos == -1:
            break
        cidx = rest.find(")", pos)
        if cidx == -1:
            break
        content = rest[pos + 1:cidx]
        kv = content.split(None, 1)
        if len(kv) == 2:
            data[kv[0].strip()] = kv[1].strip()
        idx = cidx + 1
    return data


def _cmd_available(ctx, cmd):
    res = ctx.run(["sh", "-c", "command -v %s" % cmd], mutates=False, ok_codes=[0, 1])
    return res.rc == 0


def _run_disp(ctx, params):
    version_path = params.get("version_cmd", "dspmq")
    if not _cmd_available(ctx, version_path):
        return None
    res = ctx.run([version_path, "-m"], mutates=False, ok_codes=[0, 127])
    if res.rc != 0 and res.rc != 127:
        return None
    return res


def _parse_managers(ctx, params):
    parsed = {}
    current_qmname = None
    res = _run_disp(ctx, params)
    if res == None:
        return parsed
    lines = res.stdout.splitlines()
    for line in lines:
        if line.strip() == "":
            current_qmname = None
            continue
        data = _parse_line(line.strip())
        if not data:
            continue
        if "QMNAME" in data:
            current_qmname = data["QMNAME"]
            instances = []
            parsed[current_qmname] = {"attributes": data, "instances": instances}
        elif "INSTANCE" in data and current_qmname != None and current_qmname in parsed:
            parsed[current_qmname]["instances"].append((data["INSTANCE"], data["MODE"]))
    return parsed


def _has_ibm_mq(ctx):
    return _cmd_available(ctx, "dspmq")


def _max_state(ranks):
    m = 0
    for r in ranks:
        if r > m:
            m = r
    return m


def main(ctx, params):
    if params.get("_discover"):
        if not _has_ibm_mq(ctx):
            return {"changed": False, "msg": "no IBM MQ found on this host", "data": {"discovery": []}}
        parsed = _parse_managers(ctx, params)
        if len(parsed) == 0:
            return {"changed": False, "msg": "no IBM MQ managers discovered", "data": {"discovery": []}}
        discovery = []
        for item in sorted(parsed.keys()):
            discovery.append({"item": item, "params": {}, "metrics": ["status", "instances"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not _has_ibm_mq(ctx):
        return {"changed": False, "msg": "IBM MQ is not installed on this host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_managers(ctx, params)
    if item == "":
        if len(parsed) > 0:
            item = sorted(parsed.keys())[0]
        else:
            return {"changed": False, "msg": "no IBM MQ manager found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item not in parsed:
        return {"changed": False, "msg": "no such IBM MQ manager: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = parsed[item]
    attrs = data["attributes"]
    instances = data["instances"]
    status = attrs.get("STATUS", "STATUS NOT AVAILABLE")
    default = attrs.get("DEFAULT", "NO")
    instname = attrs.get("INSTNAME", "")
    instpath = attrs.get("INSTPATH", "")
    instversion = attrs.get("INSTVER", "")

    check_state = _map_status(status, params)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

    version_state, version_summary = _ibm_mq_check_version(instversion, params, "Version")

    standby = attrs.get("STANDBY", "NOT APPLICABLE")
    ha = attrs.get("HA", "")

    details_parts = []
    details_parts.append("Status: %s" % status)
    details_parts.append(version_summary)
    details_parts.append("Installation: %s (%s), Default: %s" % (instpath, instname, default))

    instance_count = len(instances)
    inst_state = 0
    if ha == "REPLICATED":
        if instance_count > 0:
            details_parts.append("High availability: replicated, Instance: %s" % instances[0][0])
        else:
            details_parts.append("High availability: replicated")
    elif standby == "PERMITTED":
        if instance_count == 2:
            details_parts.append("Multi-Instance: %s=%s and %s=%s" % (instances[0][0], instances[0][1], instances[1][0], instances[1][1]))
            inst_state = 0
        elif instance_count == 1:
            details_parts.append("Multi-Instance: %s=%s and missing partner" % (instances[0][0], instances[0][1]))
            inst_state = 2
        else:
            inst_state = 2
            details_parts.append("Multi-Instance: unknown instances (%s)" % str(instances))
    elif standby == "NOT PERMITTED":
        if instance_count == 1:
            details_parts.append("Single-Instance: %s=%s" % (instances[0][0], instances[0][1]))
            inst_state = 0
        else:
            inst_state = 2
            details_parts.append("Single-Instance: unknown instances (%s)" % str(instances))
    elif standby == "NOT APPLICABLE":
        if instance_count != 0:
            inst_state = 2
            details_parts.append("Unknown instance setup (%s)" % str(instances))
    else:
        inst_state = 2
        details_parts.append("Unknown STANDBY state (%s)" % standby)

    final_state_rank = _max_state([check_state, version_state, inst_state])
    final_state = state_map.get(final_state_rank, "UNKNOWN")

    metrics = {"instances": float(instance_count)}

    msg = "%s - Status: %s" % (item, status)
    return {"changed": False, "msg": msg, "data": {"state": final_state, "metrics": metrics, "details": "\n".join(details_parts)}}