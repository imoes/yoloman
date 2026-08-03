# Informix Log Usage — read-only Starlark check module for the yolo-man agent.
# Reproduces cmk/plugins/ibm_informix/agent_based/informix_logusage.py against
# the live Informix sysmaster data source (via onsd/sql tools on the host),
# never through a Checkmk agent.

# Default thresholds from check_default_parameters = {"levels_perc": (80.0, 85.0)}.
DEFAULT_LEVELS_PERC = (80.0, 85.0)

def _parse_logusage(out):
    """Reproduce parse_informix_logusage on raw text lines.

    Builds {instance: [{k: v, ...}, ...]} exactly like the plugin's
    StringTable parser: lines of the form '[[[instance]]]' start a new
    instance; '(constant)'/'LOGUSAGE' rows start a new entry; 'k v'
    rows populate the current entry.
    """
    parsed = {}
    instance = None
    entry = None
    raw = out.split("\n") if out else []
    for line in raw:
        f = line.split()
        if len(f) == 0:
            continue
        if len(f) >= 2 and f[0] == "(constant)" and f[1] == "LOGUSAGE":
            entry = {}
            parsed.setdefault(instance, [])
            parsed[instance].append(entry)
        elif f[0].startswith("[[[") and f[0].endswith("]]]"):
            instance = f[0][3:-3]
        elif entry != None and len(f) >= 2:
            if f[0] == "(expression)":
                idx = f[1].find(":")
                if idx == -1:
                    continue
                k = f[1][:idx]
                v = f[1][idx+1:]
            else:
                k = f[0]
                v = f[1]
            entry.setdefault(k, v)
    return parsed

def _render_bytes(n):
    # Mirror Checkmk's render.bytes for the summary line.
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    sign = ""
    if n < 0:
        sign = "-"
        n = -n
    val = float(n)
    i = 0
    while val >= 1024 and i < len(units) - 1:
        val = val / 1024
        i = i + 1
    if i == 0:
        return sign + "%d B" % n
    return sign + "%f %s" % (val, units[i])

def _render_percent(n):
    return "%f%%" % n

def _probe_informix(ctx):
    """Determine whether Informix client tooling is present on the host."""
    # Prefer the Informix SQL shell; the agent plugin runs against sysmaster.
    candidates = ["onsql", "dbaccess", "sqlca"]
    found = None
    for tool in candidates:
        res = ctx.run(["which", tool], mutates=False)
        if res.rc == 0 and len(res.stdout.strip()) > 0:
            found = res.stdout.strip().split("\n")[0]
            break
    # Also accept the Informix environment marker that the agent plugin relies on.
    if found == None:
        # `id informix` detects the OS informix user (Informix install footprint).
        res = ctx.run(["id", "informix"], mutates=False)
        if res.rc == 0:
            found = "informix"
    return found

def _run_query(ctx, instance):
    """Run the ONSD/sysmaster LOGUSAGE query and return its stdout text.

    This is the data the Checkmk agent plugin would emit under
    <<<informix_logusage>>> — reproduced here against the host's Informix.
    """
    # The real agent plugin issues an ONML query against sysmaster:
    #   DATABASE sysmaster; SELECT * FROM sysdatabases ... LOGUSAGE rows.
    # We invoke onsql (the Informix SQL shell) with a minimal statement.
    # Use -ansi and -quiet to get clean, parseable output.
    stmt = "SELECT dbs_name, sh_pagesize, size, used FROM sysmaster:systraces JOIN sysmaster:sysdatabases ON 1=1"
    # The plugin output is row-oriented text; emulate the agent section rows.
    res = ctx.run(["onsql", "-ansi", "-quiet", stmt], mutates=False)
    if res.rc != 0 and res.rc != 127:
        # Non-zero but tool exists: surface as the raw text anyway.
        pass
    return res

def main(ctx, params):
    # --- DISCOVERY ---
    if params.get("_discover"):
        tool = _probe_informix(ctx)
        if tool == None:
            # Informix is not installed here -> the check does not apply.
            return {"changed": False, "msg": "no informix tooling found",
                    "data": {"discovery": []}}

        # Enumerate Informix instances by listing available databases
        # (the agent section is keyed by instance name).
        res = ctx.run(["onsql", "-ansi", "-quiet",
                       "SELECT dbs_name FROM sysmaster:sysdatabases WHERE dbs_flags=0"],
                      mutates=False)
        instances = []
        for line in (res.stdout.split("\n") if res.stdout else []):
            name = line.strip()
            if len(name) > 0 and not name.startswith("(") and not name.startswith("<<<"):
                instances.append(name)

        discovery = []
        for inst in instances:
            discovery.append({
                "item": inst,
                "params": {"levels_perc": DEFAULT_LEVELS_PERC},
                "metrics": ["file_count", "log_files_total", "log_files_used", "log_files_used_perc"],
            })
        return {"changed": False,
                "msg": "discovered %d informix instances" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK (one item) ---
    item = params.get("item", "")
    levels_perc = params.get("levels_perc", DEFAULT_LEVELS_PERC)

    tool = _probe_informix(ctx)
    if tool == None:
        return {"changed": False,
                "msg": "informix not installed on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Re-query the instance the same way discovery enumerated them, then
    # parse the LOGUSAGE rows for this instance.
    res = ctx.run(["onsql", "-ansi", "-quiet",
                   "SELECT dbs_name, sh_pagesize, size, used FROM sysmaster:systraces"],
                  mutates=False)
    if res.rc == 127 or len(res.stdout.strip()) == 0:
        return {"changed": False,
                "msg": "informix LOGUSAGE data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "onsql returned rc=%d" % res.rc}}

    # Build a synthetic agent-section text block so we can reuse the SAME
    # parser the Checkmk plugin uses — one instance, the requested item.
    # The agent plugin emits rows like the parser expects:
    #   [[[instance]]]
    #   (constant) LOGUSAGE
    #   <key> <value>
    built = [[[item]], "(constant) LOGUSAGE"]
    for line in (res.stdout.split("\n") if res.stdout else []):
        f = line.split()
        if len(f) >= 4:
            built.append("sh_pagesize %s" % f[1])
            built.append("size %s" % f[2])
            built.append("used %s" % f[3])
    text = "\n".join(built)
    section = _parse_logusage(text)

    if item not in section:
        return {"changed": False,
                "msg": "no logusage for instance: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section[item]
    logfiles = len(data)
    if not logfiles:
        return {"changed": False,
                "msg": "Log information missing",
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    size = 0
    used = 0
    for entry in data:
        pagesize = int(entry["sh_pagesize"]) if entry.get("sh_pagesize", "").isdigit() else 0
        size += int(entry["size"]) * pagesize
        used += int(entry["used"]) * pagesize

    warn_p, crit_p = levels_perc
    metrics = {
        "file_count": float(logfiles),
        "log_files_total": float(size),
        "log_files_used": float(used),
    }

    detail = "Files: %d, Size: %s, Used: %s" % (logfiles, _render_bytes(size), _render_bytes(used))
    state = "OK"

    if size > 0:
        perc = used * 100.0 / size
        metrics["log_files_used_perc"] = perc
        # upper levels: WARN if >= warn, CRIT if >= crit
        if perc >= crit_p:
            state = "CRIT"
        elif perc >= warn_p:
            state = "WARN"
        detail = detail + ", Usage: " + _render_percent(perc)

    return {"changed": False,
            "msg": detail,
            "data": {"state": state, "metrics": metrics,
                     "details": "levels_perc = (%f, %f)" % (warn_p, crit_p)}}