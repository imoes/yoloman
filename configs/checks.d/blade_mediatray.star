# Translated Checkmk check: blade_mediatray → read-only Starlark SNMP check.
# Monitors an IBM BladeCenter media tray via SNMP. Single-service check.

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- probe for the real thing: the SNMP agent must be reachable ---
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not installed",
            "data": {"state": "UNKNOWN", "metrics": {},
                     "details": "no snmpget binary found on host"},
        }
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP agent unreachable: " + probe.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": probe.stderr.strip()},
        }

    # --- discovery mode ---
    if params.get("_discover"):
        pres = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2.3.51.2.2.5.2.74"],
            mutates=False,
        )
        comm = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2.3.51.2.2.5.2.75"],
            mutates=False,
        )
        if pres.rc != 0 or comm.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": [], "host_labels": {}}}
        present_val = pres.stdout.strip()
        communicating_val = comm.stdout.strip()
        if present_val == "1":
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ],
                    "host_labels": {"cmk/managed": "blade"},
                },
            }
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # --- check mode ---
    pres = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2.3.51.2.2.5.2.74"],
        mutates=False,
    )
    comm = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2.3.51.2.2.5.2.75"],
        mutates=False,
    )
    if pres.rc != 0 or comm.rc != 0:
        return {
            "changed": False,
            "msg": "no media tray information in SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {},
                     "details": "SNMP GET failed for media tray OIDs"},
        }

    present = pres.stdout.strip()
    communicating = comm.stdout.strip()

    if present != "1":
        return {
            "changed": False,
            "msg": "media tray not present",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    if communicating != "1":
        return {
            "changed": False,
            "msg": "media tray not communicating",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }
    return {
        "changed": False,
        "msg": "media tray present and communicating",
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }