STATUS_TEXT_MAP = {
    "on-line": ("OK", "online"),
    "online": ("OK", "online"),
    "initializing": ("OK", "initialization"),
    "quiescent": ("WARN", "quiescent"),
    "fast recovery": ("WARN", "recovery"),
    "recovery": ("WARN", "recovery"),
    "backup": ("WARN", "backup"),
    "shutdown": ("CRIT", "shutdown"),
    "abort": ("WARN", "abort"),
    "single-user": ("WARN", "single user"),
    "single user": ("WARN", "single user"),
    "off-line": ("CRIT", "offline"),
    "offline": ("CRIT", "offline"),
}

INFORMIX_SEARCH_DIRS = [
    "/opt/IBM/informix",
    "/opt/informix",
    "/usr/informix",
    "/home/informix",
    "/opt/ibm/informix",
]

def _find_informix_dir(ctx):
    for d in INFORMIX_SEARCH_DIRS:
        if ctx.file_exists(d + "/bin/onstat"):
            return d
    return None

def _parse_sqlhosts(ctx, informix_dir):
    path = informix_dir + "/etc/sqlhosts"
    if not ctx.file_exists(path):
        return {}
    content = ctx.file_read(path)
    result = {}
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) >= 4:
            result[parts[0]] = {"protocol": parts[1], "host": parts[2], "service": parts[3]}
        elif len(parts) >= 1:
            result[parts[0]] = {}
    return result

def main(ctx, params):
    informix_dir = params.get("informix_dir", "")
    if not informix_dir:
        informix_dir = _find_informix_dir(ctx)

    if params.get("_discover"):
        if not informix_dir:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        hosts_info = _parse_sqlhosts(ctx, informix_dir)
        facts = ctx.facts()
        hostname = facts.get("hostname", "")
        disc = []
        for inst in hosts_info:
            info = hosts_info[inst]
            inst_host = info.get("host", "")
            if inst_host in ("localhost", "127.0.0.1", "", hostname):
                disc.append({
                    "item": inst,
                    "params": {"informix_dir": informix_dir},
                    "metrics": [],
                })
        return {"changed": False, "msg": "discovered %d items" % len(disc),
                "data": {"discovery": disc}}

    item = params.get("item", "")

    if not informix_dir:
        return {"changed": False, "msg": item + ": Informix installation not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    onstat_bin = informix_dir + "/bin/onstat"
    if not ctx.file_exists(onstat_bin):
        return {"changed": False, "msg": item + ": onstat not found at " + onstat_bin,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    onconfig = "onconfig." + item if item else "onconfig"
    res = ctx.run(
        ["env",
         "INFORMIXSERVER=" + item,
         "INFORMIXDIR=" + informix_dir,
         "INFORMIXSQLHOSTS=" + informix_dir + "/etc/sqlhosts",
         "ONCONFIG=" + onconfig,
         onstat_bin, "-"],
        mutates=False,
        ok_codes=[0, 1, 2, 3, 4],
    )

    output = res.stdout if res.stdout else res.stderr
    if not output:
        return {"changed": False, "msg": item + ": no output from onstat",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    first_line = ""
    for ln in output.splitlines():
        if ln.strip():
            first_line = ln.strip()
            break

    state = "UNKNOWN"
    state_readable = "unknown"
    version = ""

    # "IBM Informix Dynamic Server Version X.Y.ZN -- Status -- Up ..."
    if "Version" in first_line:
        after_ver = first_line.split("Version", 1)[1].strip()
        ver_parts = after_ver.split()
        if ver_parts:
            version = ver_parts[0]

    for segment in [p.strip() for p in first_line.split("--")]:
        seg_lower = segment.lower()
        if seg_lower in STATUS_TEXT_MAP:
            state, state_readable = STATUS_TEXT_MAP[seg_lower]
            break

    if state == "UNKNOWN":
        out_lower = output.lower()
        if "off-line" in out_lower or "offline" in out_lower or "cannot attach" in out_lower or "shared memory" in out_lower:
            state = "CRIT"
            state_readable = "offline"

    hosts_info = _parse_sqlhosts(ctx, informix_dir)
    port = ""
    if item in hosts_info:
        proto = hosts_info[item].get("protocol", "")
        svc = hosts_info[item].get("service", "")
        if proto and svc:
            port = proto + " " + svc

    msg = "Status: " + state_readable
    if version:
        msg += ", Version: " + version
    if port:
        port_parts = port.split(" ")
        port_num = port_parts[1] if len(port_parts) >= 2 else port
        msg += ", Port: " + port_num

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}