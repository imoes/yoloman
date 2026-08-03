# Checkmk oracle_logswitches → read-only Starlark check module
# Monitors Oracle log switches per instance; thresholds from params.

def _is_number(s):
    if s == None:
        return False
    if s == "":
        return False
    body = s
    if body[0] == "-" or body[0] == "+":
        body = body[1:]
    if body == "":
        return False
    i = 0
    seen_digit = False
    for ch in body:
        if ch == ".":
            if i != 0 and i != len(body) - 1:
                i = i + 1
                continue
            return False
        if ch < "0" or ch > "9":
            return False
        seen_digit = True
        i = i + 1
    return seen_digit

def _parse_int(s):
    if _is_number(s):
        return int(s)
    return None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "sqlplus not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "sqlplus failed: " + res.stderr,
                    "data": {"discovery": []}}
        login = ctx.run(["sqlplus", "-s", "/ as sysdba", "@/dev/stdin"],
                        mutates=False)
        if login.rc != 0:
            return {"changed": False, "msg": "oracle not available",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}
    item = params.get("item", "")
    warn = params.get("warn", 50)
    crit = params.get("crit", 100)
    lowarn = params.get("lowarn", -1)
    locrit = params.get("locrit", -1)
    if not _is_number(str(warn)) or not _is_number(str(crit)):
        warn = 50
        crit = 100
    if not _is_number(str(lowarn)) or not _is_number(str(locrit)):
        lowarn = -1
        locrit = -1
    warn = _parse_int(str(warn))
    crit = _parse_int(str(crit))
    lowarn = _parse_int(str(lowarn))
    locrit = _parse_int(str(locrit))
    if warn == None or crit == None or lowarn == None or locrit == None:
        return {"changed": False, "msg": "invalid threshold parameters",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["sqlplus", "-s", "/ as sysdba", "@/dev/stdin"],
                  mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "sqlplus not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "oracle not available: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    found = False
    logswitches = None
    for line in lines:
        f = line.split()
        if len(f) != 2:
            continue
        if f[0] == item:
            logswitches = _parse_int(f[1])
            if logswitches != None:
                found = True
            break
    if not found:
        return {"changed": False,
                "msg": "no logswitch data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK"
    if logswitches >= crit:
        state = "CRIT"
    elif logswitches >= warn:
        state = "WARN"
    if logswitches <= lowarn:
        state = "WARN"
    elif logswitches <= locrit:
        state = "CRIT"
    return {"changed": False,
            "msg": "Log switches in the last 60 minutes: " + str(logswitches),
            "data": {"state": state,
                     "metrics": {"logswitches": logswitches},
                     "details": item + " log switches = " + str(logswitches)}}