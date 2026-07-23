# Constants defined at module top level (required in Starlark)
STATE_NAMES_GT_V11_2 = ["unknown", "offline", "forced offline", "standby", "active"]
STATE_NAMES_LE_V11_2 = ["standby", "active 1", "active 2", "active"]

# Base OIDs for SNMP sections
OID_BASE_PRE_V11_2 = ".1.3.6.1.4.1.3375.2.1.1.1.1.19"  # sysAttrFailoverUnitMask
OID_BASE_V11_2 = ".1.3.6.1.4.1.3375.2.1.14.3.1"      # sysCmFailoverStatusId

# vCMP-related OIDs
OID_VCMP_NUMBER = ".1.3.6.1.4.1.3375.2.1.13.1.1.0"  # sysVcmpNumber
OID_CM_FAILOVER_STATUS = ".1.3.6.1.4.1.3375.2.1.14.3.1"  # sysCmFailoverStatusId

# F5 BIGIP detection OIDs
OID_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
OID_F5_BIGIP_TRAFFIC_MGMT = ".1.3.6.1.4.1.3375.2"
OID_F5_BIGIP_PRODUCT_NAME = ".1.3.6.1.4.1.3375.2.1.4.1.0"
OID_F5_BIGIP_VERSION = ".1.3.6.1.4.1.3375.2.1.4.2.0"

# Default parameters
DEFAULT_PARAMS = {"type": "active_standby"}


def _parse_version(version_str):
    """Parse version string to tuple of integers for comparison."""
    if version_str == None or version_str == "":
        return (0, 0)
    # Extract numeric parts
    parts = version_str.split(".")
    nums = []
    for p in parts:
        if p.isdigit():
            nums.append(int(p))
        else:
            # Extract leading digits if any
            num = ""
            for c in p:
                if c.isdigit():
                    num += c
                else:
                    break
            if num.isdigit():
                nums.append(int(num))
            else:
                nums.append(0)
    # Ensure at least 2 components
    while len(nums) < 2:
        nums.append(0)
    return tuple(nums)


def _translate_state(state, is_gt_v11_2):
    """Translate raw state to Checkmk state (OK/WARN/CRIT/UNKNOWN)."""
    # Default state mapping from source
    state_mapping = {0: 3, 1: 2, 2: 2, 3: 0, 4: 0}
    
    # For v11.2+, use the state_mapping directly
    if is_gt_v11_2:
        mapped = state_mapping.get(state, 3)  # default to UNKNOWN if not in map
        # Convert to Checkmk state constants: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
        if mapped == 0:
            return "OK"
        elif mapped == 1:
            return "WARN"
        elif mapped == 2:
            return "CRIT"
        else:
            return "UNKNOWN"
    
    # For pre-v11.2, always OK per the source code
    return "OK"


def _get_state_name(state, is_gt_v11_2):
    """Get human-readable state name."""
    if is_gt_v11_2:
        if (0 <= state) and (state < len(STATE_NAMES_GT_V11_2)):
            return STATE_NAMES_GT_V11_2[state]
    else:
        # For pre-v11.2, use STATE_NAMES_LE_V11_2 but adjust indexing
        # According to source, STATE_NAMES[False] has 4 elements: ["standby", "active 1", "active 2", "active"]
        if (0 <= state) and (state < len(STATE_NAMES_LE_V11_2)):
            return STATE_NAMES_LE_V11_2[state]
    return "unknown"


def _snmpget(ctx, oid, host, community):
    """Perform snmpget for a single OID and return value."""
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if (res.rc != 0) or (res.stdout.strip() == ""):
        return None
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return None
    line = lines[0]
    if line.find(" = ") == -1:
        return None
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None
    value_part = parts[1].strip()
    if value_part.find(": ") == -1:
        return value_part
    return value_part.split(": ", 1)[1].strip()


def main(ctx, params):
    # Default parameters
    check_params = DEFAULT_PARAMS.copy()
    if params.get("type") != None:
        check_params["type"] = params["type"]
    
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Get F5 BIGIP product version to determine version category
    version_str = _snmpget(ctx, OID_F5_BIGIP_VERSION, host, community)
    if version_str == None:
        version_str = ""
    
    ver = _parse_version(version_str)
    is_gt_v11_2 = (ver[0] > 11) or ((ver[0] == 11) and (len(ver) > 1) and (ver[1] >= 2))
    
    # Discovery mode
    if params.get("_discover") == True:
        # Get vCMP status
        vcmp_count_str = _snmpget(ctx, OID_VCMP_NUMBER, host, community)
        if (vcmp_count_str != None) and (vcmp_count_str != "") and (vcmp_count_str.isdigit()):
            vcmp_count = int(vcmp_count_str)
            if vcmp_count > 0:
                # Single service check - return one item with empty string
                return {
                    "changed": False,
                    "msg": "discovered 1 item",
                    "data": {
                        "discovery": [
                            {
                                "item": "",
                                "params": {"type": check_params["type"]},
                                "metrics": []
                            }
                        ]
                    }
                }
        
        # Not a vCMP guest - no discovery
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    
    # Check mode (not discovery)
    item = params.get("item", "")
    
    # For non-discovery, we must have item (empty string for single-service)
    if item != "":
        # This should not happen in normal operation, but return UNKNOWN for unexpected item
        return {
            "changed": False,
            "msg": "unknown item",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Only item '' is supported for this check"
            }
        }
    
    # Get vCMP and failover status
    vcmp_count_str = _snmpget(ctx, OID_VCMP_NUMBER, host, community)
    failover_status_str = _snmpget(ctx, OID_CM_FAILOVER_STATUS, host, community)
    
    # If vCMP count == None, empty, or not a digit, report UNKNOWN
    if (vcmp_count_str == None) or (vcmp_count_str == "") or (not vcmp_count_str.isdigit()):
        return {
            "changed": False,
            "msg": "could not retrieve vCMP status",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query failed for vCMP status"
            }
        }
    
    vcmp_count = int(vcmp_count_str)
    
    # If not vCMP guest (vcmp_count == 0), report UNKNOWN
    if vcmp_count == 0:
        return {
            "changed": False,
            "msg": "device is not a vCMP guest",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Device is not running as a vCMP guest"
            }
        }
    
    # Get failover status
    if (failover_status_str == None) or (failover_status_str == "") or (not failover_status_str.isdigit()):
        return {
            "changed": False,
            "msg": "could not retrieve failover status",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query failed for failover status"
            }
        }
    
    failover_status = int(failover_status_str)
    
    # Translate state and get state name
    state = _translate_state(failover_status, is_gt_v11_2)
    state_name = _get_state_name(failover_status, is_gt_v11_2)
    
    # Check logic for active_standby type
    if check_params["type"] == "active_standby":
        # In active_standby, only one active node expected
        # Failover status meaning:
        # 0=unknown, 1=offline, 2=forced offline, 3=standby, 4=active
        if failover_status == 4:
            summary = "Node is active"
            state = "OK"  # Active is OK in active_standby
        elif failover_status == 3:
            summary = "Node is standby"
            state = "OK"  # Standby is also OK
        else:
            summary = "Node is %s" % state_name
            # Map non-active/standby states to WARNING/CRITICAL
            if failover_status == 0:
                state = "UNKNOWN"
            elif failover_status == 1:
                state = "CRIT"  # Offline
            elif failover_status == 2:
                state = "CRIT"  # Forced offline
            else:
                state = "UNKNOWN"
    else:  # active_active
        summary = "Node is %s" % state_name
        # For active_active, both active and standby are acceptable
        if failover_status == 0:
            state = "UNKNOWN"
        elif (failover_status == 1) or (failover_status == 2):
            state = "WARN"  # Offline or forced offline
        else:
            state = "OK"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
