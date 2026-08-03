# ===== check plugin: cmk.plugins.tsm_stagingpools (read-only Starlark) =====
# Translated from the Checkmk check_plugin tsm_stagingpools.
# The Checkmk agent section <<<tsm_stagingpools>>> is produced by an agent
# plug-in that runs on the TSM server and parses `db2pd` output. We read the
# same raw source the agent plug-in would use: the `tsm_stagingpools` data
# produced by `db2pd -db <db> -stagingpools` (or its piped variant). No
# checkmk tooling / special agent is invoked here.

TSM_STAGINGPOOLS_DEFAULT_LEVELS = {
    "free_below": 70,
}

def parse_tsm_stagingpools(string_table):
    """Mirror parse_tsm_stagingpools from the source."""
    parsed = {}

    def add_item(lineinfo):
        inst = lineinfo[0]
        pool = lineinfo[1]
        util = lineinfo[2]
        if inst == "default":
            item = pool
        else:
            item = inst + " / " + pool
        if item not in parsed:
            parsed[item] = []
        parsed[item].append(util.replace(",", "."))

    for line in string_table:
        add_item(line[0:3])
        # The agent plug-in sometimes seems to mix two lines together.
        # Detect and fix that.
        if len(line) == 6:
            add_item(line[3:])
    return parsed


def gather_raw(ctx, params):
    """Reproduce the data the Checkmk agent plug-in reads, on host."""
    db2pd = ctx.run(["db2pd", "--version"], mutates=False)
    if db2pd.rc == 127:
        return None
    db2pd = ctx.run(["db2pd", "-alldbs", "-stagingpools"], mutates=False)
    if db2pd.rc != 0 and not db2pd.skipped:
        return None
    string_table = []
    for line in db2pd.stdout.splitlines():
        if not line:
            continue
        f = line.split()
        if len(f) >= 3:
            string_table.append(f)
    return string_table


def discovery(ctx, params):
    raw = gather_raw(ctx, params)
    if raw == None:
        return {"changed": False, "msg": "no tsm stagingpools data", "data": {"discovery": []}}
    section = parse_tsm_stagingpools(raw)
    discovery = []
    for item in section:
        discovery.append({"item": item, "params": {"free_below": params.get("free_below", TSM_STAGINGPOOLS_DEFAULT_LEVELS["free_below"]), "levels": params.get("levels", (None, None))}, "metrics": ["free", "tapes", "util"]})
    return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}


def check(ctx, params):
    item = params.get("item", "")
    raw = gather_raw(ctx, params)
    if raw == None:
        return {"changed": False, "msg": "no tsm stagingpools data (no db2pd / no TSM)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = parse_tsm_stagingpools(raw)
    if item not in section:
        return {"changed": False, "msg": "item " + item + " not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    free_below = params.get("free_below", TSM_STAGINGPOOLS_DEFAULT_LEVELS["free_below"]) / 100.0
    levels = params.get("levels", (None, None))
    warn = levels[0] if len(levels) > 0 else None
    crit = levels[1] if len(levels) > 1 else None

    num_tapes = 0
    num_free_tapes = 0
    utilization = 0.0
    for util in section[item]:
        util_float = float(util) / 100.0
        utilization += util_float
        num_tapes += 1
        if util_float <= free_below:
            num_free_tapes += 1

    if num_tapes == 0:
        return {"changed": False, "msg": "No tapes in this pool or pool not existant.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if crit != None:
        if num_free_tapes <= crit:
            state = "CRIT"
    if state == "OK" and warn != None:
        if num_free_tapes <= warn:
            state = "WARN"

    details = "Total tapes: %d, Utilization: %f tapes, Tapes less then %f%% full" % (num_tapes, utilization, free_below)
    return {"changed": False, "msg": details, "data": {"state": state, "metrics": {"tapes": num_tapes, "util": utilization, "free": num_free_tapes}, "details": details}}


def main(ctx, params):
    if params.get("_discover"):
        return discovery(ctx, params)
    return check(ctx, params)