def main(ctx, params):
    # Juniper FRU check: read agent output for FRU data via snmpwalk
    # The Checkmk plugin parses agent data; we reproduce by walking
    # the same SNMP table: JUNIPER-CHASSIS-MIB::jnxCmntFruTable
    # Key OIDs: jnxCmntFruType (.1.3.6.1.4.1.2636.13.1.5.1.3)
    #           jnxCmntFruState (.1.3.6.1.4.1.2636.13.1.5.1.4)
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery: enumerate FRUs of type Power Supply (7) or Fan (18 for PS, 13 for fan)
        # Per the original: discover_juniper_fru uses ("7", "18"); discover_juniper_fru_fan uses ("13",)
        # We implement both in discovery and filter later in check if needed.
        # However, this module is for juniper_fru only, so we follow that plugin's discovery.
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            "1.3.6.1.4.1.2636.13.1.5.1.3", "1.3.6.1.4.1.2636.13.1.5.1.4"
        ], mutates=False)

        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }

        # Parse snmpwalk output: lines like:
        # .1.3.6.1.4.1.2636.13.1.5.1.3.1 = INTEGER: 7
        # .1.3.6.1.4.1.2636.13.1.5.1.4.1 = INTEGER: 4
        lines = res.stdout.splitlines()
        # Build index map from the two OID walks
        fru_type_map = {}
        fru_state_map = {}
        for line in lines:
            if "=" not in line:
                continue
            left, right = line.split("=", 1)
            left = left.strip()
            right = right.strip()
            if right.startswith("INTEGER: "):
                val = right[len("INTEGER: "):]
                # Extract index: last number after last dot in OID
                oid_parts = left.split(".")
                idx = oid_parts[-1]
                if left.find(".1.3.6.1.4.1.2636.13.1.5.1.3.") >= 0:
                    fru_type_map[idx] = val
                elif left.find(".1.3.6.1.4.1.2636.13.1.5.1.4.") >= 0:
                    fru_state_map[idx] = val

        # We need to reconstruct the item name from the index.
        # In real Juniper MIBs, the index maps to a physical name like "PSU 1".
        # Since we only get numeric indices, we approximate by "PSU_<index>".
        # Note: This is a limitation of a pure CLI translation; the original agent plugin
        # would use the full OID index including names. For a minimal faithful translation,
        # we assume the agent plugin uses the same index-based naming in practice.
        discovered = []
        seen = set()
        for idx in fru_type_map:
            fru_type = fru_type_map[idx]
            fru_state = fru_state_map.get(idx, "2")  # default "empty" if missing
            if fru_state == "2":
                continue
            if fru_type in ("7", "18"):
                item_name = "PSU_" + idx
                if item_name not in seen:
                    seen.add(item_name)
                    discovered.append({
                        "item": item_name,
                        "params": {},
                        "metrics": []
                    })

        return {
            "changed": False,
            "msg": "discovered %d power supply FRUs" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode
    item = params.get("item", "")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        "1.3.6.1.4.1.2636.13.1.5.1.3", "1.3.6.1.4.1.2636.13.1.5.1.4"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse again to find the specific item
    fru_type_map = {}
    fru_state_map = {}
    # Map idx -> item name
    idx_to_item = {}

    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        left, right = line.split("=", 1)
        left = left.strip()
        right = right.strip()
        if right.startswith("INTEGER: "):
            val = right[len("INTEGER: "):]
            oid_parts = left.split(".")
            idx = oid_parts[-1]
            if left.find(".1.3.6.1.4.1.2636.13.1.5.1.3.") >= 0:
                fru_type_map[idx] = val
                idx_to_item[idx] = "PSU_" + idx
            elif left.find(".1.3.6.1.4.1.2636.13.1.5.1.4.") >= 0:
                fru_state_map[idx] = val

    fru_state = None
    for idx in idx_to_item:
        if idx_to_item[idx] == item:
            fru_state = fru_state_map.get(idx, "2")
            break

    if fru_state == None:
        return {
            "changed": False,
            "msg": "FRU not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map FRU state to Checkmk state
    fru_state_map_juniper = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("CRIT", "empty"),
        "3": ("WARN", "present"),
        "4": ("OK", "ready"),
        "5": ("OK", "announce online"),
        "6": ("OK", "online"),
        "7": ("CRIT", "anounce offline"),
        "8": ("CRIT", "offline"),
        "9": ("WARN", "diagnostic"),
        "10": ("WARN", "standby"),
    }

    state_str, state_readable = fru_state_map_juniper.get(fru_state, ("UNKNOWN", "unknown"))
    return {
        "changed": False,
        "msg": "Operational status: " + state_readable,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }