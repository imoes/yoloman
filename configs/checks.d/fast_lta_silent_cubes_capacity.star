def main(ctx, params):
    # Constants from Checkmk lib.df.FILESYSTEM_DEFAULT_PARAMS
    FILESYSTEM_DEFAULT_PARAMS = {
        "levels": (80.0, 90.0),
        "levels_low": (50.0, 60.0),
        "magic_normsize": 20.0,
        "show_levels": "onwarn",
        "show_inodes": "onwarn",
        "show_reserved": True,
        "trend_range": 24,
        "trend_perfdata": False,
    }

    # Merge provided params with defaults
    effective_params = dict(FILESYSTEM_DEFAULT_PARAMS)
    for k in params:
        effective_params[k] = params[k]
    warn_percent, crit_percent = effective_params["levels"]

    # Probe Fast LTA Silent Cubes via SNMP (single value: total and used bytes)
    # SNMP OID base .1.3.6.1.4.1.27417.3 with oids 2 (total) and 3 (used)
    res = ctx.run([
        "/usr/bin/snmpget", "-Ovq", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.27417.3.2.0", ".1.3.6.1.4.1.27417.3.3.0"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.strip().split("\n")
    if len(lines) != 2:
        return {
            "changed": False,
            "msg": "Unexpected SNMP output length",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_str = lines[0].strip() if len(lines) > 0 else ""
    used_str = lines[1].strip() if len(lines) > 1 else ""
    if total_str == "" or used_str == "":
        return {
            "changed": False,
            "msg": "Missing SNMP values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not total_str.isdigit() or not used_str.isdigit():
        return {
            "changed": False,
            "msg": "Non-numeric SNMP values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    total_bytes = int(total_str)
    used_bytes = int(used_str)

    # Convert to MiB
    total_mib = total_bytes / 1048576.0
    avail_mib = (total_bytes - used_bytes) / 1048576.0
    used_mib = used_bytes / 1048576.0

    # Compute percentages
    if total_bytes == 0:
        used_percent = 0.0
    else:
        used_percent = 100.0 * float(used_bytes) / float(total_bytes)

    # Determine state
    state = "OK"
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"

    # Build message
    msg = "Size: %f MiB, Used: %f MiB (%f%%)" % (total_mib, used_mib, used_percent)

    # Build metrics dict (perfdata)
    metrics = {
        "size": total_mib,
        "used": used_mib,
        "avail": avail_mib,
        "util": used_percent,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
