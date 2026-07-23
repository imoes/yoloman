def main(ctx, params):
    # SNMP base OID for outlet/relay sensors
    base_oid = ".1.3.6.1.4.1.46501.5.3.1"

    # Discover mode: enumerate relay sensors
    if params.get("_discover"):
        # Fetch relay-related SNMP data: oids 4 (name), 5 (status), 6 (value), 7 (levels)
        # Note: Checkmk fetches oids [4,5,6,7] under base_oid
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)

        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse snmpwalk output lines: "<OID> = <TYPE>: <value>"
        relay_items = []
        current_relay = None
        relay_data = {}
        expected_oids = [".4", ".5", ".6", ".7"]  # relative to base_oid

        # Build a map of relay name -> [status, value, warn, crit, warn_l, crit_l]
        relay_oids = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value_part = parts
            value = value_part.strip().split(": ", 1)
            if len(value) != 2:
                continue
            oid_suffix = full_oid[len(base_oid):]
            if not oid_suffix.startswith("."):
                continue
            suffix = oid_suffix[1:]
            if suffix in expected_oids:
                # Extract relay index: e.g., ".4.1.1.2.1" -> index part after ".4"
                # But simpler: parse relay name from .4.1.1.2.1 -> use base + ".4"
                # Since we only care about relays, group by first number after base_oid
                # We'll extract relay name from .4.X.Y.Z.W -> use X.Y.Z.W as relay identifier
                relay_id = suffix.split(".", 1)[1] if "." in suffix else suffix
                relay_oid_key = relay_id
                relay_oids.setdefault(relay_oid_key, {})[suffix.split(".", 1)[0]] = value[1]

        # Now map relay_id -> relay name, status, value, levels
        for relay_id, data_map in relay_oids.items():
            name = data_map.get("4")
            status = data_map.get("5", "").strip().lower()
            value_str = data_map.get("6", "")
            warn_str = data_map.get("7")
            crit_str = data_map.get("7")  # Checkmk fetches 4 values: name, status, value, levels (4 values total)
            # But note: the agent uses oids [4,5,6,7], meaning all are scalar per relay
            # In the original code: line[:3] = ty,name,status; line[3] = value; line[4:] = crit_lower,warn_lower,warn,crit
            # So for outlets, we need 8 values: ty,name,status,value,warn,crit,warn_l,crit_l — but this check only fetches 4
            # Looking at the source: fetch=SNMPTree(base=".1.3.6.1.4.1.46501.5.3.1", oids=["4","5","6","7"])
            # That means 4 values per instance — but parse_didactum_sensors expects up to 8 columns.
            # Re-examining: the agent plugin actually fetches multiple columns; however, the check is for relay outlets.
            # In practice: "outlet" sensors only provide name, status, and maybe value — no numeric levels.
            # So for relay, we only have name (oid 4), status (oid 5), value (oid 6) is often empty.
            # We'll use what we have.

            # Status mapping
            state_map = {
                "alarm": "CRIT", "high alarm": "CRIT", "low alarm": "CRIT",
                "warning": "WARN", "high warning": "WARN", "low warning": "WARN",
                "normal": "OK", "not connected": "UNKNOWN", "on": "OK", "off": "UNKNOWN"
            }
            # Normalize status
            if status in state_map:
                state = state_map[status]
                state_readable = status
            else:
                state = "UNKNOWN"
                state_readable = "unknown[" + status + "]"

            # Skip 'off' and 'not connected'
            if state_readable in ("off", "not connected"):
                continue

            if name and state_readable != "":
                # No thresholds for relay (no numeric levels in this fetch)
                relay_items.append({
                    "item": name,
                    "params": {},  # no thresholds for relay status
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d relays" % len(relay_items),
                "data": {"discovery": relay_items}}

    # Check mode: verify one relay
    item = params.get("item", "")

    # Get SNMP data again — same as discovery
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse relay name -> status
    relay_status = None
    relay_state_readable = None

    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        full_oid, value_part = parts
        value = value_part.strip().split(": ", 1)
        if len(value) != 2:
            continue
        oid_suffix = full_oid[len(base_oid):]
        if not oid_suffix.startswith("."):
            continue
        suffix = oid_suffix[1:]
        # We need both name (.4) and status (.5) — but they are separate rows
        # Better: group by relay instance index — we'll do a simpler approach:
        # Extract name (oid .4) and match next .5 for same relay
        # Since snmpwalk returns in order, track previous name
        if suffix.startswith("4."):
            # This is the name line for a relay — next line is status
            relay_name = value[1].strip()
            # Get next line for status
        elif suffix.startswith("5."):
            relay_status = value[1].strip().lower()
            # Now we need to know which name this belongs to — we'll iterate with state
            pass

    # Simpler: parse all and match item by scanning
    relay_name = None
    relay_status = None

    # Re-scan for exact match
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            i += 1
            continue
        full_oid, value_part = parts
        value = value_part.strip().split(": ", 1)
        if len(value) != 2:
            i += 1
            continue
        oid_suffix = full_oid[len(base_oid):]
        if oid_suffix.startswith(".4."):
            # Name line
            relay_name = value[1].strip()
            if relay_name == item:
                # Next line should be status (.5)
                if i + 1 < len(lines):
                    next_line = lines[i + 1].strip()
                    next_parts = next_line.split(" = ")
                    if len(next_parts) == 2:
                        next_oid, next_value_part = next_parts
                        if next_oid[len(base_oid):].strip().startswith(".5"):
                            next_val = next_value_part.strip().split(": ", 1)
                            if len(next_val) == 2:
                                relay_status = next_val[1].strip().lower()
                break
        i += 1

    if relay_status == None or relay_name == None:
        # Try alternate scan — relay items may have same OID index
        # Instead, use the full OID to match item
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value_part = parts
            value = value_part.strip().split(": ", 1)
            if len(value) != 2:
                continue
            oid_suffix = full_oid[len(base_oid):]
            # Match the relay index for both name and status
            if oid_suffix.startswith(".4."):
                relay_name = value[1].strip()
                if relay_name == item:
                    # Find status line for same index
                    for other_line in res.stdout.splitlines():
                        if not other_line.strip():
                            continue
                        other_parts = other_line.strip().split(" = ")
                        if len(other_parts) != 2:
                            continue
                        other_oid, other_value_part = other_parts
                        other_value = other_value_part.strip().split(": ", 1)
                        if len(other_value) != 2:
                            continue
                        other_oid_suffix = other_oid[len(base_oid):]
                        if other_oid_suffix.startswith(".5.") and other_oid_suffix[3:] == oid_suffix[3:]:
                            relay_status = other_value[1].strip().lower()
                            break
                    break
            elif oid_suffix.startswith(".5."):
                relay_status = value[1].strip().lower()
                # Try to find name line with same index
                for other_line in res.stdout.splitlines():
                    if not other_line.strip():
                        continue
                    other_parts = other_line.strip().split(" = ")
                    if len(other_parts) != 2:
                        continue
                    other_oid, other_value_part = other_parts
                    other_value = other_value_part.strip().split(": ", 1)
                    if len(other_value) != 2:
                        continue
                    other_oid_suffix = other_oid[len(base_oid):]
                    if other_oid_suffix.startswith(".4.") and other_oid_suffix[3:] == oid_suffix[3:]:
                        relay_name = other_value[1].strip()
                        break
                break

    # If still not matched, try last-resort: item must be in name
    if relay_name == None:
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value_part = parts
            value = value_part.strip().split(": ", 1)
            if len(value) != 2:
                continue
            oid_suffix = full_oid[len(base_oid):]
            if oid_suffix.startswith(".4.") and value[1].strip() == item:
                relay_name = value[1].strip()
                # Find status for same index
                for other_line in res.stdout.splitlines():
                    if not other_line.strip():
                        continue
                    other_parts = other_line.strip().split(" = ")
                    if len(other_parts) != 2:
                        continue
                    other_oid, other_value_part = other_parts
                    other_value = other_value_part.strip().split(": ", 1)
                    if len(other_value) != 2:
                        continue
                    other_oid_suffix = other_oid[len(base_oid):]
                    if other_oid_suffix.startswith(".5.") and other_oid_suffix[3:] == oid_suffix[3:]:
                        relay_status = other_value[1].strip().lower()
                        break
                break

    # Final check
    if relay_name == None or relay_status == None:
        return {"changed": False, "msg": "relay not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map status to Checkmk state
    state_map = {
        "alarm": "CRIT", "high alarm": "CRIT", "low alarm": "CRIT",
        "warning": "WARN", "high warning": "WARN", "low warning": "WARN",
        "normal": "OK", "not connected": "UNKNOWN", "on": "OK", "off": "UNKNOWN"
    }

    if relay_status in state_map:
        state = state_map[relay_status]
        state_readable = relay_status
    else:
        state = "UNKNOWN"
        state_readable = "unknown[" + relay_status + "]"

    # Return result — no metrics for relay status
    return {"changed": False,
            "msg": "Status: " + state_readable,
            "data": {"state": state, "metrics": {}, "details": ""}}
