# ===== checkmk.nfsiostat → read-only Starlark check module =====
# Checks NFS IO statistics produced by the `nfsiostat` command.

METRIC_NAMES = [
    "op_s",
    "rpc_backlog",
    "read_ops",
    "read_b_s",
    "read_b_op",
    "read_retrans_pct",
    "read_avg_rtt_ms",
    "read_avg_exe_ms",
    "write_ops_s",
    "write_b_s",
    "write_b_op",
    "write_retrans_pct",
    "write_avg_rtt_ms",
    "write_avg_exe_ms",
]

LABELS = {
    "op_s": "Operations", "rpc_backlog": "RPC Backlog",
    "read_ops": "Read operations", "read_b_s": "Reads size",
    "read_b_op": "Read bytes per operation",
    "read_retrans_pct": "Read Retransmission",
    "read_avg_rtt_ms": "Read average RTT",
    "read_avg_exe_ms": "Read average EXE",
    "write_ops_s": "Write operations", "write_b_s": "Writes size",
    "write_b_op": "Write bytes per operation",
    "write_retrans_pct": "Write Retransmission",
    "write_avg_rtt_ms": "Write Average RTT",
    "write_avg_exe_ms": "Write Average EXE",
}

DEFAULT_PARAMS = {name: None for name in METRIC_NAMES}


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    probe = ctx.run(["nfsiostat", "-V"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "nfsiostat not installed",
                "data": {"discovery": []}}

    res = ctx.run(["nfsiostat"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "nfsiostat failed",
                "data": {"discovery": []}}

    section = _parse(res.stdout)
    out = []
    for mountname in section:
        out.append({
            "item": mountname,
            "params": dict(DEFAULT_PARAMS),
            "metrics": list(METRIC_NAMES),
        })
    return {"changed": False, "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}}


def _check(ctx, params):
    probe = ctx.run(["nfsiostat", "-V"], mutates=False)
    if probe.rc == 127:
        return {"changed": False,
                "msg": "nfsiostat not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["nfsiostat"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "nfsiostat failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse(res.stdout)
    item = params.get("item", "")
    if item not in section:
        return {"changed": False,
                "msg": "no such mount: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = section[item]
    metrics = {}
    for mname in METRIC_NAMES:
        metrics[mname] = values[mname]

    acc = {"state": "OK"}
    summaries = []
    for mname in METRIC_NAMES:
        s = _level(values[mname], params, mname, LABELS[mname], acc)
        if s:
            summaries.append(s)

    summary = ", ".join(summaries) if summaries else item
    details = _build_details(item, values)

    return {"changed": False, "msg": summary,
            "data": {"state": acc["state"], "metrics": metrics, "details": details}}


def _level(value, params, pname, label, acc):
    lvls = params.get(pname)
    if lvls == None:
        return ""
    warn = lvls[0] if len(lvls) > 0 else None
    crit = lvls[1] if len(lvls) > 1 else None
    s = "OK"
    if crit != None and value >= crit:
        s = "CRIT"
    elif warn != None and value >= warn:
        s = "WARN"
    if s != "OK":
        if s == "CRIT":
            acc["state"] = "CRIT"
        elif s == "WARN" and acc["state"] == "OK":
            acc["state"] = "WARN"
    return "%s: %s" % (label, _render(value, pname))


def _render(v, pname):
    if pname in ("read_retrans_pct", "write_retrans_pct"):
        return "%f%%" % v
    if pname in ("read_avg_rtt_ms", "read_avg_exe_ms",
                 "write_avg_rtt_ms", "write_avg_exe_ms"):
        return "%f ms" % v
    if pname in ("read_b_s", "write_b_s", "read_b_op", "write_b_op"):
        return "%f B" % v
    return "%f" % v


def _build_details(item, values):
    lines = [item]
    for mname in METRIC_NAMES:
        lines.append("  %s: %s" % (LABELS[mname], _render(values[mname], mname)))
    return "\n".join(lines)


def _parse(text):
    section = {}
    lines = text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        header = _find_mount_header(line)
        if header:
            mountname = "'" + header + "',"
            i += 1
            numbers1 = []
            read_nums = []
            write_nums = []
            while i < n:
                l = lines[i].strip()
                if l == "" or l.startswith("op/s") or l.startswith("read:") or l.startswith("write:") or l.startswith("mounted on"):
                    i += 1
                    continue
                parts = l.split()
                if len(parts) >= 2 and _is_number(parts[0]):
                    numbers1 = [_to_float(p) for p in parts[:2]]
                    i += 1
                    break
                i += 1
            while i < n:
                l = lines[i].strip()
                if l == "":
                    i += 1
                    continue
                if l.startswith("read:"):
                    i += 1
                    break
                i += 1
            if i < n and not lines[i].strip().startswith("write:") and not lines[i].strip().startswith("mounted on"):
                parts = lines[i].split()
                read_nums = _extract_numbers(parts)
                i += 1
            while i < n:
                l = lines[i].strip()
                if l == "":
                    i += 1
                    continue
                if l.startswith("write:"):
                    i += 1
                    break
                i += 1
            if i < n and not lines[i].strip().startswith("mounted on"):
                parts = lines[i].split()
                write_nums = _extract_numbers(parts)
                i += 1
            if len(read_nums) >= 7 and len(write_nums) >= 7:
                section[mountname] = {
                    "op_s": numbers1[0] if len(numbers1) > 0 else 0.0,
                    "rpc_backlog": numbers1[1] if len(numbers1) > 1 else 0.0,
                    "read_ops": read_nums[0],
                    "read_b_s": read_nums[1],
                    "read_b_op": read_nums[2],
                    "read_retrans_pct": read_nums[4],
                    "read_avg_rtt_ms": read_nums[5],
                    "read_avg_exe_ms": read_nums[6],
                    "write_ops_s": write_nums[0],
                    "write_b_s": write_nums[1],
                    "write_b_op": write_nums[2],
                    "write_retrans_pct": write_nums[4],
                    "write_avg_rtt_ms": write_nums[5],
                    "write_avg_exe_ms": write_nums[6],
                }
        else:
            i += 1
    return section


def _find_mount_header(line):
    idx = line.find(" mounted on ")
    if idx < 0:
        return None
    left = line[:idx]
    if ":" not in left:
        return None
    return left.strip()


def _extract_numbers(parts):
    nums = []
    for p in parts:
        cleaned = p.replace("(", "").replace(")", "").replace("%", "")
        if _is_number(cleaned):
            nums.append(_to_float(cleaned))
    return nums


def _is_number(s):
    if s == "":
        return False
    if s == "." or s == "-" or s == "+":
        return False
    # check valid float format without try
    parts = s.split(".")
    if len(parts) > 2:
        return False
    for seg in parts:
        if seg == "":
            continue
        if seg[0] in "+-":
            seg = seg[1:]
        if seg == "":
            return False
        for ch in seg:
            if ch < "0" or ch > "9":
                return False
    return True


def _to_float(s):
    if s == None:
        return 0.0
    sign = 1.0
    idx = 0
    if s[0] == "+":
        idx = 1
    elif s[0] == "-":
        sign = -1.0
        idx = 1
    rest = s[idx:]
    if "." in rest:
        ip, frac = rest.split(".", 1)
    else:
        ip, frac = rest, ""
    ip_val = _str_to_int(ip)
    frac_val = 0.0
    if frac:
        frac_val = _str_to_int(frac) / (_ipow(10, len(frac)))
    return sign * (ip_val + frac_val)


def _str_to_int(s):
    if s == "":
        return 0
    val = 0
    for ch in s:
        val = val * 10 + (_ord(ch) - _ord("0"))
    return val


def _ord(ch):
    o = 0
    base = "0"
    while o < 256:
        if ch == base:
            return o
        o += 1
        base = chr(o)
    return 0


def _ipow(b, e):
    result = 1
    for _ in range(e):
        result = result * b
    return result