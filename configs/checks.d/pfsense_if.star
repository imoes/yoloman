
def main(ctx, params):
    # Constants
    BASE_OID = ".1.3.6.1.4.1.12325.1.200.1.8.2.1"
    OID_INTERFACE = BASE_OID + ".2"  # OID 2 in base
    OID_IPV4_IN_BLOCKED = BASE_OID + ".12"  # OID 12 in base

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: get all interface names and their IPv4 blocked count
        # snmpwalk base OID and parse (name,value) pairs
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, BASE_OID
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Map OID suffix to (name, value)
        # Expected format: .1.3.6.1.4.1.12325.1.200.1.8.2.1.2.<idx> = STRING: "<name>"
        #                  .1.3.6.1.4.1.12325.1.200.1.8.2.1.12.<idx> = Counter32: <count>
        # Parse by grouping by index
        idx_to_name = {}
        idx_to_blocked = {}

        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract index
            if oid_part.startswith(OID_INTERFACE + "."):
                idx = oid_part[len(OID_INTERFACE) + 1:]
                name = value_part.strip().strip('"')
                idx_to_name[idx] = name
            elif oid_part.startswith(OID_IPV4_IN_BLOCKED + "."):
                idx = oid_part[len(OID_IPV4_IN_BLOCKED) + 1:]
                # value is Counter32: <number>
                if value_part.strip().startswith("Counter32:"):
                    num_str = value_part.strip()[10:].strip()
                    idx_to_blocked[idx] = num_str
                else:
                    # Try plain number
                    idx_to_blocked[idx] = value_part.strip()

        # Combine by index: only include if both name and blocked exist
        discovered = []
        for idx in idx_to_name:
            if idx in idx_to_blocked and idx_to_name[idx]:
                item = idx_to_name[idx]
                # Default params: fixed levels (100.0, 10000.0)
                discovered.append({
                    "item": item,
                    "params": {"ipv4_in_blocked": ["fixed", [100.0, 10000.0]]},
                    "metrics": ["ip4_in_blocked"]
                })

        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode: item present
    item = params.get("item", "")

    # Get current counter value
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, OID_IPV4_IN_BLOCKED + "." + item
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "interface %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse value: ".1.3.6.1.4.1.12325.1.200.1.8.2.1.12.<item> = Counter32: 123456"
    line = res.stdout.strip()
    if "=" not in line:
        return {
            "changed": False,
            "msg": "unexpected snmpget output for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value_part = line.split("=", 1)[1].strip()
    if value_part.startswith("Counter32:"):
        value_str = value_part[10:].strip()
    else:
        value_str = value_part

    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "non-numeric counter value for %s: %s" % (item, value_str),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    current = int(value_str)

    # Use rate calculation with value_store
    # Simulate get_rate: store current value and compute rate since last call
    # In Starlark, we simulate value_store via ctx.facts() persistence? No — we must use a workaround:
    # Since this is read-only, we approximate rate as 0 if no history, and we can't store state.
    # Checkmk's check uses get_rate which needs value_store — but our agent has no state.
    # Therefore we return the absolute counter value as a workaround (since rate requires state).
    # However, per the plugin spec, it uses get_rate — so we simulate a single-sample rate of 0.
    # This is acceptable in read-only mode without value_store.

    # To simulate value_store, we use ctx.stat() to check for a hidden state file?
    # But the contract forbids file mutations (no write) and file_read is read-only.
    # We cannot store state — thus we must assume 0 rate (or emit a warning).
    # Since the Checkmk plugin depends on value_store, we fallback to emitting the raw value.
    # However, per the contract: "gather data ONLY through ctx.* builtins".
    # There's no persistent state in this context — so we report "UNKNOWN" with a note.

    # For this translation, we use the raw value (since we can't compute rate) and set state to UNKNOWN.
    # This matches reality: this check requires rate calculation and cannot work without value_store.

    # But wait: the agent output is static — it's a counter, so we need two samples.
    # Since we have only one sample, we return UNKNOWN.

    # However, Checkmk's pfsense_if agent section parses from JSON; if our agent has the same data,
    # we could use a file? But the Checkmk check uses SNMP, not agent.

    # In this Starlark context, we cannot store state, so we approximate:
    # We return the raw counter value as a metric "ip4_in_blocked" with rate=0, and warn if 0.

    # But the spec demands a rate. So we simulate by assuming no previous value → rate 0.

    rate_val = 0.0  # Because no state, can't compute rate
    value_store_key = "pfsense_if_" + item + "_ip4_in_blocked"

    # Since we cannot store state, we always return 0.0 for rate.
    # Instead, to make the check usable, we report the raw value and warn/crit against that.

    warn = params.get("ipv4_in_blocked")
    crit = params.get("ipv4_in_blocked")
    # Checkmk default: ["fixed", [100.0, 10000.0]]
    # So warn_level = 100.0, crit_level = 10000.0
    warn_level = 100.0
    crit_level = 10000.0
    if isinstance(warn, list) and len(warn) == 2 and isinstance(warn[1], list):
        warn_level = warn[1][0]
        crit_level = warn[1][1]

    # Use raw value (packets) instead of rate since no rate possible without state
    # But plugin expects rate. So we set rate = raw_value (incorrect but functional)
    # Better: treat the raw value as packets per some interval? No — we must return UNKNOWN.

    # For compliance with the plugin spec, we return UNKNOWN because rate cannot be computed.
    return {
        "changed": False,
        "msg": "cannot compute rate without value store",
        "data": {"state": "UNKNOWN", "metrics": {"ip4_in_blocked": 0.0}, "details": ""}
    }