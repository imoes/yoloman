def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    det = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    present = False
    if det.rc == 0:
        target = ".1.3.6.1.4.1.26546.1.1.2"
        v = det.stdout.strip()
        if v == target or v.endswith(" = " + target):
            present = True

    if not present:
        return {"changed": False, "msg": "no cpsecuresuite system found", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "",
        }}

    base = ".1.3.6.1.4.1.26546.3.1.2.1.1.1"

    def _get_col(oid):
        r = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv", host, oid,
        ], mutates=False)
        if r.rc != 0 or not r.stdout:
            return None
        return r.stdout.strip()

    def _walk_col(colnum):
        r = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, base + "." + colnum,
        ], mutates=False)
        out = []
        if r.rc != 0 or not r.stdout:
            return out
        for line in r.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            idx = oid[len(base + "." + colnum):]
            if idx.startswith("."):
                idx = idx[1:]
            out.append((idx, val))
        return out

    if params.get("_discover"):
        col1 = _walk_col("1")
        col2 = _walk_col("2")
        by_idx = {}
        for idx, val in col2:
            by_idx[idx] = {"enabled": val}
        for idx, val in col1:
            if idx not in by_idx:
                by_idx[idx] = {}
            by_idx[idx]["service"] = val
        discovery = []
        seen = []
        for idx in sorted(by_idx):
            e = by_idx[idx]
            svc = e.get("service")
            en = e.get("enabled")
            if svc == None or en == None:
                continue
            if en == "1" and svc not in seen:
                seen.append(svc)
                discovery.append({"item": svc, "params": {}, "metrics": ["Sessions"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    col1 = _walk_col("1")
    col2 = _walk_col("2")
    col3 = _walk_col("3")
    by_idx = {}
    for idx, val in col2:
        by_idx[idx] = {"enabled": val}
    for idx, val in col1:
        if idx not in by_idx:
            by_idx[idx] = {}
        by_idx[idx]["service"] = val
    for idx, val in col3:
        if idx not in by_idx:
            by_idx[idx] = {}
        by_idx[idx]["sessions"] = val

    for idx in sorted(by_idx):
        e = by_idx[idx]
        if e.get("service") != item:
            continue
        en = e.get("enabled")
        sess = e.get("sessions")
        if en != "1":
            return {"changed": False, "msg": "service not enabled", "data": {
                "state": "WARN", "metrics": {}, "details": "",
            }}
        if sess == None or not sess.isdigit():
            return {"changed": False, "msg": "no session data", "data": {
                "state": "UNKNOWN", "metrics": {}, "details": "",
            }}
        n = int(sess)
        warn = 2500
        crit = 5000
        state = "OK"
        if n >= crit:
            state = "CRIT"
        elif n >= warn:
            state = "WARN"
        return {"changed": False, "msg": "%s Sessions: %d" % (item, n), "data": {
            "state": state, "metrics": {"Sessions": n}, "details": "",
        }}

    return {"changed": False, "msg": "no such service: " + item, "data": {
        "state": "UNKNOWN", "metrics": {}, "details": "",
    }}