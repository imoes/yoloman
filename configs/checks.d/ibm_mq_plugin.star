def tokenize_version(version):
    allowed = set("0123456789.pbi")
    chars_ok = True
    for c in version:
        if c not in allowed:
            chars_ok = False
            break
    if not version or not chars_ok:
        return None
    tokens = []
    i = 0
    n = len(version)
    while i < n:
        c = version[i]
        if c.isdigit():
            j = i
            while j < n and version[j].isdigit():
                j = j + 1
            tokens.append(int(version[i:j]))
            i = j
        elif c == ".":
            tokens.append(0)
            i = i + 1
        elif c in ("p", "b", "i"):
            mapping = {"p": 2, "b": 1, "i": 0}
            tokens.append(mapping[c])
            i = i + 1
        else:
            return None
    return tokens

def extract_version_line(text):
    if not text:
        return None
    for tok in text.split():
        candidate = tok
        while candidate and not (candidate[0].isdigit()):
            candidate = candidate[1:]
        if candidate and candidate[0].isdigit():
            ok = True
            has_dot = False
            for c in candidate:
                if c.isdigit():
                    continue
                elif c == ".":
                    has_dot = True
                else:
                    ok = False
                    break
            if ok and has_dot:
                return candidate
    t = text.strip()
    if t and t[0].isdigit():
        return t
    return None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dspmqver", "-v"], mutates=False)
        installed = res.rc == 0 and bool(res.stdout.strip())
        if not installed:
            return {"changed": False, "msg": "no IBM MQ installation found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered IBM MQ plugin check",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["version_cmp"]},
                ]}}

    res_ver = ctx.run(["dspmqver", "-v"], mutates=False)
    installed = res_ver.rc == 0 and bool(res_ver.stdout.strip())
    if not installed:
        return {"changed": False,
                "msg": "IBM MQ not installed: dspmqver not found",
                "data": {"state": "UNKNOWN",
                         "details": "IBM MQ queue manager tools are not installed on this host.",
                         "metrics": {}}}

    version_value = res_ver.stdout.strip()

    dspmq_res = ctx.run(["which", "dspmq"], mutates=False)
    dspmq_present = dspmq_res.rc == 0
    runmqsc_res = ctx.run(["which", "runmqsc"], mutates=False)
    runmqsc_present = runmqsc_res.rc == 0

    version_state = 0
    version_summary = "Plugin version: %s" % version_value

    if "version" in params and params["version"] != None:
        entry = params["version"]
        comp_type = entry.get("comp_type", "at_least")
        expected_version = entry.get("expected_version")
        want_state = entry.get("state", 2)

        parts_actual = tokenize_version(version_value)
        ver_substr = None
        if parts_actual == None:
            ver_substr = extract_version_line(version_value)
            parts_actual = tokenize_version(ver_substr) if ver_substr else None

        parts_expected = tokenize_version(expected_version) if expected_version else None

        if parts_expected == None or (parts_actual == None and ver_substr == None):
            version_state = 3
            version_summary = ("Cannot compare %s and %s. Only numbers separated by characters 'b', 'i', 'p', or '.' are allowed for a version." % (version_value, expected_version))
        else:
            if comp_type == "at_least" and parts_actual < parts_expected:
                version_state = want_state
                version_summary = "Plugin version: %s (should be at least %s)" % (version_value, expected_version)
            elif comp_type == "specific" and parts_actual != parts_expected:
                version_state = want_state
                version_summary = "Plugin version: %s (should be %s)" % (version_value, expected_version)

    holder = {"worst": 0}

    def consider(st_int):
        if st_int > holder["worst"]:
            holder["worst"] = st_int

    consider(version_state)

    def tool_state(present):
        if not present:
            return 2
        return 0

    consider(tool_state(dspmq_present))
    consider(tool_state(runmqsc_present))

    state_int = holder["worst"]
    if state_int == 3:
        state_name = "UNKNOWN"
    elif state_int == 2:
        state_name = "CRIT"
    elif state_int == 1:
        state_name = "WARN"
    else:
        state_name = "OK"

    summary = version_summary
    if dspmq_present:
        summary = summary + " | dspmq: OK"
    else:
        summary = summary + " | dspmq: Not executable"
    if runmqsc_present:
        summary = summary + " | runmqsc: OK"
    else:
        summary = summary + " | runmqsc: Not executable"

    metrics = {"version_cmp": float(state_int)}
    return {"changed": False,
            "msg": summary,
            "data": {"state": state_name,
                     "metrics": metrics,
                     "details": summary}}