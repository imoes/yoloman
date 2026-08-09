# Checkmk check: snmp_info -> read-only Starlark check module
# Monitors: SNMP system info (sysDescr, sysName, sysLocation, sysContact)

DEFAULT_LEVELS = {"warn": 80, "crit": 90}

def _parse_string(val):
    return val.strip().replace("\r\n", " ").replace("\n", " ")

def _fetch_snmp_info(ctx, host, community):
    base = ".1.3.6.1.2.1.1"
    oids = {
        "description": base + ".1",
        "object_id": base + ".2",
        "contact": base + ".4",
        "name": base + ".5",
        "location": base + ".6",
    }
    info = {}
    for field in ("description", "object_id", "contact", "name", "location"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oids[field]],
            mutates=False,
        )
        if res.rc != 0 and res.rc != 127:
            return None
        if res.rc == 127 or not res.stdout.strip():
            return None
        info[field] = _parse_string(res.stdout.strip())
    return info

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for SNMP availability
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if res.rc == 127 or not res.stdout.strip():
            return {"changed": False, "msg": "SNMP not available", "data": {"discovery": []}}

        info = _fetch_snmp_info(ctx, host, community)
        if info == None:
            return {"changed": False, "msg": "no SNMP info available", "data": {"discovery": []}}

        # Determine device type label
        device_type = "generic"
        descr_lower = info["description"].lower()
        if "cisco" in descr_lower:
            device_type = "cisco"
        elif ".1.3.6.1.4.1.25597.1" in info["object_id"]:
            device_type = "fireeye"

        return {
            "changed": False,
            "msg": "discovered SNMP info",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                        "service_labels": {
                            "device_type": device_type,
                            "sysObjectID": info["object_id"],
                        },
                    }
                ],
                "host_labels": {
                    "cmk/device_type": device_type,
                },
            },
        }

    # CHECK MODE
    info = _fetch_snmp_info(ctx, host, community)
    if info == None:
        return {
            "changed": False,
            "msg": "no SNMP info available from " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summary = "%s, %s, %s, %s" % (
        info["description"], info["name"], info["location"], info["contact"]
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": summary,
        },
    }