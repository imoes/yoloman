# SNMP OID constants for the Nimble latency table
BASE_OID = ".1.3.6.1.4.1.37447.1.2.1"

def _snmpwalk(ctx, community, host, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    return res.stdout

def _parse_nimble_latency_snmp(lines):
    """Parse snmpwalk output lines into structured data."""
    parsed = {}
    # Range keys: (key_string, title) in order
    range_keys = [
        ("0.1", "0-0.1 ms"),
        ("0.2", "0.1-0.2 ms"),
        ("0.5", "0.2-0.5 ms"),
        ("1", "0.5-1.0 ms"),
        ("2", "1-2 ms"),
        ("5", "2-5 ms"),
        ("10", "5-10 ms"),
        ("20", "10-20 ms"),
        ("50", "20-50 ms"),
        ("100", "50-100 ms"),
        ("200", "100-200 ms"),
        ("500", "200-500 ms"),
        ("1000", "500+ ms"),
    ]

    current_vol = ""
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Parse "OID = type: value"
        eq_idx = stripped.find("=")
        if eq_idx == -1:
            continue
        oid_part = stripped[:eq_idx].strip()
        value_part = stripped[eq_idx+1:].strip()

        # Extract numeric OID suffix
        if not oid_part.startswith(BASE_OID + "."):
            continue
        suffix = oid_part[len(BASE_OID)+1:]
        if not suffix.isdigit():
            continue
        idx = int(suffix)

        # Extract value string
        value_str = ""
        if value_part.startswith("INTEGER:"):
            value_str = value_part[len("INTEGER:"):].strip()
        elif value_part.startswith("STRING:"):
            value_str = value_part[len("STRING:"):].strip().strip('"')
        else:
            value_str = value_part.strip().strip('"')

        # Process by index
        if idx == 1:  # volume name (OID 3 -> index 1)
            current_vol = value_str
            if current_vol not in parsed:
                parsed[current_vol] = {"read": {"total": 0, "ranges": {}}, "write": {"total": 0, "ranges": {}}}
        elif idx >= 2 and idx <= 14:  # read latency range (OID 21..33 -> indices 2..14)
            if current_vol not in parsed:
                continue
            range_idx = idx - 2  # 0..12
            if range_idx < len(range_keys):
                key, title = range_keys[range_idx]
                val = int(value_str) if value_str.isdigit() else 0
                parsed[current_vol]["read"]["ranges"][key] = (title, val)
        elif idx == 15:  # write total (OID 39)
            if current_vol not in parsed:
                continue
            val = int(value_str) if value_str.isdigit() else 0
            parsed[current_vol]["write"]["total"] = val
        elif idx >= 16 and idx <= 28:  # write latency range (OID 40..51 -> indices 16..28)
            if current_vol not in parsed:
                continue
            range_idx = idx - 16  # 0..12
            if range_idx < len(range_keys):
                key, title = range_keys[range_idx]
                val = int(value_str) if value_str.isdigit() else 0
                parsed[current_vol]["write"]["ranges"][key] = (title, val)

    return parsed

def _discovery(ctx, params):
    """Discovery mode: discover all volumes with write latency data."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    output = _snmpwalk(ctx, community, host, BASE_OID)
    lines = output.splitlines()
    parsed = _parse_nimble_latency_snmp(lines)

    out = []
    for vol_name, vol_attrs in parsed.items():
        if vol_attrs.get("write", {}).get("total", 0) > 0:
            out.append({
                "item": vol_name,
                "params": {"range_reference": "20", "read": (10.0, 20.0), "write": (10.0, 20.0)},
                "metrics": ["nimble_write_latency_01", "nimble_write_latency_02",
                            "nimble_write_latency_05", "nimble_write_latency_1",
                            "nimble_write_latency_2", "nimble_write_latency_5",
                            "nimble_write_latency_10", "nimble_write_latency_20",
                            "nimble_write_latency_50", "nimble_write_latency_100",
                            "nimble_write_latency_200", "nimble_write_latency_500",
                            "nimble_write_latency_1000"]
            })
    return {"changed": False, "msg": "discovered %d volumes" % len(out),
            "data": {"discovery": out}}

def _check(ctx, params, item):
    """Check mode for one volume."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    output = _snmpwalk(ctx, community, host, BASE_OID)
    lines = output.splitlines()
    parsed = _parse_nimble_latency_snmp(lines)

    if item not in parsed:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = parsed[item].get("write")
    if not data:
        return {"changed": False, "msg": "no write latency data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_value = data.get("total", 0)
    if total_value == 0:
        return {"changed": False, "msg": "No current write operations",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Get thresholds and reference from params (defaults as in Checkmk)
    range_reference = params.get("range_reference", "20")
    warn_pct, crit_pct = params.get("write", (10.0, 20.0))

    # Build metrics and compute aggregate
    metrics = {}
    running_total_percent = 0.0
    range_reference_val = float(range_reference)
    breakdown_results = []
    range_keys = [
        ("0.1", "0-0.1 ms"),
        ("0.2", "0.1-0.2 ms"),
        ("0.5", "0.2-0.5 ms"),
        ("1", "0.5-1.0 ms"),
        ("2", "1-2 ms"),
        ("5", "2-5 ms"),
        ("10", "5-10 ms"),
        ("20", "10-20 ms"),
        ("50", "20-50 ms"),
        ("100", "50-100 ms"),
        ("200", "100-200 ms"),
        ("500", "200-500 ms"),
        ("1000", "500+ ms"),
    ]

    for key, (title, value) in data.get("ranges", {}).items():
        metric_name = "nimble_write_latency_" + key.replace(".", "")
        percent_value = (value / float(total_value)) * 100.0
        metrics[metric_name] = percent_value
        if float(key) >= range_reference_val:
            running_total_percent += percent_value
        # Per-range check
        state = "OK"
        if percent_value >= crit_pct:
            state = "CRIT"
        elif percent_value >= warn_pct:
            state = "WARN"
        breakdown_results.append((state, title + ": " + "%f%%" % percent_value))

    # Aggregate check against levels
    state = "OK"
    if running_total_percent >= crit_pct:
        state = "CRIT"
    elif running_total_percent >= warn_pct:
        state = "WARN"

    # Build summary message
    ref_title = ""
    for key, (title, _) in data.get("ranges", {}).items():
        if key == range_reference:
            ref_title = title
            break
    summary = "Write IO at or above %s: %f%%" % (ref_title, running_total_percent)

    details_lines = []
    for s, d in breakdown_results:
        details_lines.append("%s %s" % (s, d))
    details = "\n".join(details_lines)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": details}}

def main(ctx, params):
    if params.get("_discover"):
        return _discovery(ctx, params)
    item = params.get("item", "")
    return _check(ctx, params, item)