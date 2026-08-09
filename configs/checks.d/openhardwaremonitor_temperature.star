# ===== check plugin: cmk/plugins/openhardwaremonitor ----- read-only Starlark =====
# Translated: Temperature %s  (Openhardwaremonitor)
#
# Openhardwaremonitor is a Windows-only tool; it is NOT available on Linux
# hosts, and there is no equivalent on-host data source. The Checkmk check
# parses an agent section produced by the Windows agent plugin. Reaching for
# /proc/acpi/* or lm-sensors would be substituting a different product's
# data. This translation therefore probes for the real thing and reports
# absence when it is not present.

def main(ctx, params):
    # ---- discovery / check: probe for the real thing first ----
    res = ctx.run(["openhardwaremonitor", "--version"], mutates=False)
    present = res.rc == 0

    if params.get("_discover"):
        if not present:
            return {
                "changed": False,
                "msg": "Openhardwaremonitor not installed",
                "data": {"discovery": []},
            }
        # Present on this host type would require Windows; not applicable here.
        return {
            "changed": False,
            "msg": "Openhardwaremonitor present but no on-host data source available",
            "data": {"discovery": []},
        }

    # ---- check mode ----
    if not present:
        return {
            "changed": False,
            "msg": "Openhardwaremonitor not installed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Openhardwaremonitor binary not found on this host (rc=%d)" % res.rc,
            },
        }

    return {
        "changed": False,
        "msg": "Openhardwaremonitor present but no on-host temperature data source available",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "No Openhardwaremonitor sensor data available on this OS",
        },
    }