# stormshield_updates starlark check module (read-only, SNMP-based)

def main(ctx, params):
    if params.get("_discover"):
        # Discover subsystems with valid update states
        items = []
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.11256.1.9.1.1"
        ], mutates=False)
        if res.rc != 0:
            # No SNMP data available; return empty discovery
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Parse snmpwalk output: each line is like ".oid = STRING: subsystem|state|lastrun"
        lines = res.stdout.splitlines()
        # Map index to (subsystem, state, lastrun)
        entries = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            # Extract numeric OID suffix
            if oid_full.startswith(".1.3.6.1.4.1.11256.1.9.1.1."):
                suffix = oid_full.rsplit(".", 1)[-1]
                # Each instance has three OIDs: .1 (subsystem), .2 (state), .3 (lastrun)
                idx = suffix
                if idx not in entries:
                    entries[idx] = {"subsystem": "", "state": "", "lastrun": ""}
                if suffix.endswith(".1"):
                    # subsystem
                    # Remove quotes if present (STRING: value)
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["subsystem"] = v
                elif suffix.endswith(".2"):
                    # state
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["state"] = v
                elif suffix.endswith(".3"):
                    # lastrun
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["lastrun"] = v

        # Now filter for discovery: skip "Failed" with empty lastrun, skip "Not Available" and "Never started"
        for idx in entries:
            e = entries[idx]
            state = e["state"]
            lastrun = e["lastrun"]
            if state == "Failed" and lastrun == "":
                continue
            if state not in ["Not Available", "Never started"]:
                items.append({"item": e["subsystem"], "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    # Reuse the same SNMP data as in discovery
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.11256.1.9.1.1"
    ], mutates=False)

    STATE_MAP = {
        "Not Available": "WARN",
        "Broken": "CRIT",
        "Uptodate": "OK",
        "Disabled": "WARN",
        "Never started": "OK",
        "Running": "OK",
        "Failed": "CRIT",
    }

    state = "UNKNOWN"
    lastrun = "Never"
    infotext = "Subsystem not found"

    if res.rc == 0:
        entries = {}
        lines = res.stdout.splitlines()
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            if oid_full.startswith(".1.3.6.1.4.1.11256.1.9.1.1."):
                suffix = oid_full.rsplit(".", 1)[-1]
                idx = suffix
                if idx not in entries:
                    entries[idx] = {"subsystem": "", "state": "", "lastrun": ""}
                if suffix.endswith(".1"):
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["subsystem"] = v
                elif suffix.endswith(".2"):
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["state"] = v
                elif suffix.endswith(".3"):
                    v = value
                    if v.startswith("STRING: "):
                        v = v[8:]
                    if v.startswith('"') and v.endswith('"'):
                        v = v[1:-1]
                    entries[idx]["lastrun"] = v

        for idx in entries:
            e = entries[idx]
            if e["subsystem"] == item:
                state = e["state"]
                lastrun = e["lastrun"]
                if lastrun == "":
                    lastrun = "Never"
                infotext = "Subsystem %s is %s, last update: %s" % (item, state, lastrun)
                state = STATE_MAP.get(state, "CRIT")
                break

    # Return check result
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }