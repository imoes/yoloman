# brocade_mlx_module_status — Status Module %s (read-only Starlark check)

# SNMP base and OID mappings (from Checkmk source)
_BASE_OID_MODULE = ".1.3.6.1.4.1.1991.1.1.2.2.1.1"
_OID_MODULE_ID = "1"
_OID_MODULE_DESCR = "2"
_OID_MODULE_STATE = "12"
_OID_MEM_TOTAL = "24"
_OID_MEM_AVAIL = "25"

_BASE_OID_CPU = ".1.3.6.1.4.1.1991.1.1.2.11.1.1"

# State mapping (int -> (State, summary))
_BROCADE_MLX_STATES = {
    0: ("WARN", "Slot is empty"),
    2: ("WARN", "Module is going down"),
    3: ("CRIT", "Rejected due to wrong configuration"),
    4: ("CRIT", "Hardware is bad"),
    8: ("WARN", "Configured / Stacking"),
    9: ("WARN", "In power-up cycle"),
    10: ("OK", "Running"),
    11: ("OK", "Blocked for full height card"),
}


def _combine_item(module_id, module_descr):
    if module_descr == "":
        return module_id
    descr = module_descr.replace(" Module", "").replace("  ", " ")
    return module_id + " " + descr


def _get_state(state_int):
    return _BROCADE_MLX_STATES.get(state_int, ("UNKNOWN", "Unhandled state - %s" % state_int))


def _saveint(i):
    if i == None or not isinstance(i, str):
        return 0
    s = i.strip()
    # Guard: check if it's a valid integer string before conversion
    if not s:
        return 0
    is_negative = s.startswith("-")
    if is_negative:
        s = s[1:]
    if not s.isdigit():
        return 0
    if is_negative:
        # Only allow negative if original started with "-"
        return -int(s)
    return int(s)


def _snmpwalk(ctx, community, host, base_oid):
    # Walk base OID and parse lines like "<oid> = <type>: <value>"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid],
        mutates=False
    )
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    result = []
    for line in lines:
        if not line:
            continue
        # Split into oid and value part
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        val_raw = parts[1].strip()
        # Extract oid end (after base_oid)
        if oid_full.startswith(base_oid + "."):
            oid_end = oid_full[len(base_oid)+1:]
        else:
            oid_end = oid_full
        # Extract value (strip type prefix like "INTEGER:", "STRING:", etc.)
        if ":" in val_raw:
            val = val_raw.split(":", 1)[1].strip().strip('"')
        else:
            val = val_raw.strip('"')
        result.append((oid_end, val))
    return result


def _parse_section0(ctx, community, host):
    # Fetch first SNMPTree: base .1.3.6.1.4.1.1991.1.1.2.2.1.1, oids 1,2,12,24,25
    base = _BASE_OID_MODULE
    rows = {}
    # We'll collect by row index: .1 -> row 1, .2 -> row 2, etc.
    for oid_end, val in _snmpwalk(ctx, community, host, base):
        # oid_end is like "1", "2", "12", "24", "25", etc. (row indices)
        if not oid_end.isdigit():
            continue
        row_idx = int(oid_end)
        rows.setdefault(row_idx, {})
        # Map to known columns based on original OIDs order
        if row_idx == 1:
            rows[row_idx]["module_id"] = val
        elif row_idx == 2:
            rows[row_idx]["module_descr"] = val
        elif row_idx == 12:
            rows[row_idx]["module_state"] = val
        elif row_idx == 24:
            rows[row_idx]["mem_total"] = val
        elif row_idx == 25:
            rows[row_idx]["mem_avail"] = val
    # Now restructure into per-row (module_id, module_descr, module_state, mem_total, mem_avail)
    # Use max index seen to bound iteration
    max_row = max(rows.keys()) if rows else 0
    section0 = []
    for idx in range(1, max_row + 1):
        row = rows.get(idx, {})
        module_id = row.get("module_id", "")
        module_descr = row.get("module_descr", "")
        module_state = row.get("module_state", "0")
        mem_total = row.get("mem_total", "")
        mem_avail = row.get("mem_avail", "")
        section0.append((module_id, module_descr, module_state, mem_total, mem_avail))
    return section0


def _parse_section1(ctx, community, host):
    # Fetch second SNMPTree: base .1.3.6.1.4.1.1991.1.1.2.11.1.1, oids [OIDEnd(), "5"]
    base = _BASE_OID_CPU
    section1 = []
    for oid_end, val in _snmpwalk(ctx, community, host, base):
        # oid_end is like "1.1.1", "1.1.5", etc.
        section1.append((oid_end, val))
    return section1


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discover mode
    if params.get("_discover"):
        section0 = _parse_section0(ctx, community, host)
        discovery = []
        for module_id, module_descr, module_state, _mem_total, _mem_avail in section0:
            if module_state != "0":
                item = _combine_item(module_id, module_descr)
                # Suggest thresholds (not used by module_status but kept for compatibility)
                discovery.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d modules" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    section0 = _parse_section0(ctx, community, host)

    found = False
    for module_id, module_descr, module_state, _mem_total, _mem_avail in section0:
        candidate = _combine_item(module_id, module_descr)
        if candidate == item:
            found = True
            state_int = _saveint(module_state)
            state, summary = _get_state(state_int)
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }

    if not found:
        return {
            "changed": False,
            "msg": "Module not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
