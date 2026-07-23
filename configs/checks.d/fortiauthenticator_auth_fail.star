# ===== FortiAuthenticator authentication failures check (read-only Starlark) =====
# Source: cmk.plugins.fortinet.agent_based.fortiauthenticator_auth_fail

# Module-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.12356.113.1.202"
SNMP_OID_FAILS = "23"  # facAuthFailures5Min

# Threshold defaults from Checkmk
DEFAULT_WARN = 100
DEFAULT_CRIT = 200


def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # Discovery mode: always yield one service for this check
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",  # single-service check
                    "params": {"auth_fails": (DEFAULT_WARN, DEFAULT_CRIT)},
                    "metrics": ["fortiauthenticator_fails_5min"]
                }
            ]}
        }

    # Check mode: gather data via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # Build full OID for single scalar value
    full_oid = SNMP_BASE_OID + "." + SNMP_OID_FAILS
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, full_oid
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not retrieve authentication failures from host"
            }
        }

    # Parse SNMP output: "<oid> = INTEGER: <value>"
    line = res.stdout.strip()
    # Find the value after " = INTEGER: "
    pos = line.find(" = INTEGER: ")
    if pos == -1:
        return {
            "changed": False,
            "msg": "unable to parse SNMP response",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Unexpected SNMP response format"
            }
        }

    value_part = line[pos + len(" = INTEGER: "):].strip()
    # Guard: validate that value_part is digits (possibly negative) before converting
    # Note: SNMP values should be non-negative integers, but allow for negative too
    # Simple validation: all chars are digits or (for negative) first char is '-' and rest are digits
    is_valid = False
    if len(value_part) > 0:
        if value_part[0] == '-':
            if len(value_part) > 1 and value_part[1:].isdigit():
                is_valid = True
        elif value_part.isdigit():
            is_valid = True
    if not is_valid:
        return {
            "changed": False,
            "msg": "unable to parse integer value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Failed to parse authentication failures count"
            }
        }

    auth_fails = int(value_part)

    # Extract thresholds
    # Checkmk uses params["auth_fails"] = (warn, crit) tuple
    warn, crit = params.get("auth_fails", (DEFAULT_WARN, DEFAULT_CRIT))

    # Determine state: upper levels (warn/crit are maxima)
    state = "CRIT" if auth_fails >= crit else ("WARN" if auth_fails >= warn else "OK")

    # Return verdict
    return {
        "changed": False,
        "msg": "Authentication failures within the last 5 minutes: %d (warn/crit at %d/%d)" % (
            auth_fails, warn, crit
        ),
        "data": {
            "state": state,
            "metrics": {"fortiauthenticator_fails_5min": float(auth_fails)},
            "details": ""
        }
    }
