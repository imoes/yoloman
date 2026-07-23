def _safe_int(s):
    if s == None:
        return 0
    t = str(s).strip()
    if t == "":
        return 0
    if t.isdigit():
        return int(t)
    if t.startswith("-") and len(t) > 1 and t[1:].isdigit():
        return int(t)
    return 0

_AUTH_SCRIPT = "import hashlib,sys;u,p=sys.argv[1],sys.argv[2];ph=hashlib.md5(p.encode()).hexdigest();print(hashlib.md5((u+'_'+ph).encode()).hexdigest())"

def _compute_auth_hash(ctx, username, password):
    res = ctx.run([
        "python3", "-c", _AUTH_SCRIPT, username, password
    ], mutates=False)
    if res.rc != 0:
        return None
    h = res.stdout.strip()
    if not h:
        return None
    return h

def _login(ctx, host, auth_hash):
    res = ctx.run([
        "curl", "-k", "-s", "-m", "30",
        "-H", "datatype: json",
        "https://" + host + "/api/" + auth_hash
    ], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout.strip():
        return None
    data = json.decode(res.stdout)
    status_list = data.get("status", [])
    if not status_list:
        return None
    resp = status_list[0]
    if resp.get("response-type") != "success":
        return None
    key = resp.get("response", "")
    if not key:
        return None
    return key

def _fetch_volumes(ctx, host, session_key):
    res = ctx.run([
        "curl", "-k", "-s", "-m", "30",
        "-H", "datatype: json",
        "-H", "sessionKey: " + session_key,
        "https://" + host + "/api/show/volume-statistics"
    ], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout.strip():
        return None
    data = json.decode(res.stdout)
    return data.get("volume-statistics", [])

def _grade(bps, warn, crit):
    if crit != None and bps >= crit:
        return "CRIT"
    if warn != None and bps >= warn:
        return "WARN"
    return "OK"

def _worst(a, b):
    if a == "CRIT" or b == "CRIT":
        return "CRIT"
    if a == "WARN" or b == "WARN":
        return "WARN"
    return "OK"

def main(ctx, params):
    host     = params.get("host", "localhost")
    username = params.get("username", "manage")
    password = params.get("password", "!manage")

    auth_hash = _compute_auth_hash(ctx, username, password)
    if auth_hash == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "auth hash computation failed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "auth hash computation failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    session_key = _login(ctx, host, auth_hash)
    if session_key == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "HP MSA login failed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "HP MSA login failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    volumes = _fetch_volumes(ctx, host, session_key)
    if volumes == None:
        if params.get("_discover"):
            return {"changed": False, "msg": "failed to fetch volume statistics",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "failed to fetch volume statistics",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        items = []
        for vol in volumes:
            name = vol.get("volume-name", "")
            if name:
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["read_throughput", "write_throughput",
                                "read_ios", "write_ios", "iops"],
                })
        if items:
            items.append({
                "item": "SUMMARY",
                "params": {},
                "metrics": ["read_throughput", "write_throughput",
                            "read_ios", "write_ios", "iops"],
            })
        return {"changed": False,
                "msg": "discovered %d volumes" % len(items),
                "data": {"discovery": items}}

    item    = params.get("item", "")
    warn_rt = params.get("warn_read_throughput", None)
    crit_rt = params.get("crit_read_throughput", None)
    warn_wt = params.get("warn_write_throughput", None)
    crit_wt = params.get("crit_write_throughput", None)

    if item == "SUMMARY":
        acc = {"read": 0, "write": 0, "read_ios": 0,
               "write_ios": 0, "iops": 0, "bps": 0}
        for vol in volumes:
            acc["read"]      += _safe_int(vol.get("data-read-numeric"))
            acc["write"]     += _safe_int(vol.get("data-written-numeric"))
            acc["read_ios"]  += _safe_int(vol.get("number-of-reads"))
            acc["write_ios"] += _safe_int(vol.get("number-of-writes"))
            acc["iops"]      += _safe_int(vol.get("iops"))
            acc["bps"]       += _safe_int(vol.get("bytes-per-second-numeric"))

        bps      = acc["bps"]
        bps_mbs  = bps // (1024 * 1024)
        read_mb  = acc["read"]  // (1024 * 1024)
        write_mb = acc["write"] // (1024 * 1024)
        st = _worst(_grade(bps, warn_rt, crit_rt),
                    _grade(bps, warn_wt, crit_wt))
        msg = "Read: %d MB, Write: %d MB, Throughput: %d MB/s, IOPS: %d" % (
            read_mb, write_mb, bps_mbs, acc["iops"])
        return {"changed": False, "msg": msg,
                "data": {"state": st,
                         "metrics": {
                             "read_throughput":  bps,
                             "write_throughput": bps,
                             "read_ios":         acc["read_ios"],
                             "write_ios":        acc["write_ios"],
                             "iops":             acc["iops"],
                         },
                         "details": ""}}

    target = None
    for vol in volumes:
        if vol.get("volume-name") == item:
            target = vol
            break

    if target == None:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    read_bytes  = _safe_int(target.get("data-read-numeric"))
    write_bytes = _safe_int(target.get("data-written-numeric"))
    read_ios    = _safe_int(target.get("number-of-reads"))
    write_ios   = _safe_int(target.get("number-of-writes"))
    iops        = _safe_int(target.get("iops"))
    bps         = _safe_int(target.get("bytes-per-second-numeric"))
    vdisk       = target.get("virtual-disk-name", "")
    raidtype    = target.get("raidtype", "")

    st       = _worst(_grade(bps, warn_rt, crit_rt),
                      _grade(bps, warn_wt, crit_wt))
    read_mb  = read_bytes  // (1024 * 1024)
    write_mb = write_bytes // (1024 * 1024)
    bps_mbs  = bps         // (1024 * 1024)

    details = ""
    if vdisk and raidtype:
        details = vdisk + " (" + raidtype + ")"
    elif vdisk:
        details = vdisk

    msg = "%s - Read: %d MB, Write: %d MB, Throughput: %d MB/s, IOPS: %d" % (
        item, read_mb, write_mb, bps_mbs, iops)
    return {"changed": False, "msg": msg,
            "data": {"state": st,
                     "metrics": {
                         "read_throughput":  bps,
                         "write_throughput": bps,
                         "read_ios":         read_ios,
                         "write_ios":        write_ios,
                         "iops":             iops,
                     },
                     "details": details}}