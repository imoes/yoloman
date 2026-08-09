# Checkmk check "solaris_services_summary" -> read-only Starlark check module.
#
# Monitors SMF (Service Management Facility) services on Solaris. The original
# Checkmk solaris agent runs `svcs -H` and formats output into the
# `<<<solaris_services>>>` section. Since this translation runs on our agent
# (no Checkmk installed), we read the SAME on-host source the Checkmk agent
# reads: the `svcs` command.

def _empty_discovery():
    return {"changed": False, "msg": "no SMF services found",
            "data": {"discovery": []}}


def _count_summary(count):
    if count == 1:
        return "1 service"
    return "%d services" % count


def _state_label(svc_state):
    return svc_state.replace("_", " ")


def _grade_state(svc_state, maint_names, maint_state):
    if svc_state == "maintenance" and maint_state and maint_names:
        return maint_state, " (%s)" % ", ".join(maint_names)
    return 0, ""


def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["svcs", "-H"], mutates=False)
        if probe.rc != 0:
            return _empty_discovery()
        return {"changed": False, "msg": "discovered SMF services summary",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    item = params.get("item", "")

    probe = ctx.run(["svcs", "-H"], mutates=False)
    if probe.rc != 0:
        return {"changed": False,
                "msg": "no SMF services found (svcs unavailable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    out = probe.stdout
    if not out or not out.strip():
        return {"changed": False,
                "msg": "no SMF services found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    services_by_state = {}
    total = 0
    for line in out.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        fields = stripped.split()
        if len(fields) < 3:
            continue
        svc_state = fields[1]
        svc_descr = fields[-1]
        total = total + 1
        lst = services_by_state.get(svc_state, [])
        lst.append(svc_descr)
        services_by_state[svc_state] = lst

    maint_state = params.get("maintenance_state", 0)

    summary_line = _count_summary(total)
    details_lines = [summary_line]
    top_state_num = 0

    states = sorted(services_by_state.keys())
    for svc_state in states:
        names = services_by_state[svc_state]
        grade, extra = _grade_state(svc_state, names, maint_state)
        label = _state_label(svc_state)
        line = "%d %s%s" % (len(names), label, extra)
        details_lines.append(line)
        if grade > top_state_num:
            top_state_num = grade

    if top_state_num >= 2:
        verdict = "CRIT"
    elif top_state_num >= 1:
        verdict = "WARN"
    else:
        verdict = "OK"

    combined = "; ".join(details_lines)
    return {"changed": False,
            "msg": combined,
            "data": {
                "state": verdict,
                "metrics": {},
                "details": combined,
            }}