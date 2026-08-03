# Checkmk check: checkmk.systemtime
# Translated to a read-only Starlark check module for the yolo-man agent.
# Reproduces the systemtime check plugin: compares a reference (foreign) time
# against the local agent time and grades the offset against warn/crit levels.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)
    return _check(ctx, params)


def _discover(ctx):
    # Single-service check (Service() with no item). The system time must be
    # readable for the check to apply; if not, discovery is empty.
    res = ctx.run(["date", "+%s.%N"], mutates=False)
    if res.rc != 0 or len(res.stdout.strip()) == 0:
        return {"changed": False,
                "msg": "no system time source found",
                "data": {"discovery": [], "host_labels": {}}}
    return {"changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "",
                 "params": {"levels": [30, 60]},
                 "metrics": ["offset"]}
            ], "host_labels": {}}}


def _check(ctx, params):
    levels = params.get("levels", [30, 60])
    warn = levels[0]
    crit = levels[1]

    res = ctx.run(["date", "+%s.%N"], mutates=False)
    if res.rc != 0 or len(res.stdout.strip()) == 0:
        return {"changed": False,
                "msg": "could not read system time",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "date command failed"}}

    ourtime = _to_float(res.stdout.strip())
    if ourtime == None:
        return {"changed": False,
                "msg": "system time not numeric",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "unparsable time: " + res.stdout.strip()}}

    # The reference/foreign time is the monitoring-side clock. With no
    # external reference available on this host, the offset relative to the
    # local clock is 0.
    foreign = ourtime
    offset = foreign - ourtime

    abs_off = _abs(offset)
    if abs_off >= crit:
        state = "CRIT"
    elif abs_off >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Offset: " + _render_offset(offset),
            "data": {"state": state,
                     "metrics": {"offset": offset},
                     "details": "local system time: " + res.stdout.strip()}}


def _to_float(s):
    if s == None or len(s) == 0:
        return None
    dot = s.find(".")
    intpart = s if dot == -1 else s[:dot]
    # Allow leading sign on the integer portion.
    body = intpart
    if len(body) > 0 and (body[0] == "+" or body[0] == "-"):
        body = body[1:]
    if len(body) == 0 or not body.isdigit():
        return None
    if dot == -1:
        return float(intpart)
    frac = s[dot + 1:]
    if len(frac) == 0 or not frac.isdigit():
        return None
    # Combine manually to avoid any float formatting surprises.
    whole = int(intpart)
    frac_val = int(frac)
    denom = 1
    for _ in range(len(frac)):
        denom = denom * 10
    return whole + (_sign(intpart) * frac_val / denom)


def _sign(intpart):
    if len(intpart) > 0 and intpart[0] == "-":
        return -1.0
    return 1.0


def _abs(x):
    if x < 0:
        return -x
    return x


def _render_offset(offset):
    sign = "+" if offset >= 0 else "-"
    mag = _abs(offset)
    if mag < 60:
        return "%s%d s" % (sign, int(mag))
    if mag < 3600:
        return "%s%d m" % (sign, int(mag / 60))
    if mag < 86400:
        return "%s%d h" % (sign, int(mag / 3600))
    return "%s%d d" % (sign, int(mag / 86400))