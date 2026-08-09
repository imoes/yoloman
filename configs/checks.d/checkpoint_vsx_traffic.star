# Checkmk check: checkpoint_vsx_traffic (translated to read-only Starlark)
#
# Monitors Check Point VSX traffic counters (bytes_accepted / bytes_dropped /
# bytes_rejected) per Virtual System, read live from the VSX Gateway via SNMP.
# The check is READ-ONLY: it only walks SNMP; it never mutates the system.
#
# OIDs (per the source plugin):
#   status tree base: .1.3.6.1.4.1.2620.1.16.22.1.1
#       oids: 1 (vs_id), 3 (vs_name), 4 (vs_ip), 5 (vs_policy),
#             6 (vs_policy_type), 7 (vs_sic_status), 8 (vs_ha_status),
#             9 (conn_num)
#   counter tree base: .1.3.6.1.4.1.2620.1.16.23.1.1
#       oids: 2 (conn_table_size), 4 (packets), 5 (packets_dropped),
#             6 (packets_accepted), 7 (packets_rejected),
#             8 (bytes_accepted), 9 (bytes_dropped),
#             10 (bytes_rejected), 11 (logged), 12 (packets_logged)
#
# Discovery item = "vs_name vs_id" (e.g. "my_vsid 0"), one service per VS that
# has bytes_accepted present (non-None).

# --- metric name -> perfdata key mapping (mirrors check_ruleset_name) ----------
# The check reports one counter per metric; get_rate is approximated from the
# absolute counter since this read-only probe fetches a single snapshot.
TRAFFIC_COLS = {
    "bytes_accepted": "8",
    "bytes_dropped": "9",
    "bytes_rejected": "10",
}

# Labels applied per discovered service (stable facts about the VS item).
# Emitted only when the data is actually present from the device.

def _snmp_get(ctx, community, host, oid):
    """Fetch a single scalar via snmpget -Oqv (bare value)."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout

def _snmp_walk(ctx, community, host, oid):
    """Walk a column OID with snmpwalk -Oqn (one 'OID INDEX VALUE' line per row)."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    return res.stdout.splitlines()

def _strip_type_tag(raw):
    """Strip a leading 'TYPE: ' tag and surrounding quotes left by -Ov."""
    if raw == None:
        return ""
    s = raw
    idx = s.find(": ")
    if idx >= 0:
        s = s[idx + 2:]
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    elif len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        s = s[1:-1]
    return s

def _walk_to_index(rows):
    """Turn snmpwalk -Oqn rows into {index: value}, preserving order via list."""
    out = []
    for line in rows:
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        out.append((oid, val))
    return out

def _gather_instances(ctx, community, host):
    """
    Gather all VSX VS instances from the two SNMP tables.

    Returns a dict: "vs_name vs_id" -> instance dict, or None if the device
    is not a Checkpoint VSX Gateway (no status rows at all — absence is an
    answer, not a placeholder).
    """
    status_base = ".1.3.6.1.4.1.2620.1.16.22.1.1"
    counter_base = ".1.3.6.1.4.1.2620.1.16.23.1.1"

    # Status table: index = instance index, columns 1..9
    # Column mapping (source parse order):
    #   1 vs_id, 3 vs_name, 4 vs_ip, 5 vs_policy, 6 vs_policy_type,
    #   7 vs_sic_status, 8 vs_ha_status, 9 conn_num
    # We walk each column by index. The shared instance INDEX is the OID suffix
    # after the column base + ".".
    #
    # To recover the index reliably we walk column "1" (vs_id) and use its
    # indexes as the canonical set, then fetch the other columns per index.
    vs_id_rows = _snmp_walk(ctx, community, host, status_base + ".1")
    if len(vs_id_rows) == 0:
        # No VSX instances at all -> device is not a Checkpoint VSX Gateway.
        return None

    # Canonical index list (preserve discovery order = first occurrence wins,
    # but the source reverses; we keep natural order which is equivalent for
    # the non-duplicate case the source comments note doesn't matter).
    indexes = []
    for oid, val in _walk_to_index(vs_id_rows):
        idx = oid[len(status_base + ".1") + 1:]
        if idx == "":
            idx = "0"
        indexes.append(idx)

    # Helper: fetch a column value for a given instance index.
    def col_value(base, col, idx):
        oid = base + "." + col + "." + idx
        raw = _snmp_get(ctx, community, host, oid)
        if raw == None:
            return None
        return _strip_type_tag(raw)

    instances = {}
    # Counter columns we need for traffic (bytes_accepted/dropped/rejected).
    # Source parse order includes: 2 conn_table_size, 4 packets, 5 packets_dropped,
    # 6 packets_accepted, 7 packets_rejected, 8 bytes_accepted, 9 bytes_dropped,
    # 10 bytes_rejected, 11 logged, 12 packets_logged.
    for idx in indexes:
        vs_id = col_value(status_base, "1", idx)
        vs_name = col_value(status_base, "3", idx)
        vs_ip = col_value(status_base, "4", idx)
        vs_policy = col_value(status_base, "5", idx)
        vs_policy_type = col_value(status_base, "6", idx)
        vs_sic_status = col_value(status_base, "7", idx)
        vs_ha_status = col_value(status_base, "8", idx)
        conn_num = col_value(status_base, "9", idx)
        conn_table_size = col_value(counter_base, "2", idx)
        packets = col_value(counter_base, "4", idx)
        packets_dropped = col_value(counter_base, "5", idx)
        packets_accepted = col_value(counter_base, "6", idx)
        packets_rejected = col_value(counter_base, "7", idx)
        bytes_accepted = col_value(counter_base, "8", idx)
        bytes_dropped = col_value(counter_base, "9", idx)
        bytes_rejected = col_value(counter_base, "10", idx)
        logged = col_value(counter_base, "11", idx)
        packets_logged = col_value(counter_base, "12", idx)

        if vs_name == None:
            vs_name = ""
        if vs_id == None:
            vs_id = "0"
        item = vs_name + " " + vs_id

        def _i(s):
            if s == None or s == "":
                return None
            if s.lstrip("-").isdigit():
                return int(s)
            return None

        instances[item] = {
            "vs_name": vs_name,
            "vs_type": "VSX Gateway",
            "vs_sic_status": vs_sic_status,
            "vs_ha_status": vs_ha_status,
            "vs_ip": vs_ip,
            "vs_policy": vs_policy,
            "vs_policy_type": vs_policy_type,
            "conn_num": _i(conn_num),
            "conn_table_size": _i(conn_table_size),
            "packets": _i(packets),
            "packets_dropped": _i(packets_dropped),
            "packets_accepted": _i(packets_accepted),
            "packets_rejected": _i(packets_rejected),
            "bytes_accepted": _i(bytes_accepted),
            "bytes_dropped": _i(bytes_dropped),
            "bytes_rejected": _i(bytes_rejected),
            "logged": logged,
            "packets_logged": _i(packets_logged),
        }
    return instances


def _grade_upper(value, levels):
    """
    Apply 'upper' threshold grading (WARN if value >= warn, CRIT if >= crit).
    levels is a tuple (warn, crit) or None. Returns ("OK"|"WARN"|"CRIT"|"UNKNOWN", warn, crit).
    """
    if value == None:
        return "UNKNOWN", None, None
    if levels == None:
        return "OK", None, None
    warn = levels[0]
    crit = levels[1]
    if crit != None and value >= crit:
        return "CRIT", warn, crit
    if warn != None and value >= warn:
        return "WARN", warn, crit
    return "OK", warn, crit


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    metric = params.get("metric", "bytes_accepted")

    # Default thresholds mirror the source check's check_default_parameters:
    #   "bytes_accepted": ("no_levels", None),
    #   "bytes_dropped":  ("no_levels", None),
    #   "bytes_rejected": ("no_levels", None)
    # i.e. no default levels — operators configure them under check_ruleset_name.
    levels = params.get("levels", None)
    levels_upper = params.get("levels_upper", None)

    instances = _gather_instances(ctx, community, host)
    if instances == None:
        # Device is not a Checkpoint VSX Gateway, or SNMP unreachable for the
        # status table. Absence is an answer: report it, do not invent data.
        if params.get("_discover"):
            return {"changed": False, "msg": "no VSX instances found on this host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no VSX instances found on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        out = []
        for it, data in instances.items():
            if data.get(metric) == None:
                # Traffic check only discovers VSs that have this byte counter.
                continue
            out.append({
                "item": it,
                "params": {"levels_upper": levels_upper, "levels": levels},
                "metrics": [metric],
                "service_labels": {
                    "vsx/vs_name": data.get("vs_name", ""),
                    "vsx/vs_ip": data.get("vs_ip", ""),
                    "vsx/vs_policy": data.get("vs_policy", ""),
                    "vsx/vs_policy_type": data.get("vs_policy_type", ""),
                    "vsx/vs_ha_status": data.get("vs_ha_status", ""),
                    "vsx/vs_sic_status": data.get("vs_sic_status", ""),
                },
            })
        return {"changed": False,
                "msg": "discovered %d VSX traffic instances" % len(out),
                "data": {"discovery": out}}

    # ---- CHECK MODE ----
    if item not in instances:
        return {"changed": False, "msg": "VS " + item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = instances[item]
    counter = data.get(metric)
    if counter == None:
        return {"changed": False, "msg": "VS " + item + " has no " + metric + " counter",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # The source check uses get_rate() vs. an absolute counter over time to
    # compute bytes/sec. This read-only probe holds a single snapshot per run,
    # so we report the absolute counter value (bytes) with the configured
    # upper levels. Grading is upper-based (higher = worse).
    state, warn, crit = _grade_upper(counter, levels_upper)

    # Metric name in the source is the key itself (e.g. "bytes_accepted").
    metrics = {metric: counter}

    details = "VS: %s\n" % data.get("vs_name", item)
    details += "Metric %s = %d bytes (absolute snapshot)\n" % (metric, counter)
    if warn != None:
        details += "Upper levels: %s" % str(warn)
    if crit != None:
        details += " / %s" % str(crit)

    summary = metric + ": " + str(counter) + " bytes"
    if state != "OK":
        summary += " (%s)" % state

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": details}}