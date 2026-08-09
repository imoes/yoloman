# F5-BIGIP-Cluster-Status check module
# Read-only Starlark check: gather SNMP data and report cluster status
# No mutates=True, no file writes, changed always False

STATE_NAMES_V11_2 = ("unknown", "offline", "forced offline", "standby", "active")
STATE_NAMES_PRE_V11_2 = ("standby", "active 1", "active 2", "active")

def _map_state_v11_2_plus(state):
    default_map = {0: 3, 1: 2, 2: 2, 3: 0, 4: 0}
    return default_map.get(state, 3)

def _map_state_pre_v11_2(state):
    return 0

def _state_to_string(state_code):
    if state_code == 0:
        return "OK"
    elif state_code == 1:
        return "WARN"
    elif state_code == 2:
        return "CRIT"
    else:
        return "UNKNOWN"

def _parse_version(ctx):
    community = "public"
    oid_version = ".1.3.6.1.4.1.3375.2.1.4.2.0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", ctx.host, oid_version], mutates=False)
    if res.rc != 0 or not res.stdout:
        return False
    line = res.stdout.strip()
    if line.find("STRING:") == -1:
        return False
    version_str = line.split("STRING:")[1].strip().strip('"')
    parts = version_str.split(".")
    if len(parts) < 2:
        return False
    major_str = parts[0]
    minor_str = parts[1]
    if not major_str.isdigit():
        return False
    if not minor_str.isdigit():
        return False
    major = int(major_str)
    minor = int(minor_str)
    return major > 11 or (major == 11 and minor >= 2)

def main(ctx, params):
    community = params.get("community", "public")
    
    is_gt_v11_2 = _parse_version(ctx)
    oid = ".1.3.6.1.4.1.3375.2.1.14.3.1" if is_gt_v11_2 else ".1.3.6.1.4.1.3375.2.1.1.1.1.19"
    
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", ctx.host, oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error", "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed"}}
    
    line = res.stdout.strip()
    if not line or line.find("INTEGER:") == -1:
        return {"changed": False, "msg": "Could not parse SNMP output", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Invalid SNMP response format"}}
    
    state_str = line.split("INTEGER:")[1].strip()
    if not state_str:
        return {"changed": False, "msg": "Could not parse node state", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Node state value invalid"}}
    
    # Handle negative numbers for node_state parsing
    is_negative = state_str.startswith('-')
    digits_part = state_str[1:] if is_negative else state_str
    if not digits_part.isdigit():
        return {"changed": False, "msg": "Could not parse node state", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Node state value invalid"}}
    
    node_state = int(state_str)
    
    state_names = STATE_NAMES_V11_2 if is_gt_v11_2 else STATE_NAMES_PRE_V11_2
    if node_state < 0 or node_state >= len(state_names):
        summary = "Node is unknown"
    else:
        summary = "Node is " + state_names[node_state]
    
    mapped_state = _map_state_v11_2_plus(node_state) if is_gt_v11_2 else _map_state_pre_v11_2(node_state)
    state_name = _state_to_string(mapped_state)

    return {"changed": False, "msg": summary, "data": {"state": state_name, "metrics": {}, "details": ""}}