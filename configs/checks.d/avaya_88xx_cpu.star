# Metadata
def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detection: verify this is an Avaya device by checking sysObjectID
    sysoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid_res.rc != 0 or sysoid_res.skipped:
        if _discovery_mode(params):
            return _discovery_empty()
        return _unknown("snmp unreachable: %s" % sysoid_res.stderr)

    sysoid = sysoid_res.stdout.strip()
    if ".1.3.6.1.4.1.2272" not in sysoid:
        if _discovery_mode(params):
            return _discovery_empty()
        return _unknown("not an Avaya device (sysObjectID: %s)" % sysoid)

    # Discovery mode: single-service check (item "")
    if _discovery_mode(params):
        return {
            "changed": False,
            "msg": "discovered CPU utilization",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"util": (90.0, 95.0)},
                        "metrics": ["cpu_util"],
                    }
                ],
            },
        }

    # Check mode: fetch CPU utilization from .1.3.6.1.4.1.2272.1.1.20
    cpu_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2272.1.1.20"],
        mutates=False,
    )
    if cpu_res.rc != 0 or cpu_res.skipped:
        return _unknown("failed to fetch CPU utilization: %s" % cpu_res.stderr)

    util_str = cpu_res.stdout.strip()
    if not util_str or not _is_int(util_str):
        return _unknown("invalid CPU utilization value: %s" % util_str)

    util = int(util_str)
    levels = params.get("util", (90.0, 95.0))
    warn = levels[0]
    crit = levels[1]

    state = "OK"
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "CPU utilization: %d%%" % util,
        "data": {
            "state": state,
            "metrics": {"cpu_util": util},
            "details": "CPU utilization is %d%%" % util,
        },
    }


def _discovery_mode(params):
    return params.get("_discover") == True


def _discovery_empty():
    return {
        "changed": False,
        "msg": "no Avaya 88xx CPU utilization found",
        "data": {"discovery": []},
    }


def _unknown(msg):
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": msg},
    }


def _is_int(s):
    if s == None or s == "":
        return False
    if s.startswith("-"):
        return s[1:].isdigit()
    return s.isdigit()