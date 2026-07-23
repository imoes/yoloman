def _is_ignored(name, patterns):
    for pattern in patterns:
        p = pattern
        if p.startswith("^"):
            p = p[1:]
        end_anchored = p.endswith("$")
        if end_anchored:
            p = p[:-1]
        if ".*" in p:
            parts = p.split(".*")
            matched = True
            pos = 0
            anchor_start = True
            for part in parts:
                if part == "":
                    anchor_start = False
                    continue
                if anchor_start:
                    if not name.startswith(part):
                        matched = False
                        break
                    pos = len(part)
                    anchor_start = False
                else:
                    idx = name.find(part, pos)
                    if idx == -1:
                        matched = False
                        break
                    pos = idx + len(part)
            if matched and end_anchored and pos != len(name):
                matched = False
            if matched:
                return True
        else:
            if end_anchored:
                if name == p:
                    return True
            else:
                if name.startswith(p):
                    return True
    return False

def _parse_services(stdout):
    services = []
    if not stdout.strip():
        return services
    raw = json.decode(stdout)
    if raw == None:
        return services
    if type(raw) == "dict":
        raw = [raw]
    if type(raw) != "list":
        return services
    for svc in raw:
        if type(svc) != "dict":
            continue
        name = svc.get("Name") or ""
        state_raw = svc.get("State") or ""
        start_mode_raw = svc.get("StartMode") or ""
        display_name = svc.get("DisplayName") or name
        state = state_raw.lower()
        start_mode = start_mode_raw.lower()
        if start_mode == "auto":
            start_type = "auto"
        elif start_mode == "manual":
            start_type = "demand"
        elif start_mode == "disabled":
            start_type = "disabled"
        else:
            start_type = start_mode
        services.append({
            "name": name,
            "state": state,
            "start_type": start_type,
            "description": display_name,
        })
    return services

def main(ctx, params):
    ps_cmd = (
        "Get-CimInstance Win32_Service | " +
        "Select-Object Name,State,StartMode,DisplayName | " +
        "ConvertTo-Json -Compress"
    )
    res = ctx.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_cmd],
        mutates=False,
        ok_codes=[0, 1, 2],
    )

    if params.get("_discover"):
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        services = _parse_services(res.stdout)
        if not services:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "",
                "params": {"ignored": [], "state_if_stopped": 0},
                "metrics": ["autostart_services", "stopped_services", "ignored_services"],
            }]},
        }

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "could not retrieve Windows services",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    services = _parse_services(res.stdout)
    if not services:
        return {
            "changed": False,
            "msg": "no services found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    ignored = params.get("ignored", [])
    state_if_stopped = params.get("state_if_stopped", 0)

    num_auto = 0
    num_blacklist = 0
    stoplist = []

    for svc in services:
        if svc["start_type"] != "auto":
            continue
        num_auto += 1
        if svc["state"] == "stopped":
            if _is_ignored(svc["name"], ignored):
                num_blacklist += 1
            else:
                stoplist.append(svc["name"])

    if stoplist and state_if_stopped == 2:
        final_state = "CRIT"
    elif stoplist and state_if_stopped == 1:
        final_state = "WARN"
    else:
        final_state = "OK"

    msg_parts = [
        "Autostart services: %d" % num_auto,
        "Stopped services: %d" % len(stoplist),
    ]
    if num_blacklist:
        msg_parts.append("Stopped but ignored: %d" % num_blacklist)

    details_parts = [
        "Autostart services: %d" % num_auto,
        "Services found in total: %d" % len(services),
    ]
    if stoplist:
        details_parts.append("Stopped services: %s" % ", ".join(stoplist))
    if num_blacklist:
        details_parts.append("Stopped but ignored: %d" % num_blacklist)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": final_state,
            "metrics": {
                "autostart_services": num_auto,
                "stopped_services": len(stoplist),
                "ignored_services": num_blacklist,
            },
            "details": "\n".join(details_parts),
        },
    }