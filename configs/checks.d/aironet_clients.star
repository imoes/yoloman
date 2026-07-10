def main(ctx, params):
    # Discovery mode: enumerate the three items (strength, quality, clients)
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.4.1.9.9.273.1.3.1.1"], mutates=False)
        # Skip if snmpwalk fails or no data
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        # Count number of clients = number of entries (each line is one client record)
        client_count = len(lines) // 2  # Each client has two OIDs: signal (3) and quality (4)
        discovery = [
            {"item": "strength", "params": {}, "metrics": ["strength"]},
            {"item": "quality", "params": {}, "metrics": ["quality"]},
            {"item": "clients", "params": {}, "metrics": ["clients"]},
        ]
        return {"changed": False, "msg": "discovered 3 items",
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    # Read SNMP data: fetch signal (oid .3) and quality (oid .4) for each client entry
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", "1.3.6.1.4.1.9.9.273.1.3.1.1"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
    # Map raw SNMP output to (signal, quality) pairs per client
    section = []
    for i in range(0, len(lines), 2):
        if i + 1 < len(lines):
            # Extract numeric value from "oid .N = INTEGER: value"
            signal_str = lines[i].split(":")[-1].strip()
            quality_str = lines[i+1].split(":")[-1].strip()
            # Validate integers manually (no try/except in Starlark)
            signal_valid = True
            quality_valid = True
            for c in signal_str:
                if c < "0" or c > "9":
                    signal_valid = False
                    break
            for c in quality_str:
                if c < "0" or c > "9":
                    quality_valid = False
                    break
            if signal_valid and quality_valid:
                signal = int(signal_str)
                quality = int(quality_str)
                section.append([signal, quality])
            # Skip malformed entries silently

    if not section:
        return {"changed": False, "msg": "No clients currently logged in",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if item == "clients":
        count = len(section)
        return {"changed": False, "msg": "%d clients currently logged in" % count,
                "data": {"state": "OK", "metrics": {"clients": count}, "details": ""}}

    if item == "quality":
        index = 1
        mmin = 0
        mmax = 100
        unit = "%"
        neg = 1
        warn, crit = (40, 35)  # default aironet_default_quality_levels
    else:  # item == "strength"
        index = 0
        mmin = None
        mmax = 0
        unit = "dB"
        neg = -1
        warn, crit = (-25, -20)  # default aironet_default_strength_levels

    total = 0
    for line in section:
        total = total + int(line[index])

    avg = float(total) / float(len(section)) if len(section) > 0 else 0.0

    # Determine state based on levels
    if neg * avg <= neg * crit:
        state = "CRIT"
    elif neg * avg <= neg * warn:
        state = "WARN"
    else:
        state = "OK"

    infotxt = "signal %s at %.1f%s (warn/crit at %s%s/%s%s)" % (
        item, avg, unit, warn, unit, crit, unit
    )

    return {"changed": False, "msg": infotxt,
            "data": {"state": state, "metrics": {item: avg}, "details": ""}}
