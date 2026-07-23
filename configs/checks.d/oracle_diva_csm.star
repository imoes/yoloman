def main(ctx, params):
    # Status mapping: 1=online(OK), 2=offline(CRIT), 3=unknown(WARN), else=UNKNOWN(3)
    def status_result(reading):
        if reading == "1":
            return 0, "online"
        if reading == "2":
            return 2, "offline"
        if reading == "3":
            return 1, "unknown"
        return 3, "unexpected state"

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discover all possible items from all sections
        items = []
        
        # Library section (index 0)
        base_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    value_part = parts[1]
                    if value_part.startswith("STRING: "):
                        value = value_part[8:]
                    else:
                        value = value_part
                    # Extract element ID from the end of the OID
                    oid_base = parts[0].strip()
                    # Get last part of OID as element ID
                    oid_elements = oid_base.split(".")
                    if len(oid_elements) > 0:
                        element_id = oid_elements[-1]
                        if element_id.isdigit():
                            item_name = "Library " + element_id
                            items.append({
                                "item": item_name,
                                "params": {},
                                "metrics": []
                            })
        
        # Drive section (index 1)
        base_oid = ".1.3.6.1.4.1.110901.1.2.2.1.1.3"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    oid_base = parts[0].strip()
                    oid_elements = oid_base.split(".")
                    if len(oid_elements) > 0:
                        element_id = oid_elements[-1]
                        if element_id.isdigit():
                            item_name = "Drive " + element_id
                            items.append({
                                "item": item_name,
                                "params": {},
                                "metrics": []
                            })
        
        # Actor section (index 2)
        base_oid = ".1.3.6.1.4.1.110901.1.3.1.1.2"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    oid_base = parts[0].strip()
                    oid_elements = oid_base.split(".")
                    if len(oid_elements) > 0:
                        element_id = oid_elements[-1]
                        if element_id.isdigit():
                            item_name = "Actor " + element_id
                            items.append({
                                "item": item_name,
                                "params": {},
                                "metrics": []
                            })
        
        # Manager section (archive)
        base_oid = ".1.3.6.1.4.1.110901.1.4.1"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            items.append({
                "item": "Manager",
                "params": {},
                "metrics": []
            })
        
        # Objects section (single item)
        base_oid = ".1.3.6.1.4.1.110901.1.4.2"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            items.append({
                "item": "",
                "params": {},
                "metrics": ["managed_object_count", "storage_used"]
            })
        
        # Tapes section (single item)
        base_oid = ".1.3.6.1.4.1.110901.1.4.3"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            items.append({
                "item": "",
                "params": {},
                "metrics": ["tapes_free"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }

    # Normal check mode - check one item
    item = params.get("item", "")
    
    # Check Library status
    if item.startswith("Library "):
        element_id = item[8:]
        base_oid = ".1.3.6.1.4.1.110901.1.2.1.1.1.2." + element_id
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            parts = res.stdout.strip().split(" = ")
            if len(parts) == 2:
                value_part = parts[1]
                if value_part.startswith("STRING: "):
                    reading = value_part[8:].strip().strip('"')
                else:
                    reading = value_part.strip()
                state, summary = status_result(reading)
                state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
                return {
                    "changed": False,
                    "msg": summary,
                    "data": {
                        "state": state_names[state] if state < len(state_names) else "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
        return {
            "changed": False,
            "msg": "Library element %s not found" % element_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check Drive status
    if item.startswith("Drive "):
        element_id = item[6:]
        base_oid = ".1.3.6.1.4.1.110901.1.2.2.1.1.8." + element_id
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            parts = res.stdout.strip().split(" = ")
            if len(parts) == 2:
                value_part = parts[1]
                if value_part.startswith("STRING: "):
                    reading = value_part[8:].strip().strip('"')
                else:
                    reading = value_part.strip()
                state, summary = status_result(reading)
                state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
                return {
                    "changed": False,
                    "msg": summary,
                    "data": {
                        "state": state_names[state] if state < len(state_names) else "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
        return {
            "changed": False,
            "msg": "Drive element %s not found" % element_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check Actor status
    if item.startswith("Actor "):
        element_id = item[6:]
        base_oid = ".1.3.6.1.4.1.110901.1.3.1.1.4." + element_id
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            parts = res.stdout.strip().split(" = ")
            if len(parts) == 2:
                value_part = parts[1]
                if value_part.startswith("STRING: "):
                    reading = value_part[8:].strip().strip('"')
                else:
                    reading = value_part.strip()
                state, summary = status_result(reading)
                state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
                return {
                    "changed": False,
                    "msg": summary,
                    "data": {
                        "state": state_names[state] if state < len(state_names) else "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
        return {
            "changed": False,
            "msg": "Actor element %s not found" % element_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check Manager (archive) status
    if item == "Manager":
        base_oid = ".1.3.6.1.4.1.110901.1.4.1"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0 and " = " in res.stdout:
            parts = res.stdout.strip().split(" = ")
            if len(parts) == 2:
                value_part = parts[1]
                if value_part.startswith("STRING: "):
                    reading = value_part[8:].strip().strip('"')
                else:
                    reading = value_part.strip()
                state, summary = status_result(reading)
                state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
                return {
                    "changed": False,
                    "msg": summary,
                    "data": {
                        "state": state_names[state] if state < len(state_names) else "UNKNOWN",
                        "metrics": {},
                        "details": ""
                    }
                }
        return {
            "changed": False,
            "msg": "Manager status not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check Managed Objects
    if item == "":
        base_oid = ".1.3.6.1.4.1.110901.1.4"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc == 0:
            object_count = 0
            remaining_size = 0
            total_size = 0
            found = False
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    oid_base = parts[0].strip()
                    value_part = parts[1]
                    if value_part.startswith("STRING: "):
                        value = value_part[8:].strip().strip('"')
                    else:
                        value = value_part.strip()
                    
                    if oid_base.endswith(".2"):  # objects count
                        object_count = int(value) if value.isdigit() else 0
                    elif oid_base.endswith(".4"):  # remaining size
                        remaining_size = int(value) if value.isdigit() else 0
                    elif oid_base.endswith(".5"):  # total size
                        total_size = int(value) if value.isdigit() else 0
                        found = True
            
            if found:
                infotext = "managed objects: %d, remaining size: %d GB of %d GB" % (object_count, remaining_size, total_size)
                GB = 1073741824  # 1024*1024*1024
                storage_used = (total_size - remaining_size) * GB
                return {
                    "changed": False,
                    "msg": infotext,
                    "data": {
                        "state": "OK",
                        "metrics": {
                            "managed_object_count": object_count,
                            "storage_used": storage_used
                        },
                        "details": ""
                    }
                }
        return {
            "changed": False,
            "msg": "Managed objects data not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check Blank Tapes
    levels_lower = params.get("levels_lower", [5, 1])
    warn = levels_lower[0] if type(levels_lower) == "list" and len(levels_lower) > 0 else 5
    crit = levels_lower[1] if type(levels_lower) == "list" and len(levels_lower) > 1 else 1
    
    base_oid = ".1.3.6.1.4.1.110901.1.4.3"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc == 0 and " = " in res.stdout:
        parts = res.stdout.strip().split(" = ")
        if len(parts) == 2:
            value_part = parts[1]
            if value_part.startswith("STRING: "):
                blank_tapes_str = value_part[8:].strip().strip('"')
            else:
                blank_tapes_str = value_part.strip()
            blank_tapes = int(blank_tapes_str) if blank_tapes_str.isdigit() else 0
            
            state = "OK"
            summary = "Blank tapes: %d" % blank_tapes
            if blank_tapes <= crit:
                state = "CRIT"
                summary = "Blank tapes: %d (critical)" % blank_tapes
            elif blank_tapes <= warn:
                state = "WARN"
                summary = "Blank tapes: %d (warning)" % blank_tapes
            
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": state,
                    "metrics": {"tapes_free": blank_tapes},
                    "details": ""
                }
            }
    return {
        "changed": False,
        "msg": "Blank tapes data not found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }