# Module for checkmk.pulse_secure_users - read-only SNMP-based Checkmk check
# Parses .1.3.6.1.4.1.12532.2 (signedInWebUsers) and reports current user count

def main(ctx, params):
    # Discovery mode: one service per host
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["current_users"]}]}
        }

    # Check mode: fetch SNMP data for signedInWebUsers
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.12532.2"

    # Use snmpget for the single scalar OID (we only need one value)
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: "OID = STRING: value"
    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract value from format like ".1.3.6.1.4.1.12532.2 = INTEGER: 42"
    idx = line.rfind(": ")
    if idx == -1:
        return {
            "changed": False,
            "msg": "cannot parse SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = line[idx + 2:].strip()
    n_users = int(value_str) if value_str.isdigit() else -1
    if n_users < 0:
        return {
            "changed": False,
            "msg": "invalid user count value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract levels from params (default None as in Checkmk plugin)
    warn = params.get("upper_number_of_users")

    # Apply levels: warn and crit are either None or (warn_level, crit_level) tuple
    # But Checkmk plugin passes single integer for upper bound or None
    # The actual Checkmk rule may be a tuple (warn, crit) or just an int (crit)
    # We follow the Checkmk v1 check_levels logic:
    # - If warn/crit == None -> no levels applied
    # - If warn/crit is int -> treat as upper bound
    # - If warn/crit is tuple -> warn is first, crit is second
    # Since params["upper_number_of_users"] is passed directly from default {upper_number_of_users: None},
    # we check type to distinguish.

    state = "OK"
    msg_parts = ["Pulse Secure users: %d" % n_users]

    if warn != None:
        if type(warn) == "int":
            # Only one level provided: treat as crit
            crit_level = warn
            warn_level = None
        elif type(warn) == "list" and len(warn) == 2:
            warn_level = warn[0]
            crit_level = warn[1]
        else:
            warn_level = None
            crit_level = None
    else:
        warn_level = None
        crit_level = None

    # Apply upper levels
    if crit_level != None and n_users >= crit_level:
        state = "CRIT"
        msg_parts.append(">= %d (crit at %d)" % (n_users, crit_level))
    elif warn_level != None and n_users >= warn_level:
        state = "WARN"
        msg_parts.append(">= %d (warn at %d)" % (n_users, warn_level))

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"current_users": n_users},
            "details": ""
        }
    }