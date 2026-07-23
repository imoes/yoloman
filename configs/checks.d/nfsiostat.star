STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _to_float(s):
    s = s.strip().lstrip("(").rstrip(")%")
    if s == "" or s == "-":
        return 0.0
    if "." in s:
        parts = s.split(".")
        if parts[0].lstrip("-").isdigit() and parts[1].isdigit():
            return float(s)
        return 0.0
    if s.lstrip("-").isdigit():
        return float(s)
    return 0.0

def _worst(a, b):
    if STATE_ORDER.get(b, 0) > STATE_ORDER.get(a, 0):
        return b
    return a

def _check_upper(value, levels, label, unit):
    if levels == None:
        return ("OK", "%s: %f%s" % (label, value, unit))
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return ("CRIT", "%s: %f%s (crit)" % (label, value, unit))
    if value >= warn:
        return ("WARN", "%s: %f%s (warn)" % (label, value, unit))
    return ("OK", "%s: %f%s" % (label, value, unit))

def _parse_nfsiostat(output):
    mounts = {}
    lines = output.splitlines()
    current_mount = None
    st = None
    mdata = {}

    for line in lines:
        stripped = line.strip()
        if "mounted on" in line and stripped != "" and not stripped.startswith("#"):
            parts = line.split()
            if len(parts) >= 1:
                current_mount = "'" + parts[0] + "',"
                mdata = {}
                st = "op_header"
        elif st == "op_header" and stripped.startswith("op/s"):
            st = "op_vals"
        elif st == "op_vals" and stripped != "":
            parts = stripped.split()
            if len(parts) >= 2:
                mdata["op_s"] = _to_float(parts[0])
                mdata["rpc_backlog"] = _to_float(parts[1])
            st = "read_header"
        elif st == "read_header" and stripped.startswith("read:"):
            st = "read_vals"
        elif st == "read_vals" and stripped != "":
            parts = stripped.split()
            if len(parts) >= 7:
                mdata["read_ops"] = _to_float(parts[0])
                mdata["read_b_s"] = _to_float(parts[1])
                mdata["read_b_op"] = _to_float(parts[2])
                mdata["read_retrans"] = _to_float(parts[4])
                mdata["read_avg_rtt_s"] = _to_float(parts[5]) / 1000.0
                mdata["read_avg_exe_s"] = _to_float(parts[6]) / 1000.0
            st = "write_header"
        elif st == "write_header" and stripped.startswith("write:"):
            st = "write_vals"
        elif st == "write_vals" and stripped != "":
            parts = stripped.split()
            if len(parts) >= 7:
                mdata["write_ops_s"] = _to_float(parts[0])
                mdata["write_b_s"] = _to_float(parts[1])
                mdata["write_b_op"] = _to_float(parts[2])
                mdata["write_retrans"] = _to_float(parts[4])
                mdata["write_avg_rtt_s"] = _to_float(parts[5]) / 1000.0
                mdata["write_avg_exe_s"] = _to_float(parts[6]) / 1000.0
            if current_mount != None:
                mounts[current_mount] = mdata
            current_mount = None
            mdata = {}
            st = None

    return mounts

def main(ctx, params):
    res = ctx.run(["nfsiostat"], mutates=False, ok_codes=[0, 1, 127])

    if params.get("_discover"):
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "discovered 0 mounts",
                    "data": {"discovery": []}}
        mounts = _parse_nfsiostat(res.stdout)
        items = []
        for name in mounts:
            items.append({
                "item": name,
                "params": {},
                "metrics": [
                    "op_s", "rpc_backlog",
                    "read_ops", "read_b_s", "read_b_op", "read_retrans",
                    "read_avg_rtt_s", "read_avg_exe_s",
                    "write_ops_s", "write_b_s", "write_b_op", "write_retrans",
                    "write_avg_rtt_s", "write_avg_exe_s",
                ],
            })
        return {"changed": False, "msg": "discovered %d mounts" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    if res.rc != 0:
        return {"changed": False, "msg": "nfsiostat failed (rc=%d)" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}

    mounts = _parse_nfsiostat(res.stdout)

    if item not in mounts:
        return {"changed": False, "msg": "NFS mount not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    d = mounts[item]

    checks = [
        ("op_s",            d.get("op_s", 0.0),            params.get("op_s"),            "/s"),
        ("rpc_backlog",     d.get("rpc_backlog", 0.0),      params.get("rpc_backlog"),     ""),
        ("read_ops",        d.get("read_ops", 0.0),         params.get("read_ops"),        "/s"),
        ("read_b_s",        d.get("read_b_s", 0.0),         params.get("read_b_s"),        " kB/s"),
        ("read_b_op",       d.get("read_b_op", 0.0),        params.get("read_b_op"),       " kB/op"),
        ("read_retrans",    d.get("read_retrans", 0.0),     params.get("read_retrans"),    "%"),
        ("read_avg_rtt_s",  d.get("read_avg_rtt_s", 0.0),  params.get("read_avg_rtt_s"),  "s"),
        ("read_avg_exe_s",  d.get("read_avg_exe_s", 0.0),  params.get("read_avg_exe_s"),  "s"),
        ("write_ops_s",     d.get("write_ops_s", 0.0),      params.get("write_ops_s"),     "/s"),
        ("write_b_s",       d.get("write_b_s", 0.0),        params.get("write_b_s"),       " kB/s"),
        ("write_b_op",      d.get("write_b_op", 0.0),       params.get("write_b_op"),      " kB/op"),
        ("write_retrans",   d.get("write_retrans", 0.0),    params.get("write_retrans"),   "%"),
        ("write_avg_rtt_s", d.get("write_avg_rtt_s", 0.0), params.get("write_avg_rtt_s"), "s"),
        ("write_avg_exe_s", d.get("write_avg_exe_s", 0.0), params.get("write_avg_exe_s"), "s"),
    ]

    overall = "OK"
    msgs = []
    metrics = {}

    for cname, value, levels, unit in checks:
        cstate, cmsg = _check_upper(value, levels, cname, unit)
        overall = _worst(overall, cstate)
        msgs.append(cmsg)
        metrics[cname] = value

    summary = "Ops: %f/s, Read: %f kB/s, Write: %f kB/s" % (
        d.get("op_s", 0.0), d.get("read_b_s", 0.0), d.get("write_b_s", 0.0))

    return {"changed": False, "msg": summary,
            "data": {"state": overall, "metrics": metrics, "details": "\n".join(msgs)}}