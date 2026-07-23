INCOMPLETE_CALLS_CTR = "\\LS:CAA - Operations\\CAA - Incomplete calls per sec"
CREATE_LATENCY_CTR = "\\LS:USrv - Conference Mcu Allocator\\USrv - Create Conference Latency (msec)"
ALLOC_LATENCY_CTR = "\\LS:USrv - Conference Mcu Allocator\\USrv - Allocation Latency (msec)"

ALL_CTRS = [INCOMPLETE_CALLS_CTR, CREATE_LATENCY_CTR, ALLOC_LATENCY_CTR]


def _is_numeric(s):
    s = s.strip()
    if s.startswith("-"):
        s = s[1:]
    s2 = s.replace(".", "")
    return len(s2) > 0 and s2.isdigit()


def _parse_typeperf(stdout, n):
    data_lines = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped or not stripped.startswith('"'):
            continue
        parts = stripped.split('","')
        if len(parts) < 2:
            continue
        if not _is_numeric(parts[1].strip('"')):
            continue
        data_lines.append(stripped)
    if not data_lines:
        return None
    parts = data_lines[-1].split('","')
    values = []
    for i in range(1, n + 1):
        if i >= len(parts):
            values.append(None)
        else:
            v = parts[i].strip('"').strip()
            if _is_numeric(v):
                values.append(float(v))
            else:
                values.append(None)
    return values


def _grade(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _worst(states):
    if "CRIT" in states:
        return "CRIT"
    if "WARN" in states:
        return "WARN"
    if states:
        return "OK"
    return "UNKNOWN"


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["typeperf"] + ALL_CTRS + ["-sc", "1"], mutates=False, ok_codes=[0, 1])
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        values = _parse_typeperf(res.stdout, 3)
        if values == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{
                "item": "",
                "params": {
                    "incomplete_calls_warn": 20.0,
                    "incomplete_calls_crit": 40.0,
                    "create_conference_latency_warn": 5000.0,
                    "create_conference_latency_crit": 10000.0,
                    "allocation_latency_warn": 5000.0,
                    "allocation_latency_crit": 10000.0,
                },
                "metrics": ["caa_incomplete_calls", "usrv_create_conference_latency", "usrv_allocation_latency"],
            }]},
        }

    res = ctx.run(["typeperf"] + ALL_CTRS + ["-si", "1", "-sc", "2"], mutates=False, ok_codes=[0, 1])
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Skype conferencing counters unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    values = _parse_typeperf(res.stdout, 3)
    if values == None:
        return {
            "changed": False,
            "msg": "Failed to parse typeperf output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    incomplete_calls = values[0]
    create_latency = values[1]
    alloc_latency = values[2]

    inc_warn = float(params.get("incomplete_calls_warn", 20.0))
    inc_crit = float(params.get("incomplete_calls_crit", 40.0))
    cl_warn = float(params.get("create_conference_latency_warn", 5000.0))
    cl_crit = float(params.get("create_conference_latency_crit", 10000.0))
    al_warn = float(params.get("allocation_latency_warn", 5000.0))
    al_crit = float(params.get("allocation_latency_crit", 10000.0))

    states = []
    msgs = []
    metrics = {}

    if incomplete_calls != None:
        states.append(_grade(incomplete_calls, inc_warn, inc_crit))
        msgs.append("Incomplete calls/sec: %f" % incomplete_calls)
        metrics["caa_incomplete_calls"] = incomplete_calls

    if create_latency != None:
        states.append(_grade(create_latency, cl_warn, cl_crit))
        msgs.append("Create conference latency: %d ms" % int(create_latency))
        metrics["usrv_create_conference_latency"] = create_latency

    if alloc_latency != None:
        states.append(_grade(alloc_latency, al_warn, al_crit))
        msgs.append("Allocation latency: %d ms" % int(alloc_latency))
        metrics["usrv_allocation_latency"] = alloc_latency

    if not states:
        return {
            "changed": False,
            "msg": "No counter values retrieved",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {"state": _worst(states), "metrics": metrics, "details": ""},
    }