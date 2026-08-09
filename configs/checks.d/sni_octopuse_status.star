# Checkmk check: sni_octopuse_status — Global status (SNMP Octopus E PABX)
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# Data source: SNMP scalar .1.3.6.1.4.1.231.7.2.9.1.1.0
# Detection: sysDescr.0 (1.3.6.1.2.1.1.1.0) contains "agent for hipath"
# States: normal(1) OK, warning(2) WARN, minor(3) WARN, major(4) CRIT, critical(5) CRIT

def _state_for(value):
    """Map the Octopus E PABX status integer to (state, description)."""
    table = {
        1: ("OK", "normal"),
        2: ("WARN", "warning"),
        3: ("WARN", "minor"),
        4: ("CRIT", "major"),
        5: ("CRIT", "critical"),
    }
    return table.get(value, ("UNKNOWN", "unknown(%s)" % str(value)))

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid_base = "1.3.6.1.4.1.231.7.2.9.1.1"
    oid = oid_base + ".0"

    if params.get("_discover"):
        # Detection: does sysDescr look like an Octopus E PABX?
        sysDescr_oid = "1.3.6.1.2.1.1.1.0"
        sd = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, sysDescr_oid],
            mutates=False,
        )
        if sd.rc != 0 or "agent for hipath" not in sd.stdout:
            return {
                "changed": False,
                "msg": "Octopus E PABX not detected",
                "data": {"discovery": []},
            }
        # The PABX is present — this is a single-service check.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["status"]},
            ]},
        }

    # Check mode: fetch the scalar status value.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return {
            "changed": False,
            "msg": "no Octopus E PABX status reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    # snmpget -Oqv may emit a quoted string for some types; strip quotes if present.
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = raw[1:-1]

    try_value = raw
    # Guard the int conversion like the original would parse STRING/Integer.
    is_int = try_value.lstrip("-").isdigit()
    if not is_int:
        return {
            "changed": False,
            "msg": "unexpected status value: " + raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    octopus_state = int(try_value)
    state, desc = _state_for(octopus_state)
    msg = "PBX system state is " + desc
    if octopus_state >= 3:
        msg += " error"

    # Emit the raw integer as a perfdata metric (status level 1..5).
    metrics = {"status": octopus_state}

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }