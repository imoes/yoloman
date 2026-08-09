# Checkmk: checkmk.pulse_secure_users -> read-only Starlark check module
# Monitors Pulse Secure signed-in web users via SNMP (OID .1.3.6.1.4.1.12532.2).

def _fetch_signed_in_users(ctx, host, community):
    # -Oqv: bare scalar value, no type tag, no "= " prefix.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.12532.2"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Detection: probe for the Pulse Secure SNMP scalar.
        val = _fetch_signed_in_users(ctx, host, community)
        if val == None:
            return {"changed": False,
                    "msg": "no Pulse Secure users data found",
                    "data": {"discovery": []}}
        # Single-service check: one item per host.
        return {"changed": False,
                "msg": "discovered Pulse Secure users service",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"upper_number_of_users": None},
                     "metrics": ["current_users"]}
                ]}}

    # Check mode: grade the single item.
    val = _fetch_signed_in_users(ctx, host, community)
    if val == None:
        return {"changed": False,
                "msg": "no Pulse Secure device responding for SNMP scalar .1.3.6.1.4.1.12532.2",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Coerce to int; non-numeric -> UNKNOWN (no fabricated default).
    if not val.lstrip("-").isdigit():
        return {"changed": False,
                "msg": "Pulse Secure users value not numeric: %s" % val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    n_users = int(val)

    # Levels: params["upper_number_of_users"] defaults to None (no levels).
    levels = params.get("upper_number_of_users", None)
    warn = levels[0] if levels != None and len(levels) >= 1 and levels[0] != None else None
    crit = levels[1] if levels != None and len(levels) >= 2 and levels[1] != None else None

    state = "OK"
    if crit != None and n_users >= crit:
        state = "CRIT"
    elif warn != None and n_users >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Pulse Secure users: %d" % n_users,
            "data": {"state": state,
                     "metrics": {"current_users": n_users},
                     "details": "signedInWebUsers=%d" % n_users}}