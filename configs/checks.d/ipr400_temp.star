# ===== check plugin: cmk/plugins/ipr400/agent_based/ipr400_temp.py =====
# Translated to read-only Starlark for the yolo-man agent.
#
# This is an SNMP check sourcing the ambient temperature reading from an
# ipr400 VoIP device, OID .1.3.6.1.4.1.27053.1.4.5.9 (a single scalar).
# Detection is by sysDescr prefix.

def main(ctx, params):
    # ---- configuration / defaults ----
    # Checkmk "temperature" ruleset defaults: levels=(warn, crit).
    # params may carry "levels" (a 2-tuple/list) or individual warn/crit keys.
    levels = params.get("levels")
    warn = 30.0
    crit = 40.0
    if levels != None:
        # levels is expected to be [warn, crit]
        warn = levels[0]
        crit = levels[1]
    else:
        if params.get("warn") != None:
            warn = params.get("warn")
        if params.get("crit") != None:
            crit = params.get("crit")

    base_oid = ".1.3.6.1.4.1.27053.1.4.5"
    temp_oid = base_oid + ".9"

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        # The real Checkmk detector is:
        #   detect=startswith(".1.3.6.1.2.1.1.1.0", "ipr voip device ipr400")
        # Probe sysDescr (.1.3.6.1.2.1.1.1.0) with -Oqv (bare value).
        sysdesc_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv",
             host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        # rc 127 -> snmpget not installed -> product not present.
        if sysdesc_res.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if sysdesc_res.rc != 0 or not sysdesc_res.stdout:
            # Could not read sysDescr -> do not claim the device exists.
            return {"changed": False, "msg": "sysDescr not available",
                    "data": {"discovery": []}}

        desc = sysdesc_res.stdout.strip()
        prefix = "ipr voip device ipr400"
        if desc.startswith(prefix):
            entry = {
                "item": "Ambient",
                "params": {"levels": [warn, crit]},
                "metrics": ["temperature"],
                "service_labels": {},
            }
            return {"changed": False,
                    "msg": "discovered 1 item",
                    "data": {"discovery": [entry],
                             "host_labels": {"cmk/snmp": "ipr400"}}}
        # sysDescr does not match -> this is not an ipr400 device.
        return {"changed": False,
                "msg": "not an ipr400 device",
                "data": {"discovery": []}}

    # ---- CHECK MODE (single item) ----
    item = params.get("item", "")

    # The scalar temperature OID exists independent of the item name (single
    # service), but guard the product presence again via sysDescr so we never
    # report OK on a host that is not the device.
    sysdesc_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdesc_res.rc == 127:
        return {"changed": False,
                "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysdesc_res.rc != 0 or not sysdesc_res.stdout:
        return {"changed": False,
                "msg": "sysDescr not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sysdesc_res.stdout.strip().startswith("ipr voip device ipr400"):
        return {"changed": False,
                "msg": "not an ipr400 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the ambient temperature scalar (-Oqv -> bare integer value).
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, temp_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "could not read temperature OID",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    # The value is an integer count of degrees Celsius; tolerate a trailing
    # non-digit fraction but be defensive.
    digits = raw
    # Strip a possible leading sign.
    # Starlark has no regex; parse defensively.
    val = 0
    parsed_ok = False
    if digits.lstrip("-").isdigit():
        val = int(digits)
        parsed_ok = True
    if not parsed_ok:
        # Fall back to taking the integer prefix.
        # Find the longest integer prefix of the stripped value.
        sign = ""
        rest = digits
        if rest.startswith("-"):
            sign = "-"
            rest = rest[1:]
        idx = 0
        while idx < len(rest) and rest[idx] >= "0" and rest[idx] <= "9":
            idx = idx + 1
        if idx > 0:
            val = int(sign + rest[:idx])
            parsed_ok = True
    if not parsed_ok:
        return {"changed": False,
                "msg": "could not parse temperature: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = float(val)

    # ---- threshold logic (upper levels: warn then crit) ----
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "%s temperature %f C" % (item, temperature),
        "data": {
            "state": state,
            "metrics": {"temperature": temperature},
            "details": "ipr400 ambient temperature",
        },
    }