# akcp_sensor_drycontact Starlark check module
# Translated from Checkmk plugin cmk/plugins/akcp/agent_based/akcp_sensor_drycontact.py
# READ-ONLY check: never mutates system state

# State mapping for dry contact sensors (from SPAGENT-MIB)
AKCP_DRYCONTACT_STATES = {
    "1": (2, "no status"),
    "7": (2, "sensor error"),
    "8": (2, "output low"),
    "9": (2, "output high"),
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # First try the main AKCP OID tree
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.3854.1.2.2.1.18"
        ], mutates=False)
        
        # If that fails, try SP2Plus tree
        if res.rc != 0 or res.stdout == "":
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, ".1.3.6.1.4.1.3854.3.5.4"
            ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        # Parse SNMP output and collect online dry contacts
        discovered = []
        for line in res.stdout.splitlines():
            # Format: OID = TYPE: value
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            
            oid_full = parts[0].strip()
            value = parts[1].strip()
            
            # Extract OID base to determine type
            if ".1.3.6.1.4.1.3854.1.2.2.1.18.1." in oid_full:
                # Main AKCP tree - index is after the base OID
                index_part = oid_full.split(".1.3.6.1.4.1.3854.1.2.2.1.18.1.")[-1]
                if "." in index_part:
                    index = index_part.split(".")[0]
                else:
                    index = index_part
                
                # Map OID suffixes to fields
                if oid_full.endswith(".1"):  # description (oid 1)
                    description = value
                    online = ""
                    status = ""
                elif oid_full.endswith(".3"):  # status (oid 3)
                    status = value.strip('"')
                    description = ""
                    online = ""
                elif oid_full.endswith(".5"):  # go online (oid 5)
                    online = value
                    description = ""
                    status = ""
                else:
                    continue
                
                # Try to find matching entry in discovered list
                found = False
                for item in discovered:
                    if item["index"] == index:
                        if description:
                            item["description"] = description
                        if status:
                            item["status"] = status
                        if online:
                            item["online"] = online
                        found = True
                        break
                
                if not found and (description or status or online):
                    item = {"index": index}
                    if description:
                        item["description"] = description.strip('"')
                    if status:
                        item["status"] = status
                    if online:
                        item["online"] = online
                    discovered.append(item)
            
            elif ".1.3.6.1.4.1.3854.3.5.4.1." in oid_full:
                # SP2Plus tree - similar structure
                index_part = oid_full.split(".1.3.6.1.4.1.3854.3.5.4.1.")[-1]
                if "." in index_part:
                    index = index_part.split(".")[0]
                else:
                    index = index_part
                
                if oid_full.endswith(".2"):  # drycontactDescription (oid 2)
                    description = value.strip('"')
                    status = ""
                    online = ""
                elif oid_full.endswith(".6"):  # drycontactStatus (oid 6)
                    status = value.strip('"')
                    description = ""
                    online = ""
                elif oid_full.endswith(".8"):  # drycontactGoOffline (oid 8)
                    # Invert logic: 1=online, 2=offline
                    online_val = value.strip('"')
                    online = "1" if online_val == "2" else "2"
                    description = ""
                    status = ""
                else:
                    continue
                
                # Try to find matching entry in discovered list
                found = False
                for item in discovered:
                    if item["index"] == index:
                        if description:
                            item["description"] = description
                        if status:
                            item["status"] = status
                        if online:
                            item["online"] = online
                        found = True
                        break
                
                if not found and (description or status or online):
                    item = {"index": index}
                    if description:
                        item["description"] = description
                    if status:
                        item["status"] = status
                    if online:
                        item["online"] = online
                    discovered.append(item)
        
        # Filter to only online contacts and format output
        result = []
        for item in discovered:
            online_val = item.get("online", "2")
            if online_val == "1":
                result.append({
                    "item": item.get("description", "drycontact"),
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d dry contact sensors" % len(result),
            "data": {"discovery": result}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # First try main AKCP tree
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.3854.1.2.2.1.18.1"
    ], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        # Fall back to SP2Plus tree
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.3854.3.5.4.1"
        ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output to find matching item
    status = ""
    online = "2"  # default offline
    normal_desc = "Drycontact OK"
    crit_desc = "Drycontact on Error"
    
    for line in res.stdout.splitlines():
        # Format: OID = TYPE: value
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        
        oid_full = parts[0].strip()
        value = parts[1].strip()
        
        # Extract index and field
        if ".1.3.6.1.4.1.3854.1.2.2.1.18.1." in oid_full:
            index_part = oid_full.split(".1.3.6.1.4.1.3854.1.2.2.1.18.1.")[-1]
            if "." in index_part:
                index = index_part.split(".")[0]
            else:
                index = index_part
            
            suffix = index_part.split(".")[-1] if "." in index_part else ""
            
            if suffix == "1":  # description
                if value.strip('"') == item:
                    description_match = True
                else:
                    description_match = False
                if description_match:
                    continue
            elif description_match:
                if suffix == "3":  # status
                    status = value.strip('"')
                elif suffix == "5":  # go online
                    online = value
        
        elif ".1.3.6.1.4.1.3854.3.5.4.1." in oid_full:
            index_part = oid_full.split(".1.3.6.1.4.1.3854.3.5.4.1.")[-1]
            if "." in index_part:
                index = index_part.split(".")[0]
            else:
                index = index_part
            
            suffix = index_part.split(".")[-1] if "." in index_part else ""
            
            if suffix == "2":  # drycontactDescription
                if value.strip('"') == item:
                    description_match = True
                else:
                    description_match = False
                if description_match:
                    continue
            elif description_match:
                if suffix == "6":  # drycontactStatus
                    status = value.strip('"')
                elif suffix == "8":  # drycontactGoOffline
                    # Invert: 1=online, 2=offline
                    online_val = value.strip('"')
                    online = "1" if online_val == "2" else "2"
    
    # Check if we found the item
    if not status:
        return {
            "changed": False,
            "msg": "dry contact '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Evaluate state according to Checkmk logic
    if online != "1":
        state = "CRIT"
        infotext = "Sensor is offline"
    elif status == "2":
        state = "OK"
        infotext = normal_desc
    elif status in ["4", "6"]:
        state = "CRIT"
        infotext = crit_desc
    else:
        state_info = AKCP_DRYCONTACT_STATES.get(status, (2, "unknown status"))
        state_code = state_info[0]
        infotext = state_info[1]
        state = ["OK", "WARN", "CRIT"][state_code]
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
