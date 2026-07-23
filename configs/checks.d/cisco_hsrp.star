# Constants
HSRP_STATES = {
    "1": "initial",
    "2": "learn",
    "3": "listen",
    "4": "speak",
    "5": "standby",
    "6": "active",
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: gather HSRP groups and enumerate items for working states (5 or 6)
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.106.1.2.1.1"
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Parse snmpwalk output
        lines = res.stdout.splitlines()
        data = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            
            # Extract last part after last dot (e.g., "1.192" from .1.192)
            last_dot_idx = oid.rfind(".")
            if last_dot_idx == -1:
                continue
            key = oid[last_dot_idx + 1:]
            
            # Split into interface_index and group
            dot_idx = key.find(".")
            if dot_idx == -1:
                continue
            if_idx_str = key[:dot_idx]
            grp_id_str = key[dot_idx + 1:]
            if not if_idx_str.isdigit() or not grp_id_str.isdigit():
                continue
            if_idx = int(if_idx_str)
            grp_id = int(grp_id_str)
            
            # Determine field based on OID prefix
            # OID structure: .1.3.6.1.4.1.9.9.106.1.2.1.1.<field>.<if_idx>.<grp_id>
            # We need to extract the field part (second to last number before if_idx.grp_id)
            base_oid = oid[:last_dot_idx]
            last_dot_idx2 = base_oid.rfind(".")
            if last_dot_idx2 == -1:
                continue
            base_oid_field = base_oid[last_dot_idx2 + 1:]
            
            idx = (if_idx, grp_id)
            if idx not in data:
                data[idx] = {"vip": "", "state": "", "vmac": ""}
            
            # Parse value
            val = ""
            if value.startswith("String: "):
                val = value[8:].strip().strip('"')
            elif value.startswith("INTEGER: "):
                int_str = value[9:].strip()
                if int_str.isdigit():
                    val = int_str
                else:
                    continue
            else:
                continue
            
            if base_oid_field == "2":
                data[idx]["vip"] = val
            elif base_oid_field == "5":
                data[idx]["state"] = val
            elif base_oid_field == "6":
                data[idx]["vmac"] = val
        
        # Build discovery list for state 5 (standby) or 6 (active)
        discovery_items = []
        for (if_idx, grp_id), info in data.items():
            state = info.get("state", "")
            if state == "5" or state == "6":
                item = "{}-{}".format(info.get("vip", ""), grp_id)
                discovery_items.append({
                    "item": item,
                    "params": {"group": str(grp_id), "state": int(state)},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: verify one item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "HSRP Group not found in Agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Gather data via SNMP
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.106.1.2.1.1"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "HSRP Group not found in Agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpwalk output
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        
        # Extract last part after last dot
        last_dot_idx = oid.rfind(".")
        if last_dot_idx == -1:
            continue
        key = oid[last_dot_idx + 1:]
        
        # Split into interface_index and group
        dot_idx = key.find(".")
        if dot_idx == -1:
            continue
        if_idx_str = key[:dot_idx]
        grp_id_str = key[dot_idx + 1:]
        if not if_idx_str.isdigit() or not grp_id_str.isdigit():
            continue
        if_idx = int(if_idx_str)
        grp_id = int(grp_id_str)
        
        # Determine field based on OID prefix
        base_oid = oid[:last_dot_idx]
        last_dot_idx2 = base_oid.rfind(".")
        if last_dot_idx2 == -1:
            continue
        base_oid_field = base_oid[last_dot_idx2 + 1:]
        
        idx = (if_idx, grp_id)
        if idx not in data:
            data[idx] = {"vip": "", "state": "", "vmac": ""}
        
        # Parse value
        val = ""
        if value.startswith("String: "):
            val = value[8:].strip().strip('"')
        elif value.startswith("INTEGER: "):
            int_str = value[9:].strip()
            if int_str.isdigit():
                val = int_str
            else:
                continue
        else:
            continue
        
        if base_oid_field == "2":
            data[idx]["vip"] = val
        elif base_oid_field == "5":
            data[idx]["state"] = val
        elif base_oid_field == "6":
            data[idx]["vmac"] = val
    
    # Find matching item
    item_found = False
    state_found = ""
    for (if_idx, grp_id), info in data.items():
        item_check = "{}-{}".format(info.get("vip", ""), grp_id)
        if item_check == item:
            item_found = True
            state_found = info.get("state", "")
            break
    
    if not item_found:
        return {
            "changed": False,
            "msg": "HSRP Group not found in Agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply check logic
    state_int = int(state_found) if state_found.isdigit() else 0
    state_wanted_str = params.get("state", "0")
    state_wanted = int(state_wanted_str) if str(state_wanted_str).isdigit() else 0
    
    # Determine state
    if state_wanted in [3, 5, 6] and state_int == state_wanted:
        state = "OK"
        msgtxt = "Redundancy Group %s is OK" % item
    elif state_wanted in [5, 6]:
        state = "WARN"
        msgtxt = "Redundancy Group %s has failed over" % item
    else:
        state = "CRIT"
        msgtxt = "Redundancy Group %s" % item
    
    return {
        "changed": False,
        "msg": "{}, Status: {}".format(msgtxt, HSRP_STATES.get(state_found, "unknown")),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
