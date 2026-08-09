def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    res = ctx.run(["svcs", "-H", "-o", "state,stime,fmri"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "svcs not installed", "data": {"discovery": []}}

    discovery = []
    seen = set()
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        if fields[0] == "STATE":
            continue
        fmri = fields[2]
        if fmri in seen:
            continue
        seen.add(fmri)
        discovery.append({
            "item": fmri,
            "params": {},
            "metrics": [],
        })

    return {
        "changed": False,
        "msg": "discovered %d services" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    item = params.get("item", "")
    res = ctx.run(["svcs", "-H", "-o", "state,stime,fmri"], mutates=False)
    if res.rc == 127:
        return _unknown("svcs not installed")

    states = params.get("states", [
        ("online", None, 0),
        ("disabled", None, 2),
        ("legacy_run", None, 0),
        ("maintenance", None, 0),
    ])
    else_state = params.get("else", 2)
    additional = params.get("additional_servicenames", [])

    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        if fields[0] == "STATE":
            continue
        svc_state = fields[0]
        svc_stime = fields[1]
        svc_descr = fields[2]

        if item in svc_descr or svc_descr in additional:
            has_changed = svc_stime.count(":") == 2
            if has_changed:
                info_stime = "Restarted in the last 24h (client's localtime: %s)" % svc_stime
            else:
                info_stime = "Started on %s" % svc_stime.replace("_", " ")

            check_state = 0
            for s in states:
                s_state = s[0]
                s_p_stime = s[1]
                s_p_state = s[2]
                if s_state == svc_state:
                    if s_p_stime != None:
                        if has_changed == s_p_stime:
                            check_state = s_p_state
                            break
                    else:
                        check_state = s_p_state
                        break

            verdict = ["OK", "WARN", "CRIT", "UNKNOWN"][check_state] if (0 <= check_state) and (check_state < 4) else "UNKNOWN"
            return {
                "changed": False,
                "msg": "Status: %s, %s" % (svc_state, info_stime),
                "data": {"state": verdict, "metrics": {}, "details": ""},
            }

    return _unknown("Service not found")


def _unknown(msg):
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }