# ===== Starlark check: pulse_secure_mem_util =====
# Reads Pulse Secure IVE memory and swap utilization from SNMP

def main(ctx, params):
    # Discovery mode: always yield a single service if device is present
    if params.get("_discover"):
        # Detect presence via the same OID as Checkmk (1.3.6.1.4.1.12532.11)
        # We only need to check that the device responds (single scalar OID)
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.12532.11"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 services (no data)",
                    "data": {"discovery": []}}
        # Device is present -> one service
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["mem_used_percent", "swap_used_percent"]}]}}

    # Check mode: fetch memory and swap utilization
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    mem_oid = ".1.3.6.1.4.1.12532.11"
    swap_oid = ".1.3.6.1.4.1.12532.24"

    # Fetch both OIDs in one go (two separate snmpget calls for simplicity and robustness)
    mem_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, mem_oid
    ], mutates=False)
    swap_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, swap_oid
    ], mutates=False)

    # Parse values: extract numeric value from "OID = INTEGER: <value>"
    def extract_int(res):
        if res.rc != 0:
            return None
        for line in res.stdout.splitlines():
            # Format: .1.3.6.1.4.1.12532.11 = INTEGER: 42
            if ": INTEGER:" in line:
                parts = line.rsplit(": ", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if val.isdigit():
                        return int(val)
                # Alternative format: .1.3.6.1.4.1.12532.11 = INTEGER: 42%
                if "% INTEGER:" in line or "%:" in line:
                    # Try to find the number before % sign
                    idx = line.find("%")
                    if idx > 0:
                        candidate = line[max(0, idx-5):idx].strip()
                        if candidate.isdigit():
                            return int(candidate)
        return None

    mem_pct = extract_int(mem_res)
    swap_pct = extract_int(swap_res)

    # Extract thresholds from params (Checkmk defaults)
    mem_levels = params.get("mem_used_percent", (90, 95))
    swap_levels = params.get("swap_used_percent", (5, 101))

    # Compute states and messages
    def check_levels(value, levels):
        if value == None:
            return "UNKNOWN"
        warn, crit = levels
        # upper levels: WARN if value >= warn, CRIT if value >= crit
        if crit < 101 and value >= crit:
            return "CRIT"
        if warn < 101 and value >= warn:
            return "WARN"
        return "OK"

    state = "OK"
    details_parts = []

    if mem_pct != None:
        mem_state = check_levels(mem_pct, mem_levels)
        if mem_state != "OK":
            state = mem_state
        details_parts.append("RAM used: %d%%" % mem_pct)
    else:
        details_parts.append("RAM used: N/A")

    if swap_pct != None:
        swap_state = check_levels(swap_pct, swap_levels)
        if swap_state != "OK":
            state = swap_state
        details_parts.append("Swap used: %d%%" % swap_pct)
    else:
        details_parts.append("Swap used: N/A")

    # Build summary message
    msg = "; ".join(details_parts)

    # Build metrics dict (only numbers)
    metrics = {}
    if mem_pct != None:
        metrics["mem_used_percent"] = mem_pct
    if swap_pct != None:
        metrics["swap_used_percent"] = swap_pct

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        },
    }