# Checkmk check translation: sap_hana_replication_status
# Read-only Starlark check module for the yolo-man agent.
# Reproduces the discovery + check logic from the Checkmk plugin, reading the
# REAL on-host data source (the SAP HANA CLI tools) rather than Checkmk itself.

# Map of system replication status codes to (state, readable, param_key).
# Mirrors the (omitted) lib.sap_hana.get_replication_state helper.
REPLICATION_STATES = {
    "0":  {"state": "UNKNOWN", "readable": "uninitialized",    "param": "state_ok"},
    "1":  {"state": "UNKNOWN", "readable": "undefined",        "param": "state_ok"},
    "2":  {"state": "UNKNOWN", "readable": "not found",        "param": "state_ok"},
    "3":  {"state": "UNKNOWN", "readable": "not configured",   "param": "state_ok"},
    "4":  {"state": "OK",      "readable": "active",           "param": "state_ok"},
    "10": {"state": "OK",      "readable": "active",           "param": "state_ok"},
    "11": {"state": "OK",      "readable": "synced",           "param": "state_ok"},
    "12": {"state": "OK",      "readable": "copy",             "param": "state_ok"},
    "13": {"state": "CRIT",    "readable": "sync error",       "param": "state_crit"},
    "14": {"state": "CRIT",    "readable": "copy error",       "param": "state_crit"},
    "15": {"state": "WARN",    "readable": "sync inactive",    "param": "state_warn"},
    "16": {"state": "WARN",    "readable": "sync stopping",    "param": "state_warn"},
    "17": {"state": "OK",      "readable": "syncing",          "param": "state_ok"},
    "18": {"state": "OK",      "readable": "pending",          "param": "state_ok"},
}

def _get_replication_state(status):
    """Map a SAP HANA system replication status code.

    Returns a tuple (state, readable, param_key). Mirrors
    lib.sap_hana.get_replication_state from the Checkmk plugin.
    """
    if status == None:
        return ("UNKNOWN", "no status", "state_ok")
    info = REPLICATION_STATES.get(status)
    if info == None:
        return ("UNKNOWN", "unknown status: %s" % status, "state_ok")
    return (info["state"], info["readable"], info["param"])

def _token(line):
    """Lowercased first whitespace-delimited token of a line."""
    if line == None:
        return ""
    parts = line.strip().split()
    if len(parts) == 0:
        return ""
    return parts[0].lower()

def _parse_instance_block(lines, start):
    """Parse one sid_instance block starting at index `start` in `lines`.

    Returns (instance_name, data_dict, next_index). A block is a sequence of
    'mode:', 'systemreplicationstatus:'/'returncode:' entries, optionally
    prefixed by an instance header line of the form 'SID:INSTANCE' or
    'SID:INSTANCE:'.
    """
    inst = {}
    name = ""
    i = start
    while i < len(lines):
        ln = lines[i].strip()
        if ln == "":
            i = i + 1
            continue
        toks = ln.split()
        key = toks[0].lower() if len(toks) > 0 else ""
        if key == "mode:" or key == "systemreplicationstatus:" or key == "returncode:":
            if len(toks) >= 2:
                val = toks[1]
                if key == "mode:":
                    inst["mode"] = val
                else:
                    inst["sys_repl_status"] = val
            i = i + 1
        elif ":" in key and "mode:" not in key and "systemreplicationstatus:" not in key and "returncode:" not in key:
            # Heuristic instance header: SID:INSTANCE or SID:INSTANCE.
            name = key.replace(":", "")
            i = i + 1
        else:
            # End of this block: back up so the caller sees this line.
            break
    return (name, inst, i)

def _hana_present(ctx):
    """Return True if SAP HANA tooling appears to be installed."""
    for cmd in [["HDB", "--version"], ["hdb", "info"]]:
        res = ctx.run(cmd, mutates=False)
        if res.rc == 0:
            return True
    # Fall back to a `which` probe.
    res = ctx.run(["which", "HDB"], mutates=False)
    if res.rc == 0 and res.stdout.strip() != "":
        return True
    res = ctx.run(["which", "hdb"], mutates=False)
    if res.rc == 0 and res.stdout.strip() != "":
        return True
    return False

def _fetch_replication_data(ctx):
    """Run the on-host SAP HANA replication status command.

    This mirrors the data the Checkmk agent plugin gathers (the
    <<<sap_hana_replication_status>>> section). Returns the raw stdout lines
    and a boolean indicating whether HANA is present.
    """
    if not _hana_present(ctx):
        return ([], False)
    res = ctx.run(["hdbnsutil", "-sr_state"], mutates=False)
    if res.rc != 0:
        # hdbnsutil may not always be on PATH; the instance-scoped tool is
        # <sid>adm's hdb. Try the system-wide `hdbnsutil` again with full path.
        res = ctx.run(["/usr/sap/hostlife", "hdbnsutil", "-sr_state"], mutates=False)
        if res.rc != 0:
            return ([], True)
    lines = res.stdout.splitlines()
    return (lines, True)

def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        present = _hana_present(ctx)
        if not present:
            return {
                "changed": False,
                "msg": "no SAP HANA installation found",
                "data": {"discovery": []},
            }
        lines, _ok = _fetch_replication_data(ctx)
        if len(lines) == 0:
            return {
                "changed": False,
                "msg": "SAP HANA present but no replication data available",
                "data": {"discovery": []},
            }
        section = {}
        idx = 0
        current_name = ""
        current_block = []
        # Group into instance blocks. An instance header is a line whose token
        # contains ':' but is none of the known mode/status keys.
        for line in lines:
            toks = line.strip().split()
            key = toks[0].lower() if len(toks) > 0 else ""
            if key == "mode:" or key == "systemreplicationstatus:" or key == "returncode:":
                current_block.append(line)
            elif ":" in key and key != "mode:" and key != "systemreplicationstatus:" and key != "returncode:":
                # Flush previous block.
                if current_name != "" and len(current_block) > 0:
                    name = current_name
                    inst = {}
                    for bl in current_block:
                        bt = bl.strip().split()
                        bk = bt[0].lower() if len(bt) > 0 else ""
                        if bk == "mode:" and len(bt) >= 2:
                            inst["mode"] = bt[1]
                        elif (bk == "systemreplicationstatus:" or bk == "returncode:") and len(bt) >= 2:
                            inst["sys_repl_status"] = bt[1]
                    section[name] = inst
                current_name = key.replace(":", "")
                current_block = []
            else:
                current_block.append(line)
        # Flush final block.
        if current_name != "" and len(current_block) > 0:
            inst = {}
            for bl in current_block:
                bt = bl.strip().split()
                bk = bt[0].lower() if len(bt) > 0 else ""
                if bk == "mode:" and len(bt) >= 2:
                    inst["mode"] = bt[1]
                elif (bk == "systemreplicationstatus:" or bk == "returncode:") and len(bt) >= 2:
                    inst["sys_repl_status"] = bt[1]
            section[current_name] = inst
        discovery = []
        for sid_instance, data in section.items():
            if not data:
                continue
            sys_status = data.get("sys_repl_status", "")
            mode = data.get("mode", "").lower()
            # Match the discovery predicate from the source plugin.
            if sys_status != "10" and (mode == "primary" or mode == "sync"):
                entry = {
                    "item": sid_instance,
                    "params": {
                        "state_ok": "OK",
                        "state_warn": "WARN",
                        "state_crit": "CRIT",
                        "state_unknown": "UNKNOWN",
                    },
                    "metrics": [],
                }
                discovery.append(entry)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE ----
    item = params.get("item", "")
    present = _hana_present(ctx)
    if not present:
        return {
            "changed": False,
            "msg": "SAP HANA not installed; cannot check replication status",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SAP HANA binary not found on this host",
            },
        }
    lines, _ok = _fetch_replication_data(ctx)
    if len(lines) == 0:
        if item == "":
            return {
                "changed": False,
                "msg": "no SAP HANA replication state available",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "hdbnsutil -sr_state produced no replication data",
                },
            }
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no replication data for item: %s" % item,
            },
        }

    # Parse into instance blocks the same way discovery does.
    section = {}
    current_name = ""
    current_block = []
    for line in lines:
        toks = line.strip().split()
        key = toks[0].lower() if len(toks) > 0 else ""
        if key == "mode:" or key == "systemreplicationstatus:" or key == "returncode:":
            current_block.append(line)
        elif ":" in key and key != "mode:" and key != "systemreplicationstatus:" and key != "returncode:":
            if current_name != "" and len(current_block) > 0:
                inst = {}
                for bl in current_block:
                    bt = bl.strip().split()
                    bk = bt[0].lower() if len(bt) > 0 else ""
                    if bk == "mode:" and len(bt) >= 2:
                        inst["mode"] = bt[1]
                    elif (bk == "systemreplicationstatus:" or bk == "returncode:") and len(bt) >= 2:
                        inst["sys_repl_status"] = bt[1]
                section[current_name] = inst
            current_name = key.replace(":", "")
            current_block = []
        else:
            current_block.append(line)
    if current_name != "" and len(current_block) > 0:
        inst = {}
        for bl in current_block:
            bt = bl.strip().split()
            bk = bt[0].lower() if len(bt) > 0 else ""
            if bk == "mode:" and len(bt) >= 2:
                inst["mode"] = bt[1]
            elif (bk == "systemreplicationstatus:" or bk == "returncode:") and len(bt) >= 2:
                inst["sys_repl_status"] = bt[1]
        section[current_name] = inst

    # Resolve the requested item. If item == "" pick the single block, or the
    # unique block present (matching a single-service fallback).
    data = None
    if item != "":
        data = section.get(item)
    else:
        keys = list(section.keys())
        if len(keys) == 1:
            data = section[keys[0]]
        elif len(keys) > 1:
            # Multiple instances but no item specified: cannot pick.
            data = None

    if data == None or len(data) == 0:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no replication data for item: %s" % item,
            },
        }

    sys_repl_status = data.get("sys_repl_status", "")
    if not sys_repl_status:
        sys_repl_status = "0"

    state, state_readable, param_key = _get_replication_state(sys_repl_status)
    final_state = params.get(param_key, state)

    summary = "System replication: %s" % state_readable
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": {},
            "details": summary,
        },
    }