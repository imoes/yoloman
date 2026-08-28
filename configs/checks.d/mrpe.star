def _mrpe_url_decode(s):
    if "%" not in s:
        return s
    parts = s.split("%")
    result = parts[0]
    for part in parts[1:]:
        if len(part) >= 2:
            hi = part[0]
            lo = part[1]
            if _is_hex(hi) and _is_hex(lo):
                code = _hex_val(hi) * 16 + _hex_val(lo)
                result += chr(code) + part[2:]
            else:
                result += "%" + part
        else:
            result += "%" + part
    return result.replace("+", " ")


def _is_hex(c):
    return ("0" <= c and c <= "9") or ("a" <= c and c <= "f") or ("A" <= c and c <= "F")


def _hex_val(c):
    if "0" <= c and c <= "9":
        return ord(c) - ord("0")
    if "a" <= c and c <= "f":
        return ord(c) - ord("a") + 10
    if "A" <= c and c <= "F":
        return ord(c) - ord("A") + 10
    return 0


def _mrpe_strip_unit_float(string):
    for i in range(len(string), 0, -1):
        sub = string[:i]
        if _can_float(sub):
            return float(sub)
        # guard-based fallback already handled by loop
    return None


def _can_float(s):
    if s == "":
        return False
    if s == "":
        return False
    # minimal check without exceptions
    ok = True
    has_digit = False
    idx = 0
    if s[0] == "-":
        idx = 1
    if idx >= len(s):
        return False
    saw_dot = False
    # BY INDEX: a Starlark string is NOT iterable, so `for ch in s[idx:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_ch in range(idx, len(s)):
        ch = s[_i_ch]
        if ch == ".":
            if saw_dot:
                return False
            saw_dot = True
        elif "0" <= ch and ch <= "9":
            has_digit = True
        else:
            return False
    return has_digit


def _mrpe_opt_float(string):
    if string == "" or string == None:
        return None
    if _can_float(string):
        return float(string)
    return None


def _mrpe_parse_perfstring(perfinfo):
    eq = perfinfo.find("=")
    if eq == -1:
        return None
    name = perfinfo[:eq]
    valuetxt = perfinfo[eq + 1:]

    if valuetxt.startswith("U"):
        return None

    values_raw = valuetxt.split(";")
    values = []
    for v in values_raw:
        colon = v.rfind(":")
        if colon >= 0:
            v = v[colon + 1:]
        values.append(v)

    values = values[:5]
    while len(values) < 5:
        values.append("")

    value_str = values[0]
    value = _mrpe_strip_unit_float(value_str)
    if value == None:
        return None

    warn = _mrpe_opt_float(values[1])
    crit = _mrpe_opt_float(values[2])
    minn = _mrpe_opt_float(values[3])
    maxx = _mrpe_opt_float(values[4])
    return (name, value, warn, crit, minn, maxx)


def main(ctx, params):
    # ---- Discovery mode ----
    if params.get("_discover"):
        # MRPE is a Checkmk-specific feature: custom commands registered
        # in Checkmk and executed by the Checkmk agent's mrpe section.
        # No Checkmk agent present → MRPE does not exist on this host.
        # Probe for the real source.
        probe = ctx.run(["mrpe", "--list"], mutates=False)
        if probe.rc != 0:
            return {
                "changed": False,
                "msg": "no MRPE checks configured",
                "data": {"discovery": []},
            }

        items = []
        seen = set()
        for line in probe.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            parts = line.split("|")
            if len(parts) < 1:
                continue
            it = parts[0]
            if it not in seen:
                seen.add(it)
                items.append({
                    "item": it,
                    "params": {},
                    "metrics": [],
                })

        return {
            "changed": False,
            "msg": "discovered %d MRPE checks" % len(items),
            "data": {"discovery": items},
        }

    # ---- Check mode ----
    item = params.get("item", "")

    probe = ctx.run(["mrpe", "--list"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "MRPE not available on this host",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No Checkmk agent or mrpe binary found",
            },
        }

    found = False
    for line in probe.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split("|")
        if len(parts) >= 1 and parts[0] == item:
            found = True
            break

    if not found:
        return {
            "changed": False,
            "msg": "no MRPE check found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Execute the MRPE command for this item
    exec_res = ctx.run(["mrpe", "--execute", item], mutates=False)
    if exec_res.rc != 0:
        return {
            "changed": False,
            "msg": "MRPE execution failed for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": exec_res.stderr,
            },
        }

    raw_lines = exec_res.stdout.splitlines()
    if len(raw_lines) == 0:
        return {
            "changed": False,
            "msg": "empty MRPE output for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    raw_state = ""
    info_lines = []

    for raw_line in raw_lines:
        raw_line = raw_line.strip()
        if raw_line == "":
            continue
        segs = raw_line.split("|", 2)
        if len(segs) >= 2:
            if len(segs) == 3:
                raw_state = segs[1]
                info_lines = segs[2].split("\x01")
            else:
                raw_state = segs[0]
                info_lines = segs[1].split("\x01")
            break

    if raw_state == "":
        return {
            "changed": False,
            "msg": "could not parse MRPE output for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state_num = 3
    if _can_float(raw_state) or (len(raw_state) > 0 and _can_float_simple(raw_state)):
        state_num = _str_to_int(raw_state)
    else:
        # invalid state → UNKNOWN, prepend error notice
        info_lines = ["Invalid plug-in status '%s'. Output is:" % raw_state] + info_lines
        state_num = 3

    if state_num == 0:
        state = "OK"
    elif state_num == 1:
        state = "WARN"
    elif state_num == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    metrics = {}
    details_lines = []

    for line in info_lines:
        parts = line.split("|", 1)
        output_text = parts[0].strip()
        if output_text != "":
            details_lines.append(output_text)
        if len(parts) > 1:
            for perf in parts[1].strip().split():
                parsed_perf = _mrpe_parse_perfstring(perf)
                if parsed_perf != None:
                    pname = parsed_perf[0]
                    pval = parsed_perf[1]
                    metrics[pname] = pval

    summary_text = details_lines[0] if len(details_lines) > 0 else "No further information available"
    details_text = "\n".join(details_lines[1:]) if len(details_lines) > 1 else ""

    return {
        "changed": False,
        "msg": item + ": " + summary_text,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details_text,
        },
    }


def _can_float_simple(s):
    if s == "":
        return False
    idx = 0
    if s[0] == "-":
        idx = 1
    if idx >= len(s):
        return False
    has_digit = False
    saw_dot = False
    # BY INDEX: a Starlark string is NOT iterable, so `for ch in s[idx:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_ch in range(idx, len(s)):
        ch = s[_i_ch]
        if ch == ".":
            if saw_dot:
                return False
            saw_dot = True
        elif "0" <= ch and ch <= "9":
            has_digit = True
        else:
            return False
    return has_digit


def _str_to_int(s):
    result = 0
    start = 0
    neg = False
    if s[0] == "-":
        neg = True
        start = 1
    elif s[0] == "+":
        start = 1
    # BY INDEX: a Starlark string is NOT iterable, so `for ch in s[start:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_ch in range(start, len(s)):
        ch = s[_i_ch]
        if "0" <= ch and ch <= "9":
            result = result * 10 + (ord(ch) - ord("0"))
        else:
            return 0
    return -result if neg else result