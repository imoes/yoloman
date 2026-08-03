# Checkmk check: stormshield_cluster_node (HA Member %s)
# Translated to a read-only Starlark check module.
# Source: SNMP table .1.3.6.1.4.1.11256.1.11.7.1
# Columns: serial(1) online(2) model(3) version(4) license(5)
#          quality(6) priority(7) statusforced(8) active(9) _uptime(10)
# Index: OID suffix of the walked row OID.
# Defaults: quality levels_lower = (80.0, 50.0)

# Column OIDs (suffixes) under base .1.3.6.1.4.1.11256.1.11.7.1
COL_SERIAL = 1
COL_ONLINE = 2
COL_MODEL = 3
COL_VERSION = 4
COL_LICENSE = 5
COL_QUALITY = 6
COL_PRIORITY = 7
COL_STATUSFORCED = 8
COL_ACTIVE = 9
COL_UPTIME = 10

QUALITY_WARN_DEFAULT = 80.0
QUALITY_CRIT_DEFAULT = 50.0

def _is_stormshield_cluster(ctx, host, community):
    # Reproduce DETECT_STORMSHIELD_CLUSTER:
    #   sysID startswith .1.3.6.1.4.1.8072 (Net-SNMP) OR equals .1.3.6.1.4.1.11256.2.0 OR
    #       startswith .1.3.6.1.4.1.11256.1
    #   AND .1.3.6.1.4.1.11256.1.0.1.0 exists
    #   AND .1.3.6.1.4.1.11256.1.11.1.0 exists
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False)
    if sysid_res.rc != 0:
        return False
    sysid_out = sysid_res.stdout.strip()
    if not sysid_out:
        return False
    # snmpget -Ovqn on a single OID returns "<oid> <value>"; the value is the sysID string.
    # Value form: ".1.3.6.1.4.1.11256.2.0" or ".1.3.6.1.4.1.11256.1.x..." etc.
    parts = sysid_out.split()
    if len(parts) < 1:
        return False
    sysid_val = parts[-1]
    matched = False
    if sysid_val.startswith(".1.3.6.1.4.1.8072") or sysid_val == ".1.3.6.1.4.1.11256.2.0" or sysid_val.startswith(".1.3.6.1.4.1.11256.1"):
        matched = True
    if not matched:
        return False
    # Exists .1.3.6.1.4.1.11256.1.0.1.0
    r1 = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.4.1.11256.1.0.1.0"],
        mutates=False)
    if r1.rc != 0:
        return False
    # Exists .1.3.6.1.4.1.11256.1.11.1.0 (HA info)
    r2 = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.4.1.11256.1.11.1.0"],
        mutates=False)
    if r2.rc != 0:
        return False
    return True


def _walk_col(ctx, host, community, base, col):
    # Walk a single column OID with -Oqn: "<oid>.<index> <value>" per line.
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, "%s.%d" % (base, col)],
        mutates=False)
    rows = {}
    if res.rc != 0 or not res.stdout:
        return rows
    for line in res.stdout.splitlines():
        line = line.rstrip()
        if not line:
            continue
        # Split on first space: left=oid, right=value
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[0:sp]
        val = line[sp + 1:]
        idx = oid[len(base) + 1:]
        # If no "." prefix was on base, handle accordingly
        if not oid.startswith(base + "."):
            # oid should start with "<base>." ; index is remainder
            if oid.find(base + ".") != 0:
                continue
        rows[idx] = val
    return rows


def _node_quality(ctx, host, community, base, index):
    # Use the per-index column value: we already gathered all columns in discovery.
    # This helper is unused; kept for clarity.
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for Stormshield cluster device presence.
        if not _is_stormshield_cluster(ctx, host, community):
            return {"changed": False, "msg": "no Stormshield cluster device found",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.11256.1.11.7.1"
        # Walk each column to build the table.
        col_serial = _walk_col(ctx, host, community, base, COL_SERIAL)
        col_online = _walk_col(ctx, host, community, base, COL_ONLINE)
        col_model = _walk_col(ctx, host, community, base, COL_MODEL)
        col_version = _walk_col(ctx, host, community, base, COL_VERSION)
        col_license = _walk_col(ctx, host, community, base, COL_LICENSE)
        col_quality = _walk_col(ctx, host, community, base, COL_QUALITY)
        col_priority = _walk_col(ctx, host, community, base, COL_PRIORITY)
        col_statusforced = _walk_col(ctx, host, community, base, COL_STATUSFORCED)
        col_active = _walk_col(ctx, host, community, base, COL_ACTIVE)

        # Index set: union of indices from any column (serial is the canonical identity)
        indices = list(col_serial.keys())
        # Deduplicate while preserving order
        seen = {}
        uniq_indices = []
        for i in indices:
            if not seen.get(i):
                seen[i] = True
                uniq_indices.append(i)

        out = []
        for index in uniq_indices:
            out.append({
                "item": index,
                "params": {"quality": [QUALITY_WARN_DEFAULT, QUALITY_CRIT_DEFAULT]},
                "metrics": ["quality"],
            })
        return {"changed": False,
                "msg": "discovered %d HA members" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/snmp_monitoring": "stormshield"}}}

    # CHECK MODE
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.11256.1.11.7.1"

    # Gather all columns for the indexed rows.
    col_serial = _walk_col(ctx, host, community, base, COL_SERIAL)
    col_online = _walk_col(ctx, host, community, base, COL_ONLINE)
    col_model = _walk_col(ctx, host, community, base, COL_MODEL)
    col_version = _walk_col(ctx, host, community, base, COL_VERSION)
    col_license = _walk_col(ctx, host, community, base, COL_LICENSE)
    col_quality = _walk_col(ctx, host, community, base, COL_QUALITY)
    col_priority = _walk_col(ctx, host, community, base, COL_PRIORITY)
    col_statusforced = _walk_col(ctx, host, community, base, COL_STATUSFORCED)
    col_active = _walk_col(ctx, host, community, base, COL_ACTIVE)

    # Collect index from any column.
    all_indices = set()
    for m in [col_serial, col_online, col_model, col_version, col_license,
              col_quality, col_priority, col_statusforced, col_active]:
        for k in m.keys():
            all_indices.add(k)

    if item not in all_indices:
        return {"changed": False,
                "msg": "no such HA member: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _val(m, idx, default):
        v = m.get(idx)
        if v == None:
            return default
        return v

    online = _val(col_online, item, "0") == "1"
    active_val = _val(col_active, item, "1")
    forced = _val(col_statusforced, item, "0") == "1"
    state = "active" if active_val == "2" else "passive"
    quality_raw = _val(col_quality, item, "0")
    quality = 0.0
    if quality_raw != None and quality_raw != "":
        try_quality = quality_raw
        # strip any non-numeric suffix
        # quality is a float string like "100.0"
        dot = try_quality.find(".")
        if dot >= 0:
            head = try_quality[0:dot]
            tail = try_quality[dot + 1:]
            head_ok = head.isdigit() or (head.startswith("-") and head[1:].isdigit())
            tail_ok = tail.isdigit()
        else:
            head_ok = try_quality.isdigit() or (try_quality.startswith("-") and try_quality[1:].isdigit())
            tail_ok = False
        if (dot >= 0 and head_ok and tail_ok) or (dot < 0 and head_ok):
            quality = float(try_quality)

    model = _val(col_model, item, "")
    version = _val(col_version, item, "")
    license_ = _val(col_license, item, "")
    priority = _val(col_priority, item, "")
    serial = _val(col_serial, item, "")

    # Determine aggregate state per Checkmk semantics:
    # online True -> OK ; False -> CRIT
    # forced -> WARN ; else OK (but forced is informational alongside state)
    # quality levels_lower: WARN if <= warn, CRIT if <= crit
    quality_levels = params.get("quality")
    if quality_levels == None:
        q_warn = QUALITY_WARN_DEFAULT
        q_crit = QUALITY_CRIT_DEFAULT
    else:
        q_warn = QUALITY_WARN_DEFAULT
        q_crit = QUALITY_CRIT_DEFAULT
        # params["quality"] is [warn, crit] form
        if type(quality_levels) == "list" and len(quality_levels) >= 2:
            q_warn = quality_levels[0]
            q_crit = quality_levels[1]
        elif type(quality_levels) == "tuple" and len(quality_levels) >= 2:
            q_warn = quality_levels[0]
            q_crit = quality_levels[1]

    summaries = []
    if online:
        summaries.append("Online")
    else:
        summaries.append("Offline")
    ha_str = "HA-State: %s (forced)" % state if forced else "HA-State: %s (not forced)" % state
    summaries.append(ha_str)
    summaries.append("Model: %s" % model)
    summaries.append("Version: %s" % version)
    summaries.append("Role: %s" % license_)
    summaries.append("Priority: %s" % priority)
    summaries.append("Serial: %s" % serial)

    details = "\n".join(summaries)

    # Aggregate state: CRIT if offline OR quality <= crit; WARN if forced OR quality <= warn; else OK
    aggr = "OK"
    if not online:
        aggr = "CRIT"
    if quality <= q_crit and aggr != "CRIT":
        aggr = "CRIT"
    elif quality <= q_warn:
        if aggr == "OK":
            aggr = "WARN"
    if forced and aggr == "OK":
        aggr = "WARN"
    # Offline is CRIT; forced only upgrades to WARN if not already critical.
    # If offline, CRIT dominates; forced+offline -> CRIT.

    msg = "Quality: %f%%, %s" % (quality, ha_str)

    return {"changed": False,
            "msg": msg,
            "data": {"state": aggr,
                     "metrics": {"quality": quality},
                     "details": details}}