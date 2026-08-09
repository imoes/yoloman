# pulse_secure_disk_util.star
# Translated from Checkmk checkmk.pulse_secure_disk_util (SNMP-based).
# Read-only Starlark module for the yolo-man agent.

# OID base for Pulse Secure enterprise MIB (.1.3.6.1.4.1.12532)
# and the scalar OID (.25) for disk utilization, per the Checkmk source.
_PULSE_BASE = ".1.3.6.1.4.1.12532"
_PULSE_DISK_UTIL_OID = "25"

# Default upper levels (warn, crit) from Checkmk: (80.0, 90.0)
_DEFAULT_WARN = 80.0
_DEFAULT_CRIT = 90.0

METRIC_PULSE_SECURE_DISK = "disk_utilization"


def _parse_snmp_value(raw):
    # snmpget -Oqv prints the bare value. For a percent it is something like
    # "42". Strip any residual whitespace/quotes just in case.
    v = raw.strip()
    # Remove surrounding quotes if present.
    if len(v) >= 2 and v[0] == '"' and v[len(v) - 1] == '"':
        v = v[1:len(v) - 1]
    return v


def _grade_upper(value, warn, crit):
    # upper levels: WARN if value >= warn, CRIT if value >= crit.
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _probe_installed(ctx):
    # A real Pulse Secure appliance is NOT the local host. Its SNMP scalar OID
    # is only reachable on a Pulse Secure device. We probe the configured host
    # via snmpget; rc == 127 / no-data means not installed / not reachable.
    host = ctx.params.get("host", "localhost") if hasattr(ctx, "params") else None
    # Fall back to params dict passed into main (ctx does not carry params here).
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    oid = _PULSE_BASE + "." + _PULSE_DISK_UTIL_OID

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # Probe the actual SNMP OID on the target device. The Pulse Secure
        # disk-utilization scalar is only present on a Pulse Secure appliance.
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
        # rc == 127 -> snmpget binary missing on the agent host.
        if res.rc == 127 or res.rc != 0:
            return {
                "changed": False,
                "msg": "Pulse Secure disk utilization: snmpget unavailable or host not a Pulse Secure device",
                "data": {"discovery": [], "host_labels": {}},
            }
        raw = _parse_snmp_value(res.stdout)
        if raw == "" or raw == "No" or raw == "0":
            # No scalar value reported -> not a Pulse Secure device / not present.
            return {
                "changed": False,
                "msg": "Pulse Secure disk utilization: device not detected",
                "data": {"discovery": [], "host_labels": {}},
            }

        # Determine the device / host label (stable fact about the item).
        host_label = "pulsesecure"
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"upper_levels": (80.0, 90.0)},
                        "metrics": [METRIC_PULSE_SECURE_DISK],
                    }
                ],
                "host_labels": {"cmk/pulse_secure": host_label},
            },
        }

    # --- CHECK MODE ---
    item = params.get("item", "")

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
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "Pulse Secure disk utilization: snmpget not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Pulse Secure disk utilization: host is not a Pulse Secure device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = _parse_snmp_value(res.stdout)
    if raw == "" or not raw.isdigit():
        return {
            "changed": False,
            "msg": "Pulse Secure disk utilization: no disk utilization value available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    percent = int(raw)
    warn = params.get("warn", _DEFAULT_WARN)
    crit = params.get("crit", _DEFAULT_CRIT)
    upper = params.get("upper_levels")
    if upper != None and len(upper) == 2:
        warn = upper[0]
        crit = upper[1]

    state = _grade_upper(float(percent), float(warn), float(crit))
    return {
        "changed": False,
        "msg": "Disk utilization: %d%% used" % percent,
        "data": {
            "state": state,
            "metrics": {METRIC_PULSE_SECURE_DISK: percent},
            "details": "Percentage of disk space used: %f%%" % float(percent),
        },
    }