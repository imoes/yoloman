# Constants for defaults and SNMP base
AIRONET_DEFAULT_STRENGTH_LEVELS = (-25, -20)
AIRONET_DEFAULT_QUALITY_LEVELS = (40, 35)
AIRONET_BASE_OID = ".1.3.6.1.4.1.9.9.273.1.3.1.1"

def _saveint(i):
    """Safely convert string to int; return 0 on failure."""
    if i == "" or i == None:
        return 0
    # Guard: only convert if it's a valid integer string
    stripped = i.strip()
    if stripped == "":
        return 0
    # Handle negative numbers
    neg = False
    if stripped.startswith("-"):
        neg = True
        stripped = stripped[1:]
    if stripped.isdigit():
        return -int(stripped) if neg else int(stripped)
    return 0

def _sum_list(lst):
    """Compute sum of a list of integers."""
    total = 0
    for v in lst:
        total += v
    return total

def _float_div(num, denom):
    """Safe float division."""
    if denom == 0:
        return 0.0
    return float(num) / float(denom)

def main(ctx, params):
    if params.get("_discover"):
        # Discover services: strength, quality, clients
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            AIRONET_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        entries = []
        for line in lines:
            # Parse "OID = TYPE: value" format; we only need the last part (value)
            eq_idx = line.find(" = ")
            if eq_idx == -1:
                continue
            value_part = line.rsplit(" = ", 1)[1].strip()
            # Skip non-numeric values (e.g., STRING: types)
            if value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit()):
                entries.append(value_part)
        
        # We discovered entries if we got any data at all
        if len(entries) > 0:
            discovery = [
                {"item": "strength", "params": {}, "metrics": ["strength"]},
                {"item": "quality", "params": {}, "metrics": ["quality"]},
                {"item": "clients", "params": {}, "metrics": ["clients"]}
            ]
            return {"changed": False, "msg": "discovered 3 services", 
                    "data": {"discovery": discovery}}
        else:
            return {"changed": False, "msg": "discovered 0 services", 
                    "data": {"discovery": []}}

    # Check mode
    item = params.get("item", "")
    
    # Fetch data via SNMP (same OID tree)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        AIRONET_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse entries: each line has signal (idx 0) and quality (idx 1)
    entries = []
    for line in res.stdout.splitlines():
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        value_part = line.rsplit(" = ", 1)[1].strip()
        # Skip non-numeric values (e.g., STRING: types)
        if not (value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit())):
            continue
        entries.append(value_part)
    
    # Convert pairs: odd indices are signal (OID .3), even are quality (OID .4)
    if len(entries) % 2 != 0:
        entries = entries[:len(entries)-1]  # Drop last if odd count
    
    pairs = []
    for i in range(0, len(entries), 2):
        signal = _saveint(entries[i])
        quality = _saveint(entries[i+1])
        pairs.append((signal, quality))
    
    if len(pairs) == 0:
        return {"changed": False, "msg": "No clients currently logged in",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if item == "clients":
        count = len(pairs)
        return {"changed": False, "msg": "%d clients currently logged in" % count,
                "data": {"state": "OK", "metrics": {"clients": count}, "details": ""}}
    
    # Compute average
    if item == "quality":
        values = [pair[1] for pair in pairs]
        avg = _float_div(_sum_list(values), len(values)) if len(values) > 0 else 0.0
        warn, crit = AIRONET_DEFAULT_QUALITY_LEVELS
        unit = "%"
        neg = 1
    else:  # strength
        values = [pair[0] for pair in pairs]
        avg = _float_div(_sum_list(values), len(values)) if len(values) > 0 else 0.0
        warn, crit = AIRONET_DEFAULT_STRENGTH_LEVELS
        unit = "dB"
        neg = -1

    # Determine state
    state = "OK"
    if neg * avg <= neg * crit:
        state = "CRIT"
    elif neg * avg <= neg * warn:
        state = "WARN"
    
    msg = "signal %s at %f%s (warn/crit at %d%s/%d%s)" % (
        item, avg, unit, warn, unit, crit, unit)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {item: avg}, "details": ""}}
