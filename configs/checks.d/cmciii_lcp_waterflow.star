# ===== Starlark check module: cmk.cmciii_lcp_waterflow =====
# Translation of Checkmk check: cmk.plugins.rittal.agent_based.cmciii_lcp_waterflow

def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["flow"]}]}
        }

    # ===== CHECK MODE =====
    # Fetch SNMP data from the Rittal LCP waterflow section
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
    # We fetch all OIDs in one walk and parse manually
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpwalk output: lines like ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2.74 = STRING: ..."
    lines = res.stdout.splitlines()
    values = {}
    for line in lines:
        # Split once on " = " to separate OID from value
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx]
        value_part = line[eq_idx+3:]

        # Extract the OID index number (e.g., "74" from ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2.74")
        last_dot_idx = oid_part.rfind(".")
        if last_dot_idx == -1:
            continue
        oid_suffix = oid_part[last_dot_idx+1:]

        # Check if it's one of the OIDs we need (74-78)
        if oid_suffix in ["74", "75", "76", "77", "78"]:
            # Extract string value: "STRING: value" or "STRING: \"value\""
            if value_part.startswith("STRING: "):
                val = value_part[8:].strip().strip('"')
                values[int(oid_suffix)] = val
            elif value_part.startswith("STRING:"):
                val = value_part[7:].strip().strip('"')
                values[int(oid_suffix)] = val
            else:
                # Try to take everything after " = "
                val = value_part.strip().strip('"')
                values[int(oid_suffix)] = val

    # Check we got enough data (need at least 5 fields)
    if not (74 in values and 75 in values and 76 in values and 77 in values and 78 in values):
        return {
            "changed": False,
            "msg": "incomplete SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map values per source: 74=name, 75=flow+unit, 76=maxflow+unit, 77=minflow+unit, 78=status
    name = values[74].strip()
    flow_parts = values[75].strip().split(" ", 1)
    flow_str = flow_parts[0]
    # Parse float safely (Starlark has no try/except - guard first)
    flow = 0.0
    # Check if string is a valid number (allows digits, dot, minus sign)
    if flow_str.replace('.', '', 1).lstrip('-').isdigit():
        flow = float(flow_str)

    maxflow_parts = values[76].strip().split(" ", 1)
    maxflow_str = maxflow_parts[0]
    maxflow = 0.0
    if maxflow_str.replace('.', '', 1).lstrip('-').isdigit():
        maxflow = float(maxflow_str)

    minflow_parts = values[77].strip().split(" ", 1)
    minflow_str = minflow_parts[0]
    minflow = 0.0
    if minflow_str.replace('.', '', 1).lstrip('-').isdigit():
        minflow = float(minflow_str)

    status = values[78].strip()

    # Determine state
    state = "OK"
    if status != "OK":
        state = "CRIT"
    elif flow < minflow or flow > maxflow:
        state = "WARN"

    # Build summary message
    msg = "{} Status: {}; Flow: {:.1f}; MinFlow: {:.1f}; MaxFlow: {:.1f}".format(
        name, status, flow, minflow, maxflow
    )

    # Return result (always changed=False for read-only checks)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"flow": flow},
            "details": ""
        }
    }
