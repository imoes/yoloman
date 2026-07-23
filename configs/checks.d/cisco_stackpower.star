# Discovery and check for Cisco Stackpower interfaces via SNMP

def main(ctx, params):
    # Discover mode: enumerate enabled interfaces
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Fetch all Stackpower data: OID end, oper status (2), link status (5), port name (7)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.9.9.500.1.3.2.1"
        ], mutates=False)
        
        # Parse snmpwalk output lines: "OID = TYPE: VALUE"
        section = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_str = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip('"')
            else:
                value = value_part.split(": ", 1)[-1] if ": " in value_part else value_part
            
            # OID ends with ".<oid>.<index>" like ".1.3.6.1.4.1.9.9.500.1.3.2.1.2.1001.0"
            # We need to group by base OID (oid without last component) and index
            # Split OID and get components
            oid_comps = oid_str.split(".")
            if len(oid_comps) < 20:  # Sanity check for long OIDs
                continue
            
            # Last component is the instance; second-last is the column
            instance = oid_comps[-1]
            col_oid = oid_comps[-2]
            base_oid = ".".join(oid_comps[:-2])
            
            # Map column OIDs to indices: 2->0 (portOperStatus), 5->1 (portLinkStatus), 7->2 (portName)
            # We'll collect values per base_oid.instance
            if col_oid == "2":
                key = (base_oid, instance)
                # Store in section as (oid_end, oper_status, link_status, port_name)
                section.append([key, "oper", value])
            elif col_oid == "5":
                key = (base_oid, instance)
                # Look for existing entry to complete
                found = False
                for i, entry in enumerate(section):
                    if entry[0] == key and entry[1] == "oper":
                        # Need link status next
                        section[i] = [key, "link", value]
                        found = True
                        break
                if not found:
                    # May appear in different order; store and fill later
                    section.append([key, "link", value])
            elif col_oid == "7":
                key = (base_oid, instance)
                # Store port name and try to complete entry
                found = False
                for i, entry in enumerate(section):
                    if entry[0] == key and entry[1] in ["oper", "link"]:
                        section[i] = [key, "name", value]
                        found = True
                        break
                if not found:
                    section.append([key, "name", value])
        
        # Build clean section list: (oid_end, oper_status, link_status, port_name)
        # where oid_end = base_oid + "." + instance
        clean_section = []
        seen = {}
        for entry in section:
            key, col, value = entry
            base_oid, instance = key
            full_oid = base_oid + "." + instance
            if full_oid not in seen:
                seen[full_oid] = {"oid": full_oid, "oper": "", "link": "", "name": ""}
            if col == "oper":
                seen[full_oid]["oper"] = value
            elif col == "link":
                seen[full_oid]["link"] = value
            elif col == "name":
                seen[full_oid]["name"] = value
        
        # Now construct section list for items with oper_status == "1"
        items = []
        for full_oid, data in seen.items():
            if data["oper"] == "1":
                # item format: "<oid> <port_name>"
                item = "%s %s" % (full_oid.split(".")[-1], data["name"])
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(items),
            "data": {"discovery": items}
        }

    # Check mode for specific item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item provided",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.9.9.500.1.3.2.1"
    ], mutates=False)

    # Parse and group same as discovery
    section = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_str = parts[0].strip()
        value_part = parts[1].strip()
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip('"')
        else:
            value = value_part.split(": ", 1)[-1] if ": " in value_part else value_part
        
        oid_comps = oid_str.split(".")
        if len(oid_comps) < 20:
            continue
        
        instance = oid_comps[-1]
        col_oid = oid_comps[-2]
        base_oid = ".".join(oid_comps[:-2])
        full_oid = base_oid + "." + instance

        if col_oid == "2":
            section.append([full_oid, "oper", value])
        elif col_oid == "5":
            section.append([full_oid, "link", value])
        elif col_oid == "7":
            section.append([full_oid, "name", value])

    # Group by full_oid
    data_by_oid = {}
    for full_oid, col, value in section:
        if full_oid not in data_by_oid:
            data_by_oid[full_oid] = {"oper": "", "name": ""}
        if col == "oper":
            data_by_oid[full_oid]["oper"] = value
        elif col == "name":
            data_by_oid[full_oid]["name"] = value

    # Find matching item
    found = False
    for full_oid, data in data_by_oid.items():
        if item == "%s %s" % (full_oid.split(".")[-1], data["name"]):
            found = True
            oper_status = data["oper"]
            link_status = data["link"]

            # Map status to messages and states
            if oper_status == "1":
                oper_msg = "Port enabled"
                oper_state = "OK"
            elif oper_status == "2":
                oper_msg = "Port disabled"
                oper_state = "CRIT"
            else:
                oper_msg = "Port status unknown"
                oper_state = "UNKNOWN"

            if link_status == "1":
                link_msg = "Status: connected and operational"
                link_state = "OK"
            elif link_status == "2":
                link_msg = "Status: forced down or not connected"
                link_state = "CRIT"
            else:
                link_msg = "Link status unknown"
                link_state = "UNKNOWN"

            # Combine into Checkmk-style message
            msg = "%s; %s" % (oper_msg, link_msg)
            state = "CRIT" if (oper_state == "CRIT" or link_state == "CRIT") else \
                    ("UNKNOWN" if (oper_state == "UNKNOWN" or link_state == "UNKNOWN") else "OK")

            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }

    # Item not found
    if not found:
        return {
            "changed": False,
            "msg": "interface not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
