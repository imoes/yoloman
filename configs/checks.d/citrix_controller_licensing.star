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

def _parse_section(content):
    section = {
        "version": None,
        "state": None,
        "licensing_grace_state": None,
        "licensing_server_state": None,
        "session": None,
        "desktop_count": None,
        "active_site_services": None,
    }
    session = {"active": 0, "inactive": 0}
    lines = content.splitlines()
    table = []
    i = 0
    for line in lines:
        f = line.split()
        if len(f) >= 2:
            table.append(f)
        elif len(f) == 1:
            table.append([f[0]])
        else:
            table.append([])
        i = i + 1
    j = 0
    for f in table:
        j = j + 1
        if len(f) == 0:
            continue
        head = f[0]
        if head == "ControllerVersion" and len(f) >= 2:
            section["version"] = f[1]
        elif head == "ControllerState" and len(f) >= 2:
            section["state"] = f[1]
        elif head == "ControllerState":
            section["state"] = "Error"
        elif head == "LicensingGraceState" and len(f) >= 2 and section["licensing_grace_state"] == None:
            section["licensing_grace_state"] = f[1]
        elif head == "LicensingServerState" and len(f) >= 2 and section["licensing_server_state"] == None:
            section["licensing_server_state"] = f[1]
        elif head == "TotalFarmActiveSessions" and len(f) >= 2:
            v = f[1]
            session["active"] = int(v) if v.isdigit() else 0
            section["session"] = dict(session)
        elif head == "TotalFarmInactiveSessions" and len(f) >= 2:
            v = f[1]
            session["inactive"] = int(v) if v.isdigit() else 0
            section["session"] = dict(session)
        elif head == "DesktopsRegistered" and len(f) >= 2:
            v = f[1]
            if v.isdigit():
                section["desktop_count"] = int(v)
            else:
                section["desktop_count"] = "Error"
        elif head == "ActiveSiteServices":
            section["active_site_services"] = " ".join(f[1:])
    return section

def _probe_section(ctx, params):
    probe = ctx.run(["citrix_controller", "--section"], mutates=False)
    if probe.rc == 127:
        return None, "citrix_controller not installed"
    if probe.rc != 0:
        return None, "citrix_controller probe failed: " + probe.stderr
    return _parse_section(probe.stdout), ""

def main(ctx, params):
    if params.get("_discover"):
        section, err = _probe_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": err,
                    "data": {"discovery": [],
                             "host_labels": {"cmk/citrix_controller": "not_installed"}}}
        if section["licensing_server_state"] == None and section["licensing_grace_state"] == None:
            return {"changed": False, "msg": "no licensing data",
                    "data": {"discovery": [],
                             "host_labels": {"cmk/citrix_controller": "present"}}}
        return {"changed": False, "msg": "discovered Citrix Controller Licensing",
                "data": {"discovery": [
                    {"item": "",
                     "params": {},
                     "metrics": ["licensing_server_state", "licensing_grace_state"]},
                ],
                "host_labels": {"cmk/citrix_controller": "present"}}}

    section, err = _probe_section(ctx, params)
    if section == None:
        return {"changed": False,
                "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": err}}

    results = []
    metrics = {}

    server_state = section["licensing_server_state"]
    if server_state != None:
        state, text = SERVER_STATES.get(server_state, ("UNKNOWN", "unknown[%s]" % server_state))
        results.append({"state": state,
                        "summary": "Licensing Server State: " + text})
    else:
        results.append({"state": "UNKNOWN",
                        "summary": "Licensing Server State: not available"})

    grace_state = section["licensing_grace_state"]
    if grace_state != None:
        state, text = GRACE_STATES.get(grace_state, ("UNKNOWN", "unknown[%s]" % grace_state))
        results.append({"state": state,
                        "summary": "Licensing Grace State: " + text})
    else:
        results.append({"state": "UNKNOWN",
                        "summary": "Licensing Grace State: not available"})

    order = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
    worst = "OK"
    k = 0
    for r in results:
        k = k + 1
        if order.get(r["state"], 2) > order.get(worst, 0):
            worst = r["state"]

    msg = "; ".join([r["summary"] for r in results])
    return {"changed": False,
            "msg": msg,
            "data": {"state": worst,
                     "metrics": metrics,
                     "details": "\n".join([r["summary"] for r in results])}}