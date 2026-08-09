# liebert_bat_temp — Checkmk Liebert battery temperature check
# Translated to a read-only Starlark check module for the yolo-man agent.

# Default temperature thresholds (warn, crit) from the Checkmk check plugin.
DEFAULT_LEVELS = (40.0, 50.0)

# SNMP base OID for the Liebert battery temperature table leaf.
TEMP_OID = "1.3.6.1.4.1.476.1.4.2.3.4.1.3.3.1.3"
# The sysoid prefix that identifies a Liebert/LGP device.
LGP_SYSOID = "1.3.6.1.4.1.476.1.42"


def _grade_temperature(value, levels):
    """Return (state, warn, crit) for a temperature value.

    levels is a (warn, crit) tuple. Returns "OK"/"WARN"/"CRIT".
    """
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT", warn, crit
    if value >= warn:
        return "WARN", warn, crit
    return "OK", warn, crit


def _snmp_walk_one(ctx, host, community):
    """Read the battery temperature scalar via snmpget -Oqv.

    Returns the bare value string, or empty string if unavailable.
    """
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", community,
            "-Oqv",
            host,
            TEMP_OID + ".1",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _sys_oid(ctx, host, community):
    """Read sysOid (.1.3.6.1.2.1.1.2.0) to detect an LGP device."""
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c", community,
            "-Oqv",
            host,
            "1.3.6.1.2.1.1.2.0",
        ],
        mutates=False,
    )
    if res.resc != 0:
        return ""
    return res.stdout.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Discovery: verify this is an LGP device with a battery temperature
        # value available. If not, return an empty discovery.
        lgp = _sys_oid(ctx, host, community)
        if lgp != LGP_SYSOID:
            return {
                "changed": False,
                "msg": "host is not an LGP/Liebert device",
                "data": {"discovery": []},
            }
        val = _snmp_walk_one(ctx, host, community)
        if val == "":
            return {
                "changed": False,
                "msg": "no Liebert battery temperature available",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "Battery",
                        "params": {"levels": params.get("levels", DEFAULT_LEVELS)},
                        "metrics": ["temperature"],
                    }
                ],
            },
        }

    # Check mode for a single item.
    item = params.get("item", "Battery")
    levels = params.get("levels", DEFAULT_LEVELS)
    if levels == None:
        levels = DEFAULT_LEVELS

    lgp = _sys_oid(ctx, host, community)
    if lgp != LGP_SYSOID:
        return {
            "changed": False,
            "msg": "host is not an LGP/Liebert device (no Battery)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "sysOid does not match Liebert/LGP prefix",
            },
        }

    val = _snmp_walk_one(ctx, host, community)
    if val == "":
        return {
            "changed": False,
            "msg": "no Liebert battery temperature available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "could not read battery temperature OID",
            },
        }

    # snmpget -Oqv returns a bare numeric string for an INTEGER.
    temp = 0
    if val.lstrip("-").isdigit():
        temp = int(val)
    else:
        return {
            "changed": False,
            "msg": "unable to parse battery temperature: " + val,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "non-numeric temperature value",
            },
        }

    state, warn, crit = _grade_temperature(temp, levels)
    return {
        "changed": False,
        "msg": "Temperature %s" % item,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "Battery temperature: %d C (warn=%s, crit=%s)" % (
                temp, str(warn), str(crit),
            ),
        },
    }