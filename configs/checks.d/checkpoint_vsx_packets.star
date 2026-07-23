# Module for checkmk.checkpoint_vsx_packets
# Read-only Starlark check module translating the Checkmk packet check

# SNMP OID base for checkpoint VSX packet counters
_OID_BASE_STATUS = ".1.3.6.1.4.1.2620.1.16.22.1.1"
_OID_BASE_COUNTERS = ".1.3.6.1.4.1.2620.1.16.23.1.1"

# Default thresholds (no_levels)
_DEFAULT_LEVELS = ("no_levels", None)


def _opt_int(raw):
    # Starlark has no try/except - use guard instead
    return int(raw) if raw.isdigit() or (raw.startswith("-") and raw[1:].isdigit()) else None


def _get_rate(value, time_delta):
    # Rate calculation: value_per_sec = value / time_delta
    # Since value is cumulative, we divide by elapsed time
    if value == None:
        return None
    return float(value) / float(time_delta)


def main(ctx, params):
    # Discovery mode: enumerate VS instances with packet counters via SNMP
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        time_delta = 300  # assume 5-minute check interval

        # Fetch status section OIDs: vs_id, vs_name, vs_type, vs_ip, vs_policy, vs_policy_type, vs_sic_status, vs_ha_status
        status_oids = ["1", "3", "4", "5", "6", "7", "8", "9"]
        status_results = []
        for oid in status_oids:
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                           _OID_BASE_STATUS + "." + oid], mutates=False)
            if res.rc != 0:
                continue
            status_results.append(res.stdout)

        # Fetch counter section OIDs: packets, packets_accepted, packets_dropped, packets_rejected, packets_logged
        counter_oids = ["2", "4", "5", "6", "12"]
        counter_results = []
        for oid in counter_oids:
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                           _OID_BASE_COUNTERS + "." + oid], mutates=False)
            if res.rc != 0:
                continue
            counter_results.append(res.stdout)

        # Parse status table: each line has format "OID = value" or "OID = STRING: value"
        status_lines = []
        if len(status_results) > 0 and len(status_results[0].splitlines()) > 0:
            num_lines = len(status_results[0].splitlines())
            for i in range(num_lines):
                line_parts = []
                for j in range(len(status_oids)):
                    lines = status_results[j].splitlines()
                    if i < len(lines):
                        line = lines[i]
                        # Extract value after ": "
                        if ": " in line:
                            val = line.split(": ", 1)[1].strip().strip('"')
                            line_parts.append(val)
                        else:
                            line_parts.append("")
                    else:
                        line_parts.append("")
                if len(line_parts) >= 8:
                    status_lines.append(line_parts)

        # Parse counter table similarly
        counter_lines = []
        if len(counter_results) > 0 and len(counter_results[0].splitlines()) > 0:
            num_lines = len(counter_results[0].splitlines())
            for i in range(num_lines):
                line_parts = []
                for j in range(len(counter_oids)):
                    lines = counter_results[j].splitlines()
                    if i < len(lines):
                        line = lines[i]
                        if ": " in line:
                            raw = line.split(": ", 1)[1].strip().strip('"')
                            line_parts.append(_opt_int(raw))
                        else:
                            line_parts.append(None)
                    else:
                        line_parts.append(None)
                if len(line_parts) >= 5:
                    counter_lines.append(line_parts)

        # Pair status and counter lines (reversed order as in Checkmk)
        out = []
        # Use reversed order for pairing (last item first)
        for i in range(min(len(status_lines), len(counter_lines))):
            s = status_lines[-(i+1)]
            c = counter_lines[-(i+1)]
            if len(s) < 8 or len(c) < 5:
                continue
            vs_id, vs_name, vs_type, vs_ip, vs_policy, vs_policy_type, vs_sic_status, vs_ha_status = s
            packets, packets_accepted, packets_dropped, packets_rejected, packets_logged = c

            # Only create service if any packet counter != None
            if packets != None or packets_accepted != None or packets_dropped != None or \
               packets_rejected != None or packets_logged != None:
                item = vs_name + " " + str(vs_id)
                out.append({
                    "item": item,
                    "params": {
                        "packets": _DEFAULT_LEVELS,
                        "packets_accepted": _DEFAULT_LEVELS,
                        "packets_dropped": _DEFAULT_LEVELS,
                        "packets_rejected": _DEFAULT_LEVELS,
                        "packets_logged": _DEFAULT_LEVELS,
                    },
                    "metrics": ["packets", "packets_accepted", "packets_dropped", "packets_rejected", "packets_logged"],
                })

        return {
            "changed": False,
            "msg": "discovered %d VS instances with packet counters" % len(out),
            "data": {"discovery": out},
        }

    # Check mode for one item
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    levels = {
        "packets": params.get("packets", _DEFAULT_LEVELS),
        "packets_accepted": params.get("packets_accepted", _DEFAULT_LEVELS),
        "packets_dropped": params.get("packets_dropped", _DEFAULT_LEVELS),
        "packets_rejected": params.get("packets_rejected", _DEFAULT_LEVELS),
        "packets_logged": params.get("packets_logged", _DEFAULT_LEVELS),
    }
    time_delta = 300  # assume 5-minute check interval

    # Parse item to extract vs_name and vs_id
    parts = item.split(" ", 1)
    vs_name = parts[0] if len(parts) >= 1 else ""
    vs_id = parts[1] if len(parts) >= 2 else ""

    # Fetch status section to find the row index
    status_oids = ["1", "3", "4", "5", "6", "7", "8", "9"]
    status_results = []
    for oid in status_oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                       _OID_BASE_STATUS + "." + oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        status_results.append(res.stdout)

    # Parse status table and find matching row
    status_lines = []
    if len(status_results) > 0 and len(status_results[0].splitlines()) > 0:
        num_lines = len(status_results[0].splitlines())
        for i in range(num_lines):
            line_parts = []
            for j in range(len(status_oids)):
                lines = status_results[j].splitlines()
                if i < len(lines):
                    line = lines[i]
                    if ": " in line:
                        val = line.split(": ", 1)[1].strip().strip('"')
                        line_parts.append(val)
                    else:
                        line_parts.append("")
                else:
                    line_parts.append("")
            if len(line_parts) >= 8:
                status_lines.append(line_parts)

    # Find the row matching item
    target_row = None
    for i in range(len(status_lines)):
        s = status_lines[i]
        if len(s) >= 8:
            row_vs_id = s[0]
            row_vs_name = s[1]
            if row_vs_name == vs_name and row_vs_id == vs_id:
                target_row = i
                break

    if target_row == None:
        return {
            "changed": False,
            "msg": "VS instance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch counter section OIDs
    counter_oids = ["2", "4", "5", "6", "12"]
    counter_results = []
    for oid in counter_oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                       _OID_BASE_COUNTERS + "." + oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        counter_results.append(res.stdout)

    # Parse counter table and extract row values
    counter_lines = []
    if len(counter_results) > 0 and len(counter_results[0].splitlines()) > 0:
        num_lines = len(counter_results[0].splitlines())
        for i in range(num_lines):
            line_parts = []
            for j in range(len(counter_oids)):
                lines = counter_results[j].splitlines()
                if i < len(lines):
                    line = lines[i]
                    if ": " in line:
                        raw = line.split(": ", 1)[1].strip().strip('"')
                        line_parts.append(_opt_int(raw))
                    else:
                        line_parts.append(None)
                else:
                    line_parts.append(None)
            if len(line_parts) >= 5:
                counter_lines.append(line_parts)

    if target_row >= len(counter_lines):
        return {
            "changed": False,
            "msg": "Counter data not found for VS: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    c = counter_lines[target_row]
    packets = c[0]
    packets_accepted = c[1]
    packets_dropped = c[2]
    packets_rejected = c[3]
    packets_logged = c[4]

    # Compute rates (approximate, per 300s)
    rates = {
        "packets": _get_rate(packets, time_delta),
        "packets_accepted": _get_rate(packets_accepted, time_delta),
        "packets_dropped": _get_rate(packets_dropped, time_delta),
        "packets_rejected": _get_rate(packets_rejected, time_delta),
        "packets_logged": _get_rate(packets_logged, time_delta),
    }

    # Evaluate levels
    state = "OK"
    messages = []
    metrics = {}

    for key, label, rate in [
        ("packets", "Total number of packets processed", rates["packets"]),
        ("packets_accepted", "Total number of accepted packets", rates["packets_accepted"]),
        ("packets_dropped", "Total number of dropped packets", rates["packets_dropped"]),
        ("packets_rejected", "Total number of rejected packets", rates["packets_rejected"]),
        ("packets_logged", "Total number of logs sent", rates["packets_logged"]),
    ]:
        if rate == None:
            continue

        level = levels.get(key, _DEFAULT_LEVELS)
        metric_name = key
        metrics[metric_name] = rate

        # Level handling: level[0] is "no_levels" or "fixed", level[1] == None or (warn, crit)
        if level[0] == "no_levels":
            # Always OK
            pass
        elif level[0] == "fixed":
            warn = None
            crit = None
            if level[1] != None:
                (warn, crit) = level[1]
            if crit != None and rate >= crit:
                state = "CRIT"
            elif warn != None and rate >= warn:
                state = "WARN"

        # Build label
        label_text = label + ": %f/s" % rate
        messages.append(label_text)

    # Final state may have been upgraded by any metric
    summary = messages[0] if messages else "No packet counters found"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
