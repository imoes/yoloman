MRPE_CONF_PATHS = ["/etc/check_mk/mrpe.cfg", "/etc/mrpe.cfg"]

STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _is_numeric(s):
    if s == "":
        return False
    start = 0
    if s[0] == "-":
        start = 1
    if start >= len(s):
        return False
    dot_count = 0
    for i in range(start, len(s)):
        c = s[i]
        if c == ".":
            dot_count += 1
            if dot_count > 1:
                return False
        elif not (c >= "0" and c <= "9"):
            return False
    return True


def _strip_unit_float(s):
    for i in range(len(s), 0, -1):
        sub = s[:i]
        if _is_numeric(sub):
            return float(sub)
    return None


def _parse_conf(content):
    checks = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        desc = parts[0]
        rest = parts[1:]
        if rest[0].startswith("(") and rest[0].endswith(")"):
            rest = rest[1:]
        if rest:
            checks.append({"desc": desc, "cmd": rest})
    return checks


def _parse_perf(perf_str):
    metrics = {}
    for raw in perf_str.strip().split():
        if "=" not in raw:
            continue
        eq_idx = raw.find("=")
        name = raw[:eq_idx]
        rest = raw[eq_idx + 1:]
        parts = rest.split(";")
        value_str = parts[0]
        if ":" in value_str:
            value_str = value_str.split(":")[-1]
        if value_str.startswith("U"):
            continue
        v = _strip_unit_float(value_str)
        if v != None:
            safe_name = name.replace("-", "_").replace(" ", "_").replace(".", "_")
            metrics[safe_name] = v
    return metrics


def main(ctx, params):
    conf_content = None
    for path in MRPE_CONF_PATHS:
        if ctx.file_exists(path):
            conf_content = ctx.file_read(path)
            break

    if params.get("_discover"):
        if conf_content == None:
            return {"changed": False, "msg": "no mrpe.cfg found",
                    "data": {"discovery": []}}
        checks = _parse_conf(conf_content)
        discovery = [{"item": c["desc"], "params": {}, "metrics": []}
                     for c in checks]
        return {"changed": False,
                "msg": "discovered %d mrpe checks" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    if conf_content == None:
        return {"changed": False, "msg": "no mrpe.cfg found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    checks = _parse_conf(conf_content)
    cmd_parts = None
    for c in checks:
        if c["desc"] == item:
            cmd_parts = c["cmd"]
            break

    if cmd_parts == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(cmd_parts, mutates=False, ok_codes=[0, 1, 2, 3, 126, 127])
    rc = res.rc
    state = STATE_NAMES.get(rc, "UNKNOWN")

    stdout = res.stdout.strip()
    lines = stdout.splitlines()
    first_line = lines[0] if lines else ""

    lsplit = first_line.split("|", 1)
    output_parts = [lsplit[0].strip()]
    perf_str = lsplit[1].strip() if len(lsplit) > 1 else ""

    now_comes_perf = False
    for line in lines[1:]:
        if now_comes_perf:
            perf_str = perf_str + " " + line
        else:
            lparts = line.split("|", 1)
            output_parts.append(lparts[0].strip())
            if len(lparts) > 1:
                perf_str = perf_str + " " + lparts[1].strip()
                now_comes_perf = True

    metrics = _parse_perf(perf_str)
    summary = output_parts[0] if (output_parts and output_parts[0]) else "No further information available"
    details = "\n".join(output_parts[1:]) if len(output_parts) > 1 else ""

    return {
        "changed": False,
        "msg": "[%s] %s" % (state, summary),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }