def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    detect_oid = ".1.3.6.1.2.1.1.1.0"
    res_detect = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqvv", host, detect_oid],
        mutates=False,
    )
    if res_detect.rc != 0:
        return {
            "changed": False,
            "msg": "snmp detection failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sys_desc = res_detect.stdout.strip()
    if "agent for hipath" not in sys_desc:
        return {
            "changed": False,
            "msg": "not a Hitachi VSP Octopus e system",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["util"]},
                ],
            },
        }

    cpu_val = _fetch_cpu(ctx, host, community)
    if cpu_val == None:
        return {
            "changed": False,
            "msg": "could not retrieve CPU utilization",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "CPU utilization is %d%%" % cpu_val,
        "data": {
            "state": "OK",
            "metrics": {"util": float(cpu_val)},
            "details": "",
        },
    }


def _fetch_cpu(ctx, host, community):
    oid = ".1.3.6.1.4.1.231.7.2.9.1.7"
    r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                mutates=False)
    if r.rc != 0:
        return None
    val = r.stdout.strip()
    if not val.isdigit():
        return None
    return int(val)