def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["citrix_controller_probe"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "citrix_controller not installed",
                    "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}
        section = parse_section(res.stdout)
        services = []
        if section.get("version") != None or section.get("state") != None:
            services.append({"item": "Citrix Controller State", "params": {}, "metrics": []})
        if section.get("licensing_server_state") != None or section.get("licensing_grace_state") != None:
            services.append({"item": "Citrix Controller Licensing", "params": {}, "metrics": []})
        if section.get("session") != None:
            services.append({"item": "Citrix Total Sessions", "params": {}, "metrics": ["total_sessions", "active_sessions", "inactive_sessions"]})
        if section.get("desktop_count") != None:
            services.append({"item": "Citrix Desktops Registered", "params": {}, "metrics": ["registered_desktops"]})
        if section.get("active_site_services") != None:
            services.append({"item": "Citrix Active Site Services", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(services),
                "data": {"discovery": services, "host_labels": {"cmk/os_family": "linux"}}}
    item = params.get("item", "")
    res = ctx.run(["citrix_controller_probe"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "citrix_controller not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = parse_section(res.stdout)
    if item == "Citrix Controller State":
        state = section.get("state")
        if state == None:
            return {"changed": False, "msg": "no state", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if state == "Error":
            return {"changed": False, "msg": "unknown", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if state == "Active":
            return {"changed": False, "msg": state, "data": {"state": "OK", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": state, "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if item == "Citrix Controller Licensing":
        results = []
        raw = section.get("licensing_server_state")
        if raw != None:
            pair = SERVER_STATES.get(raw, ("UNKNOWN", "unknown[" + str(raw) + "]"))
            results.append((pair[0], "Licensing Server State: " + pair[1]))
        raw = section.get("licensing_grace_state")
        if raw != None:
            pair = GRACE_STATES.get(raw, ("UNKNOWN", "unknown[" + str(raw) + "]"))
            results.append((pair[0], "Licensing Grace State: " + pair[1]))
        if len(results) > 0:
            best = "OK"
            for s, m in results:
                if s == "CRIT":
                    best = "CRIT"
                    break
                if s == "WARN" and best != "CRIT":
                    best = "WARN"
            msgs = []
            for s, m in results:
                msgs.append(m)
            return {"changed": False, "msg": "; ".join(msgs), "data": {"state": best, "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no licensing state", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item == "Citrix Total Sessions":
        session = section.get("session")
        if session == None:
            session = {"active": 0, "inactive": 0}
        active = session.get("active", 0)
        inactive = session.get("inactive", 0)
        total = active + inactive
        metrics = {"total_sessions": total, "active_sessions": active, "inactive_sessions": inactive}
        lvl_total = params.get("total")
        lvl_active = params.get("active")
        lvl_inactive = params.get("inactive")
        warn = params.get("warn")
        crit = params.get("crit")
        state = "OK"
        if lvl_total != None:
            w = lvl_total[0]
            c = lvl_total[1]
            if total >= c:
                state = "CRIT"
            elif total >= w:
                state = "WARN"
        if lvl_active != None:
            w = lvl_active[0]
            c = lvl_active[1]
            if active >= c:
                state = "CRIT"
            elif active >= w:
                state = "WARN"
        if lvl_inactive != None:
            w = lvl_inactive[0]
            c = lvl_inactive[1]
            if inactive >= c:
                state = "CRIT"
            elif inactive >= w:
                state = "WARN"
        if warn != None:
            w = warn[0]
            c = warn[1]
            if total >= c:
                state = "CRIT"
            elif total >= w:
                state = "WARN"
        if crit != None and total >= crit:
            state = "CRIT"
        msg = "total: %d, active: %d, inactive: %d" % (total, active, inactive)
        return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}
    if item == "Citrix Desktops Registered":
        dc = section.get("desktop_count")
        if dc == None:
            return {"changed": False, "msg": "No desktops registered", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if dc == "Error":
            return {"changed": False, "msg": "No desktops registered", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        levels = params.get("levels")
        levels_lower = params.get("levels_lower")
        warn = params.get("warn")
        crit = params.get("crit")
        state = "OK"
        if levels != None:
            w = levels[0]
            c = levels[1]
            if dc >= c:
                state = "CRIT"
            elif dc >= w:
                state = "WARN"
        if levels_lower != None:
            w = levels_lower[0]
            c = levels_lower[1]
            if dc <= c:
                state = "CRIT"
            elif dc <= w:
                state = "WARN"
        if warn != None:
            w = warn[0]
            c = warn[1]
            if dc >= c:
                state = "CRIT"
            elif dc >= w:
                state = "WARN"
        if crit != None and dc >= crit:
            state = "CRIT"
        return {"changed": False, "msg": "%d desktops registered" % dc,
                "data": {"state": state, "metrics": {"registered_desktops": dc}, "details": ""}}
    if item == "Citrix Active Site Services":
        services = section.get("active_site_services")
        if services == None:
            return {"changed": False, "msg": "no active site services", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if services == "":
            return {"changed": False, "msg": "No services", "data": {"state": "OK", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": services, "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "unknown item: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


SERVER_STATES = {
    "ServerNotSpecified": ("CRIT", "server not specified"),
    "NotConnected": ("WARN", "not connected"),
    "OK": ("OK", "OK"),
    "LicenseNotInstalled": ("CRIT", "license not installed"),
    "LicenseExpired": ("CRIT", "licenese expired"),
    "Incompatible": ("CRIT", "incompatible"),
    "Failed": ("CRIT", "failed"),
}

GRACE_STATES = {
    "NotActive": ("OK", "not active"),
    "Active": ("CRIT", "active"),
    "InOutOfBoxGracePeriod": ("WARN", "in-out-of-box grace period"),
    "InSupplementalGracePeriod": ("WARN", "in-supplemental grace period"),
    "InEmergencyGracePeriod": ("CRIT", "in-emergency grace period"),
    "GracePeriodExpired": ("CRIT", "grace period expired"),
    "Expired": ("CRIT", "expired"),
}


def parse_section(stdout):
    section = {}
    session = {"active": 0, "inactive": 0}
    for line in stdout.splitlines():
        f = line.split()
        if not f:
            continue
        key = f[0]
        if key == "ControllerVersion" and len(f) >= 2:
            section["version"] = f[1]
        elif key == "ControllerState":
            if len(f) >= 2:
                section["state"] = f[1]
            else:
                section["state"] = "Error"
        elif key == "LicensingGraceState" and len(f) >= 2:
            if section.get("licensing_grace_state") == None:
                section["licensing_grace_state"] = f[1]
        elif key == "LicensingServerState" and len(f) >= 2:
            if section.get("licensing_server_state") == None:
                section["licensing_server_state"] = f[1]
        elif key == "TotalFarmActiveSessions" and len(f) >= 2:
            if f[1].isdigit():
                session["active"] = int(f[1])
                section["session"] = session
        elif key == "TotalFarmInactiveSessions" and len(f) >= 2:
            if f[1].isdigit():
                session["inactive"] = int(f[1])
                section["session"] = session
        elif key == "DesktopsRegistered" and len(f) >= 2:
            if f[1].isdigit():
                section["desktop_count"] = int(f[1])
            else:
                section["desktop_count"] = "Error"
        elif key == "ActiveSiteServices":
            section["active_site_services"] = " ".join(f[1:])
    return section