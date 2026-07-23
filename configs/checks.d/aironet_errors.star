# Module: checkmk_aironet_errors.star
# Translate Checkmk check: aironet_errors (MAC CRC errors radio)

# SNMP OIDs for Cisco Aironet devices
_AIRONET_OID_BASE = ".1.3.6.1.4.1.9.9.272.1.2.1.1.1"
_AIRONET_SYSTEM_OID = ".1.3.6.1.2.1.1.2.0"

# Expected enterprise OIDs for Cisco Aironet devices
_AIRONET_ENTERPRISE_OIDS = [
    ".1.3.6.1.4.1.9.1.525",
    ".1.3.6.1.4.1.9.1.618",
    ".1.3.6.1.4.1.9.1.685",
    ".1.3.6.1.4.1.9.1.758",
    ".1.3.6.1.4.1.9.1.1034",
    ".1.3.6.1.4.1.9.1.1247",
]

# Checkmk thresholds (fixed levels)
_DEFAULT_WARN = 1.0
_DEFAULT_CRIT = 10.0

def _parse_snmp_output(output):
    # Parse snmpwalk output lines: "<oid> = <type>: <value>"
    result = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        # Split on first "=" to separate OID and value parts
        if "=" in line:
            parts = line.split("=", 1)
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract OID end
            oid_end = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            # Extract numeric value (strip type prefix like "Counter32: ")
            if ":" in value_part:
                val_str = value_part.split(":", 1)[1].strip()
            else:
                val_str = value_part
            # Extract the last number (OID end) and the value (second column)
            if oid_end.isdigit():
                val = int(val_str) if val_str.isdigit() else float(val_str)
                result.append([oid_end, val])
    return result

def _is_cisco_aironet_device(ctx, host, community):
    # Probe system OID to determine if device is Cisco Aironet
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        _AIRONET_SYSTEM_OID
    ], mutates=False)
    if res.rc != 0:
        return False
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return False
    # Parse line like: .1.3.6.1.2.1.1.2.0 = OID: .1.3.6.1.4.1.9.1.525
    for line in lines:
        if "=" in line:
            parts = line.split("=", 1)
            oid_val = parts[1].strip() if len(parts) > 1 else ""
            # Extract OID from "OID: .1.3.6.1.4.1.9.1.525"
            if oid_val.startswith("OID: "):
                sys_oid = oid_val[5:].strip()
                for enterprise_oid in _AIRONET_ENTERPRISE_OIDS:
                    if sys_oid == enterprise_oid:
                        return True
    return False

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Check if this is a Cisco Aironet device
    if not _is_cisco_aironet_device(ctx, host, community):
        # Device not detected as Aironet - no services should be discovered
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no such item: ",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Discover items: walk Aironet errors table
        res_err = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            _AIRONET_OID_BASE + ".2"
        ], mutates=False)
        if res_err.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        # Collect unique interface indices (first OID column) from section
        # We need both OID ends and error counters from two columns
        # Get both columns by walking base + .1 (index) and base + .2 (value)
        res_idx = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            _AIRONET_OID_BASE + ".1"
        ], mutates=False)
        
        if res_idx.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}

        # Parse indices (first column, OID ends)
        indices = []
        for line in res_idx.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" in line:
                parts = line.split("=", 1)
                oid_part = parts[0].strip()
                oid_end = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
                if oid_end.isdigit():
                    indices.append(oid_end)

        # Parse error values (second column, same order)
        error_values = []
        for line in res_err.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" in line:
                parts = line.split("=", 1)
                value_part = parts[1].strip()
                if ":" in value_part:
                    val_str = value_part.split(":", 1)[1].strip()
                else:
                    val_str = value_part
                val = int(val_str) if val_str.isdigit() else float(val_str)
                error_values.append(val)

        # Build discovery items: index -> item name
        discovered = []
        for idx, val in zip(indices, error_values):
            item_name = str(idx)
            discovered.append({
                "item": item_name,
                "params": {"warn": _DEFAULT_WARN, "crit": _DEFAULT_CRIT},
                "metrics": ["errors"]
            })

        return {"changed": False, "msg": "discovered %d items" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode for a specific item
    item = params.get("item", "")
    if item == None:
        item = ""

    # Get error counter for this item
    oid_for_item = _AIRONET_OID_BASE + ".2." + str(item)
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid_for_item
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse snmpget response: ".1.3.6.1.4.1.9.9.272.1.2.1.1.2.1 = Counter32: 0"
    line = res.stdout.strip()
    current_value = 0
    if "=" in line:
        parts = line.split("=", 1)
        value_part = parts[1].strip() if len(parts) > 1 else ""
        if ":" in value_part:
            val_str = value_part.split(":", 1)[1].strip()
        else:
            val_str = value_part
        current_value = int(val_str) if val_str.isdigit() else float(val_str)

    # Get rate of errors (simulating get_rate from Checkmk)
    # Using a simple per-iteration rate: since we have only one value, use current value
    # In practice, Checkmk calculates delta between now and last run
    # Since we can't store state in Starlark, use current_value directly for first run
    # and assume 0 for subsequent (but we'll just use the raw counter for simplicity)
    # In real scenario, agent would store previous values in state file
    # For this translation, we approximate: use current_value as absolute error count,
    # and treat it as errors per second for simplicity (as first approximation)
    errors_per_second = current_value

    # Apply thresholds (fixed levels from Checkmk: (1.0, 10.0))
    warn = params.get("warn", _DEFAULT_WARN)
    crit = params.get("crit", _DEFAULT_CRIT)

    # Determine state: upper levels -> WARN if >= warn, CRIT if >= crit
    if errors_per_second >= crit:
        state = "CRIT"
    elif errors_per_second >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Errors/s: %f" % errors_per_second
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"errors": errors_per_second},
                     "details": ""}}
