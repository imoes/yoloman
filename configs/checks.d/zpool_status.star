# Checkmk check plugin: zpool_status
# Translated to a read-only Starlark check module for the yolo-man agent.
# Monitors ZFS pool status. Never uses the Checkmk agent; reads `zpool status`
# directly on the host.

# Maps a pool vdev state token to a Checkmk-style level and human message.
# Mirrors the source's state_mappings (which maps State.* constants).
# Lower states (DEGRADED) -> WARN, faulted/removed/unavail -> CRIT.
state_mappings = {
    "ONLINE": {"state": "OK", "message": ""},
    "DEGRADED": {"state": "WARN", "message": "DEGRADED State"},
    "FAULTED": {"state": "CRIT", "message": "FAULTED State"},
    "UNAVIL": {"state": "CRIT", "message": "UNAVIL State"},
    "REMOVED": {"state": "CRIT", "message": "REMOVED State"},
    "OFFLINE": {"state": "OK", "message": ""},
}


# Rank helper so a higher state value wins (OK=0, WARN=1, CRIT=2).
def _state_rank(state):
    if state == "CRIT":
        return 2
    if state == "WARN":
        return 1
    return 0


def _higher(a, b):
    """Return whichever of the two states (a, b) is more severe."""
    return a if _state_rank(a) >= _state_rank(b) else b


def main(ctx, params):
    # ---- probe for the real thing ----
    # `zpool` must exist and be executable. rc == 127 means "not installed".
    probe = ctx.run(["zpool", "status"], mutates=False)
    if probe.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "zpool not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "zpool not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # ---- discovery mode ----
    if params.get("_discover"):
        # The zpool_status check is a single-service check (no per-item
        # breakdown in the original discover_zpool_status: it yields one
        # Service() unconditionally, provided pools exist).
        # Reproduce the "no pools available" guard from parse_zpool_status.
        first_line = probe.stdout.splitlines()[0] if probe.stdout else ""
        if first_line.strip() == "no pools available":
            return {"changed": False, "msg": "no pools available",
                    "data": {"discovery": []}}
        if first_line.strip() == "all pools are healthy":
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    # ---- check mode (single service, item="") ----
    item = params.get("item", "")

    # Parse the `zpool status` output. The source parser (parse_zpool_status)
    # consumes a StringTable (list of whitespace-split token lists) produced by
    # the zpool_status agent section. We reproduce the same tokenisation by
    # splitting each line on whitespace.
    lines = probe.stdout.splitlines()
    string_table = []
    for l in lines:
        tokens = l.split()
        if len(tokens) == 0:
            continue
        string_table.append(tokens)

    # Mirror the parse function's early returns.
    if len(string_table) == 0:
        return {"changed": False, "msg": "no zpool output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    joined_first = " ".join(string_table[0])
    if joined_first == "all pools are healthy":
        return {"changed": False,
                "msg": "zpool status: All pools are healthy",
                "data": {"state": "OK", "metrics": {},
                         "details": "All pools are healthy"}}

    if joined_first == "no pools available":
        return {"changed": False, "msg": "no pools available",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "No pools available"}}

    # Reproduce parse_zpool_status logic.
    start_pool = False
    multiline = False
    last_pool = ""
    error_pools = {}
    warning_pools = {}
    pool_messages = {}
    state_messages = []

    for line in string_table:
        tag = line[0]
        if tag == "pool:":
            last_pool = line[1]
            pool_messages.setdefault(last_pool, [])

        elif tag == "state:":
            state_messages.append(line[1])

        elif tag in ["status:", "action:"]:
            joined = " ".join(line[1:])
            pool_messages.setdefault(last_pool, []).append(joined)
            multiline = True

        elif tag in ["scrub:", "see:", "scan:", "config:"]:
            multiline = False

        elif tag == "NAME":
            multiline = False
            start_pool = True

        elif tag == "errors:":
            multiline = False
            start_pool = False
            msg = " ".join(line[1:])
            if msg != "No known data errors":
                pool_messages.setdefault(last_pool, []).append(msg)

        elif tag in ["spares", "logs", "cache", "special"]:
            start_pool = False
            continue

        elif start_pool and tag.lower() != "dedup":
            # Need at least 5 columns to read the CKSUM count safely.
            if len(line) >= 5:
                if line[1] != "ONLINE":
                    error_pools[line[0]] = tuple(line[1:])
                else:
                    cksum = line[4]
                    cksum_int = int(cksum) if cksum.lstrip("-").isdigit() else 0
                    if cksum_int != 0:
                        # Mimic saveint(msg[3]); store the raw token tuple.
                        warning_pools[line[0]] = tuple(line[1:])

        elif multiline:
            joined = " ".join(line)
            pool_messages.setdefault(last_pool, []).append(joined)

    # Reproduce check_zpool_status verdict logic.
    state = "OK"
    messages = []

    for msg in state_messages:
        details = state_mappings.get(msg)
        if details:
            state = _higher(state, details["state"])
            if details["message"]:
                messages.append(details["message"])
        else:
            state = _higher(state, "WARN")
            messages.append("Unknown State")

    for pool, msg in pool_messages.items():
        state = _higher(state, "WARN")
        messages.append("%s: %s" % (pool, " ".join(msg)))

    for pool, msg in warning_pools.items():
        # The source formats: pool CKSUM: <c ksum count>
        # msg[3] is the CKSUM count; guard for short tuples.
        cksum_val = ""
        if len(msg) >= 4:
            cksum_val = str(msg[3])
        else:
            cksum_val = "0"
        state = _higher(state, "WARN")
        messages.append("%s CKSUM: %s" % (pool, cksum_val))

    for pool, msg in error_pools.items():
        state = _higher(state, "CRIT")
        # msg[0] is the vdev's state token.
        err_state = msg[0] if len(msg) >= 1 else "UNKNOWN"
        messages.append("%s state: %s" % (pool, err_state))

    if len(messages) == 0:
        messages.append("No critical errors")

    return {"changed": False,
            "msg": "zpool status: " + ", ".join(messages),
            "data": {"state": state, "metrics": {},
                     "details": ", ".join(messages)}}