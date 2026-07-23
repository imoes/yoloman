# ===== Checkmk check: arbor_memory =====
# Translated to Starlark for yolo-man agent
# Read-only SNMP-based check for Arbor PeakFlow memory usage

# Define the SNMP base OIDs for each device family
OID_BASE_SP = ".1.3.6.1.4.1.9694.1.4.2.1"
OID_BASE_TMS = ".1.3.6.1.4.1.9694.1.5.2"
OID_BASE_PRAVAIL = ".1.3.6.1.4.1.9694.1.6.2"

# SNMP OIDs for RAM and Swap (relative to base)
OID_RAM = "7.0"
OID_SWAP_SP = "10.0"
OID_SWAP_TMS_PRAVAIL = "8.0"

def parse_snmp_value(line):
    # Expected format: ".1.3.6.1.4.1.9694.1.4.2.1.7.0 = INTEGER: 45"
    idx = line.rfind(": ")
    if idx == -1:
        return None
    value_str = line[idx+2:].strip()
    # Remove trailing whitespace or semicolons
    value_str = value_str.strip().rstrip(";")
    # Guard instead of try/except
    if value_str == "" or value_str.find(".") != -1:
        return None
    # Check if it's a valid integer string
    i = 0
    if len(value_str) > 0 and value_str[0] == "-":
        i = 1
    while i < len(value_str):
        if value_str[i] < "0" or value_str[i] > "9":
            return None
        i = i + 1
    return int(value_str)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "levels_ram": ("perc_used", (80.0, 90.0)),
                            "levels_swap": ("perc_used", (80.0, 90.0)),
                        },
                        "metrics": ["mem_used_percent", "swap_used_percent"],
                    },
                ],
            },
        }

    # Check mode
    # Get thresholds from params with Checkmk defaults
    levels_ram = params.get("levels_ram", ("perc_used", (80.0, 90.0)))
    levels_swap = params.get("levels_swap", ("perc_used", (80.0, 90.0)))

    # Determine which device type we're dealing with
    facts = ctx.facts()
    hostname = facts.get("hostname", "localhost")
    community = params.get("community", "public")

    # Try to detect the device type based on SNMP discovery
    # First, try PeakFlow SP base
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", hostname,
        OID_BASE_SP + "." + OID_RAM,
    ], mutates=False)

    # Check if we got valid data for PeakFlow SP
    if res.rc == 0 and res.stdout.find("INTEGER:") != -1:
        base = OID_BASE_SP
        swap_oid = OID_SWAP_SP
    else:
        # Try PeakFlow TMS
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", hostname,
            OID_BASE_TMS + "." + OID_RAM,
        ], mutates=False)
        if res.rc == 0 and res.stdout.find("INTEGER:") != -1:
            base = OID_BASE_TMS
            swap_oid = OID_SWAP_TMS_PRAVAIL
        else:
            # Try PeakFlow Pravail
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", hostname,
                OID_BASE_PRAVAIL + "." + OID_RAM,
            ], mutates=False)
            if res.rc == 0 and res.stdout.find("INTEGER:") != -1:
                base = OID_BASE_PRAVAIL
                swap_oid = OID_SWAP_TMS_PRAVAIL
            else:
                # No matching device found
                return {
                    "changed": False,
                    "msg": "no matching Arbor device found",
                    "data": {
                        "state": "UNKNOWN",
                        "metrics": {},
                        "details": "",
                    },
                }

    # Now get both RAM and Swap values using snmpget (scalar values, single instance)
    ram_oid = base + "." + OID_RAM
    swap_oid = base + "." + swap_oid

    # Get RAM value
    res_ram = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", hostname, ram_oid,
    ], mutates=False)

    # Get Swap value
    res_swap = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", hostname, swap_oid,
    ], mutates=False)

    # Check if we got valid responses
    if res_ram.rc != 0 or res_swap.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse RAM and Swap percentages (format: OID = INTEGER: XX)
    ram_line = res_ram.stdout.strip()
    swap_line = res_swap.stdout.strip()

    # Extract numeric value from response
    ram_percent = parse_snmp_value(ram_line)
    swap_percent = parse_snmp_value(swap_line)

    # Validate parsed values
    if ram_percent == None or swap_percent == None:
        return {
            "changed": False,
            "msg": "failed to parse SNMP values",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Extract threshold values (Checkmk format: ("perc_used", (warn, crit)))
    warn_ram = 80.0
    crit_ram = 90.0
    warn_swap = 80.0
    crit_swap = 90.0
    
    if levels_ram[0] == "perc_used":
        warn_ram = float(levels_ram[1][0])
        crit_ram = float(levels_ram[1][1])
    
    if levels_swap[0] == "perc_used":
        warn_swap = float(levels_swap[1][0])
        crit_swap = float(levels_swap[1][1])

    # Determine states
    state = "OK"
    if ram_percent >= crit_ram or swap_percent >= crit_swap:
        state = "CRIT"
    elif ram_percent >= warn_ram or swap_percent >= warn_swap:
        state = "WARN"

    # Build message
    msg = "Used RAM: %d%%, Used Swap: %d%%" % (ram_percent, swap_percent)

    # Return the check result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "mem_used_percent": ram_percent,
                "swap_used_percent": swap_percent,
            },
            "details": "",
        },
    }
