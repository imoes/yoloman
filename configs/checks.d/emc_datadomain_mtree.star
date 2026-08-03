# Checkmk check: checkmk.emc_datadomain_mtree
# Translated to a read-only Starlark check module for the yolo-man agent.
# This is an SNMP check: walks the EMC Data Domain MTree table and grades each
# MTree's status code against operator-configured levels.

def _parse_bytes(v):
    """Parse a numeric string that may contain quotes/type tags into bytes (int)."""
    cleaned = v.strip()
    if cleaned.startswith("STRING:"):
        cleaned = cleaned[len("STRING:"):]
    cleaned = cleaned.strip()
    cleaned = cleaned.strip('"')
    f = float(cleaned) if _is_float(cleaned) else 0.0
    return int(f * 1024 * 1024 * 1024)

def _is_float(s):
    s = s.strip()
    if s.startswith("-"):
        s = s[1:]
    if s == "":
        return False
    parts = s.split(".")
    if len(parts) > 2:
        return False
    for p in parts:
        if p == "":
            return False
        for ch in p:
            if ch < "0" or ch > "9":
                return False
    return True

# OID base for the MTree table columns.
BASE_OID = "1.3.6.1.4.1.19746.1.15.2.1.1"
COL_NAME = BASE_OID + ".2"      # MTree name (index base)
COL_PRECOMPILED = BASE_OID + ".3"
COL_STATUS = BASE_OID + ".4"

# Map of status codes -> state string (mirrors the check plugin).
STATUS_TABLE = {
    "0": "unknown",
    "1": "deleted",
    "2": "read-only",
    "3": "read-write",
    "4": "replication destination",
    "5": "retention lock enabled",
    "6": "retention lock disabled",
}

# Default state mapping (Checkmk check_default_parameters).
DEFAULT_LEVELS = {
    "deleted": 2,
    "read-only": 1,
    "read-write": 0,
    "replication destination": 0,
    "retention lock disabled": 0,
    "retention lock enabled": 0,
    "unknown": 3,
}

def _render_bytes(b):
    """Render a byte count (int) into a human-readable string."""
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    val = float(b)
    idx = 0
    while val >= 1024 and idx < len(units) - 1:
        val = val / 1024
        idx = idx + 1
    if idx == 0:
        return "%d %s" % (b, units[idx])
    return "%f %s" % (val, units[idx])

def _map_state(state_int):
    """Map an integer level (0=OK,1=WARN,2=CRIT,3=UNKNOWN) to a Checkmk state string."""
    if state_int == 0:
        return "OK"
    if state_int == 1:
        return "WARN"
    if state_int == 2:
        return "CRIT"
    return "UNKNOWN"

def _snmp_get_bytes(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return _parse_bytes(res.stdout)

def _snmp_get_status(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _walk_table(ctx, host, community, column_oid):
    """Walk a single SNMP column OID with -Oqn; returns list of (index, value)."""
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    prefix = column_oid + "."
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        idx = line.find(" ")
        if idx < 0:
            continue
        oid_full = line[:idx]
        value = line[idx + 1:].strip()
        if oid_full.startswith(prefix):
            index = oid_full[len(prefix):]
            rows.append((index, value))
    return rows

def _is_data_domain(ctx, host, community):
    """Detect whether the target is an EMC Data Domain (sysDescr startswith 'Data Domain OS')."""
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc != 0:
        return False
    desc = res.stdout.strip()
    desc = desc.strip('"')
    return desc.startswith("Data Domain OS")

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- discovery mode ---
    if params.get("_discover"):
        if not _is_data_domain(ctx, host, community):
            return {"changed": False, "msg": "not a Data Domain system", "data": {"discovery": []}}
        # Walk the MTree name column to enumerate items (table index == name).
        rows = _walk_table(ctx, host, community, COL_NAME)
        discovery = []
        for index, value in rows:
            # The index IS the item name; use the value as the display name when
            # available, otherwise fall back to the index.
            item_name = value.strip().strip('"') if value != "" else index
            discovery.append({
                "item": item_name,
                "params": dict(DEFAULT_LEVELS),
                "metrics": ["precompiled"],
            })
        return {"changed": False, "msg": "discovered %d mtree items" % len(discovery),
                "data": {"discovery": discovery}}

    # --- check mode ---
    item = params.get("item", "")
    if not _is_data_domain(ctx, host, community):
        return {"changed": False, "msg": "not a Data Domain system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Re-walk the name column to map the display item name back to its SNMP index.
    name_rows = _walk_table(ctx, host, community, COL_NAME)
    target_index = None
    for index, value in name_rows:
        display = value.strip().strip('"') if value != "" else index
        if display == item or index == item:
            target_index = index
            break
    if target_index == None:
        return {"changed": False, "msg": "no such mtree: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    precompiled = _snmp_get_bytes(ctx, host, community, COL_PRECOMPILED + "." + target_index)
    status_code = _snmp_get_status(ctx, host, community, COL_STATUS + "." + target_index)
    if precompiled == None or status_code == None:
        return {"changed": False, "msg": "failed to gather mtree data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_code = status_code.strip().strip('"')
    dev_state_str = STATUS_TABLE.get(status_code, "invalid code " + status_code)
    state_int = params.get(dev_state_str, DEFAULT_LEVELS.get(dev_state_str, 3))
    state = _map_state(state_int) if state_int in (0, 1, 2, 3) else "UNKNOWN"

    summary = "Status: %s, Precompiled: %s" % (dev_state_str, _render_bytes(precompiled))
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"precompiled": precompiled}, "details": ""}}