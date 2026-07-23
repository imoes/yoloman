WARN_DEFAULT = 30
CRIT_DEFAULT = 60

def _is_float_str(s):
    s2 = s[1:] if (s.startswith("-") or s.startswith("+")) else s
    if s2 == "" or s2 == ".":
        return False
    parts = s2.split(".")
    if len(parts) > 2:
        return False
    for p in parts:
        if p != "" and not p.isdigit():
            return False
    return True

def _fmt_seconds(val):
    whole = int(val)
    frac = int((val - whole) * 1000)
    frac_s = str(1000 + frac)[1:]
    return str(whole) + "." + frac_s

def _parse_chrony_offset(output):
    for line in output.splitlines():
        if not line.strip().startswith("System time"):
            continue
        colon_idx = line.find(":")
        if colon_idx < 0:
            continue
        rest = line[colon_idx + 1:].strip()
        tokens = rest.split()
        if len(tokens) < 3:
            continue
        val_str = tokens[0]
        if not _is_float_str(val_str):
            continue
        val = float(val_str)
        if tokens[2] == "slow":
            val = -val
        return val
    return None

def _parse_ntpq_offset(output):
    for line in output.splitlines():
        if not (line.startswith("*") or line.startswith("o")):
            continue
        parts = line.split()
        if len(parts) < 9:
            continue
        offset_str = parts[8]
        if _is_float_str(offset_str):
            return float(offset_str) / 1000.0
    return None

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"levels": [WARN_DEFAULT, CRIT_DEFAULT]}, "metrics": ["offset"]},
            ]},
        }

    levels = params.get("levels", [WARN_DEFAULT, CRIT_DEFAULT])
    warn = levels[0]
    crit = levels[1]

    offset = None

    for p in ["/usr/bin/chronyc", "/usr/sbin/chronyc", "/bin/chronyc"]:
        if ctx.file_exists(p):
            res = ctx.run(["chronyc", "tracking"], mutates=False, ok_codes=[0, 1])
            if res.rc == 0:
                offset = _parse_chrony_offset(res.stdout)
            break

    if offset == None:
        for p in ["/usr/bin/ntpq", "/usr/sbin/ntpq"]:
            if ctx.file_exists(p):
                res = ctx.run(["ntpq", "-pn"], mutates=False, ok_codes=[0, 1])
                if res.rc == 0:
                    offset = _parse_ntpq_offset(res.stdout)
                break

    if offset == None:
        return {
            "changed": False,
            "msg": "Cannot determine time offset (no chrony/ntpq available or no sync)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    abs_offset = abs(offset)
    state = "CRIT" if abs_offset >= crit else ("WARN" if abs_offset >= warn else "OK")
    direction = "fast" if offset >= 0 else "slow"
    msg = "Offset: %s s (%s)" % (_fmt_seconds(abs_offset), direction)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"offset": offset},
            "details": "",
        },
    }