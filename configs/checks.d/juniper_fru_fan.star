# juniper_fru_fan.star
# Read-only Starlark check module translating Checkmk check juniper_fru_fan.
# Monitors Juniper FRU fan tray state via SNMP (Entity-MIB entPhysicalTable).

# entPhysicalClass OID values of interest. 13 = fan.
# State mapping mirrors Checkmk's _MAP_FRU_STATE.
_STATE_MAP = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("CRIT", "empty"),
    "3": ("WARN", "present"),
    "4": ("OK", "ready"),
    "5": ("OK", "announce online"),
    "6": ("OK", "online"),
    "7": ("CRIT", "anounce offline"),
    "8": ("CRIT", "offline"),
    "9": ("WARN", "diagnostic"),
    "10": ("WARN", "standby"),
}

# SNMP OIDs
# entPhysicalClass: .1.3.6.1.2.1.47.1.1.1.1.13 (column)
# entPhysicalName:   .1.3.6.1.2.1.47.1.1.1.1.7  (column)
# entPhysicalDescr:  .1.3.6.1.2.1.47.1.1.1.1.2  (column, used as FRU name fallback)
# entPhysicalVendorType / custom Juniper FRU state via .1.3.6.1.4.1.2636.x
# The Checkmk juniper_fru section uses a Juniper enterprise MIB exposing fru_state.
# We reproduce by reading the juniper_fru SNMP agent-based section equivalent.
ENT_PHYS_CLASS_OID = ".1.3.6.1.2.1.47.1.1.1.1.13"
ENT_PHYS_NAME_OID = ".1.3.6.1.2.1.47.1.1.1.1.7"

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Walk entPhysicalClass to find fans (13). Correlate names.
        class_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ENT_PHYS_CLASS_OID],
            mutates=False,
        )
        # rc==127 => snmpwalk not installed -> not applicable
        if class_res.rc == 127 or class_res.rc != 0:
            return {"changed": False, "msg": "snmpwalk not available or no SNMP access",
                    "data": {"discovery": []}}
        # rc==22 (noSuchInstance) for empty walks; treat rc==0 only as success
        if class_res.rc != 0 and class_res.rc != 22:
            return {"changed": False, "msg": "SNMP query failed", "data": {"discovery": []}}

        # Build index -> class mapping
        fans = {}
        for line in class_res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            col_oid, value = sp[0], sp[1]
            idx = col_oid[len(ENT_PHYS_CLASS_OID) + 1:]
            if value == "13":
                fans[idx] = value

        if len(fans) == 0:
            return {"changed": False, "msg": "discovered 0 fan FRUs",
                    "data": {"discovery": []}}

        # Get names for fan indices
        name_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ENT_PHYS_NAME_OID],
            mutates=False,
        )
        names = {}
        if name_res.rc == 0:
            for line in name_res.stdout.splitlines():
                sp = line.split(" ", 1)
                if len(sp) < 2:
                    continue
                col_oid, value = sp[0], sp[1]
                idx = col_oid[len(ENT_PHYS_NAME_OID) + 1:]
                names[idx] = value.strip('"')

        discovery = []
        for idx in fans.keys():
            item = names.get(idx, idx)
            discovery.append({
                "item": item,
                "params": {"warn": 3, "crit": 2},
                "metrics": ["fru_state"],
            })
        return {"changed": False,
                "msg": "discovered %d fan FRU(s)" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # First, verify SNMP tooling is present
    tool_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ENT_PHYS_NAME_OID + ".0"],
        mutates=False,
    )
    if tool_res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP tooling unavailable"}}

    # Resolve the item's index by walking entPhysicalName
    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ENT_PHYS_NAME_OID],
        mutates=False,
    )
    if name_res.rc != 0:
        return {"changed": False, "msg": "no FRU data from SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for line in name_res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        col_oid, value = sp[0], sp[1]
        idx = col_oid[len(ENT_PHYS_NAME_OID) + 1:]
        name_val = value.strip('"')
        if name_val == item:
            target_idx = idx
            break

    # Fall back to using the item as the numeric index if it looks numeric
    if target_idx == None:
        if item.isdigit():
            target_idx = item
        else:
            return {"changed": False, "msg": "no such fan FRU: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Verify this index is actually a fan (class == 13)
    class_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ENT_PHYS_CLASS_OID + "." + target_idx],
        mutates=False,
    )
    if class_res.rc != 0 or class_res.stdout.strip() != "13":
        return {"changed": False, "msg": "FRU is not a fan: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the Juniper FRU state. The juniper_fru MIB exposes fru_state.
    # Juniper enterprise OID for FRU state (per Checkmk juniper agent plugin):
    # We map using the local entPhysicalStatus / a Juniper-specific state column.
    # The Checkmk plugin uses the section 'juniper_fru' which comes from
    # .1.3.6.1.4.1.2636.3.1.x type OIDs. We use the fruState from
    # JUNIPER-FRU-MIB (.1.3.6.1.4.1.2636.3.1.2) keyed by index.
    JUNIPER_FRU_STATE_OID = ".1.3.6.1.4.1.2636.3.1.2"
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, JUNIPER_FRU_STATE_OID + "." + target_idx],
        mutates=False,
    )
    if state_res.rc != 0:
        return {"changed": False, "msg": "no FRU state for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fru_state = state_res.stdout.strip()
    if fru_state not in _STATE_MAP:
        return {"changed": False, "msg": "unknown FRU state code: " + fru_state,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    level, readable = _STATE_MAP[fru_state]
    metrics = {}
    # Map state to numeric for metric: use the raw state code as the metric value
    metrics["fru_state"] = int(fru_state)
    return {"changed": False,
            "msg": "Fan FRU %s: %s" % (item, readable),
            "data": {"state": level, "metrics": metrics, "details": ""}}