# HP fan check module for yolo-man agent (read-only)
# Translates checkmk.hp_fan: reads fan states via SNMP, reports status per fan tray+index

def main(ctx, params):
    # Get SNMP parameters with defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # SNMP base OID for HP fans: .1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1"

    # Discovery mode: enumerate all fans
    if params.get("_discover"):
        # Get tray and fan state values using snmpwalk
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".2",  # tray index
            base_oid + ".4"   # fan state
        ], mutates=False)
        if res.rc != 0:
            # Agent unreachable -> no fans discovered
            return {"changed": False, "msg": "discovered 0 fans",
                    "data": {"discovery": []}}

        # Parse snmpwalk output: lines like "OID.index = INTEGER: value"
        # We need tray index (from .2) and fan state (from .4)
        # Build mapping of fan: "tray/fan_index" -> state
        lines = res.stdout.splitlines()
        tray_map = {}  # index -> tray value
        fan_state_map = {}  # index -> state value

        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index from OID (e.g., ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.2.1.2.1.1.1 = INTEGER: 1")
            # Look for ".2." (tray) or ".4." after base_oid
            if oid_part.startswith(base_oid + ".2."):
                # tray index
                index_str = oid_part[len(base_oid + ".2."):]
                idx = int(index_str) if index_str.isdigit() else 0
                # Parse value: might be "INTEGER: value" or just "value"
                if ":" in value_part:
                    value_part = value_part.split(":", 1)[1].strip()
                tray_map[idx] = value_part
            elif oid_part.startswith(base_oid + ".4."):
                # fan state
                index_str = oid_part[len(base_oid + ".4."):]
                idx = int(index_str) if index_str.isdigit() else 0
                if ":" in value_part:
                    value_part = value_part.split(":", 1)[1].strip()
                fan_state_map[idx] = value_part

        # Combine: fans are keyed by index (same index for tray and fan state)
        discovery = []
        for idx in sorted(tray_map.keys()):
            if idx in fan_state_map:
                tray = tray_map[idx]
                state = fan_state_map[idx]
                item = "%s/%s" % (tray, idx)
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: single item (e.g., "1/3")
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse item to get the fan index (second part after "/")
    parts = item.split("/")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fan_index_str = parts[1]
    if not fan_index_str.isdigit():
        return {"changed": False, "msg": "invalid fan index in item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fan_index = int(fan_index_str)

    state_oid = base_oid + ".4." + str(fan_index)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, state_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to get fan state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse output: "OID = INTEGER: value" or similar
    output = res.stdout.strip()
    if output == "":
        return {"changed": False, "msg": "no fan state data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract value (last token)
    tokens = output.split()
    if len(tokens) < 2:
        return {"changed": False, "msg": "cannot parse snmpget output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str = tokens[-1]
    # Clean up "INTEGER:" prefix if present
    if ":" in value_str:
        value_str = value_str.split(":", 1)[1].strip()
    if not value_str.isdigit():
        return {"changed": False, "msg": "fan state not a number: " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_code = value_str
    status_map = {
        "0": ("UNKNOWN", "unknown"),
        "1": ("CRIT", "removed"),
        "2": ("CRIT", "off"),
        "3": ("WARN", "underspeed"),
        "4": ("WARN", "overspeed"),
        "5": ("OK", "ok"),
        "6": ("UNKNOWN", "maxstate"),
    }
    state_txt = status_map.get(state_code, ("UNKNOWN", "unknown"))[1]

    return {"changed": False, "msg": state_txt,
            "data": {"state": status_map.get(state_code, ("UNKNOWN", "unknown"))[0],
                     "metrics": {}, "details": ""}}