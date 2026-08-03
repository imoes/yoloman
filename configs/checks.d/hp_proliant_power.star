# Translated Checkmk check hp_proliant_power -> read-only Starlark check module
# Monitors an HP ProLiant server power meter via SNMP (cpqHePowerMeterStatus / cpqHePowerMeterCurrReading).

# cpqHePowerMeterStatus textual values (OID .2 under .1.3.6.1.4.1.232.6.2.15)
_STATUS_TABLE = {
    "1": "other",
    "2": "present",
    "3": "absent",
}

# SNMP base OID for cpqHePowerMeter group
_BASE_OID = ".1.3.6.1.4.1.232.6.2.15"


def _snmp_get_int(ctx, host, community, oid):
    """Run an SNMP GET with -Oqv and return the bare integer value, or None on failure."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    if not out.isdigit():
        return None
    return int(out)


def _snmp_get_str(ctx, host, community, oid):
    """Run an SNMP GET with -Oqv and return the bare (stripped, unquoted) string value, or None on failure."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    # -Oqv may still wrap a value in quotes for OCTET STRINGs; strip surrounding quotes.
    if len(out) >= 2 and out[0] == '"' and out[-1] == '"':
        out = out[1:-1]
    return out


def main(ctx, params):
    # Read-only: never mutate, always changed=False.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels")  # (warn, crit) upper levels or None

    if params.get("_discover"):
        # Discovery: probe whether the power meter is present (status != "absent").
        status_code = _snmp_get_str(ctx, host, community, _BASE_OID + ".2")
        if status_code == None:
            # No SNMP access / device not reachable -> nothing to discover.
            return {
                "changed": False,
                "msg": "no SNMP data found",
                "data": {"discovery": []},
            }

        status = _STATUS_TABLE.get(status_code.strip(), "other")
        if status == "absent":
            # Power meter data not available -> not a service for this host.
            return {
                "changed": False,
                "msg": "hp_proliant_power not present",
                "data": {"discovery": []},
            }

        # Service exists (status == other or present). Metric exposed: power.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {"levels": levels},
                    "metrics": ["power"],
                }
            ]},
        }

    # ---- CHECK MODE (single service, item is "") ----
    status_code = _snmp_get_str(ctx, host, community, _BASE_OID + ".2")
    reading = _snmp_get_int(ctx, host, community, _BASE_OID + ".3")

    if status_code == None or reading == None:
        return {
            "changed": False,
            "msg": "no power meter data reachable via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = _STATUS_TABLE.get(status_code.strip(), "other")

    if status != "present":
        return {
            "changed": False,
            "msg": "Power Meter state: " + str(status),
            "data": {"state": "CRIT", "metrics": {}, "details": "status=" + str(status)},
        }

    # status == "present": grade the current reading against upper levels.
    metric_reading = reading
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if metric_reading >= crit:
            state = "CRIT"
        elif metric_reading >= warn:
            state = "WARN"

    render = "%d Watts" % metric_reading
    if levels != None:
        details = "Current reading: %s (warn=%s, crit=%s)" % (
            render, str(levels[0]), str(levels[1]),
        )
    else:
        details = "Current reading: " + render

    return {
        "changed": False,
        "msg": "Power: " + render,
        "data": {
            "state": state,
            "metrics": {"power": metric_reading},
            "details": details,
        },
    }