def _to_service(name, status, description):
    cur_state, start_type = (status.split("/", 1) + ["unknown"])[:2] if "/" in status else (status, "unknown")
    return {"name": name, "state": cur_state, "start_type": start_type, "description": description}


def _parse_services(raw_lines):
    section = []
    for line in raw_lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        status = parts[1]
        description = " ".join(parts[2:])
        section.append(_to_service(name, status, description))
    return section


def _matches_item(service, item):
    return item in (service["name"], service["description"])


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                       "Get-Service | ForEach-Object { $_.Name + ' ' + ($_.Status.ToString() + '/' + $_.StartType.ToString()) + ' ' + $_.DisplayName }"],
                      mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no Windows services found", "data": {"discovery": []}}
        section = _parse_services(res.stdout.splitlines())
        if not section:
            return {"changed": False, "msg": "no Windows services found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered service summary",
            "data": {"discovery": [{"item": "", "params": {"ignored": [], "state_if_stopped": 0}, "metrics": []}]},
        }

    item = params.get("item", "")
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                   "Get-Service | ForEach-Object { $_.Name + ' ' + ($_.Status.ToString() + '/' + $_.StartType.ToString()) + ' ' + $_.DisplayName }"],
                  mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no Windows services found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_services(res.stdout.splitlines())
    if not section:
        return {"changed": False, "msg": "no Windows services found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ignored = params.get("ignored", [])
    state_if_stopped = params.get("state_if_stopped", 0)

    num_blacklist = 0
    num_auto = 0
    stoplist = []

    for service in section:
        if service["start_type"] != "auto":
            continue
        num_auto += 1
        if service["state"] == "stopped":
            matched = False
            for srv in ignored:
                if service["name"].find(srv) != -1 or service["description"].find(srv) != -1:
                    matched = True
                    break
            if matched:
                num_blacklist += 1
            else:
                stoplist.append(service["name"])

    overall_state = "OK"
    if stoplist:
        if state_if_stopped >= 2:
            overall_state = "CRIT"
        elif state_if_stopped >= 1:
            overall_state = "WARN"

    summary = "Autostart services: %d, Stopped services: %d" % (num_auto, len(stoplist))
    details = "Autostart services: %d\nServices found in total: %d\nStopped services: %s" % (
        num_auto, len(section), ", ".join(stoplist) if stoplist else "none")

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall_state,
            "metrics": {"num_auto": num_auto, "num_stoplist": len(stoplist)},
            "details": details,
        },
    }