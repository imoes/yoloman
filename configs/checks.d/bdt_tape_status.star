def main(ctx, params):
    if params.get("_discover"):
        # Detect presence of the BDT tape library device via the SNMP
        # sysObjectID (.1.3.6.1.2.1.1.2.0) the source checkkey uses to
        # decide applicability.
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        probe = ctx.run(
            [
                "snmpget", "-v2c", "-c", community, "-Oqv",
                host, ".1.3.6.1.2.1.1.2.0",
            ],
            mutates=False,
        )
        if probe.rc != 0:
            # SNMP probe failed or device not present: no services here.
            return {"changed": False, "msg": "no bdt tape library found",
                    "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {},
                    "metrics": [],
                }
            ]},
        }

    # ---- CHECK mode ----
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.4.1.20884.10893.2.101.2.1",
        ],
        mutates=False,
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "bdt tape library not reachable: %s" % res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()

    status_map = {
        "1": "other",
        "2": "unknown",
        "3": "ok",
        "4": "non-critical",
        "5": "critical",
        "6": "non-recoverable",
    }
    state_map = {
        "other": "UNKNOWN",
        "unknown": "UNKNOWN",
        "ok": "OK",
        "non-critical": "WARN",
        "critical": "CRIT",
        "non-recoverable": "CRIT",
    }

    status = status_map.get(raw, "unknown")
    state = state_map.get(status, "UNKNOWN")

    return {
        "changed": False,
        "msg": status,
        "data": {"state": state, "metrics": {}, "details": ""},
    }