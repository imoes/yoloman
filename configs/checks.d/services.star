_START_MODE_MAP = {
    "auto": "auto",
    "manual": "demand",
    "disabled": "disabled",
    "boot": "boot",
    "system": "system",
}

_STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

def _norm_start(raw):
    low = raw.strip().lower()
    return _START_MODE_MAP.get(low, low)

def _match_rule(params, svc_state, svc_start):
    for rule in params.get("states", [["running", None, 0]]):
        t_state = rule[0]
        t_start = rule[1] if len(rule) > 1 else None
        mon = rule[2] if len(rule) > 2 else 0
        state_ok = (t_state == None) or (t_state == svc_state)
        start_ok = (t_start == None) or (t_start == svc_start)
        if state_ok and start_ok:
            return int(mon)
    return int(params.get("else", 2))

def _query_services(ctx):
    res = ctx.run(
        [
            "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
            "Get-WmiObject Win32_Service | ForEach-Object { $_.Name + '|' + $_.State + '|' + $_.StartMode + '|' + $_.DisplayName }",
        ],
        mutates=False,
        ok_codes=[0, 1],
    )
    if res.rc != 0:
        return None
    svcs = []
    for raw in res.stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("|", 3)
        if len(parts) < 4:
            continue
        svcs.append({
            "name": parts[0].strip(),
            "state": parts[1].strip().lower(),
            "start_type": _norm_start(parts[2]),
            "desc": parts[3].strip(),
        })
    return svcs

def main(ctx, params):
    svcs = _query_services(ctx)

    if params.get("_discover"):
        if svcs == None:
            return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}
        out = [
            {
                "item": s["name"],
                "params": {"states": [["running", None, 0]], "else": 2, "additional_servicenames": []},
                "metrics": [],
            }
            for s in svcs
        ]
        return {
            "changed": False,
            "msg": "discovered %d services" % len(out),
            "data": {"discovery": out},
        }

    if svcs == None:
        return {
            "changed": False,
            "msg": "failed to query Windows services",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    item = params.get("item", "")
    additional_names = params.get("additional_servicenames", [])

    found = None
    for s in svcs:
        if s["name"] == item or s["desc"] == item:
            found = s
            break
    if found == None:
        for s in svcs:
            if s["name"] in additional_names:
                found = s
                break

    if found == None:
        else_n = int(params.get("else", 2))
        return {
            "changed": False,
            "msg": "service not found",
            "data": {
                "state": _STATE_NAMES.get(else_n, "UNKNOWN"),
                "metrics": {},
                "details": "",
            },
        }

    mon = _match_rule(params, found["state"], found["start_type"])
    return {
        "changed": False,
        "msg": "%s: %s (start type is %s)" % (found["desc"], found["state"], found["start_type"]),
        "data": {
            "state": _STATE_NAMES.get(mon, "UNKNOWN"),
            "metrics": {},
            "details": "",
        },
    }