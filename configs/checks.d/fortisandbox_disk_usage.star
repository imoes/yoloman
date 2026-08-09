# fortisandbox_disk_usage — Disk usage
# Translated from Checkmk check plugin for the yolo-man agent (read-only Starlark).


# Checkmk FILESYSTEM_DEFAULT_PARAMS for the "filesystem" ruleset (levels_warn, levels_crit).
DEFAULT_LEVELS = (80.0, 90.0)

# OID for the Fortinet enterprise root we detect a FortiSandbox by.
FORTINET_ENTERPRISE_OID = "1.3.6.1.2.1.1.2.0"
FORTISANDBOX_SYSOID_PREFIX = ".1.3.6.1.4.1.12356.118.1."

# Disk-usage scalar OIDs: fsaSysDiskUsage (oid 5), fsaSysDiskCapacity (oid 6)
DISK_USAGE_OID = ".1.3.6.1.4.1.12356.118.3.1.5"
DISK_CAPACITY_OID = ".1.3.6.1.4.1.12356.118.3.1.6"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    discover = params.get("_discover", False)

    # --- Detection: is this a FortiSandbox at all? ---
    sys_oid = _snmpget(ctx, host, community, version, FORTINET_ENTERPRISE_OID)
    if sys_oid == None or not sys_oid.startswith(FORTISANDBOX_SYSOID_PREFIX.lstrip(".")):
        if discover:
            return {
                "changed": False,
                "msg": "host is not a FortiSandbox",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "host is not a FortiSandbox",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # --- Gather the scalar values for disk usage and capacity ---
    used_raw = _snmpget(ctx, host, community, version, DISK_USAGE_OID)
    cap_raw = _snmpget(ctx, host, community, version, DISK_CAPACITY_OID)

    if used_raw == None or cap_raw == None:
        if discover:
            return {
                "changed": False,
                "msg": "FortiSandbox disk-usage OIDs not available",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "FortiSandbox disk-usage OIDs not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse the bare values returned by -Oqv.
    used = _to_int(used_raw)
    cap = _to_int(cap_raw)
    if used == None or cap == None or cap <= 0:
        if discover:
            return {
                "changed": False,
                "msg": "invalid FortiSandbox disk-usage values",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "invalid FortiSandbox disk-usage values",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if discover:
        # Reproduces discover_fortisandbox_disk: yield Service(item="system").
        # Metrics mirror df_check_filesystem_single's available perfdata.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "system",
                        "params": {"levels": list(DEFAULT_LEVELS)},
                        "metrics": [
                            "used_percent",
                            "size",
                            "used",
                            "free",
                            "reserved",
                            "inodes_used_percent",
                        ],
                    }
                ]
            },
        }

    # --- Check one item (only "system" is ever discovered) ---
    warn, crit = _levels_from_params(params)
    pct = (used / cap) * 100.0

    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    pct_rounded = int(pct * 100 + 0.5) / 100.0
    msg = "%s: %d/%d bytes (%f%% used)" % ("system", used, cap, pct_rounded)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": pct_rounded,
                "size": cap,
                "used": used,
                "free": cap - used,
                "reserved": 0,
            },
            "details": "",
        },
    }


def _snmpget(ctx, host, community, version, oid):
    """Return the bare value from snmpget -Oqv, or None if the OID is unavailable."""
    res = ctx.run(
        [
            "snmpget",
            "-v" + version,
            "-c",
            community,
            "-Oqv",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip() or None


def _to_int(s):
    s = s.strip()
    if s.lstrip("-").isdigit():
        return int(s)
    return None


def _levels_from_params(params):
    levels = params.get("levels")
    if levels != None and type(levels) == "list" and len(levels) == 2:
        return float(levels[0]), float(levels[1])
    warn = params.get("warn")
    crit = params.get("crit")
    if warn != None and crit != None:
        return float(warn), float(crit)
    return DEFAULT_LEVELS