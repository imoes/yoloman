DIGITS = "0123456789"
VERSION_CHAR_MAP = {"p": 2, "b": 1, "i": 0}
MQ_BIN = "/opt/mqm/bin"

def _tokenize_version(v):
    tokens = []
    i = 0
    n = len(v)
    for _outer in range(n):
        if i >= n:
            break
        ch = v[i]
        if ch in DIGITS:
            j = i + 1
            for _inner in range(n):
                if j >= n or v[j] not in DIGITS:
                    break
                j = j + 1
            tokens.append(int(v[i:j]))
            i = j
        elif ch in VERSION_CHAR_MAP:
            tokens.append(VERSION_CHAR_MAP[ch])
            i = i + 1
        elif ch == ".":
            i = i + 1
        else:
            break
    return tokens

def _version_less(a, b):
    for i in range(min(len(a), len(b))):
        if a[i] < b[i]:
            return True
        if a[i] > b[i]:
            return False
    return len(a) < len(b)

def _version_equal(a, b):
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True

def _check_version(actual_version, params, label):
    info = "%s: %s" % (label, str(actual_version))
    if actual_version == None:
        return (3, info + " (no agent info)")
    if "version" not in params:
        return (0, info)
    version_rule = params["version"]
    comp_info = version_rule[0]
    state = version_rule[1]
    comp_type = comp_info[0]
    expected_version = comp_info[1]
    parts_actual = _tokenize_version(str(actual_version))
    parts_expected = _tokenize_version(str(expected_version))
    if len(parts_actual) == 0 or len(parts_expected) == 0:
        return (3, "Cannot compare %s and %s" % (str(actual_version), str(expected_version)))
    if comp_type == "at_least" and _version_less(parts_actual, parts_expected):
        return (state, info + " (should be at least %s)" % expected_version)
    if comp_type == "specific" and not _version_equal(parts_actual, parts_expected):
        return (state, info + " (should be %s)" % expected_version)
    return (0, info)

def _state_to_str(s):
    if s == 0:
        return "OK"
    if s == 1:
        return "WARN"
    if s == 2:
        return "CRIT"
    return "UNKNOWN"

def _gather_ibm_mq(ctx):
    section = {}
    dspmqver_bin = MQ_BIN + "/dspmqver"
    dspmq_bin = MQ_BIN + "/dspmq"
    runmqsc_bin = MQ_BIN + "/runmqsc"

    if ctx.file_exists(dspmqver_bin):
        ver_res = ctx.run([dspmqver_bin], mutates=False, ok_codes=[0, 1, 2, 3])
        if ver_res.rc == 0:
            for line in ver_res.stdout.splitlines():
                stripped = line.strip()
                if stripped.startswith("Version:"):
                    parts = stripped.split(":", 1)
                    if len(parts) == 2:
                        section["version"] = parts[1].strip()
                        break

    if ctx.file_exists(dspmq_bin):
        dspmq_res = ctx.run([dspmq_bin], mutates=False, ok_codes=[0, 1, 2, 3, 4, 5, 8])
        section["dspmq"] = "OK" if dspmq_res.rc == 0 else "rc=%d" % dspmq_res.rc
    else:
        section["dspmq"] = "Not executable"

    section["runmqsc"] = "OK" if ctx.file_exists(runmqsc_bin) else "Not executable"

    return section

def main(ctx, params):
    if params.get("_discover"):
        exists = ctx.file_exists(MQ_BIN + "/dspmq") or ctx.file_exists(MQ_BIN + "/dspmqver")
        if not exists:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    section = _gather_ibm_mq(ctx)

    msgs = []
    worst = 0

    ver_state, ver_msg = _check_version(section.get("version"), params, "Plugin version")
    msgs.append(ver_msg)
    if ver_state > worst:
        worst = ver_state

    for tool in ["dspmq", "runmqsc"]:
        val = section.get(tool)
        if val == None:
            t_state = 3
            t_msg = "%s: No agent info" % tool
        else:
            t_state = 0 if val == "OK" else 2
            t_msg = "%s: %s" % (tool, val)
        msgs.append(t_msg)
        if t_state > worst:
            worst = t_state

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {
            "state": _state_to_str(worst),
            "metrics": {},
            "details": "",
        },
    }