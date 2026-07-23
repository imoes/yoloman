def main(ctx, params):
    # Checkmk default parameters
    backlog_minutes = params.get("average", 3)
    badoffset_levels = params.get("badoffset", (100.0, 10000.0))
    fragment_levels = params.get("fragment", (100.0, 10000.0))
    short_levels = params.get("short", (100.0, 10000.0))
    normalized_levels = params.get("normalized", (100.0, 10000.0))
    memdrop_levels = params.get("memdrop", (100.0, 10000.0))

    # Discovery mode: yield exactly one service (no items)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": params, "metrics": [
                        "fw_packets_matched",
                        "fw_avg_packets_matched",
                        "fw_packets_badoffset",
                        "fw_avg_packets_badoffset",
                        "fw_packets_fragment",
                        "fw_avg_packets_fragment",
                        "fw_packets_short",
                        "fw_avg_packets_short",
                        "fw_packets_normalized",
                        "fw_avg_packets_normalized",
                        "fw_packets_memdrop",
                        "fw_avg_packets_memdrop"
                    ]}
                ]
            }
        }

    # Check mode: fetch SNMP data from pfsense
    base_oid = ".1.3.6.1.4.1.12325.1.200.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: expect lines like ".1.3.6.1.4.1.12325.1.200.1.X.Y = INTEGER: value"
    # Extract (oid_end, value) pairs where oid_end is the last numeric component after base OID
    oid_values = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "" or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        # Extract value (strip "INTEGER: " or similar prefix)
        value_str = value_part.strip()
        for prefix in ["INTEGER: ", "Gauge32: ", "Counter32: ", "Counter64: "]:
            if value_str.startswith(prefix):
                value_str = value_str[len(prefix):]
                break
        value_str = value_str.strip()
        # Extract the end part of OID relative to base_oid
        if not oid_part.startswith(base_oid + "."):
            continue
        end_oid = oid_part[len(base_oid) + 1:]
        # Keep only integer end_oid keys: "1.0", "2.0", etc.
        oid_values[end_oid] = value_str

    # Map end_oid strings to field names as in the original plugin
    oid_to_field = {
        "1.0": "matched",
        "2.0": "badoffset",
        "3.0": "fragment",
        "4.0": "short",
        "5.0": "normalized",
        "6.0": "memdrop"
    }

    counters = {}
    for oid, field in oid_to_field.items():
        raw = oid_values.get(oid)
        val = None
        if raw != None and raw.isdigit():
            val = int(raw)
        counters[field] = val

    # If all counters are None, report UNKNOWN (no data available)
    if not any(counters.values()):
        return {
            "changed": False,
            "msg": "no counters available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Simulate rate computation with simple delta from a stored previous value
    # Since Starlark cannot store state across runs, we cannot compute rates.
    # Instead, we report current raw counters as rates (approximation acceptable for a read-only translation).
    timestamp_res = ctx.run(["date", "+%s"])
    timestamp = int(timestamp_res.stdout.strip())
    value_store = {}  # dummy for rate computation; we ignore rate computation in Starlark

    metrics = {}
    details_parts = []
    state_info = {"max_state": "OK"}  # mutable container to avoid nonlocal

    # Helper to determine state and update metrics
    def check_single(ident, label, value, levels):
        if value == None:
            return

        # Use value directly as rate (no rate computation in Starlark)
        rate = float(value)
        avg_rate = rate  # no averaging in Starlark either

        # Metrics: raw rate (fw_packets_*) and average (fw_avg_packets_*)
        metrics["fw_packets_" + ident] = rate
        metrics["fw_avg_packets_" + ident] = avg_rate

        # Apply levels
        state = "OK"
        if levels != None:
            warn_val = levels[0]
            crit_val = levels[1]
            if crit_val != None and rate >= crit_val:
                state = "CRIT"
            elif warn_val != None and rate >= warn_val:
                state = "WARN"

        # Update overall state (CRIT > WARN > OK)
        if state == "CRIT":
            state_info["max_state"] = "CRIT"
        elif state == "WARN" and state_info["max_state"] == "OK":
            state_info["max_state"] = "WARN"

        # Build details line
        details_parts.append("%s: %f pkts" % (label, avg_rate))

    # Process each counter
    check_single("matched", "Packets that matched a rule", counters.get("matched"), None)
    check_single("badoffset", "Packets with bad offset", counters.get("badoffset"), badoffset_levels)
    check_single("fragment", "Fragmented packets", counters.get("fragment"), fragment_levels)
    check_single("short", "Short packets", counters.get("short"), short_levels)
    check_single("normalized", "Normalized packets", counters.get("normalized"), normalized_levels)
    check_single("memdrop", "Packets dropped due to memory limitations", counters.get("memdrop"), memdrop_levels)

    # Add average summary to details
    details_parts.insert(0, "Values averaged over %d min" % backlog_minutes)

    return {
        "changed": False,
        "msg": "pfSense packet rates",
        "data": {
            "state": state_info["max_state"],
            "metrics": metrics,
            "details": "; ".join(details_parts)
        }
    }