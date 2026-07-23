def main(ctx, params):
    # Discovery mode: enumerate alarm items
    if params.get("_discover"):
        # SNMP walk for the alarm table: base .1.3.6.1.4.1.13595.2.2.1.1
        # OIDs: .1=coHandleModuleLink, .2=coAlarmStatus, .3=coAlarmMode
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.13595.2.2.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse snmpwalk output lines like:
        # .1.3.6.1.4.1.13595.2.2.1.1.2.1.1 = INTEGER: 2
        # .1.3.6.1.4.1.13595.2.2.1.1.2.1.2 = INTEGER: 2
        alarms = []
        lines = res.stdout.splitlines()
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end_str = parts[0].strip()
            if not oid_end_str.startswith(base_oid + ".2."):
                continue
            # Extract item: e.g., ".1.3.6.1.4.1.13595.2.2.1.1.2.1.1" -> item "1"
            tail = oid_end_str[len(base_oid) + 1:]
            # Format: co_index.module_index.component_index
            # We want module_index as the item (second segment)
            segments = tail.split(".")
            if len(segments) < 2:
                continue
            item = segments[1]
            value_str = parts[1].strip()
            # Value 2 means inactive; we skip those (like the original)
            if value_str.isdigit() and int(value_str) == 2:
                continue
            # Find associated remark (description) from the basic_components table
            # by matching module index in the first SNMP table
            # Basic components table OID: .1.3.6.1.4.1.13595.2.1.3.3.1.1
            # OIDs: .1=oidEnd, .2=basModuleStatus, .3=basModuleType, .4=basModuleInfo, .6=basModuleRemark
            basic_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, ".1.3.6.1.4.1.13595.2.1.3.3.1.1"
            ], mutates=False)
            if basic_res.rc != 0:
                continue  # We can't get remark, but still include the alarm without it

            # Build mapping from module index to remark (basModuleRemark)
            module_to_remark = {}
            for basic_line in basic_res.stdout.splitlines():
                if not basic_line.strip():
                    continue
                basic_parts = basic_line.strip().split(" = ")
                if len(basic_parts) != 2:
                    continue
                basic_oid_end = basic_parts[0].strip()
                if not basic_oid_end.startswith(".1.3.6.1.4.1.13595.2.1.3.3.1.1.6."):
                    continue
                # Extract module index: OID ends with .module_index
                basic_tail = basic_oid_end[len(".1.3.6.1.4.1.13595.2.1.3.3.1.1.6."):]
                # basic_tail is the module index
                module_idx = basic_tail.strip()
                remark_raw = basic_parts[1].strip()
                # Convert octet string: e.g., "STRING: 'Name'" or "OCTET STRING: 'Name'"
                # Remove quotes if present
                if remark_raw.startswith("STRING: '") and remark_raw.endswith("'"):
                    remark_raw = remark_raw[9:-1]
                elif remark_raw.startswith("OCTET STRING: '") and remark_raw.endswith("'"):
                    remark_raw = remark_raw[16:-1]
                elif remark_raw.startswith("STRING: \"") and remark_raw.endswith("\""):
                    remark_raw = remark_raw[9:-1]
                elif remark_raw.startswith("OCTET STRING: \"") and remark_raw.endswith("\""):
                    remark_raw = remark_raw[16:-1]
                # Handle empty remark
                if remark_raw == "":
                    continue
                module_to_remark[module_idx] = remark_raw

            # Build item name: if remark exists, use it; otherwise use "Perip <module>"
            if item in module_to_remark:
                itemname = module_to_remark[item]
            else:
                itemname = "Perip " + item

            # Add to alarms list
            alarms.append({
                "item": itemname,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d alarms" % len(alarms),
            "data": {"discovery": alarms}
        }

    # Check mode: single alarm item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch alarm status
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.13595.2.2.1.1.2." + item
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output
    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parts = line.split(" = ")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "cannot parse snmpget response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = parts[1].strip()
    # Extract integer value (e.g., "INTEGER: 3" -> "3")
    if value_str.startswith("INTEGER: "):
        value_str = value_str[9:]
    value = int(value_str) if value_str.isdigit() else -1

    map_states = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "inactive"),
        "3": ("CRIT", "active"),
        "4": ("OK", "latched"),
    }

    if str(value) in map_states:
        state_readable = map_states[str(value)][1]
        state = map_states[str(value)][0]
    else:
        state = "UNKNOWN"
        state_readable = "unknown"

    return {
        "changed": False,
        "msg": "Status: " + state_readable,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
