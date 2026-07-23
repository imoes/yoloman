# Top-level constants (no imports, no classes, no lambdas)
_MAP_STATES = {
    "0": (0, "standby"),
    "1": (0, "on"),
    "2": (1, "not present"),
    "3": (1, "switched off"),
    "255": (2, "not applicable"),
}

def _parse_power_value(s):
    # Parse '123W' -> 123, return 0 on invalid
    s = s.strip()
    if not s.endswith("W"):
        return 0
    num_part = s[:-1]
    return int(num_part) if num_part.isdigit() else 0

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk both SNMP trees to find bay items with state "on" or "standby"
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        out = []
        
        for power_domain, base_oid in [(1, ".1.3.6.1.4.1.2.3.51.2.2.10.2.1.1"), (2, ".1.3.6.1.4.1.2.3.51.2.2.10.3.1.1")]:
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", community,
                "-On", host,
                base_oid
            ], mutates=False)
            if res.rc != 0:
                continue

            # Parse snmpwalk lines: OID = TYPE: value
            entries = {}
            for line in res.stdout.splitlines():
                line = line.strip()
                if not line or "=" not in line:
                    continue
                parts = line.split("=", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0].strip()
                val_raw = parts[1].strip()
                # Extract last segment after last dot for OIDEnd
                last_dot = oid_full.rfind(".")
                if last_dot < 0:
                    continue
                oid_end = oid_full[last_dot+1:]
                # Value type handling: strip quotes from STRING
                if val_raw.startswith('"') and val_raw.endswith('"'):
                    val = val_raw[1:-1]
                else:
                    val = val_raw
                # Store by OIDEnd
                entries.setdefault(oid_end, []).append(val)

            # Reconstruct rows: each OIDEnd corresponds to one row, columns in order of fetch
            for oid_end, vals in entries.items():
                if len(vals) < 6:
                    continue
                # vals: [name, state, type, id, power, power_max] (OIDEnd already used as key)
                name = vals[0]
                state = vals[1]
                ty = vals[2]
                identifier = vals[3]
                power_str = vals[4]
                power_max_str = vals[5]

                itemname = "PD%d %s" % (power_domain, name)
                # Check state mapping
                dev_state = _MAP_STATES.get(state, (3, "unhandled[" + state + "]"))
                # Only yield services with state "on" or "standby"
                if dev_state[1] not in ["standby", "on"]:
                    continue

                out.append({
                    "item": itemname,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d bays" % len(out),
            "data": {"discovery": out},
        }

    # Check mode: one item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    found_data = None
    for power_domain, base in [(1, ".1.3.6.1.4.1.2.3.51.2.2.10.2.1.1"), (2, ".1.3.6.1.4.1.2.3.51.2.2.10.3.1.1")]:
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base
        ], mutates=False)
        if res.rc != 0:
            continue

        # Parse: collect rows by OIDEnd
        entries = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            val_raw = parts[1].strip()
            last_dot = oid_full.rfind(".")
            if last_dot < 0:
                continue
            oid_end = oid_full[last_dot+1:]
            # Strip quotes for STRING
            if val_raw.startswith('"') and val_raw.endswith('"'):
                val = val_raw[1:-1]
            else:
                val = val_raw
            entries.setdefault(oid_end, []).append(val)

        for oid_end, vals in entries.items():
            if len(vals) < 6:
                continue
            name = vals[0]
            state = vals[1]
            ty = vals[2]
            identifier = vals[3]
            power_str = vals[4]
            power_max_str = vals[5]

            itemname = "PD%d %s" % (power_domain, name)
            if itemname == item:
                power = _parse_power_value(power_str)
                power_max = _parse_power_value(power_max_str)

                dev_state = _MAP_STATES.get(state, (3, "unhandled[" + state + "]"))
                found_data = {
                    "type": ty.split("(")[0],
                    "id": identifier,
                    "power_max": power_max,
                    "device_state": dev_state,
                    "power": power
                }
                break

        if found_data != None:
            break

    if found_data == None:
        return {
            "changed": False,
            "msg": "No data for '" + item + "' in SNMP info",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_int, state_readable = found_data["device_state"]
    state = "OK" if state_int == 0 else ("WARN" if state_int == 1 else "CRIT")

    # Return summary and metrics
    metrics = {}
    metrics["power"] = found_data["power"]
    metrics["power_max"] = found_data["power_max"]

    return {
        "changed": False,
        "msg": "Status: %s, Max. power: %d W, ID: %s" % (state_readable, found_data["power_max"], found_data["id"]),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
