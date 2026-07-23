# ===== Starlark check module for ipr400_in_voltage =====
# Read-only check: gathers in voltage via SNMP, reports state/metrics, never mutates.

def main(ctx, params):
    # Discovery mode: check if host matches SNMP detection (snmpwalk will succeed if device is ipr400)
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.27053.1.4.5.10"
        ], mutates=False)
        # If the walk returned any output, there's one service item "1"
        if res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "1", "params": {"levels_lower": [12.0, 11.0]}, "metrics": ["in_voltage"]}
                    ]
                },
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    # Check mode: single item "1" only
    item = params.get("item", "1")
    if item != "1":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    # Fetch raw voltage value (mV) from OID .1.3.6.1.4.1.27053.1.4.5.10.0
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.27053.1.4.5.10.0"
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP get failed or empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse: output format: ".1.3.6.1.4.1.27053.1.4.5.10.0 = INTEGER: 12500\n"
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "cannot parse snmpget output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value_part = parts[1]
    # Extract integer from "INTEGER: 12500" or similar
    if ":" in value_part:
        value_str = value_part.split(":", 1)[1].strip()
    else:
        value_str = value_part.strip()

    # Guard: ensure it's a digit
    if not value_str.replace("-", "").isdigit():
        return {
            "changed": False,
            "msg": "invalid voltage value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mV = int(value_str)
    power = mV / 1000.0  # convert mV to V

    # Thresholds from params (defaults from Checkmk defaults)
    warn_lower = params.get("levels_lower", [12.0, 11.0])[0]
    crit_lower = params.get("levels_lower", [12.0, 11.0])[1]
    warn_upper = None
    crit_upper = None
    if params.get("levels_upper") != None:
        warn_upper = params.get("levels_upper")[0]
        crit_upper = params.get("levels_upper")[1]

    # Determine state
    state = "OK"
    summary = "in voltage: %fV" % power

    # Lower bounds first (critical)
    if power <= crit_lower:
        state = "CRIT"
        summary = "%s, (warn/crit below %fV/%fV)" % (summary, warn_lower, crit_lower)
    elif crit_upper != None and power >= crit_upper:
        state = "CRIT"
        summary = "%s, (warn/crit at or above %fV/%fV)" % (summary, warn_upper, crit_upper)
    elif power <= warn_lower:
        state = "WARN"
        summary = "%s, (warn/crit below %fV/%fV)" % (summary, warn_lower, crit_lower)
    elif warn_upper != None and power >= warn_upper:
        state = "WARN"
        summary = "%s, (warn/crit at or above %fV/%fV)" % (summary, warn_upper, crit_upper)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"in_voltage": power},
            "details": "",
        },
    }