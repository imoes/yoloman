# Module-level constants for SNMP OIDs
_BDTMS_TAPE_MODULE_OID_BASE = ".1.3.6.1.4.1.20884.2.4.1"
_BDTMS_TAPE_MODULE_OID_END = ".1.3.6.1.2.1.1.2.0"
_BDTMS_TAPE_MODULE_OID_PATTERN = ".1.3.6.1.4.1.20884.77.83.1"

# Map human-readable states to monitoring states
def _state_from_human(human_state):
    return "OK" if human_state.lower() == "ok" else "CRIT"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch all tape module entries via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Detect target device type first
        res_detect = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            _BDTMS_TAPE_MODULE_OID_END
        ], mutates=False)
        
        if res_detect.rc != 0 or _BDTMS_TAPE_MODULE_OID_PATTERN not in res_detect.stdout:
            return {
                "changed": False,
                "msg": "no tape library device detected",
                "data": {"discovery": []}
            }
        
        # Fetch module data: module_id, module_status, board_status, power_supply_status
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            _BDTMS_TAPE_MODULE_OID_BASE + ".4"
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "failed to fetch tape module data",
                "data": {"discovery": []}
            }
        
        # Parse snmpwalk output: format is "OID.123 = STRING: value" or similar
        items = []
        # We need the OID end values to build item names; use snmpwalk on base OID
        res_oid_end = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, _BDTMS_TAPE_MODULE_OID_BASE
        ], mutates=False)
        
        if res_oid_end.rc == 0 and res_oid_end.stdout.strip():
            # Build mapping of module IDs to statuses by parsing the walk
            lines = res_oid_end.stdout.strip().split("\n")
            module_data = {}
            
            for line in lines:
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid = parts[0].strip()
                value = parts[1].strip()
                
                # Extract the module ID from OID (last component)
                # OIDs look like: .1.3.6.1.4.1.20884.2.4.1.4.1 = STRING: "ok"
                # The last number is the module index (1, 2, 3, etc.)
                segments = oid.split(".")
                if len(segments) > 0 and segments[-1].isdigit():
                    idx = segments[-1]
                    # Get the OID suffix (4=module_status, 5=board_status, 6=power_supply_status)
                    # We already have module_status (index 4) in our res_oid_end
                    if idx not in module_data:
                        module_data[idx] = {"module_status": "", "board_status": "", "power_supply_status": ""}
                    
                    # Determine which field this OID represents based on position
                    # OID base: .1.3.6.1.4.1.20884.2.4.1
                    # OID suffix: 4=module, 5=board, 6=power_supply
                    suffix = segments[-2] if len(segments) > 1 else ""
                    if suffix == "4":
                        # Module status
                        module_data[idx]["module_status"] = value.split(": ", 1)[-1].strip('"').lower()
                    elif suffix == "5":
                        # Board status
                        module_data[idx]["board_status"] = value.split(": ", 1)[-1].strip('"').lower()
                    elif suffix == "6":
                        # Power supply status
                        module_data[idx]["power_supply_status"] = value.split(": ", 1)[-1].strip('"').lower()
            
            # Build discovery list
            for idx in sorted(module_data.keys(), key=lambda x: int(x)):
                data = module_data[idx]
                if data["module_status"]:  # Only include if we have at least module_status
                    items.append({
                        "item": idx,
                        "params": {},
                        "metrics": ["module_status", "board_status", "power_supply_status"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d tape modules" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: verify a single module item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch module data via snmpget for the specific item
    module_oid = _BDTMS_TAPE_MODULE_OID_BASE + ".4." + str(item)
    board_oid = _BDTMS_TAPE_MODULE_OID_BASE + ".5." + str(item)
    power_oid = _BDTMS_TAPE_MODULE_OID_BASE + ".6." + str(item)
    
    res_module = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, module_oid
    ], mutates=False)
    
    res_board = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, board_oid
    ], mutates=False)
    
    res_power = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, power_oid
    ], mutates=False)
    
    # Extract values
    def extract_value(output):
        if not output or output.rc != 0:
            return ""
        lines = output.stdout.strip().split("\n")
        if not lines:
            return ""
        line = lines[0]
        if " = " in line:
            return line.split(" = ", 1)[-1].strip().strip('"').lower()
        return ""
    
    module_status = extract_value(res_module)
    board_status = extract_value(res_board)
    power_supply_status = extract_value(res_power)
    
    # Handle missing data
    if not module_status:
        return {
            "changed": False,
            "msg": "module %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Module %s not found" % item
            }
        }
    
    # Compute states
    module_state = _state_from_human(module_status)
    board_state = _state_from_human(board_status)
    power_state = _state_from_human(power_supply_status)
    
    # Determine overall state (most severe)
    states = [module_state, board_state, power_state]
    overall_state = "CRIT" if "CRIT" in states else ("WARN" if "WARN" in states else "OK")
    
    # Build summary message
    summary = "Module: %s, Board: %s, Power supply: %s" % (
        module_status, board_status, power_supply_status
    )
    
    # Return result
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall_state,
            "metrics": {
                "module_status": 0 if module_status == "ok" else 1,
                "board_status": 0 if board_status == "ok" else 1,
                "power_supply_status": 0 if power_supply_status == "ok" else 1
            },
            "details": summary
        }
    }
