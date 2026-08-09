# Pulse Secure IVE CPU utilization — Checkmk check translated to read-only Starlark.
#
# The Checkmk source reads the OID ".1.3.6.1.4.1.12532.10" (a scalar integer
# percent) via an SNMPTree and grades it with the cpu_utilization ruleset
# (default warn/crit levels (80.0, 90.0)).
#
# This translation reads that same scalar OID with net-snmp using -Oqv so the
# bare value is returned, then applies the same warn/crit logic.

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.4.1.12532.10"],
            mutates=False,
        )
        # 127 => snmpget binary missing; non-zero / empty => device does not
        # answer (Pulse Secure not present here) => no service.
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "no Pulse Secure IVE found",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels": (80.0, 90.0)},
                     "metrics": ["cpu_util"]},
                ],
                "host_labels": {"cmk/pulse_secure_present": "true"},
            },
        }

    # --- CHECK MODE ---
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.4.1.12532.10"],
        mutates=False,
    )

    # Device not present / not responding => UNKNOWN, not OK.
    if res.rc != 0 or res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "no Pulse Secure IVE response (snmpget rc=%s)" % res.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    # Strip any residual SNMP TYPE tag (should not happen with -Oqv, but be safe).
    if raw.find(": ") != -1:
        raw = raw[raw.find(": ") + 2:]
    # Strip surrounding quotes if present.
    if len(raw) >= 2 and raw[0] == '"' and raw[len(raw) - 1] == '"':
        raw = raw[1:len(raw) - 1]

    if not raw.isdigit():
        return {
            "changed": False,
            "msg": "could not parse CPU utilization value: %s" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = int(raw)
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "CPU utilization %d%%" % value,
        "data": {
            "state": state,
            "metrics": {"cpu_util": value},
            "details": "",
        },
    }