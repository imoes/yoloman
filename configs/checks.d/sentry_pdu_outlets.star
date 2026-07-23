# Map of outlet states for v3 (OUTLET_STATES in the source)
OUTLET_STATES_V3 = {
    0: ("OK", "off"),
    1: ("OK", "on"),
    2: ("WARN", "off wait"),
    3: ("WARN", "on wait"),
    4: ("CRIT", "off error"),
    5: ("CRIT", "on error"),
    6: ("CRIT", "no comm"),
    7: ("CRIT", "reading"),
    8: ("CRIT", "off fuse"),
    9: ("CRIT", "on fuse"),
}

# Map of outlet states for v4 (DEVICE_STATES_V4 in the source)
OUTLET_STATES_V4 = {
    0: ("OK", "normal"),
    1: ("CRIT", "disabled"),
    2: ("CRIT", "purged"),
    5: ("WARN", "reading"),
    6: ("WARN", "settle"),
    7: ("CRIT", "not found"),
    8: ("CRIT", "lost"),
    9: ("CRIT", "read error"),
    10: ("CRIT", "no comm"),
    11: ("CRIT", "pwr error"),
    12: ("CRIT", "breaker tripped"),
    13: ("CRIT", "fuse blown"),
    14: ("CRIT", "low alarm"),
    15: ("WARN", "low warning"),
    16: ("WARN", "high warning"),
    17: ("CRIT", "high alarm"),
    18: ("CRIT", "alarm"),
    19: ("CRIT", "under limit"),
    20: ("CRIT", "over limit"),
    21: ("CRIT", "nvm fail"),
    22: ("CRIT", "profile error"),
    23: ("CRIT", "conflict"),
}


def _get_outlet_info(ctx, host, community, is_v4):
    """Walk the SNMP tree and build the section dict {item_name: state_int}."""
    base_oid = ".1.3.6.1.4.1.1718.3.2.3.1" if not is_v4 else ".1.3.6.1.4.1.1718.4.1.8"
    if is_v4:
        # v4 OIDs: 2.1.2 (outletId), 2.1.3 (outletName), 3.1.2 (outletState)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".2.1.2", base_oid + ".2.1.3", base_oid + ".3.1.2"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {}
        lines = res.stdout.splitlines()
        outlet_id = {}
        outlet_name = {}
        outlet_state = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            idx_eq = line.find("=")
            if idx_eq == -1:
                continue
            oid_part = line[:idx_eq].strip()
            val_part = line[idx_eq+1:].strip()
            parts = oid_part.split(".")
            if len(parts) < 2:
                continue
            idx_str = parts[-1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            if "2.1.2" in oid_part:
                outlet_id[idx] = val_part.strip('"')
            elif "2.1.3" in oid_part:
                outlet_name[idx] = val_part.strip('"')
            elif "3.1.2" in oid_part:
                if val_part.isdigit():
                    outlet_state[idx] = int(val_part)
        section = {}
        all_indices = []
        for k in outlet_id:
            all_indices.append(k)
        for k in outlet_name:
            if k not in all_indices:
                all_indices.append(k)
        for k in outlet_state:
            if k not in all_indices:
                all_indices.append(k)
        for idx in sorted(all_indices):
            oid = outlet_id.get(idx, "")
            name = outlet_name.get(idx, "")
            state = outlet_state.get(idx, -1)
            name_clean = name.replace("Outlet", "")
            item = "%s %s" % (oid, name_clean)
            section[item] = state
        return section
    else:
        # v3 OIDs: base + ".2" (outletId), ".3" (outletName), ".5" (outletState)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".2", base_oid + ".3", base_oid + ".5"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {}
        lines = res.stdout.splitlines()
        outlet_id = {}
        outlet_name = {}
        outlet_state = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            idx_eq = line.find("=")
            if idx_eq == -1:
                continue
            oid_part = line[:idx_eq].strip()
            val_part = line[idx_eq+1:].strip()
            parts = oid_part.split(".")
            if len(parts) < 2:
                continue
            idx_str = parts[-1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            if oid_part.endswith(".2"):
                outlet_id[idx] = val_part.strip('"')
            elif oid_part.endswith(".3"):
                outlet_name[idx] = val_part.strip('"')
            elif oid_part.endswith(".5"):
                if val_part.isdigit():
                    outlet_state[idx] = int(val_part)
        section = {}
        all_indices = []
        for k in outlet_id:
            all_indices.append(k)
        for k in outlet_name:
            if k not in all_indices:
                all_indices.append(k)
        for k in outlet_state:
            if k not in all_indices:
                all_indices.append(k)
        for idx in sorted(all_indices):
            oid = outlet_id.get(idx, "")
            name = outlet_name.get(idx, "")
            state = outlet_state.get(idx, -1)
            name_clean = name.replace("Outlet", "")
            item = "%s %s" % (oid, name_clean)
            section[item] = state
        return section


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        section = _get_outlet_info(ctx, host, community, True)
        if not section:
            section = _get_outlet_info(ctx, host, community, False)
        items = []
        for item in section:
            items.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d outlets" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    section = _get_outlet_info(ctx, host, community, True)
    if not section:
        section = _get_outlet_info(ctx, host, community, False)

    state_map = OUTLET_STATES_V3
    for k in section:
        if section[k] >= 100:
            state_map = OUTLET_STATES_V4
            break

    outlet_state = section.get(item)
    if outlet_state == None:
        return {
            "changed": False,
            "msg": "outlet not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lookup = state_map.get(outlet_state)
    if lookup == None:
        return {
            "changed": False,
            "msg": "Unhandled state: " + str(outlet_state),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state, status = lookup
    return {
        "changed": False,
        "msg": "Status: " + status,
        "data": {"state": state, "metrics": {}, "details": ""},
    }