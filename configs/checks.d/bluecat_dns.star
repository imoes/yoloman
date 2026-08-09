def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.13315.2.1",
            ],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "not a Bluecat device", "data": {"discovery": []}}
        sys_oid = res.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.13315.2.1":
            return {"changed": False, "msg": "not a Bluecat device", "data": {"discovery": []}}
        dns_res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.13315.3.1.2.2.1.1",
            ],
            mutates=False,
        )
        if dns_res.rc != 0:
            return {"changed": False, "msg": "no DNS operational state", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "oper_states": {
                                "warning": [2, 3, 4],
                                "critical": [5],
                            }
                        },
                        "metrics": [],
                    }
                ],
            },
        }
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.13315.3.1.2.2.1.1",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no DNS operational state found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    oper_state_str = res.stdout.strip()
    if not oper_state_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid operational state value: " + oper_state_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    oper_state = int(oper_state_str)
    oper_state_map = {
        1: "running normally",
        2: "not running",
        3: "currently starting",
        4: "currently stopping",
        5: "fault",
    }
    if oper_state not in oper_state_map:
        return {
            "changed": False,
            "msg": "unknown operational state: " + str(oper_state),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    warn_states = params.get("oper_states", {"warning": [2, 3, 4], "critical": [5]})
    warn_list = warn_states.get("warning", [2, 3, 4])
    crit_list = warn_states.get("critical", [5])
    mon_state = "OK"
    if oper_state in crit_list:
        mon_state = "CRIT"
    elif oper_state in warn_list:
        mon_state = "WARN"
    summary = "DNS is " + oper_state_map[oper_state]
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": mon_state, "metrics": {}, "details": ""},
    }